//! Discovery of skills belonging to CLI tools that
//! [zest](https://github.com/JustinWoodring/zest) has installed.
//!
//! zymposium does not link against zest as a library — it reads zest's
//! on-disk state. Under the zest data root (`$XDG_DATA_HOME/zest` by
//! default):
//!
//!   state.json          which tools are installed, and at which commit
//!   src/<name>/         the staged git clone, where `skills/` lives
//!
//! Absence is the common case, not an error: most users never run zest, and a
//! `zymposium sync` must stay quiet for them. A half-cleaned state — a tool
//! listed in `state.json` whose clone is gone — is likewise skipped rather
//! than fatal.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const sources = @import("sources.zig");
const state = @import("state.zig");
const util = @import("util.zig");

pub const Error = error{
    /// `state.json` exists but is not a JSON object we can make sense of.
    InvalidState,
    OutOfMemory,
} || util.ReadFileError || Io.Dir.StatFileError || Io.Cancelable || Io.UnexpectedError;

/// Read zest's `state.json` and return one candidate per installed tool whose
/// staged clone actually contains a `skills` directory. Caller frees with
/// `sources.freeCandidates`.
///
/// A missing zest root or `state.json` is not an error: it yields an empty
/// slice, because a user with no zest installation must not be told they have
/// one.
pub fn collect(gpa: std.mem.Allocator, io: Io, zest_root: []const u8) Error![]sources.Candidate {
    const state_path = try std.fmt.allocPrint(gpa, "{s}/state.json", .{zest_root});
    defer gpa.free(state_path);

    const bytes = util.readFileAlloc(Io.Dir.cwd(), io, gpa, state_path) catch |err| switch (err) {
        error.FileNotFound => return gpa.alloc(sources.Candidate, 0),
        else => |e| return e,
    };
    defer gpa.free(bytes);

    var out: std.ArrayList(sources.Candidate) = .empty;
    // `freeCandidates` frees a slice the caller owns; `out.items` is only a
    // view into the list's own buffer, so the list is deinitialized instead.
    errdefer {
        for (out.items) |*c| c.deinit(gpa);
        out.deinit(gpa);
    }

    // Parsing into a generic value keeps this tolerant: zest may add fields,
    // and a single mangled tool entry should cost that tool, not the sync.
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        // Running out of memory is not evidence that zest wrote nonsense, and
        // reporting it as a corrupt manifest would send the user hunting.
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidState,
    };
    const tools = switch (root.get("tools") orelse return out.toOwnedSlice(gpa)) {
        .object => |o| o,
        else => return error.InvalidState,
    };

    var it = tools.iterator();
    while (it.next()) |entry| {
        const obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            // A tool whose entry is not an object has no usable provenance.
            else => continue,
        };
        const name = entry.key_ptr.*;

        // A tool whose staged clone is gone, or that ships no skills, is
        // skipped: a half-cleaned state must not fail a sync.
        const tool_root = try std.fmt.allocPrint(gpa, "{s}/src/{s}", .{ zest_root, name });
        if (!hasSkills(io, gpa, tool_root)) {
            gpa.free(tool_root);
            continue;
        }
        // `buildCandidate` owns every allocation on its error paths and hands
        // them over on success, so the only unwinding left here is a failed
        // append, which arrives with a fully built candidate in hand.
        const candidate = try buildCandidate(gpa, name, tool_root, obj);
        out.append(gpa, candidate) catch |err| {
            var orphaned = candidate;
            orphaned.deinit(gpa);
            return err;
        };
    }

    // Deterministic order: a sync that reshuffles its report every run looks
    // like it changed something.
    const owned = try out.toOwnedSlice(gpa);
    std.mem.sort(sources.Candidate, owned, {}, lessByProvider);
    return owned;
}

fn lessByProvider(_: void, a: sources.Candidate, b: sources.Candidate) bool {
    return std.mem.order(u8, a.provider, b.provider) == .lt;
}

/// Read an optional provenance string. A missing, null, or non-string field is
/// an empty string rather than an error: provenance is display data, and a
/// tool installed by an older zest should still offer its skills.
fn optString(
    gpa: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) error{OutOfMemory}![]u8 {
    const v = obj.get(key) orelse return gpa.dupe(u8, "");
    return switch (v) {
        .string => |s| gpa.dupe(u8, s),
        else => gpa.dupe(u8, ""),
    };
}

/// True when `tool_root` holds a `skills` directory. A missing staged clone
/// is a partially cleaned state, so this answers false rather than failing.
fn hasSkills(io: Io, gpa: std.mem.Allocator, tool_root: []const u8) bool {
    const skills_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ tool_root, manifest.skills_dir_name }) catch
        return false;
    defer gpa.free(skills_path);
    const st = Io.Dir.cwd().statFile(io, skills_path, .{}) catch return false;
    return st.kind == .directory;
}

/// Build one candidate, taking ownership of `tool_root` and of every string it
/// allocates. On error it frees all of them itself, so the caller's only job
/// is to append the result.
fn buildCandidate(
    gpa: std.mem.Allocator,
    name: []const u8,
    tool_root: []u8,
    obj: std.json.ObjectMap,
) error{OutOfMemory}!sources.Candidate {
    errdefer gpa.free(tool_root);
    const provider = try gpa.dupe(u8, name);
    errdefer gpa.free(provider);
    const source_url = try optString(gpa, obj, "source_url");
    errdefer gpa.free(source_url);
    const commit = try optString(gpa, obj, "commit");
    errdefer gpa.free(commit);
    const version = try optString(gpa, obj, "version");
    return .{
        .provider = provider,
        .source_kind = .zest_tool,
        .source_url = source_url,
        .commit = commit,
        .version = version,
        .root = tool_root,
    };
}

const testing = std.testing;

test "collect finds a tool whose staged clone has skills" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A skill directory is what makes a clone worth offering, so discovery
    // agrees with what `manifest.discover` would later find inside it.
    try tmp.dir.createDirPath(io, "src/zest-tool/skills/deploy");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/zest-tool/skills/deploy/SKILL.md",
        .data = "---\nname: deploy\n---\n",
    });

    // A tool with a clone but no skills directory.
    try tmp.dir.createDirPath(io, "src/plain-tool");
    // A tool with no clone at all: a half-cleaned state.
    try writeState(tmp.dir, io,
        \\{
        \\  "version": 1,
        \\  "tools": {
        \\    "zest-tool": {
        \\      "source_url": "https://github.com/JustinWoodring/zest",
        \\      "version": "v1.2.0",
        \\      "commit": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        \\      "installed_binary": "/home/u/.local/share/zest/bin/zest-tool",
        \\      "installed_at": "2026-09-29T16:26:00Z",
        \\      "unknown_future_field": 42
        \\    },
        \\    "plain-tool": {
        \\      "source_url": "https://example.com/plain",
        \\      "version": "main",
        \\      "commit": "abc",
        \\      "installed_binary": "/bin/plain",
        \\      "installed_at": "2026-09-29T16:26:00Z"
        \\    },
        \\    "gone-tool": {
        \\      "source_url": "https://example.com/gone",
        \\      "version": "v0.1.0",
        \\      "commit": "def",
        \\      "installed_binary": "/bin/gone",
        \\      "installed_at": "2026-09-29T16:26:00Z"
        \\    }
        \\  }
        \\}
    );

    const root = try tmpRoot(gpa, &tmp);
    defer gpa.free(root);

    const found = try collect(gpa, io, root);
    defer sources.freeCandidates(gpa, found);

    try testing.expectEqual(@as(usize, 1), found.len);
    const c = found[0];
    try testing.expectEqualStrings("zest-tool", c.provider);
    try testing.expectEqual(state.SourceKind.zest_tool, c.source_kind);
    try testing.expectEqualStrings("https://github.com/JustinWoodring/zest", c.source_url);
    try testing.expectEqualStrings("v1.2.0", c.version);
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", c.commit);
    try testing.expectEqualStrings(root, c.root[0..root.len]);
    try testing.expect(std.mem.endsWith(u8, c.root, "/src/zest-tool"));

    // The candidate root must actually resolve to the staged clone, so the
    // skills it claims are the ones on disk.
    const skills = try manifest.discover(gpa, io, c.root);
    defer manifest.freeSkills(gpa, skills);
    try testing.expectEqual(@as(usize, 1), skills.len);
    try testing.expectEqualStrings("deploy", skills[0].name);
}

test "collect is quiet when zest is not installed" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(gpa, &tmp);
    defer gpa.free(root);

    // No state.json at all, and no src/ either.
    const found = try collect(gpa, io, root);
    defer sources.freeCandidates(gpa, found);
    try testing.expectEqual(@as(usize, 0), found.len);

    // A state.json that lists nothing.
    try writeState(tmp.dir, io,
        \\{
        \\  "version": 1,
        \\  "tools": {}
        \\}
    );
    const after = try collect(gpa, io, root);
    defer sources.freeCandidates(gpa, after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "collect tolerates malformed entries but rejects unusable state" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/good/skills/s");

    const root = try tmpRoot(gpa, &tmp);
    defer gpa.free(root);

    // A non-object tool entry, an entry with no provenance fields, and one
    // naming a clone that does not exist: none may fail the whole sync.
    try writeState(tmp.dir, io,
        \\{
        \\  "version": 1,
        \\  "tools": {
        \\    "broken": "not an object",
        \\    "good": { "source_url": "https://example.com/good", "commit": null },
        \\    "missing": { "source_url": "https://example.com/missing" }
        \\  }
        \\}
    );
    const found = try collect(gpa, io, root);
    defer sources.freeCandidates(gpa, found);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("good", found[0].provider);
    // Absent and null provenance become empty, not missing fields.
    try testing.expectEqualStrings("", found[0].version);
    try testing.expectEqualStrings("https://example.com/good", found[0].source_url);
    try testing.expectEqualStrings("", found[0].commit);

    // A state.json that is not JSON at all is a real error: something other
    // than zest wrote it, and silently ignoring it would hide that.
    try writeState(tmp.dir, io, "{ not json");
    try testing.expectError(error.InvalidState, collect(gpa, io, root));

    // Valid JSON that is not an object is equally unusable.
    try writeState(tmp.dir, io, "[1, 2, 3]");
    try testing.expectError(error.InvalidState, collect(gpa, io, root));

    try writeState(tmp.dir, io, "{ \"tools\": [] }");
    try testing.expectError(error.InvalidState, collect(gpa, io, root));
}

test "collect returns candidates in a stable order" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "zeta", "alpha", "mid" }) |name| {
        const path = try std.fmt.allocPrint(gpa, "src/{s}/skills/s", .{name});
        defer gpa.free(path);
        try tmp.dir.createDirPath(io, path);
    }

    const root = try tmpRoot(gpa, &tmp);
    defer gpa.free(root);

    try writeState(tmp.dir, io,
        \\{
        \\  "version": 1,
        \\  "tools": {
        \\    "zeta": {},
        \\    "alpha": {},
        \\    "mid": {}
        \\  }
        \\}
    );
    const found = try collect(gpa, io, root);
    defer sources.freeCandidates(gpa, found);
    try testing.expectEqual(@as(usize, 3), found.len);
    try testing.expectEqualStrings("alpha", found[0].provider);
    try testing.expectEqualStrings("mid", found[1].provider);
    try testing.expectEqualStrings("zeta", found[2].provider);
}

/// The tmp dir's path as `collect` sees it. `testing.tmpDir` hands back a
/// `Dir` handle plus a path relative to `.zig-cache/tmp`, and `collect`
/// resolves every path against the cwd, so a cwd-relative path is what makes
/// the two agree.
fn tmpRoot(gpa: std.mem.Allocator, tmp: *const testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn writeState(dir: Io.Dir, io: Io, text: []const u8) !void {
    return dir.writeFile(io, .{ .sub_path = "state.json", .data = text });
}
