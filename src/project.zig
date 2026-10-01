//! Project scope: walk a Zig project's `build.zig.zon` dependency graph and
//! collect the packages that ship skills.
//!
//! The graph is followed transitively, because the ecosystem's skills mostly
//! live in libraries rather than in applications. Walking is cycle-safe (a
//! `visited` set keyed by dependency identity) and depth-limited, and a
//! dependency that cannot be fetched is reported without aborting the run.
//!
//! A project's own `skills/` directory is deliberately *not* provisioned:
//! those files already live where the agent will look for them.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const git = @import("git.zig");
const paths_mod = @import("paths.zig");
const sources = @import("sources.zig");
const util = @import("util.zig");

pub const zon_file_name = "build.zig.zon";

/// A dependency entry from `build.zig.zon`, borrowing from the parsed source.
pub const Dep = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    lazy: bool = false,
};

/// Something worth telling the user about, without failing the run.
pub const Notice = struct {
    /// The dependency the notice is about.
    dep: []u8,
    /// Human-readable explanation.
    message: []u8,

    pub fn deinit(self: *Notice, gpa: std.mem.Allocator) void {
        gpa.free(self.dep);
        gpa.free(self.message);
    }
};

pub fn freeNotices(gpa: std.mem.Allocator, items: []Notice) void {
    for (items) |*n| n.deinit(gpa);
    gpa.free(items);
}

pub const Options = struct {
    /// Directory cloned dependencies are fetched into.
    deps_root: []const u8,
    /// Clone dependencies that are not present yet. When false the walk only
    /// considers what is already cached and never touches the network.
    fetch: bool = true,
    /// Skip `.lazy` dependencies, which the build may never pull in.
    skip_lazy: bool = false,
    /// Guard against pathological graphs; also bounds cycle re-entry.
    max_depth: usize = 16,
};

pub const Result = struct {
    candidates: []sources.Candidate,
    notices: []Notice,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        sources.freeCandidates(gpa, self.candidates);
        freeNotices(gpa, self.notices);
    }
};

pub const Error = error{
    /// `build.zig.zon` is not valid ZON.
    ParseZon,
} || std.mem.Allocator.Error || util.ReadFileError || Io.Cancelable ||
    Io.UnexpectedError;

/// True when `path` holds a `build.zig.zon`.
pub fn isProject(gpa: std.mem.Allocator, io: Io, path: []const u8) bool {
    const candidate = std.fs.path.join(gpa, &.{ path, zon_file_name }) catch return false;
    defer gpa.free(candidate);
    const st = Io.Dir.cwd().statFile(io, candidate, .{}) catch return false;
    return st.kind == .file;
}

/// Collect every dependency package reachable from `project_root`.
///
/// A directory with no `build.zig.zon` yields an empty result rather than an
/// error, so `zymposium sync` works outside a Zig project.
pub fn collect(
    gpa: std.mem.Allocator,
    io: Io,
    project_root: []const u8,
    opts: Options,
) Error!Result {
    var set: sources.Set = .{ .gpa = gpa };
    defer set.deinit();

    var notices: std.ArrayList(Notice) = .empty;
    errdefer notices.deinit(gpa);

    var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (visited.keys()) |k| gpa.free(k);
        visited.deinit(gpa);
    }

    try walk(gpa, io, project_root, opts, &set, &visited, &notices, 0);

    return .{
        .candidates = try set.sorted(gpa),
        .notices = try notices.toOwnedSlice(gpa),
    };
}

fn walk(
    gpa: std.mem.Allocator,
    io: Io,
    package_root: []const u8,
    opts: Options,
    set: *sources.Set,
    visited: *std.StringArrayHashMapUnmanaged(void),
    notices: *std.ArrayList(Notice),
    depth: usize,
) Error!void {
    if (depth > opts.max_depth) return;

    const zon_path = std.fs.path.join(gpa, &.{ package_root, zon_file_name }) catch
        return error.OutOfMemory;
    defer gpa.free(zon_path);

    const text = util.readFileAlloc(Io.Dir.cwd(), io, gpa, zon_path) catch |err| switch (err) {
        // A package without build.zig.zon has no dependency graph to follow.
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer gpa.free(text);

    const deps = parseDeps(gpa, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            try notices.append(gpa, .{
                .dep = try gpa.dupe(u8, package_root),
                .message = try std.fmt.allocPrint(
                    gpa,
                    "{s} is not valid ZON; dependencies skipped",
                    .{zon_path},
                ),
            });
            return;
        },
    };
    defer freeDeps(gpa, deps);

    for (deps) |dep| {
        if (opts.skip_lazy and dep.lazy) continue;
        try visitDep(gpa, io, package_root, dep, opts, set, visited, notices, depth);
    }
}

fn visitDep(
    gpa: std.mem.Allocator,
    io: Io,
    parent_root: []const u8,
    dep: Dep,
    opts: Options,
    set: *sources.Set,
    visited: *std.StringArrayHashMapUnmanaged(void),
    notices: *std.ArrayList(Notice),
    depth: usize,
) Error!void {
    // Path dependencies are already in the tree: register them as skill
    // sources and recurse, with no clone and no network.
    if (dep.url == null) {
        if (dep.path) |p| {
            const key = try depKey(gpa, dep.name, p);
            if (visited.contains(key)) {
                gpa.free(key);
                return;
            }
            // `visited` owns the key from here; `collect` frees it.
            try visited.put(gpa, key, {});

            const child = std.fs.path.resolve(gpa, &.{ parent_root, p }) catch return;
            defer gpa.free(child);
            try set.add(.{
                .provider = try gpa.dupe(u8, dep.name),
                .source_kind = .project_dep,
                .source_url = try gpa.dupe(u8, child),
                .commit = try gpa.dupe(u8, ""),
                .version = try gpa.dupe(u8, dep.hash orelse ""),
                .root = try gpa.dupe(u8, child),
            });
            try walk(gpa, io, child, opts, set, visited, notices, depth + 1);
        }
        return;
    }

    const url = git.normalizeGitUrl(dep.url.?);
    if (!git.isGitUrl(url)) {
        try notices.append(gpa, .{
            .dep = try gpa.dupe(u8, dep.name),
            .message = try std.fmt.allocPrint(
                gpa,
                "{s}: {s} is not a git URL; only git dependencies can supply skills",
                .{ dep.name, dep.url.? },
            ),
        });
        return;
    }

    const dir_name = try cloneDirName(gpa, dep.name, url);
    defer gpa.free(dir_name);
    const clone_dir = try std.fs.path.join(gpa, &.{ opts.deps_root, dir_name });
    defer gpa.free(clone_dir);

    const present = blk: {
        const st = Io.Dir.cwd().statFile(io, clone_dir, .{ .follow_symlinks = false }) catch
            break :blk false;
        break :blk st.kind == .directory;
    };

    if (!present) {
        if (!opts.fetch) return;
        Io.Dir.cwd().createDirPath(io, opts.deps_root) catch {};
        Io.Dir.cwd().deleteTree(io, clone_dir) catch {};
        const res = git.clone(gpa, io, url, clone_dir, null) catch |err| {
            try notices.append(gpa, .{
                .dep = try gpa.dupe(u8, dep.name),
                .message = try std.fmt.allocPrint(
                    gpa,
                    "{s}: could not fetch {s} ({s})",
                    .{ dep.name, url, @errorName(err) },
                ),
            });
            return;
        };
        defer gpa.free(res.output);
        if (!res.ok) {
            Io.Dir.cwd().deleteTree(io, clone_dir) catch {};
            try notices.append(gpa, .{
                .dep = try gpa.dupe(u8, dep.name),
                .message = try std.fmt.allocPrint(
                    gpa,
                    "{s}: clone failed:\n{s}",
                    .{ dep.name, res.output },
                ),
            });
            return;
        }
    }

    const key = try depKey(gpa, dep.name, url);
    if (visited.contains(key)) {
        gpa.free(key);
        return;
    }
    // `visited` owns the key from here; `collect` frees it with the set.
    try visited.put(gpa, key, {});

    const commit = git.headCommit(gpa, io, clone_dir) catch "";

    try set.add(.{
        .provider = try gpa.dupe(u8, dep.name),
        .source_kind = .project_dep,
        .source_url = try gpa.dupe(u8, url),
        .commit = try gpa.dupe(u8, commit),
        .version = try gpa.dupe(u8, dep.hash orelse ""),
        .root = try gpa.dupe(u8, clone_dir),
    });

    try walk(gpa, io, clone_dir, opts, set, visited, notices, depth + 1);
}

/// A visited-set identity for a dependency. The URL (or path) is what
/// distinguishes two versions of the same package name.
fn depKey(gpa: std.mem.Allocator, name: []const u8, url_or_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ name, url_or_path });
}

/// `<name>-<digest>`: readable, and distinct for distinct URLs.
fn cloneDirName(gpa: std.mem.Allocator, name: []const u8, url: []const u8) ![]u8 {
    const safe = try paths_mod.sanitizeName(gpa, name);
    defer gpa.free(safe);
    const h = std.hash.Wyhash.hash(0, url);
    return std.fmt.allocPrint(gpa, "{s}-{x:0>12}", .{ safe, h });
}

// ---------------------------------------------------------------------------
// ZON parsing
// ---------------------------------------------------------------------------

const Zoir = std.zig.Zoir;

/// Parse the `.dependencies` table of a `build.zig.zon`.
///
/// ZON is Zig syntax, not JSON, and its tables are maps with enum-literal
/// keys, which `std.zon.parse`'s typed deserializer does not accept. The
/// document is therefore lowered to Zoir and walked directly.
pub fn parseDeps(gpa: std.mem.Allocator, text: []const u8) ![]Dep {
    // Ast.parse needs a sentinel-terminated source; zon files are read from
    // disk without one.
    const owned = try gpa.dupeZ(u8, text);
    defer gpa.free(owned);
    var ast = std.zig.Ast.parse(gpa, owned, .zon) catch return error.OutOfMemory;
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) return error.ParseZon;

    var zoir = std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = true }) catch
        return error.OutOfMemory;
    defer zoir.deinit(gpa);

    const root_idx: Zoir.Node.Index = .root;
    var out: std.ArrayList(Dep) = .empty;
    errdefer freeDeps(gpa, out.items);

    // A package without a dependency table is normal, not malformed.
    const deps_idx = structField(root_idx.get(zoir), zoir, "dependencies") orelse
        return out.toOwnedSlice(gpa);

    const table = switch (deps_idx.get(zoir)) {
        .struct_literal => |s| s,
        .empty_literal => return out.toOwnedSlice(gpa),
        else => return error.ParseZon,
    };

    // Every string is copied out of Zoir: the Zoir node borrows the parsed
    // source, which is freed before the caller is done with these.
    for (table.names, 0..) |nts, i| {
        const entry = table.vals.at(@intCast(i)).get(zoir);
        const dep = Dep{
            .name = try gpa.dupe(u8, nts.get(zoir)),
            .url = try dupField(gpa, entry, zoir, "url"),
            .path = try dupField(gpa, entry, zoir, "path"),
            .hash = try dupField(gpa, entry, zoir, "hash"),
            .lazy = boolField(entry, zoir, "lazy"),
        };
        errdefer {
            gpa.free(dep.name);
            if (dep.url) |v| gpa.free(v);
            if (dep.path) |v| gpa.free(v);
            if (dep.hash) |v| gpa.free(v);
        }
        try out.append(gpa, dep);
    }
    return out.toOwnedSlice(gpa);
}

/// Release a `[]Dep` and every string in it.
pub fn freeDeps(gpa: std.mem.Allocator, deps: []Dep) void {
    for (deps) |*d| {
        gpa.free(d.name);
        if (d.url) |v| gpa.free(v);
        if (d.path) |v| gpa.free(v);
        if (d.hash) |v| gpa.free(v);
    }
    gpa.free(deps);
}

fn dupField(gpa: std.mem.Allocator, node: Zoir.Node, zoir: Zoir, name: []const u8) !?[]u8 {
    const s = stringField(node, zoir, name) orelse return null;
    return try gpa.dupe(u8, s);
}

/// Value of a string field, or null when absent or not a string literal.
fn stringField(node: Zoir.Node, zoir: Zoir, name: []const u8) ?[]const u8 {
    const idx = structField(node, zoir, name) orelse return null;
    return switch (idx.get(zoir)) {
        .string_literal => |s| s,
        else => null,
    };
}

/// Value of a boolean field, defaulting to false.
fn boolField(node: Zoir.Node, zoir: Zoir, name: []const u8) bool {
    const idx = structField(node, zoir, name) orelse return false;
    return switch (idx.get(zoir)) {
        .true => true,
        else => false,
    };
}

/// Index of a named field in a struct-literal node, if present.
fn structField(node: Zoir.Node, zoir: Zoir, want: []const u8) ?Zoir.Node.Index {
    const s = switch (node) {
        .struct_literal => |v| v,
        else => return null,
    };
    for (s.names, 0..) |nts, i| {
        if (std.mem.eql(u8, nts.get(zoir), want)) return s.vals.at(@intCast(i));
    }
    return null;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const test_zon =
    \\.{
    \\    .name = .myproj,
    \\    .version = "0.1.0",
    \\    .fingerprint = 0x1234,
    \\    .dependencies = .{
    \\        .example = .{ .url = "https://example.com/foo.tar.gz", .hash = "1220-abc" },
    \\        .local = .{ .path = "../local" },
    \\        .gitdep = .{ .url = "git+https://github.com/a/b.git", .lazy = true },
    \\        .plain = .{ .url = "https://example.com/other.tar.gz" },
    \\    },
    \\    .paths = .{ "src" },
    \\}
;

test "parseDeps reads url, path, hash and lazy" {
    const gpa = std.testing.allocator;
    const deps = try parseDeps(gpa, test_zon);
    defer freeDeps(gpa, deps);
    try std.testing.expectEqual(@as(usize, 4), deps.len);

    try std.testing.expectEqualStrings("example", deps[0].name);
    try std.testing.expectEqualStrings("https://example.com/foo.tar.gz", deps[0].url.?);
    try std.testing.expectEqualStrings("1220-abc", deps[0].hash.?);
    try std.testing.expect(deps[0].path == null);
    try std.testing.expect(!deps[0].lazy);

    try std.testing.expectEqualStrings("local", deps[1].name);
    try std.testing.expectEqualStrings("../local", deps[1].path.?);
    try std.testing.expect(deps[1].url == null);

    try std.testing.expect(deps[2].lazy);
    try std.testing.expectEqualStrings("git+https://github.com/a/b.git", deps[2].url.?);

    try std.testing.expectEqualStrings("plain", deps[3].name);
    try std.testing.expect(!deps[3].lazy);
}

test "parseDeps handles zon without dependencies" {
    const gpa = std.testing.allocator;
    {
        const deps = try parseDeps(gpa, ".{ .name = .x }");
        defer freeDeps(gpa, deps);
        try std.testing.expectEqual(@as(usize, 0), deps.len);
    }
    {
        const deps = try parseDeps(gpa, ".{ .dependencies = .{} }");
        defer freeDeps(gpa, deps);
        try std.testing.expectEqual(@as(usize, 0), deps.len);
    }
}

test "parseDeps rejects malformed zon" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.ParseZon, parseDeps(gpa, ".{ .name = "));
    try std.testing.expectError(error.ParseZon, parseDeps(gpa, "not zon at all"));
}

test "cloneDirName is stable and URL-sensitive" {
    const gpa = std.testing.allocator;
    const a = try cloneDirName(gpa, "dep", "https://github.com/a/b.git");
    defer gpa.free(a);
    const b = try cloneDirName(gpa, "dep", "https://github.com/a/b.git");
    defer gpa.free(b);
    const c = try cloneDirName(gpa, "dep", "https://github.com/a/c.git");
    defer gpa.free(c);

    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(!std.mem.eql(u8, a, c));
    try std.testing.expect(std.mem.startsWith(u8, a, "dep-"));
}

test "collect on a directory without build.zig.zon is empty, not an error" {
    const gpa = std.testing.allocator;
    var res = try collect(gpa, std.testing.io, "/nonexistent-project", .{
        .deps_root = "/tmp/zymposium-deps-test",
        .fetch = false,
    });
    defer res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), res.candidates.len);
    try std.testing.expectEqual(@as(usize, 0), res.notices.len);
}
