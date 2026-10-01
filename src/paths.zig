//! Resolution of XDG base directories and the zymposium on-disk layout:
//!
//!   $XDG_DATA_HOME/zymposium/            (default ~/.local/share/zymposium)
//!   ├── state.json                       provisioning manifest
//!   ├── deps/<name>/                     clones of build.zig.zon dependencies
//!   └── pkgs/<name>/                     clones added via `zymposium add`
//!
//!   $XDG_CONFIG_HOME/zymposium/config.json  (default ~/.config/zymposium)
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Paths = struct {
    /// $XDG_DATA_HOME/zymposium, always absolute.
    root: []const u8,
    /// root/state.json
    state_file: []const u8,
    /// root/deps — dependency clones discovered from build.zig.zon.
    deps: []const u8,
    /// root/pkgs — clones added explicitly with `zymposium add`.
    pkgs: []const u8,
    /// $XDG_CONFIG_HOME/zymposium/config.json
    config_file: []const u8,
    /// Absolute user home directory, or null when the environment supplies
    /// neither $HOME nor $USERPROFILE and the XDG variables cover every data
    /// path. Global agent skill directories hang off it and are unavailable in
    /// that case; project scope still works.
    home: ?[]const u8,

    pub const Error = error{ NoHomeDirectory, OutOfMemory };

    pub fn resolve(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Error!Paths {
        var owned_data: ?[]u8 = null;
        defer if (owned_data) |b| gpa.free(b);
        var owned_config: ?[]u8 = null;
        defer if (owned_config) |b| gpa.free(b);
        const data_base = xdgBase(gpa, environ, "XDG_DATA_HOME", &owned_data, ".local/share") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoHomeDirectory => return error.NoHomeDirectory,
        };
        const config_base = xdgBase(gpa, environ, "XDG_CONFIG_HOME", &owned_config, ".config") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoHomeDirectory => return error.NoHomeDirectory,
        };
        // $HOME is only consulted for the agent boundary, not for our own
        // storage: a fully XDG-configured environment needs no home at all.
        const home: ?[]const u8 = if (environ.get("HOME") orelse environ.get("USERPROFILE")) |h|
            try gpa.dupe(u8, h)
        else
            null;

        return .{
            .root = try std.fmt.allocPrint(gpa, "{s}/zymposium", .{data_base}),
            .state_file = try std.fmt.allocPrint(gpa, "{s}/zymposium/state.json", .{data_base}),
            .deps = try std.fmt.allocPrint(gpa, "{s}/zymposium/deps", .{data_base}),
            .pkgs = try std.fmt.allocPrint(gpa, "{s}/zymposium/pkgs", .{data_base}),
            .config_file = try std.fmt.allocPrint(gpa, "{s}/zymposium/config.json", .{config_base}),
            .home = home,
        };
    }

    /// An XDG base dir: honored only when set to an absolute path, per the XDG
    /// base directory specification. `owned` receives the fallback when the
    /// variable is missing or relative.
    fn xdgBase(
        gpa: std.mem.Allocator,
        environ: *const std.process.Environ.Map,
        key: []const u8,
        owned: *?[]u8,
        fallback: []const u8,
    ) ![]const u8 {
        if (environ.get(key)) |v| {
            if (isAbsolutePath(v)) return v;
        }
        const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse
            return error.NoHomeDirectory;
        const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, fallback });
        owned.* = joined;
        return joined;
    }

    /// Absolute on POSIX (leading '/'); absolute on Windows (drive root).
    fn isAbsolutePath(p: []const u8) bool {
        if (p.len == 0) return false;
        if (p[0] == '/') return true;
        return builtin.os.tag == .windows and p.len > 2 and p[1] == ':';
    }

    pub fn deinit(self: Paths, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
        gpa.free(self.state_file);
        gpa.free(self.deps);
        gpa.free(self.pkgs);
        gpa.free(self.config_file);
        if (self.home) |h| gpa.free(h);
    }

    /// Directory a zest-installed tool's clone lives in.
    pub fn zestRoot(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
        var owned: ?[]u8 = null;
        defer if (owned) |b| gpa.free(b);
        const base = xdgBase(gpa, environ, "XDG_DATA_HOME", &owned, ".local/share") catch
            return error.OutOfMemory;
        return std.fmt.allocPrint(gpa, "{s}/zest", .{base});
    }

    /// Directory that holds every clone the named dependency is fetched into.
    pub fn depDir(gpa: std.mem.Allocator, deps: []const u8, name: []const u8) ![]u8 {
        const safe = try sanitizeName(gpa, name);
        defer gpa.free(safe);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ deps, safe });
    }

    pub fn pkgDir(gpa: std.mem.Allocator, pkgs: []const u8, name: []const u8) ![]u8 {
        const safe = try sanitizeName(gpa, name);
        defer gpa.free(safe);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ pkgs, safe });
    }

    /// Create the data skeleton if missing.
    pub fn ensureLayout(self: Paths, io: Io) !void {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, self.root);
        try cwd.createDirPath(io, self.deps);
        try cwd.createDirPath(io, self.pkgs);
    }
};

/// Reduce an arbitrary dependency key to a safe single path segment. Zig
/// package names are identifiers, but a zon file is untrusted input, so any
/// byte that could alter the path is percent-encoded. Encoding rather than
/// flattening keeps the mapping injective: `a/b` and `a_b` stay distinct
/// directories instead of colliding on one clone.
pub fn sanitizeName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (name.len == 0) return gpa.dupe(u8, "%00");
    for (name, 0..) |c, i| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => try out.append(gpa, c),
            '.' => if (i == 0) {
                try out.appendSlice(gpa, "%2E");
            } else {
                try out.append(gpa, c);
            },
            else => {
                const encoded = [_]u8{ '%', hex[c >> 4], hex[c & 0xf] };
                try out.appendSlice(gpa, &encoded);
            },
        }
    }
    return out.toOwnedSlice(gpa);
}

test "Paths.resolve honors XDG_DATA_HOME" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/xdg/data");
    try env.put("XDG_CONFIG_HOME", "/xdg/config");
    const p = try Paths.resolve(gpa, &env);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("/xdg/data/zymposium", p.root);
    try std.testing.expectEqualStrings("/xdg/data/zymposium/state.json", p.state_file);
    try std.testing.expectEqualStrings("/xdg/data/zymposium/deps", p.deps);
    try std.testing.expectEqualStrings("/xdg/config/zymposium/config.json", p.config_file);
}

test "Paths.resolve falls back to home and ignores relative XDG" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    // Relative XDG values must be ignored per the XDG base dir spec.
    try env.put("XDG_DATA_HOME", "relative/path");
    const p = try Paths.resolve(gpa, &env);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("/home/tester/.local/share/zymposium", p.root);
    try std.testing.expectEqualStrings("/home/tester/.config/zymposium/config.json", p.config_file);
}

test "Paths.resolve needs a home when no XDG variable is set" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try std.testing.expectError(error.NoHomeDirectory, Paths.resolve(gpa, &env));
}

test "Paths.resolve works with XDG only and reports no home" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/xdg/data");
    try env.put("XDG_CONFIG_HOME", "/xdg/config");
    const p = try Paths.resolve(gpa, &env);
    defer p.deinit(gpa);
    // Storage is fully specified, so the absence of $HOME only means the
    // global agent boundary is unavailable.
    try std.testing.expectEqualStrings("/xdg/data/zymposium", p.root);
    try std.testing.expect(p.home == null);
}

test "Paths.resolve records home when present" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    try env.put("XDG_DATA_HOME", "/xdg/data");
    try env.put("XDG_CONFIG_HOME", "/xdg/config");
    const p = try Paths.resolve(gpa, &env);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("/home/tester", p.home.?);
}

test "zestRoot tracks XDG_DATA_HOME" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("XDG_DATA_HOME", "/xdg/data");
    const root = try Paths.zestRoot(gpa, &env);
    defer gpa.free(root);
    try std.testing.expectEqualStrings("/xdg/data/zest", root);
}

test "sanitizeName yields safe unique segments" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "example", .want = "example" },
        .{ .in = "a/b", .want = "a%2Fb" },
        .{ .in = ".hidden", .want = "%2Ehidden" },
        .{ .in = "", .want = "%00" },
    };
    for (cases) |c| {
        const got = try sanitizeName(gpa, c.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }

    // Distinct inputs must not collide onto one directory.
    const slash = try sanitizeName(gpa, "a/b");
    defer gpa.free(slash);
    const underscore = try sanitizeName(gpa, "a_b");
    defer gpa.free(underscore);
    try std.testing.expect(!std.mem.eql(u8, slash, underscore));
    const escaped = try sanitizeName(gpa, "a%2Fb");
    defer gpa.free(escaped);
    try std.testing.expect(!std.mem.eql(u8, slash, escaped));

    // Nothing that could traverse or hide may survive unescaped.
    for ([_][]const u8{ "..", ".", "/", "\\", "a/../b" }) |bad| {
        const safe = try sanitizeName(gpa, bad);
        defer gpa.free(safe);
        for (safe) |c| try std.testing.expect(c != '/' and c != '\\');
        try std.testing.expect(safe[0] != '.');
    }
}
