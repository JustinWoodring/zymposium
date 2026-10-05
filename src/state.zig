//! The provisioning manifest (`state.json`): which skills zymposium has placed,
//! where they came from, and exactly which paths it owns.
//!
//! Ownership is the point of this file. zymposium only ever deletes a path
//! that appears here, so hand-written skills sitting next to provisioned ones
//! are never touched.
//!
//! Schema (version 1):
//! {
//!   "version": 1,
//!   "skills": {
//!     "<provider>\\u0000<skill-name>": {
//!       "name": "<skill-name>",
//!       "provider": "<package name>",
//!       "source_kind": "zest_tool" | "project_dep" | "package",
//!       "source_url": "...",
//!       "commit": "<sha>",
//!       "version": "<label>",
//!       "skill_path": "<absolute path of the skill directory>",
//!       "description": "..." | null,
//!       "provisioned_at": "<RFC 3339 UTC>",
//!       "links": [
//!         { "agent": "claude", "scope": "global", "path": "...",
//!           "mode": "symlink", "project_root": null }
//!       ]
//!     }
//!   }
//! }
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

pub const ScopeKind = enum {
    global,
    project,

    pub fn parse(s: []const u8) ?ScopeKind {
        if (std.mem.eql(u8, s, "global")) return .global;
        if (std.mem.eql(u8, s, "project")) return .project;
        return null;
    }

    pub fn name(k: ScopeKind) []const u8 {
        return @tagName(k);
    }
};

pub const SourceKind = enum {
    /// A CLI tool installed by zest; skills live in zest's staged clone.
    zest_tool,
    /// A dependency of the current project's build.zig.zon graph.
    project_dep,
    /// A package added explicitly with `zymposium add`.
    package,

    pub fn parse(s: []const u8) ?SourceKind {
        inline for (@typeInfo(SourceKind).@"enum".field_names) |f| {
            if (std.mem.eql(u8, s, f)) return @field(SourceKind, f);
        }
        return null;
    }

    pub fn name(k: SourceKind) []const u8 {
        return @tagName(k);
    }
};

/// One materialized path zymposium owns.
pub const Link = struct {
    /// Agent id, from `agents.all`.
    agent: []u8,
    scope: ScopeKind,
    /// Absolute path of the skill inside the agent's skills directory.
    path: []u8,
    /// How the path was materialized, for display and for re-linking.
    mode: util.Materialized,
    /// Project root, set only for project-scoped links.
    project_root: ?[]u8,

    pub fn deinit(self: *Link, gpa: std.mem.Allocator) void {
        gpa.free(self.agent);
        gpa.free(self.path);
        if (self.project_root) |r| gpa.free(r);
    }
};

pub const Skill = struct {
    name: []u8,
    /// Package that supplied the skill; a skill name is claimed by one provider.
    provider: []u8,
    source_kind: SourceKind,
    source_url: []u8,
    commit: []u8,
    version: []u8,
    /// Absolute path of the skill directory in its source package.
    skill_path: []u8,
    description: ?[]u8,
    provisioned_at: []u8,
    links: []Link,

    pub fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.provider);
        gpa.free(self.source_url);
        gpa.free(self.commit);
        gpa.free(self.version);
        gpa.free(self.skill_path);
        if (self.description) |d| gpa.free(d);
        gpa.free(self.provisioned_at);
        for (self.links) |*l| l.deinit(gpa);
        gpa.free(self.links);
    }
};

pub const State = struct {
    version: u32 = 1,
    /// Insertion-ordered by skill name; keys and all strings are gpa-owned.
    skills: std.StringArrayHashMapUnmanaged(Skill) = .empty,
    gpa: std.mem.Allocator,

    /// Canonical storage key for a provider's skill. A NUL separator cannot
    /// occur in either identifier and keeps same-named skills from different
    /// The manifest JSON escapes this NUL byte as `\\u0000`.
    pub fn identityKey(gpa: std.mem.Allocator, provider: []const u8, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ provider, name });
    }

    pub const Selector = union(enum) {
        found: []const u8,
        missing,
        ambiguous,
    };

    /// Resolve `provider/name`, or a bare skill name when it is unique.
    pub fn resolveSelector(self: *const State, selector: []const u8) Selector {
        if (self.skills.contains(selector)) return .{ .found = self.skills.keys()[self.skills.getIndex(selector).?] };
        if (std.mem.indexOfScalar(u8, selector, '/')) |slash| {
            const provider = selector[0..slash];
            const name = selector[slash + 1 ..];
            for (self.skills.keys(), self.skills.values()) |key, skill| {
                if (std.mem.eql(u8, skill.provider, provider) and std.mem.eql(u8, skill.name, name)) {
                    return .{ .found = key };
                }
            }
            return .missing;
        }
        var match: ?[]const u8 = null;
        for (self.skills.keys(), self.skills.values()) |key, skill| {
            if (!std.mem.eql(u8, skill.name, selector)) continue;
            if (match != null) return .ambiguous;
            match = key;
        }
        return if (match) |key| .{ .found = key } else .missing;
    }

    pub fn deinit(self: *State) void {
        // StringArrayHashMapUnmanaged does not own its keys, so the skill
        // names it holds are freed here alongside the values.
        for (self.skills.keys(), self.skills.values()) |k, *s| {
            self.gpa.free(k);
            s.deinit(self.gpa);
        }
        self.skills.deinit(self.gpa);
    }

    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) !State {
        const bytes = util.readFileAlloc(Io.Dir.cwd(), io, gpa, path) catch |err| switch (err) {
            error.FileNotFound => return .{ .gpa = gpa },
            else => |e| return e,
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    pub fn save(self: *const State, io: Io, path: []const u8) !void {
        const bytes = try self.render();
        defer self.gpa.free(bytes);
        if (std.fs.path.dirname(path)) |dir| {
            Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        try util.writeFileAtomic(Io.Dir.cwd(), io, self.gpa, path, bytes);
    }

    /// Parse manifest bytes. Unknown fields are ignored; missing fields fall
    /// back to empty strings so a manifest written by an older zymposium still
    /// loads; structurally wrong input is `error.InvalidState`.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !State {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch
            return error.InvalidState;
        defer parsed.deinit();

        var state: State = .{ .gpa = gpa };
        errdefer state.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidState,
        };
        if (root.get("version")) |v| switch (v) {
            .integer => |n| state.version = std.math.cast(u32, n) orelse 1,
            else => {},
        };
        const skills = switch (root.get("skills") orelse return state) {
            .object => |o| o,
            else => return error.InvalidState,
        };

        var it = skills.iterator();
        while (it.next()) |entry| {
            const obj = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return error.InvalidState,
            };
            const skill_name = if (obj.get("name")) |v| switch (v) {
                .string => |s| s,
                else => return error.InvalidState,
            } else entry.key_ptr.*;
            const skill = try parseSkill(gpa, skill_name, obj);
            errdefer {
                var tmp = skill;
                tmp.deinit(gpa);
            }
            const key = try identityKey(gpa, skill.provider, skill.name);
            errdefer gpa.free(key);
            try state.skills.put(gpa, key, skill);
        }
        return state;
    }

    fn parseSkill(gpa: std.mem.Allocator, name: []const u8, obj: std.json.ObjectMap) !Skill {
        var s = Skill{
            .name = try gpa.dupe(u8, name),
            .provider = try optString(gpa, obj, "provider"),
            .source_kind = if (obj.get("source_kind")) |v|
                (SourceKind.parse(jsonStr(v) orelse "") orelse .package)
            else
                .package,
            .source_url = try optString(gpa, obj, "source_url"),
            .commit = try optString(gpa, obj, "commit"),
            .version = try optString(gpa, obj, "version"),
            .skill_path = try optString(gpa, obj, "skill_path"),
            .description = null,
            .provisioned_at = try optString(gpa, obj, "provisioned_at"),
            .links = &.{},
        };
        errdefer s.deinit(gpa);

        if (obj.get("description")) |v| {
            if (jsonStr(v)) |d| s.description = try gpa.dupe(u8, d);
        }

        const links = switch (obj.get("links") orelse std.json.Value{ .null = {} }) {
            .array => |a| a.items,
            .null => &[_]std.json.Value{},
            else => return error.InvalidState,
        };
        const owned = try gpa.alloc(Link, links.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |*l| l.deinit(gpa);
            gpa.free(owned);
        }
        for (links, 0..) |lv, i| {
            owned[i] = try parseLink(gpa, lv);
            filled += 1;
        }
        s.links = owned;
        return s;
    }

    fn parseLink(gpa: std.mem.Allocator, lv: std.json.Value) !Link {
        const lobj = switch (lv) {
            .object => |o| o,
            else => return error.InvalidState,
        };
        const scope_raw = try optString(gpa, lobj, "scope");
        defer gpa.free(scope_raw);
        const scope = ScopeKind.parse(scope_raw) orelse return error.InvalidState;

        const mode_raw = try optString(gpa, lobj, "mode");
        defer gpa.free(mode_raw);

        var link = Link{
            .agent = try stringField(gpa, lobj, "agent"),
            .scope = scope,
            .path = undefined,
            .mode = if (std.mem.eql(u8, mode_raw, "copy")) .copy else .symlink,
            .project_root = undefined,
        };
        errdefer link.deinit(gpa);

        link.path = try stringField(gpa, lobj, "path");
        link.project_root = switch (lobj.get("project_root") orelse std.json.Value{ .null = {} }) {
            .string => |p| try gpa.dupe(u8, p),
            .null => null,
            else => return error.InvalidState,
        };
        return link;
    }

    fn jsonStr(v: std.json.Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    /// Read an optional string field. Absent or JSON `null` becomes ""; any
    /// other type is a corrupt manifest.
    fn optString(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
        const v = obj.get(key) orelse return gpa.dupe(u8, "");
        return switch (v) {
            .string => |s| gpa.dupe(u8, s),
            .null => gpa.dupe(u8, ""),
            else => error.InvalidState,
        };
    }

    fn stringField(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
        const v = obj.get(key) orelse return error.InvalidState;
        return switch (v) {
            .string => |s| gpa.dupe(u8, s),
            else => error.InvalidState,
        };
    }

    /// Serialize as pretty JSON. Caller owns memory.
    pub fn render(self: *const State) ![]u8 {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\n  \"version\": {d},\n  \"skills\": {{", .{self.version});
        for (self.skills.keys(), self.skills.values(), 0..) |key, s, i| {
            try w.print("{s}\n    {f}: {{\n", .{
                if (i == 0) "" else ",",
                std.json.fmt(key, .{}),
            });
            try w.print("      \"name\": {f},\n", .{std.json.fmt(s.name, .{})});
            try w.print("      \"provider\": {f},\n", .{std.json.fmt(s.provider, .{})});
            try w.print("      \"source_kind\": {f},\n", .{std.json.fmt(s.source_kind.name(), .{})});
            try w.print("      \"source_url\": {f},\n", .{std.json.fmt(s.source_url, .{})});
            try w.print("      \"commit\": {f},\n", .{std.json.fmt(s.commit, .{})});
            try w.print("      \"version\": {f},\n", .{std.json.fmt(s.version, .{})});
            try w.print("      \"skill_path\": {f},\n", .{std.json.fmt(s.skill_path, .{})});
            if (s.description) |d| {
                try w.print("      \"description\": {f},\n", .{std.json.fmt(d, .{})});
            } else {
                try w.writeAll("      \"description\": null,\n");
            }
            try w.print("      \"provisioned_at\": {f},\n", .{std.json.fmt(s.provisioned_at, .{})});
            try w.print("      \"links\": [", .{});
            for (s.links, 0..) |l, li| {
                if (li > 0) try w.writeAll(", ");
                try w.print("{{\"agent\": {f}, \"scope\": {f}, \"path\": {f}, \"mode\": {f}, \"project_root\": ", .{
                    std.json.fmt(l.agent, .{}),
                    std.json.fmt(l.scope.name(), .{}),
                    std.json.fmt(l.path, .{}),
                    std.json.fmt(if (l.mode == .copy) "copy" else "symlink", .{}),
                });
                if (l.project_root) |r| {
                    try w.print("{f}}}", .{std.json.fmt(r, .{})});
                } else {
                    try w.writeAll("null}");
                }
            }
            try w.writeAll("]\n    }");
        }
        if (self.skills.count() > 0) try w.writeAll("\n  ");
        try w.writeAll("}\n}\n");
        return self.gpa.dupe(u8, aw.written());
    }
};

/// Reading a manifest: a structurally wrong file is `InvalidState`, while a
/// missing one simply yields an empty manifest.
pub const LoadError = error{
    InvalidState,
} || util.ReadFileError || Io.Cancelable || Io.UnexpectedError;

pub const SaveError = error{
    OutOfMemory,
} || util.WriteFileError || Io.Cancelable || Io.UnexpectedError;

test "state round trips through render and parse" {
    const gpa = std.testing.allocator;
    var state: State = .{ .gpa = gpa };
    defer state.deinit();

    const links = try gpa.alloc(Link, 1);
    links[0] = .{
        .agent = try gpa.dupe(u8, "claude"),
        .scope = .global,
        .path = try gpa.dupe(u8, "/home/u/.claude/skills/zig-idioms"),
        .mode = .symlink,
        .project_root = null,
    };
    try state.skills.put(gpa, try State.identityKey(gpa, "zig-cc", "zig-idioms"), .{
        .name = try gpa.dupe(u8, "zig-idioms"),
        .provider = try gpa.dupe(u8, "zig-cc"),
        .source_kind = .zest_tool,
        .source_url = try gpa.dupe(u8, "https://github.com/zig-cc/zig-cc"),
        .commit = try gpa.dupe(u8, "abc123"),
        .version = try gpa.dupe(u8, "v1.2.0"),
        .skill_path = try gpa.dupe(u8, "/home/u/.local/share/zest/src/zig-cc/skills/zig-idioms"),
        .description = try gpa.dupe(u8, "Modern Zig conventions"),
        .provisioned_at = try gpa.dupe(u8, "2026-09-30T10:00:00Z"),
        .links = links,
    });

    const text = try state.render();
    defer gpa.free(text);

    var reloaded = try State.parse(gpa, text);
    defer reloaded.deinit();
    const key = switch (reloaded.resolveSelector("zig-cc/zig-idioms")) {
        .found => |k| k,
        else => return error.TestUnexpectedResult,
    };
    const s = reloaded.skills.get(key).?;
    try std.testing.expectEqualStrings("zig-cc", s.provider);
    try std.testing.expectEqual(SourceKind.zest_tool, s.source_kind);
    try std.testing.expectEqualStrings("v1.2.0", s.version);
    try std.testing.expectEqual(@as(usize, 1), s.links.len);
    try std.testing.expectEqualStrings("claude", s.links[0].agent);
    try std.testing.expectEqual(ScopeKind.global, s.links[0].scope);
    try std.testing.expectEqual(util.Materialized.symlink, s.links[0].mode);
    try std.testing.expect(s.links[0].project_root == null);
}

test "state preserves project root and copy mode" {
    const gpa = std.testing.allocator;
    var state: State = .{ .gpa = gpa };
    defer state.deinit();
    var links = try gpa.alloc(Link, 1);
    links[0] = .{
        .agent = try gpa.dupe(u8, "codex"),
        .scope = .project,
        .path = try gpa.dupe(u8, "/work/p/.codex/skills/s"),
        .mode = .copy,
        .project_root = try gpa.dupe(u8, "/work/p"),
    };
    try state.skills.put(gpa, try State.identityKey(gpa, "dep", "s"), .{
        .name = try gpa.dupe(u8, "s"),
        .provider = try gpa.dupe(u8, "dep"),
        .source_kind = .project_dep,
        .source_url = try gpa.dupe(u8, ""),
        .commit = try gpa.dupe(u8, ""),
        .version = try gpa.dupe(u8, ""),
        .skill_path = try gpa.dupe(u8, "/cache/deps/dep/skills/s"),
        .description = null,
        .provisioned_at = try gpa.dupe(u8, "2026-09-30T10:00:00Z"),
        .links = links,
    });

    const text = try state.render();
    defer gpa.free(text);
    var reloaded = try State.parse(gpa, text);
    defer reloaded.deinit();
    const key = switch (reloaded.resolveSelector("dep/s")) {
        .found => |k| k,
        else => return error.TestUnexpectedResult,
    };
    const l = reloaded.skills.get(key).?.links[0];
    try std.testing.expectEqual(util.Materialized.copy, l.mode);
    try std.testing.expectEqualStrings("/work/p", l.project_root.?);
    try std.testing.expect(reloaded.skills.get(key).?.description == null);
}

test "parse tolerates empty manifests and rejects junk" {
    const gpa = std.testing.allocator;
    {
        var s = try State.parse(gpa, "{ \"version\": 1, \"skills\": {} }");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 0), s.skills.count());
    }
    {
        var s = try State.parse(gpa, "{}");
        defer s.deinit();
        try std.testing.expectEqual(@as(usize, 0), s.skills.count());
    }
    try std.testing.expectError(error.InvalidState, State.parse(gpa, "{ not json"));
    try std.testing.expectError(error.InvalidState, State.parse(gpa, "[1,2]"));
    // A malformed scope must not be silently coerced to global.
    try std.testing.expectError(
        error.InvalidState,
        State.parse(gpa,
            \\{"version":1,"skills":{"s":{"links":[{"agent":"a","scope":"weird","path":"/p"}]}}}
        ),
    );
}

test "ScopeKind and SourceKind round trip through parse" {
    inline for (@typeInfo(ScopeKind).@"enum".field_names) |f| {
        const k: ScopeKind = @field(ScopeKind, f);
        try std.testing.expectEqual(k, ScopeKind.parse(k.name()).?);
    }
    inline for (@typeInfo(SourceKind).@"enum".field_names) |f| {
        const k: SourceKind = @field(SourceKind, f);
        try std.testing.expectEqual(k, SourceKind.parse(k.name()).?);
    }
    try std.testing.expect(ScopeKind.parse("nope") == null);
    try std.testing.expect(SourceKind.parse("nope") == null);
}
