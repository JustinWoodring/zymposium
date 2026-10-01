//! Small shared helpers: buffered file I/O, atomic writes, timestamps,
//! symlink-or-copy materialization, and version ordering.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;

/// Largest file zymposium will read into memory (config, state, SKILL.md).
pub const max_read_size: u64 = 32 * 1024 * 1024;

pub const ReadFileError =
    std.mem.Allocator.Error ||
    Io.File.OpenError ||
    Io.Reader.LimitedAllocError;

pub const WriteFileError =
    std.mem.Allocator.Error ||
    Io.File.OpenError ||
    Io.Writer.Error ||
    Io.Dir.RenameError;

/// Read a whole file into caller-owned memory. `error.FileNotFound` passes through.
pub fn readFileAlloc(
    dir: Io.Dir,
    io: Io,
    gpa: std.mem.Allocator,
    sub_path: []const u8,
) ReadFileError![]u8 {
    const file = try dir.openFile(io, sub_path, .{ .mode = .read_only });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    return file_reader.interface.allocRemaining(gpa, .limited(max_read_size));
}

/// Write `bytes` to `sub_path` atomically: temp file + rename within the same
/// directory, so a crash never leaves a half-written manifest behind.
pub fn writeFileAtomic(
    dir: Io.Dir,
    io: Io,
    gpa: std.mem.Allocator,
    sub_path: []const u8,
    bytes: []const u8,
) WriteFileError!void {
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{sub_path});
    defer gpa.free(tmp_path);

    const file = try dir.createFile(io, tmp_path, .{});
    {
        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        try file_writer.interface.writeAll(bytes);
        try file_writer.interface.flush();
    }
    file.close(io);

    try dir.rename(tmp_path, dir, sub_path, io);
}

/// Format unix seconds as RFC 3339 UTC ("2026-09-30T16:26:00Z") into `buf`.
pub fn formatRfc3339(buf: []u8, unix_seconds: i64) []const u8 {
    const secs: u64 = @intCast(@max(unix_seconds, 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Current wall-clock time formatted as RFC 3339 UTC.
pub fn nowRfc3339(io: Io) [20]u8 {
    const now = Io.Timestamp.now(io, .real);
    const unix_seconds: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
    var buf: [20]u8 = undefined;
    _ = formatRfc3339(&buf, unix_seconds);
    return buf;
}

/// Release/version ordering: compare dot-separated numeric segments after an
/// optional leading `v`; fall back to lexicographic for non-numeric parts.
pub fn versionLess(a: []const u8, b: []const u8) bool {
    const av = stripV(a);
    const bv = stripV(b);
    var ai = std.mem.splitScalar(u8, av, '.');
    var bi = std.mem.splitScalar(u8, bv, '.');
    while (true) {
        const as = ai.next();
        const bs = bi.next();
        if (as == null and bs == null) return false;
        if (as == null) return true; // shorter prefix sorts lower
        if (bs == null) return false;
        const an = std.fmt.parseInt(u64, as.?, 10) catch {
            return std.mem.order(u8, as.?, bs.?) == .lt;
        };
        const bn = std.fmt.parseInt(u64, bs.?, 10) catch {
            return std.mem.order(u8, as.?, bs.?) == .lt;
        };
        if (an != bn) return an < bn;
    }
}

fn stripV(tag: []const u8) []const u8 {
    if (tag.len > 1 and (tag[0] == 'v' or tag[0] == 'V') and tag[1] >= '0' and tag[1] <= '9') return tag[1..];
    return tag;
}

// ---------------------------------------------------------------------------
// Filesystem materialization
// ---------------------------------------------------------------------------

pub const LinkMode = enum {
    /// Prefer a symlink; fall back to a recursive copy when the platform or
    /// filesystem refuses (Windows without developer mode, FAT/exFAT, some
    /// container overlay mounts).
    auto,
    symlink,
    copy,

    pub fn parse(s: []const u8) ?LinkMode {
        inline for (@typeInfo(LinkMode).@"enum".fields) |f| {
            if (s.len == f.name.len and std.mem.eql(u8, s, f.name))
                return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn name(m: LinkMode) []const u8 {
        return @tagName(m);
    }
};

/// What `materialize` actually did for one path.
pub const Materialized = enum { symlink, copy };

pub const MaterializeError = error{
    /// The filesystem rejected a symlink and `mode` was not `.auto`.
    SymlinkRefused,
} || std.mem.Allocator.Error || Io.Cancelable || Io.UnexpectedError ||
    Io.Dir.WriteFileError || Io.Dir.CreateDirPathError || Io.Dir.RenameError ||
    Io.Dir.SymLinkError || Io.Dir.OpenError || Io.Dir.StatFileError ||
    Io.Dir.DeleteTreeError || Io.Dir.CopyFileError;

/// Create `link_path` pointing at `target_path`, replacing anything already
/// there. `mode` selects the strategy; `.auto` tries a symlink first and falls
/// back to a directory copy.
pub fn materialize(
    gpa: std.mem.Allocator,
    io: Io,
    target_path: []const u8,
    link_path: []const u8,
    mode: LinkMode,
) MaterializeError!Materialized {
    removePath(gpa, io, link_path);

    // The agent's skills directory may not exist yet on a first run. A symlink
    // cannot be created without its parent, and without this the very first
    // skill would silently degrade to a copy while later ones became links.
    if (std.fs.path.dirname(link_path)) |parent| {
        try Io.Dir.cwd().createDirPath(io, parent);
    }

    if (mode != .copy) {
        const cwd = Io.Dir.cwd();
        cwd.symLinkAtomic(io, target_path, link_path, .{}) catch |err| {
            // `.auto` degrades to a copy wherever symlinks are unavailable:
            // Windows without developer mode, FAT/exFAT, some container
            // overlay mounts. An explicit `.symlink` surfaces the failure.
            if (mode == .auto) {
                try copyTree(gpa, io, target_path, link_path);
                return .copy;
            }
            return err;
        };
        return .symlink;
    }
    try copyTree(gpa, io, target_path, link_path);
    return .copy;
}

/// Delete a file, symlink, or directory tree if present. Never fails the
/// caller: a missing path is success, and a path we cannot remove is left for
/// `doctor` to report.
pub fn removePath(gpa: std.mem.Allocator, io: Io, path: []const u8) void {
    _ = gpa;
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, path) catch {};
}

/// What currently occupies `path`, if anything.
pub const Existing = union(enum) {
    absent,
    symlink: []u8, // raw link target, caller owns
    directory,
    file,

    pub fn deinit(self: Existing, gpa: std.mem.Allocator) void {
        switch (self) {
            .symlink => |t| gpa.free(t),
            else => {},
        }
    }
};

/// Classify `path` without following the final symlink.
pub fn inspectPath(gpa: std.mem.Allocator, io: Io, path: []const u8) Existing {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = Io.Dir.cwd();
    const len = cwd.readLink(io, path, &buf) catch |err| switch (err) {
        // Not a symlink: fall through to a stat.
        error.NotLink => {
            const st = cwd.statFile(io, path, .{ .follow_symlinks = false }) catch return .absent;
            return switch (st.kind) {
                .directory => .directory,
                else => .file,
            };
        },
        error.FileNotFound => return .absent,
        else => return .absent,
    };
    const target = gpa.dupe(u8, buf[0..len]) catch return .file;
    return .{ .symlink = target };
}

/// True when a symlink resolves to `target_path`.
pub fn linksTo(io: Io, link_path: []const u8, target_path: []const u8) bool {
    const gpa = std.heap.page_allocator;
    const e = inspectPath(gpa, io, link_path);
    defer e.deinit(gpa);
    return switch (e) {
        .symlink => |raw_target| std.mem.eql(u8, raw_target, target_path) or
            resolvesTo(io, gpa, link_path, target_path),
        else => false,
    };
}

/// Resolve the link and requested target only when their path spellings differ.
/// This preserves the fast path for ordinary symlinks while treating aliases as
/// the same target.
fn resolvesTo(io: Io, gpa: std.mem.Allocator, link_path: []const u8, target_path: []const u8) bool {
    const actual_path = std.fs.path.resolve(gpa, &.{link_path}) catch return false;
    defer gpa.free(actual_path);
    const expected_path = std.fs.path.resolve(gpa, &.{target_path}) catch return false;
    defer gpa.free(expected_path);

    const cwd = Io.Dir.cwd();
    const actual = cwd.realPathFileAlloc(io, actual_path, gpa) catch return false;
    defer gpa.free(actual);
    const expected = cwd.realPathFileAlloc(io, expected_path, gpa) catch return false;
    defer gpa.free(expected);
    return std.mem.eql(u8, actual, expected);
}

/// Recursively copy `src` to `dst`. Symlinks inside the tree are recreated as
/// symlinks rather than followed, so a skill directory that references a
/// sibling stays a reference.
pub fn copyTree(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    dst: []const u8,
) MaterializeError!void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dst);

    var dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ src, entry.name });
        defer gpa.free(child_src);
        const child_dst = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dst, entry.name });
        defer gpa.free(child_dst);

        switch (entry.kind) {
            .directory => try copyTree(gpa, io, child_src, child_dst),
            .sym_link => {
                var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const len = cwd.readLink(io, child_src, &buf) catch continue;
                cwd.symLinkAtomic(io, buf[0..len], child_dst, .{}) catch {};
            },
            else => try cwd.copyFile(child_src, cwd, child_dst, io, .{}),
        }
    }
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

/// Left-aligned field padded to `width`, for table output.
pub const Pad = struct {
    s: []const u8,
    width: usize,

    pub fn format(self: Pad, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{s}", .{self.s});
        var remaining = self.width -| self.s.len;
        while (remaining > 0) : (remaining -= 1) try w.writeAll(" ");
    }
};

pub fn pad(s: []const u8, width: usize) Pad {
    return .{ .s = s, .width = width };
}

/// Truncate `s` to `max` bytes on a UTF-8 boundary, appending an ellipsis.
pub fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    if (max == 0) return "";
    var end = max - 1;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

test "versionLess semver ordering" {
    try std.testing.expect(versionLess("v1.2.0", "v1.2.1"));
    try std.testing.expect(versionLess("1.2.9", "1.10.0"));
    try std.testing.expect(versionLess("v0.9", "v1.0"));
    try std.testing.expect(!versionLess("v2.0", "v1.99"));
    try std.testing.expect(!versionLess("v1.0", "v1.0"));
    try std.testing.expect(versionLess("1.0", "v2.0"));
}

test "formatRfc3339" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-29T16:26:00Z", formatRfc3339(&buf, 1790699160));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", formatRfc3339(&buf, 0));
}

test "LinkMode round trips through parse" {
    inline for (@typeInfo(LinkMode).@"enum".fields) |f| {
        const m: LinkMode = @enumFromInt(f.value);
        try std.testing.expectEqualStrings(f.name, m.name());
        try std.testing.expectEqual(m, LinkMode.parse(f.name).?);
    }
    try std.testing.expect(LinkMode.parse("nonsense") == null);
}

test "truncate keeps valid utf8 boundary" {
    try std.testing.expectEqualStrings("abc", truncate("abcdef", 4));
    // "aéx" is 4 bytes; a 3-byte budget must cut on the character boundary.
    try std.testing.expectEqualStrings("a", truncate("aéx", 3));
    // A budget smaller than the first character yields nothing rather than a
    // half-character.
    try std.testing.expectEqualStrings("", truncate("éx", 2));
    try std.testing.expectEqualStrings("", truncate("abcdef", 0));
    try std.testing.expectEqualStrings("ab", truncate("ab", 8));
    // A string that fits is returned untouched.
    try std.testing.expectEqualStrings("éx", truncate("éx", 3));
}

test "materialize creates the parent and uses the supported link mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "src/skill");
    const root = try dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(root);
    const src = try std.fs.path.join(gpa, &.{ root, "skill" });
    defer gpa.free(src);
    try dir.writeFile(io, .{ .sub_path = "src/skill/SKILL.md", .data = "body" });

    // The agent skills directory does not exist yet: this is a first run.
    const link = try std.fs.path.join(gpa, &.{ root, ".claude", "skills", "k" });
    defer gpa.free(link);

    const mode = try materialize(gpa, io, src, link, .auto);
    // Unix-like hosts use a symlink. Windows without symlink privileges uses
    // the documented copy fallback; both must create a usable skill directory.
    switch (mode) {
        .symlink => {
            try std.testing.expect(linksTo(io, link, src));
            const alias = try std.fs.path.join(gpa, &.{ root, ".", "skill" });
            defer gpa.free(alias);
            try std.testing.expect(linksTo(io, link, alias));
        },
        .copy => try std.testing.expect(dirExistsForTest(io, link)),
    }

    const again = try materialize(gpa, io, src, link, .auto);
    try std.testing.expectEqual(mode, again);
    switch (again) {
        .symlink => try std.testing.expect(linksTo(io, link, src)),
        .copy => try std.testing.expect(dirExistsForTest(io, link)),
    }
}

fn dirExistsForTest(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .directory;
}

test "materialize in copy mode produces a real directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "src/skill");
    const root = try dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(root);
    const src = try std.fs.path.join(gpa, &.{ root, "skill" });
    defer gpa.free(src);
    try dir.writeFile(io, .{ .sub_path = "src/skill/SKILL.md", .data = "body" });

    const link = try std.fs.path.join(gpa, &.{ root, ".codex", "skills", "k" });
    defer gpa.free(link);

    const mode = try materialize(gpa, io, src, link, .copy);
    try std.testing.expectEqual(Materialized.copy, mode);
    try std.testing.expect(!linksTo(io, link, src));
    try std.testing.expectEqual(Existing.directory, inspectPath(gpa, io, link));

    const copied_path = try std.fs.path.join(gpa, &.{ root, ".codex", "skills", "k", "SKILL.md" });
    defer gpa.free(copied_path);
    const copied = try readFileAlloc(Io.Dir.cwd(), io, gpa, copied_path);
    defer gpa.free(copied);
    try std.testing.expectEqualStrings("body", copied);
}
