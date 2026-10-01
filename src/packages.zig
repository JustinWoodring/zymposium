//! The registry of packages added with `zymposium add`.
//!
//! These are packages zymposium manages itself, outside both zest and any
//! project's dependency graph — the third skill source, and the one that lets
//! a skill be updated from a package reference rather than a tool.
//!
//! Stored at `$XDG_DATA_HOME/zymposium/packages.json`.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const state = @import("state.zig");
const sources = @import("sources.zig");
const util = @import("util.zig");

pub const Entry = struct {
    /// Package name. This aliases the registry's map key rather than owning a
    /// second copy, so `Registry.deinit` frees it once, as the key.
    name: []const u8,
    /// The original argument: a local path or a git URL.
    source: []u8,
    /// Directory the package was fetched into; equals `source` for a local
    /// path added in place.
    root: []u8,

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.source);
        gpa.free(self.root);
    }
};

pub const Registry = struct {
    version: u32 = 1,
    /// Insertion-ordered by package name; keys and entries are gpa-owned.
    packages: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Registry) void {
        for (self.packages.keys(), self.packages.values()) |k, *v| {
            self.gpa.free(k);
            v.deinit(self.gpa);
        }
        self.packages.deinit(self.gpa);
    }

    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !Registry {
        const bytes = util.readFileAlloc(Io.Dir.cwd(), io, gpa, path) catch |err| switch (err) {
            error.FileNotFound => return .{ .gpa = gpa },
            else => |e| return e,
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    pub fn save(self: *const Registry, io: Io, path: []const u8) !void {
        const bytes = try self.render();
        defer self.gpa.free(bytes);
        if (std.fs.path.dirname(path)) |dir| {
            Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        try util.writeFileAtomic(Io.Dir.cwd(), io, self.gpa, path, bytes);
    }

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Registry {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
            return error.InvalidRegistry;
        defer parsed.deinit();

        var reg: Registry = .{ .gpa = gpa };
        errdefer reg.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidRegistry,
        };
        if (root.get("version")) |v| switch (v) {
            .integer => |n| reg.version = std.math.cast(u32, n) orelse 1,
            else => {},
        };
        const pkgs = switch (root.get("packages") orelse return reg) {
            .object => |o| o,
            else => return error.InvalidRegistry,
        };

        var it = pkgs.iterator();
        while (it.next()) |entry| {
            const obj = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return error.InvalidRegistry,
            };
            const name = try gpa.dupe(u8, entry.key_ptr.*);
            errdefer gpa.free(name);
            const source = try field(gpa, obj, "source");
            errdefer gpa.free(source);
            const root_dir = try field(gpa, obj, "root");
            try reg.packages.put(gpa, name, .{ .name = name, .source = source, .root = root_dir });
        }
        return reg;
    }

    fn field(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
        const v = obj.get(key) orelse return error.InvalidRegistry;
        return switch (v) {
            .string => |s| gpa.dupe(u8, s),
            else => error.InvalidRegistry,
        };
    }

    pub fn render(self: *const Registry) ![]u8 {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\n  \"version\": {d},\n  \"packages\": {{", .{self.version});
        for (self.packages.keys(), self.packages.values(), 0..) |key, e, i| {
            try w.print("{s}\n    {f}: {{\n", .{
                if (i == 0) "" else ",",
                std.json.fmt(key, .{}),
            });
            try w.print("      \"source\": {f},\n", .{std.json.fmt(e.source, .{})});
            try w.print("      \"root\": {f}\n    }}", .{std.json.fmt(e.root, .{})});
        }
        if (self.packages.count() > 0) try w.writeAll("\n  ");
        try w.writeAll("}\n}\n");
        return self.gpa.dupe(u8, aw.written());
    }

    /// Add or replace a package entry. All strings are copied.
    pub fn put(self: *Registry, name: []const u8, source: []const u8, root: []const u8) !void {
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_source = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(owned_source);
        const owned_root = try self.gpa.dupe(u8, root);
        errdefer self.gpa.free(owned_root);

        // Replacing frees the previous key as well as its entry, so repeated
        // `zymposium add` calls do not leak. The map stops referencing the key
        // before it is released.
        if (self.packages.getIndex(name)) |idx| {
            const old_key = self.packages.keys()[idx];
            const old = self.packages.values()[idx];
            _ = self.packages.orderedRemove(name);
            self.gpa.free(old_key);
            var old_mut = old;
            old_mut.deinit(self.gpa);
        }
        try self.packages.put(self.gpa, owned_name, .{
            .name = owned_name,
            .source = owned_source,
            .root = owned_root,
        });
    }

    /// Turn every registered package into a skill source candidate.
    pub fn toCandidates(self: *const Registry, gpa: std.mem.Allocator, io: Io) ![]sources.Candidate {
        var out: std.ArrayList(sources.Candidate) = .empty;
        errdefer {
            for (out.items) |*c| c.deinit(gpa);
            out.deinit(gpa);
        }
        for (self.packages.values()) |e| {
            const git = @import("git.zig");
            const url = git.normalizeGitUrl(e.source);
            const commit = if (git.isGitUrl(url))
                git.headCommit(gpa, io, e.root) catch ""
            else
                "";
            try out.append(gpa, .{
                .provider = try gpa.dupe(u8, e.name),
                .source_kind = .package,
                .source_url = try gpa.dupe(u8, url),
                .commit = try gpa.dupe(u8, commit),
                .version = try gpa.dupe(u8, ""),
                .root = try gpa.dupe(u8, e.root),
            });
        }
        return out.toOwnedSlice(gpa);
    }
};

test "registry round trips through render and parse" {
    const gpa = std.testing.allocator;
    var reg: Registry = .{ .gpa = gpa };
    defer reg.deinit();
    try reg.put("zig-cc", "https://github.com/zig-cc/zig-cc", "/data/pkgs/zig-cc");
    try reg.put("local", "/home/u/src/local", "/home/u/src/local");

    const text = try reg.render();
    defer gpa.free(text);

    var reloaded = try Registry.parse(gpa, text);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.packages.count());
    try std.testing.expectEqualStrings(
        "https://github.com/zig-cc/zig-cc",
        reloaded.packages.get("zig-cc").?.source,
    );
    try std.testing.expectEqualStrings("/home/u/src/local", reloaded.packages.get("local").?.root);
}

test "put replaces rather than duplicating" {
    const gpa = std.testing.allocator;
    var reg: Registry = .{ .gpa = gpa };
    defer reg.deinit();
    try reg.put("a", "url1", "/r1");
    try reg.put("a", "url2", "/r2");
    try std.testing.expectEqual(@as(usize, 1), reg.packages.count());
    try std.testing.expectEqualStrings("url2", reg.packages.get("a").?.source);
    try std.testing.expectEqualStrings("/r2", reg.packages.get("a").?.root);
}

test "parse tolerates an empty registry and rejects junk" {
    const gpa = std.testing.allocator;
    {
        var reg = try Registry.parse(gpa, "{}");
        defer reg.deinit();
        try std.testing.expectEqual(@as(usize, 0), reg.packages.count());
    }
    {
        var reg = try Registry.parse(gpa,
            \\{"version":1,"packages":{"a":{"source":"u","root":"/r"}}}
        );
        defer reg.deinit();
        try std.testing.expectEqual(@as(usize, 1), reg.packages.count());
    }
    try std.testing.expectError(error.InvalidRegistry, Registry.parse(gpa, "{ not json"));
    try std.testing.expectError(error.InvalidRegistry, Registry.parse(gpa, "[1]"));
    // A package missing its root is corrupt, not skippable: sync depends on it.
    try std.testing.expectError(
        error.InvalidRegistry,
        Registry.parse(gpa,
            \\{"version":1,"packages":{"a":{"source":"u"}}}
        ),
    );
}

test "source_kind of added packages is package" {
    const gpa = std.testing.allocator;
    var reg: Registry = .{ .gpa = gpa };
    defer reg.deinit();
    try reg.put("a", "/local/path", "/local/path");
    const cands = try reg.toCandidates(gpa, std.testing.io);
    defer sources.freeCandidates(gpa, cands);
    try std.testing.expectEqual(@as(usize, 1), cands.len);
    try std.testing.expectEqual(state.SourceKind.package, cands[0].source_kind);
    try std.testing.expectEqualStrings("a", cands[0].provider);
}
