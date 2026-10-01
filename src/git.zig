//! Git plumbing via the system `git` binary: shallow clone, commit
//! inspection, and tag discovery.
//!
//! zymposium does not link libgit2; it shells out. Every invocation goes
//! through `run`, so combined output is captured and a missing `git` is
//! reported as one error rather than a spawn failure.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

pub const Result = struct {
    ok: bool,
    /// Combined stdout+stderr; caller owns memory.
    output: []u8,
};

pub const Error = error{
    GitNotFound,
    RevParseFailed,
    LsRemoteFailed,
    OutOfMemory,
    WriteFailed,
} || std.process.RunError || Io.Cancelable || Io.UnexpectedError;

/// Run git with captured output. `cwd` selects the working directory
/// (null = inherit).
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) Error!Result {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => |e| return e,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    // git reports progress and failures on stderr; interleaving the two keeps
    // whatever the user sees identical to what the caller reports.
    try aw.writer.print("{s}{s}", .{ result.stdout, result.stderr });

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .ok = ok, .output = try aw.toOwnedSlice() };
}

/// True when a `git` binary is on PATH and runnable.
pub fn exists(gpa: std.mem.Allocator, io: Io) bool {
    const res = run(gpa, io, &.{ "git", "--version" }, null) catch return false;
    defer gpa.free(res.output);
    return res.ok;
}

/// Shallow-clone `url` into `dest`, optionally at `ref` (a tag or branch).
///
/// Depth 1 is enough for provisioning skills and keeps a large tool's clone
/// to a fraction of its history.
pub fn clone(
    gpa: std.mem.Allocator,
    io: Io,
    url: []const u8,
    dest: []const u8,
    ref: ?[]const u8,
) Error!Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "clone", "--quiet", "--depth", "1" });
    if (ref) |r| try argv.appendSlice(gpa, &.{ "--branch", r });
    try argv.appendSlice(gpa, &.{ url, dest });
    return run(gpa, io, argv.items, null);
}

/// Full commit hash of HEAD. Caller owns memory.
pub fn headCommit(gpa: std.mem.Allocator, io: Io, dir: []const u8) Error![]u8 {
    const res = try run(gpa, io, &.{ "git", "rev-parse", "HEAD" }, dir);
    if (!res.ok) {
        gpa.free(res.output);
        return error.RevParseFailed;
    }
    defer gpa.free(res.output);
    return gpa.dupe(u8, std.mem.trim(u8, res.output, " \t\r\n"));
}

/// Current branch name ("HEAD" when detached). Caller owns memory.
pub fn currentBranch(gpa: std.mem.Allocator, io: Io, dir: []const u8) Error![]u8 {
    const res = try run(gpa, io, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, dir);
    if (!res.ok) {
        gpa.free(res.output);
        return error.RevParseFailed;
    }
    defer gpa.free(res.output);
    return gpa.dupe(u8, std.mem.trim(u8, res.output, " \t\r\n"));
}

/// Highest tag published on `url` (semver-aware), or null when it has none.
/// Caller owns memory.
pub fn latestTag(gpa: std.mem.Allocator, io: Io, url: []const u8) Error!?[]u8 {
    const res = try run(gpa, io, &.{ "git", "ls-remote", "--tags", "--refs", url }, null);
    if (!res.ok) {
        gpa.free(res.output);
        return error.LsRemoteFailed;
    }
    defer gpa.free(res.output);
    const best = pickLatestTag(res.output) orelse return null;
    return try gpa.dupe(u8, best);
}

/// Highest tag named in `git ls-remote --tags --refs` output, borrowed from
/// `output`.
///
/// Split out from `latestTag` so the ordering rule is testable without a
/// network round trip: `v1.10.0` must beat `v1.9.0`, which a plain string
/// comparison gets backwards.
pub fn pickLatestTag(output: []const u8) ?[]const u8 {
    const prefix = "refs/tags/";
    var best: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Lines look like "<sha>\trefs/tags/v1.2.3".
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const ref_name = line[tab + 1 ..];
        if (!std.mem.startsWith(u8, ref_name, prefix)) continue;
        const tag = ref_name[prefix.len..];
        if (tag.len == 0) continue;
        // `refs/tags/v1.0.0^{}` is the peeled commit of an annotated tag: the
        // same release as the plain entry, but versionLess would rank the
        // longer string above the release itself.
        if (std.mem.endsWith(u8, tag, "^{}")) continue;
        if (best == null or util.versionLess(best.?, tag)) best = tag;
    }
    return best;
}

/// Strip the URL scheme qualifier a Zig package manager records for a
/// dependency that must be fetched with git, e.g. `git+https://host/x.git` →
/// `https://host/x.git`. Anything without the qualifier is returned as is.
pub fn normalizeGitUrl(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "git+")) return url["git+".len..];
    return url;
}

/// True when `url` can be handed to `git clone`.
///
/// Archive downloads are rejected: `https://host/x.tar.gz` is a plain HTTP
/// fetch that a package manager may declare, but git cannot clone it. Callers
/// use this to decide whether a dependency is fetchable at all.
pub fn isGitUrl(url: []const u8) bool {
    const bare = normalizeGitUrl(url);
    for (git_schemes) |scheme| {
        if (!std.mem.startsWith(u8, bare, scheme)) continue;
        return !isArchivePath(bare[scheme.len..]);
    }
    return false;
}

/// URL schemes `git` can be handed directly.
// `file://` is included so a repository on the local filesystem can be a
// dependency in tests and in air-gapped setups; git clones it normally.
const git_schemes = [_][]const u8{ "https://", "http://", "ssh://", "git://", "file://" };

/// True when the path part of a URL names a downloadable archive rather than
/// a repository. Compared case-insensitively because registry URLs are
/// routinely upper-cased by hand.
pub fn isArchivePath(path: []const u8) bool {
    for (archive_suffixes) |suffix| {
        if (std.ascii.endsWithIgnoreCase(path, suffix)) return true;
    }
    return false;
}

const archive_suffixes = [_][]const u8{
    ".tar.gz",
    ".tar.bz2",
    ".tar.xz",
    ".tar.zst",
    ".tgz",
    ".tbz2",
    ".txz",
    ".tar",
    ".zip",
    ".7z",
    ".whl",
    ".crate",
};

test "isGitUrl accepts cloneable transports" {
    for ([_][]const u8{
        "https://github.com/JustinWoodring/zest",
        "https://github.com/JustinWoodring/zest.git",
        "git+https://github.com/JustinWoodring/zest.git",
        "git+ssh://git@github.com/JustinWoodring/zest.git",
        "http://example.com/repo",
        "ssh://git@example.com/repo.git",
        "git://example.com/repo.git",
    }) |url| {
        try std.testing.expect(isGitUrl(url));
    }
}

test "isGitUrl rejects archives and non-URLs" {
    for ([_][]const u8{
        "https://example.com/x.tar.gz",
        "git+https://example.com/x.tar.gz",
        "https://example.com/pkg.zip",
        "https://example.com/pkg-1.0.0.tgz",
        "https://example.com/PKG.TAR.GZ",
        "https://example.com/releases/v1.0.0.whl",
        "https://example.com/some/package.tgz",
        "./local/path",
        "",
    }) |url| {
        try std.testing.expect(!isGitUrl(url));
    }
}

test "normalizeGitUrl strips only a leading git+" {
    try std.testing.expectEqualStrings(
        "https://example.com/x.git",
        normalizeGitUrl("git+https://example.com/x.git"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/x.git",
        normalizeGitUrl("https://example.com/x.git"),
    );
    // A `git+` that is part of the host is not a qualifier.
    try std.testing.expectEqualStrings("https://git+x.example", normalizeGitUrl("https://git+x.example"));
    try std.testing.expectEqualStrings("", normalizeGitUrl("git+"));
}

test "pickLatestTag orders tags semantically not lexically" {
    // Real ls-remote output: "<sha>\t<ref>".
    const output =
        "abc123\trefs/tags/v0.9.0\n" ++
        "def456\trefs/tags/v1.9.0\n" ++
        "789abc\trefs/tags/v1.10.0\n" ++
        "0f0f0f\trefs/tags/v2.0.0-rc1\n";
    try std.testing.expectEqualStrings("v2.0.0-rc1", pickLatestTag(output).?);

    // `v1.10.0` > `v1.9.0`: the failure a string sort would produce.
    const two =
        "a\trefs/tags/v1.9.0\n" ++
        "b\trefs/tags/v1.10.0\n";
    try std.testing.expectEqualStrings("v1.10.0", pickLatestTag(two).?);

    // Peeled annotated tags carry `^{}` and name the same commit as their
    // plain entry; keeping them would double-count but never change the max.
    const annotated =
        "a\trefs/tags/v1.0.0\n" ++
        "b\trefs/tags/v1.0.0^{}\n";
    try std.testing.expectEqualStrings("v1.0.0", pickLatestTag(annotated).?);

    try std.testing.expect(pickLatestTag("") == null);
    try std.testing.expect(pickLatestTag("abc123\trefs/heads/main\n") == null);
    try std.testing.expect(pickLatestTag("no-tab-here\n") == null);
}

test "isArchivePath matches archive suffixes case-insensitively" {
    try std.testing.expect(isArchivePath("/x.tar.gz"));
    try std.testing.expect(isArchivePath("/X.TGZ"));
    try std.testing.expect(isArchivePath("a/b/c.zip"));
    try std.testing.expect(!isArchivePath("/repo.git"));
    try std.testing.expect(!isArchivePath(""));
}
