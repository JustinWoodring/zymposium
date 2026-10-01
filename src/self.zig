//! Locating the package root of the running zymposium, so it can provision
//! its own skills however it was installed.
//!
//! zymposium ships a `skills/` directory describing itself and zest. When it
//! is installed through zest, the tool manifest already points at its clone, so
//! those skills are found by the ordinary zest-tools source. When it is a
//! plain `zig build` binary there is no manifest, so it locates itself instead.
//!
//! The search walks up from the running executable looking for the enclosing
//! package root, which is the nearest ancestor holding a `build.zig.zon`. That
//! covers both layouts without hardcoding either:
//!
//!     <repo>/zig-out/bin/zymposium                     -> <repo>
//!     <zest>/src/zymposium/dist/bin/zymposium           -> <zest>/src/zymposium
//!
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;

/// Provider name used for zymposium's own skills.
pub const provider_name = "zymposium";

pub const Error = error{OutOfMemory};

/// Absolute path of the running executable, or null when the platform cannot
/// say. Caller owns memory.
pub fn executablePath(gpa: std.mem.Allocator, io: Io) !?[]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return null;
    return try gpa.dupe(u8, buf[0..n]);
}

/// Walk up from `start` looking for the nearest directory holding a
/// `build.zig.zon`. Returns an absolute path, or null when none is found
/// before the filesystem root.
pub fn findPackageRoot(gpa: std.mem.Allocator, io: Io, start: []const u8) !?[]u8 {
    var current: []const u8 = start;
    // Bounded so a pathological layout cannot spin forever; real installs are
    // a handful of levels deep.
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        const zon = std.fs.path.join(gpa, &.{ current, "build.zig.zon" }) catch
            return error.OutOfMemory;
        defer gpa.free(zon);
        const st = Io.Dir.cwd().statFile(io, zon, .{}) catch null;
        if (st != null and st.?.kind == .file) return try gpa.dupe(u8, current);

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null; // reached the root
        current = parent;
    }
    return null;
}
/// Locate the running installation's package root. Returns null when the
/// binary has been copied somewhere without its source tree — a bare binary in
/// a bin directory with no `build.zig.zon` above it — which is not an error:
/// it just means there are no package skills to offer.
pub fn discoverRoot(gpa: std.mem.Allocator, io: Io) !?[]u8 {
    const exe = (try executablePath(gpa, io)) orelse return null;
    defer gpa.free(exe);

    // The link zest installs points into its clone; resolve it so the walk
    // starts from the real location rather than the symlink's directory.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const start = if (std.Io.Dir.cwd().realPathFile(io, exe, &buf)) |n| buf[0..n] else |_| exe;

    const dir = std.fs.path.dirname(start) orelse return null;
    return try findPackageRoot(gpa, io, dir);
}

/// Locate zest's package root, so zymposium can provision the skill zest
/// ships about itself.
///
/// Both of zest's install paths keep its source tree on disk at
/// `<zest root>/self/src`: `install.sh` clones it there, and `zest self-update`
/// re-clones it there. A zest that was not installed by its installer, or
/// whose source tree has been removed, has no zest skill; that is the intended
/// behaviour, not an error.
pub fn discoverZestRoot(gpa: std.mem.Allocator, io: Io, zest_root: []const u8) !?[]u8 {
    const staged = std.fs.path.join(gpa, &.{ zest_root, "self", "src" }) catch
        return error.OutOfMemory;
    defer gpa.free(staged);
    const zon = std.fs.path.join(gpa, &.{ staged, "build.zig.zon" }) catch
        return error.OutOfMemory;
    defer gpa.free(zon);
    const stat = Io.Dir.cwd().statFile(io, zon, .{}) catch return null;
    if (stat.kind != .file) return null;
    return try gpa.dupe(u8, staged);
}

test "findPackageRoot walks up to the nearest build.zig.zon" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // <tmp>/build.zig.zon is the package root; the binary lives two levels down.
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = ".{ .name = .pkg }" });
    try dir.createDirPath(io, "zig-out/bin");
    try dir.createDirPath(io, "dist/bin");

    const root = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const zigout = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin", .{root});
    defer gpa.free(zigout);
    const found_zigout = (try findPackageRoot(gpa, io, zigout)).?;
    defer gpa.free(found_zigout);
    try std.testing.expectEqualStrings(root, found_zigout);

    // The same walk works from a zest-style dist/bin layout.
    const dist = try std.fmt.allocPrint(gpa, "{s}/dist/bin", .{root});
    defer gpa.free(dist);
    const found_dist = (try findPackageRoot(gpa, io, dist)).?;
    defer gpa.free(found_dist);
    try std.testing.expectEqualStrings(root, found_dist);
}

test "findPackageRoot prefers the nearest package root" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // A nested package: the walk must stop at `inner`, not continue to the
    // enclosing `outer` package.
    try dir.createDirPath(io, "outer");
    try dir.createDirPath(io, "outer/inner");
    try dir.createDirPath(io, "outer/inner/dist/bin");
    try dir.writeFile(io, .{ .sub_path = "outer/build.zig.zon", .data = ".{ .name = .outer }" });
    try dir.writeFile(io, .{ .sub_path = "outer/inner/build.zig.zon", .data = ".{ .name = .inner }" });
    try dir.createDirPath(io, "outer/inner/dist/bin");

    const outer = try dir.realPathFileAlloc(io, "outer", gpa);
    defer gpa.free(outer);
    const inner = try dir.realPathFileAlloc(io, "outer/inner", gpa);
    defer gpa.free(inner);

    const start = try std.fmt.allocPrint(gpa, "{s}/dist/bin", .{inner});
    defer gpa.free(start);
    const found = (try findPackageRoot(gpa, io, start)).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings(inner, found);
    try std.testing.expect(!std.mem.eql(u8, outer, found));
}

test "discoverZestRoot finds zest's staged self source and tolerates absence" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "zest/self/src/skills/zest");
    try dir.writeFile(io, .{ .sub_path = "zest/self/src/build.zig.zon", .data = ".{ .name = .zest }" });
    try dir.writeFile(io, .{ .sub_path = "zest/self/src/skills/zest/SKILL.md", .data = "zest" });

    const root = try dir.realPathFileAlloc(io, "zest", gpa);
    defer gpa.free(root);
    const src = try std.fs.path.join(gpa, &.{ root, "self", "src" });
    defer gpa.free(src);
    const found = (try discoverZestRoot(gpa, io, root)).?;
    defer gpa.free(found);
    try std.testing.expectEqualStrings(src, found);

    const no_zest = try std.fs.path.join(gpa, &.{ root, "missing-zest" });
    defer gpa.free(no_zest);
    try std.testing.expect((try discoverZestRoot(gpa, io, no_zest)) == null);
}
