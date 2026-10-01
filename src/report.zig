//! Human- and machine-readable rendering for `list`, `sources`, `doctor`,
//! `agents`, and `sync`.
//!
//! Every `--json` document is emitted by hand rather than through
//! `std.json.stringify`, so key order is stable and the output stays readable
//! and diffable in a terminal.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const agents_mod = @import("agents.zig");
const provision = @import("provision.zig");
const state = @import("state.zig");
const dragonfruit = @import("dragonfruit");
const util = @import("util.zig");

const w = std.json.fmt;

/// Width of the description column, and of a per-row summary buffer.
pub const desc_width = 48;
pub const summary_buf = 96;

fn shortCommit(commit: []const u8) []const u8 {
    if (commit.len <= 12) return commit;
    return commit[0..12];
}

/// A short provenance label: the version if known, else the commit prefix.
fn versionLabel(s: state.Skill) []const u8 {
    if (s.version.len > 0) return s.version;
    if (s.commit.len > 0) return shortCommit(s.commit);
    return "-";
}

/// Distinct agents a skill is linked into, in registry order, with `/p`
/// marking project scope. Written into a fixed buffer so table rows stay
/// aligned without allocating per row.
fn writeAgentSummary(buf: []u8, s: state.Skill) []const u8 {
    var len: usize = 0;
    for (agents_mod.all) |a| {
        var saw_global = false;
        var saw_project = false;
        for (s.links) |l| {
            if (!std.mem.eql(u8, l.agent, a.id)) continue;
            switch (l.scope) {
                .global => saw_global = true,
                .project => saw_project = true,
            }
        }
        if (!saw_global and !saw_project) continue;
        const suffix: []const u8 = if (saw_project) "/p" else "";
        if (len + a.id.len + suffix.len + 1 > buf.len) break;
        if (len > 0) {
            buf[len] = ',';
            len += 1;
        }
        @memcpy(buf[len .. len + a.id.len], a.id);
        len += a.id.len;
        @memcpy(buf[len .. len + suffix.len], suffix);
        len += suffix.len;
    }
    if (len == 0) {
        buf[0] = '-';
        return buf[0..1];
    }
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

pub fn printSkills(out: *Io.Writer, st: *const state.State) !void {
    if (st.skills.count() == 0) {
        try out.writeAll("no skills provisioned (run `zymposium sync`)\n");
        return;
    }

    var summary: [summary_buf]u8 = undefined;

    var name_w: usize = "SKILL".len;
    var prov_w: usize = "PROVIDER".len;
    var agent_w: usize = "AGENTS".len;
    var ver_w: usize = "VERSION".len;
    for (st.skills.values()) |s| {
        const sum = writeAgentSummary(&summary, s);
        name_w = @max(name_w, s.name.len);
        prov_w = @max(prov_w, s.provider.len);
        ver_w = @max(ver_w, versionLabel(s).len);
        agent_w = @max(agent_w, sum.len);
    }

    try out.print("{f}  {f}  {f}  {f}  {s}\n", .{
        util.pad("SKILL", name_w),
        util.pad("PROVIDER", prov_w),
        util.pad("VERSION", ver_w),
        util.pad("AGENTS", agent_w),
        "DESCRIPTION",
    });
    for (st.skills.values()) |s| {
        const sum = writeAgentSummary(&summary, s);
        try out.print("{f}  {f}  {f}  {f}  {s}\n", .{
            util.pad(s.name, name_w),
            util.pad(s.provider, prov_w),
            util.pad(versionLabel(s), ver_w),
            util.pad(sum, agent_w),
            if (s.description) |d| util.truncate(d, desc_width) else "",
        });
    }
}

pub fn skillsJson(gpa: std.mem.Allocator, st: *const state.State) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const out = &aw.writer;

    try out.print("{{\n  \"version\": {d},\n  \"skills\": [", .{st.version});
    for (st.skills.values(), 0..) |s, i| {
        if (i > 0) try out.writeAll(",");
        try out.print("\n    {{\n      \"name\": {f},\n      \"provider\": {f},\n", .{
            w(s.name, .{}),
            w(s.provider, .{}),
        });
        try out.print("      \"source_kind\": {f},\n      \"source_url\": {f},\n", .{
            w(s.source_kind.name(), .{}),
            w(s.source_url, .{}),
        });
        try out.print("      \"commit\": {f},\n      \"version\": {f},\n", .{
            w(s.commit, .{}),
            w(s.version, .{}),
        });
        try out.print("      \"skill_path\": {f},\n      \"description\": ", .{w(s.skill_path, .{})});
        if (s.description) |d| {
            try out.print("{f},\n", .{w(d, .{})});
        } else {
            try out.writeAll("null,\n");
        }
        try out.writeAll("      \"links\": [");
        for (s.links, 0..) |l, li| {
            if (li > 0) try out.writeAll(",");
            try out.print("\n        {{\"agent\": {f}, \"scope\": {f}, \"path\": {f}, \"mode\": {f}, \"project_root\": ", .{
                w(l.agent, .{}),
                w(l.scope.name(), .{}),
                w(l.path, .{}),
                w(if (l.mode == .copy) "copy" else "symlink", .{}),
            });
            if (l.project_root) |r| {
                try out.print("{f}}}", .{w(r, .{})});
            } else {
                try out.writeAll("null}");
            }
        }
        if (s.links.len > 0) try out.writeAll("\n      ");
        try out.writeAll("]\n    }");
    }
    if (st.skills.count() > 0) try out.writeAll("\n  ");
    try out.writeAll("]\n}\n");
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// sources
// ---------------------------------------------------------------------------

/// One provider row: what it is, where it came from, and what it offers.
pub const SourceRow = struct {
    provider: []const u8,
    kind: state.SourceKind,
    /// Human-readable origin: a clone URL, or a local path.
    origin: []const u8,
    version: []const u8,
    /// Names of skills this provider ships.
    skills: []const []const u8,
    /// How many of those are already provisioned.
    provisioned: usize,
};

pub fn printSources(out: *Io.Writer, rows: []const SourceRow) !void {
    if (rows.len == 0) {
        try out.writeAll("no skill sources found\n\n");
        try out.writeAll("Sources come from three places:\n");
        try out.writeAll("  zest tools      a tool installed by `zest` that ships a skills/ directory\n");
        try out.writeAll("  project deps    dependencies of the current build.zig.zon graph\n");
        try out.writeAll("  added packages  `zymposium add <url|path>`\n");
        return;
    }

    var prov_w: usize = "PROVIDER".len;
    var kind_w: usize = "KIND".len;
    var ver_w: usize = "VERSION".len;
    var skills_w: usize = "SKILLS".len;
    for (rows) |r| {
        const summary = writeSkillsSummary(r);
        prov_w = @max(prov_w, r.provider.len);
        kind_w = @max(kind_w, r.kind.name().len);
        ver_w = @max(ver_w, r.version.len);
        skills_w = @max(skills_w, summary.len);
    }

    try out.print("{f}  {f}  {f}  {f}  {s}\n", .{
        util.pad("PROVIDER", prov_w),
        util.pad("KIND", kind_w),
        util.pad("VERSION", ver_w),
        util.pad("SKILLS", skills_w),
        "ORIGIN",
    });
    for (rows) |r| {
        var buf: [summary_buf]u8 = undefined;
        const summary = writeSkillsSummaryInto(&buf, r);
        try out.print("{f}  {f}  {f}  {f}  {s}\n", .{
            util.pad(r.provider, prov_w),
            util.pad(r.kind.name(), kind_w),
            util.pad(r.version, ver_w),
            util.pad(summary, skills_w),
            r.origin,
        });
    }
}

/// `3 (2)`, meaning three skills of which two are already provisioned; `-`
/// when the provider ships none.
fn writeSkillsSummaryInto(buf: []u8, r: SourceRow) []const u8 {
    if (r.skills.len == 0) {
        buf[0] = '-';
        return buf[0..1];
    }
    return std.fmt.bufPrint(buf, "{d} ({d})", .{ r.skills.len, r.provisioned }) catch blk: {
        buf[0] = '?';
        break :blk buf[0..1];
    };
}

fn writeSkillsSummary(r: SourceRow) []const u8 {
    var buf: [summary_buf]u8 = undefined;
    return writeSkillsSummaryInto(&buf, r);
}

pub fn sourcesJson(gpa: std.mem.Allocator, rows: []const SourceRow) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const out = &aw.writer;
    try out.writeAll("{\n  \"sources\": [");
    for (rows, 0..) |r, i| {
        if (i > 0) try out.writeAll(",");
        try out.print("\n    {{\"provider\": {f}, \"kind\": {f}, \"origin\": {f}, \"version\": {f}, \"provisioned\": {d}, \"skills\": [", .{
            w(r.provider, .{}),
            w(r.kind.name(), .{}),
            w(r.origin, .{}),
            w(r.version, .{}),
            r.provisioned,
        });
        for (r.skills, 0..) |sk, si| {
            if (si > 0) try out.writeAll(", ");
            try out.print("{f}", .{w(sk, .{})});
        }
        try out.writeAll("]}");
    }
    try out.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

pub fn printProblems(
    out: *Io.Writer,
    style: dragonfruit.Style,
    glyphs: dragonfruit.Glyphs,
    problems: []const provision.Problem,
) !void {
    if (problems.len == 0) {
        try dragonfruit.status(
            out,
            style,
            glyphs,
            .success,
            "all provisioned skills are healthy",
            .{},
        );
        return;
    }
    try dragonfruit.status(
        out,
        style,
        glyphs,
        .warning,
        "{d} problem(s) found; `zymposium sync` repairs most of them:",
        .{problems.len},
    );
    for (problems) |p| {
        try dragonfruit.status(
            out,
            style,
            glyphs,
            .failure,
            "  {f}  {s}  {s}",
            .{ util.pad(p.kind.name(), "orphaned".len), p.skill, p.path },
        );
    }
}

pub fn problemsJson(gpa: std.mem.Allocator, problems: []const provision.Problem) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const out = &aw.writer;
    try out.print("{{\n  \"problems\": {d},\n  \"items\": [", .{problems.len});
    for (problems, 0..) |p, i| {
        if (i > 0) try out.writeAll(",");
        try out.print("\n    {{\"skill\": {f}, \"path\": {f}, \"kind\": {f}}}", .{
            w(p.skill, .{}),
            w(p.path, .{}),
            w(p.kind.name(), .{}),
        });
    }
    try out.writeAll("\n  ]\n}\n");
    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// agents
// ---------------------------------------------------------------------------

pub fn printAgents(out: *Io.Writer, enabled: []const []const u8, home: ?[]const u8) !void {
    try out.print("{f}  {f}  {f}  {s}\n", .{
        util.pad(" ", 2),
        util.pad("AGENT", 18),
        util.pad("DISPLAY", 18),
        "PATHS",
    });
    for (agents_mod.all) |a| {
        var on = false;
        for (enabled) |id| {
            if (std.mem.eql(u8, id, a.id)) on = true;
        }
        try out.print("{s}  {f}  {f}  {s}\n", .{
            if (on) "* " else "  ",
            util.pad(a.id, 18),
            util.pad(a.display, 18),
            a.project_subdir,
        });
    }
    try out.writeAll("\n* enabled in config.json\n");
    if (home != null) {
        try out.writeAll("global paths are relative to $HOME\n");
    } else {
        try out.writeAll("no $HOME in the environment: only project scope is available\n");
    }
}

// ---------------------------------------------------------------------------
// sync
// ---------------------------------------------------------------------------

pub fn printSync(
    out: *Io.Writer,
    style: dragonfruit.Style,
    glyphs: dragonfruit.Glyphs,
    o: provision.Outcome,
) !void {
    const summary_status: dragonfruit.Status = if (o.conflicts.len == 0) .success else .warning;
    try dragonfruit.status(
        out,
        style,
        glyphs,
        summary_status,
        "linked {d}, updated {d}, unchanged {d}, removed {d}",
        .{ o.linked, o.updated, o.unchanged, o.removed },
    );
    for (o.conflicts) |c| {
        try dragonfruit.status(
            out,
            style,
            glyphs,
            .failure,
            "conflict: {s} is held by {s}, wanted by {s}",
            .{ c.path, c.holder, c.claimant },
        );
    }
}

pub fn syncJson(gpa: std.mem.Allocator, o: provision.Outcome) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const out = &aw.writer;
    try out.print(
        "{{\"linked\": {d}, \"updated\": {d}, \"unchanged\": {d}, \"removed\": {d}, \"conflicts\": [",
        .{ o.linked, o.updated, o.unchanged, o.removed },
    );
    for (o.conflicts, 0..) |c, i| {
        if (i > 0) try out.writeAll(",");
        try out.print("{{\"path\": {f}, \"holder\": {f}, \"claimant\": {f}}}", .{
            w(c.path, .{}),
            w(c.holder, .{}),
            w(c.claimant, .{}),
        });
    }
    try out.writeAll("]}\n");
    return aw.toOwnedSlice();
}

/// Shorten a path for display by replacing the home prefix with `~`.
pub fn tildify(gpa: std.mem.Allocator, home: ?[]const u8, path: []const u8) ![]u8 {
    const h = home orelse return gpa.dupe(u8, path);
    if (!std.mem.startsWith(u8, path, h)) return gpa.dupe(u8, path);
    if (path.len == h.len) return gpa.dupe(u8, "~");
    if (path[h.len] != '/') return gpa.dupe(u8, path);
    return std.fmt.allocPrint(gpa, "~{s}", .{path[h.len..]});
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "writeAgentSummary lists agents in registry order and marks project scope" {
    // These fixtures are never deinit'd, so pointing the owning fields at
    // string literals is safe here even though the struct takes ownership.
    const cs = @as([]u8, @constCast("s"));
    const cp_ = @as([]u8, @constCast("p"));
    const empty = @as([]u8, @constCast(""));

    var buf: [summary_buf]u8 = undefined;
    var links = [_]state.Link{
        .{ .agent = @constCast("claude"), .scope = .global, .path = @constCast("/p"), .mode = .symlink, .project_root = null },
        .{ .agent = @constCast("codex"), .scope = .project, .path = @constCast("/p"), .mode = .symlink, .project_root = @constCast("/w") },
        .{ .agent = @constCast("agent"), .scope = .global, .path = @constCast("/p"), .mode = .symlink, .project_root = null },
    };
    var none = [_]state.Link{};

    const with_links = state.Skill{
        .name = cs,
        .provider = cp_,
        .source_kind = .package,
        .source_url = empty,
        .commit = empty,
        .version = empty,
        .skill_path = empty,
        .description = null,
        .provisioned_at = empty,
        .links = &links,
    };
    const without_links = state.Skill{
        .name = cs,
        .provider = cp_,
        .source_kind = .package,
        .source_url = empty,
        .commit = empty,
        .version = empty,
        .skill_path = empty,
        .description = null,
        .provisioned_at = empty,
        .links = &none,
    };

    try std.testing.expectEqualStrings("claude,codex/p,agent", writeAgentSummary(&buf, with_links));
    try std.testing.expectEqualStrings("-", writeAgentSummary(&buf, without_links));
}

test "writeSkillsSummary distinguishes offered from provisioned" {
    var buf: [summary_buf]u8 = undefined;
    const names = [_][]const u8{ "a", "b", "c" };
    try std.testing.expectEqualStrings(
        "3 (2)",
        writeSkillsSummaryInto(&buf, .{
            .provider = "p",
            .kind = .package,
            .origin = "x",
            .version = "",
            .skills = &names,
            .provisioned = 2,
        }),
    );
    try std.testing.expectEqualStrings(
        "-",
        writeSkillsSummaryInto(&buf, .{
            .provider = "p",
            .kind = .package,
            .origin = "x",
            .version = "",
            .skills = &.{},
            .provisioned = 0,
        }),
    );
}

test "tildify replaces only a real home prefix" {
    const gpa = std.testing.allocator;
    {
        const r = try tildify(gpa, "/home/u", "/home/u/.claude/skills/x");
        defer gpa.free(r);
        try std.testing.expectEqualStrings("~/.claude/skills/x", r);
    }
    {
        // A sibling directory sharing the prefix must not be rewritten.
        const r = try tildify(gpa, "/home/u", "/home/user2/x");
        defer gpa.free(r);
        try std.testing.expectEqualStrings("/home/user2/x", r);
    }
    {
        const r = try tildify(gpa, "/home/u", "/home/u");
        defer gpa.free(r);
        try std.testing.expectEqualStrings("~", r);
    }
    {
        const r = try tildify(gpa, null, "/opt/x");
        defer gpa.free(r);
        try std.testing.expectEqualStrings("/opt/x", r);
    }
}

fn addTestSkill(gpa: std.mem.Allocator, st: *state.State, name: []const u8) !void {
    const links = try gpa.alloc(state.Link, 1);
    links[0] = .{
        .agent = try gpa.dupe(u8, "claude"),
        .scope = .global,
        .path = try std.fmt.allocPrint(gpa, "/h/.claude/skills/prov/{s}", .{name}),
        .mode = .symlink,
        .project_root = null,
    };
    try st.skills.put(gpa, try state.State.identityKey(gpa, "prov", name), .{
        .name = try gpa.dupe(u8, name),
        .provider = try gpa.dupe(u8, "prov"),
        .source_kind = .zest_tool,
        .source_url = try gpa.dupe(u8, "https://x"),
        .commit = try gpa.dupe(u8, "abcdef1234567890"),
        .version = try gpa.dupe(u8, ""),
        .skill_path = try std.fmt.allocPrint(gpa, "/src/skills/{s}", .{name}),
        .description = null,
        .provisioned_at = try gpa.dupe(u8, "2026-01-01T00:00:00Z"),
        .links = links,
    });
}

test "skillsJson is valid JSON and carries provenance" {
    const gpa = std.testing.allocator;
    var st: state.State = .{ .gpa = gpa };
    defer st.deinit();
    try addTestSkill(gpa, &st, "s");

    const text = try skillsJson(gpa, &st);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\": \"s\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"source_kind\": \"zest_tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"description\": null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"mode\": \"symlink\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"project_root\": null") != null);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch unreachable;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("skills").?.array.items.len);
}

test "empty state renders a valid empty list document" {
    const gpa = std.testing.allocator;
    var st: state.State = .{ .gpa = gpa };
    defer st.deinit();
    const text = try skillsJson(gpa, &st);
    defer gpa.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch unreachable;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("skills").?.array.items.len);
}

test "sourcesJson round trips through the JSON parser" {
    const gpa = std.testing.allocator;
    const names = [_][]const u8{ "one", "two" };
    const rows = [_]SourceRow{.{
        .provider = "zig-cc",
        .kind = .zest_tool,
        .origin = "https://github.com/zig-cc/zig-cc",
        .version = "v1.0.0",
        .skills = &names,
        .provisioned = 1,
    }};
    const text = try sourcesJson(gpa, &rows);
    defer gpa.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch unreachable;
    defer parsed.deinit();
    const list = parsed.value.object.get("sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings(
        "zig-cc",
        list[0].object.get("provider").?.string,
    );
}
