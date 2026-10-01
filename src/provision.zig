//! The provisioning engine: turn discovered skills into links inside agent
//! skill directories, and reconcile those links against what we did last time.
//!
//! Two invariants make this safe to run repeatedly from a package manager:
//!
//!  * zymposium only ever deletes a path recorded in its own manifest, so a
//!    hand-written skill sitting beside a provisioned one survives every sync.
//!  * install paths are namespaced as `<provider>/<skill-name>`, so two
//!    packages can ship the same skill without colliding. A conflict is only
//!    reported when a user-owned path occupies that exact namespaced target.
//!
//! Pruning is scoped: a run that touches the global boundary and one project
//! leaves links belonging to every other project alone.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const paths_mod = @import("paths.zig");
const Io = std.Io;
const agents_mod = @import("agents.zig");
const config_mod = @import("config.zig");
const sources = @import("sources.zig");
const state = @import("state.zig");
const util = @import("util.zig");

/// One boundary zymposium manages skills within.
pub const Context = struct {
    scope: state.ScopeKind,
    /// Project root, or null for the global boundary.
    project_root: ?[]const u8 = null,

    pub fn eql(a: Context, b: Context) bool {
        if (a.scope != b.scope) return false;
        if (a.project_root == null and b.project_root == null) return true;
        const x = a.project_root orelse return false;
        const y = b.project_root orelse return false;
        return std.mem.eql(u8, x, y);
    }
};

/// A target path that already holds something zymposium does not own.
pub const Conflict = struct {
    /// Skill name or path that could not be written.
    path: []u8,
    /// Who currently holds the name.
    holder: []u8,
    /// Who wanted it.
    claimant: []u8,

    pub fn deinit(self: *Conflict, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.holder);
        gpa.free(self.claimant);
    }
};

pub fn freeConflicts(gpa: std.mem.Allocator, items: []Conflict) void {
    for (items) |*c| c.deinit(gpa);
    gpa.free(items);
}

pub const Outcome = struct {
    /// Skills written for the first time.
    linked: usize = 0,
    /// Existing skills whose links were rewritten.
    updated: usize = 0,
    /// Skills already correct; no filesystem change.
    unchanged: usize = 0,
    /// Skills dropped because nothing provides them any more.
    removed: usize = 0,
    conflicts: []Conflict = &.{},

    pub fn deinit(self: *Outcome, gpa: std.mem.Allocator) void {
        freeConflicts(gpa, self.conflicts);
        self.conflicts = &.{};
    }
};

pub const Options = struct {
    config: *const config_mod.Config,
    /// User home, required whenever the global boundary is in play.
    home: ?[]const u8 = null,
    /// Project root when running inside a project, else null.
    project_root: ?[]const u8 = null,
    /// Take over paths zymposium does not own, and let a second provider
    /// replace an existing claim.
    force: bool = false,
    /// Restrict the run to skills from this provider. Pruning is limited to
    /// that provider's skills, so `zymposium sync --tool zig-cc` never
    /// disturbs skills belonging to other tools.
    only_provider: ?[]const u8 = null,
};

pub const Error = error{
    /// The global boundary was requested but the environment supplies no home
    /// directory, so `~/.claude/skills` cannot be formed.
    NoHomeDirectory,
} || std.mem.Allocator.Error || Io.Cancelable || Io.UnexpectedError ||
    util.MaterializeError || state.LoadError || state.SaveError;

/// The boundaries this run manages, derived from the configured scope.
pub fn contexts(gpa: std.mem.Allocator, opts: Options) ![]Context {
    var out: std.ArrayList(Context) = .empty;
    errdefer out.deinit(gpa);

    if (opts.config.scope.includes(.global)) {
        if (opts.home == null) return error.NoHomeDirectory;
        try out.append(gpa, .{ .scope = .global });
    }
    if (opts.config.scope.includes(.project)) {
        if (opts.project_root) |root| {
            try out.append(gpa, .{ .scope = .project, .project_root = root });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Reconcile `found` into the agent boundaries, updating `st` in place.
/// The caller persists `st` and frees the returned outcome.
pub fn sync(
    gpa: std.mem.Allocator,
    io: Io,
    st: *state.State,
    opts: Options,
    found: []sources.Found,
) Error!Outcome {
    var outcome: Outcome = .{};

    const active = try contexts(gpa, opts);
    defer gpa.free(active);

    const enabled = try opts.config.enabledAgents(gpa);
    defer gpa.free(enabled);

    var conflicts: std.ArrayList(Conflict) = .empty;
    errdefer conflicts.deinit(gpa);

    // Every skill this run claimed, so prune can tell "the provider dropped
    // this skill" from "this run was not responsible for it".
    var provisioned: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (provisioned.keys()) |k| gpa.free(k);
        provisioned.deinit(gpa);
    }

    for (found) |f| {
        if (opts.only_provider) |only| {
            if (!std.mem.eql(u8, only, f.candidate.provider)) continue;
        }
        try provisionOne(gpa, io, st, opts, active, enabled, f, &outcome, &conflicts);
        const key = try state.State.identityKey(gpa, f.candidate.provider, f.name);
        try provisioned.put(gpa, key, {});
    }

    try prune(gpa, io, st, &provisioned, opts.only_provider, &outcome);

    outcome.conflicts = try conflicts.toOwnedSlice(gpa);
    return outcome;
}

fn provisionOne(
    gpa: std.mem.Allocator,
    io: Io,
    st: *state.State,
    opts: Options,
    active: []const Context,
    enabled: []const agents_mod.Agent,
    f: sources.Found,
    outcome: *Outcome,
    conflicts: *std.ArrayList(Conflict),
) Error!void {
    const identity = try state.State.identityKey(gpa, f.candidate.provider, f.name);
    defer gpa.free(identity);
    const previous = st.skills.get(identity);

    var links: std.ArrayList(state.Link) = .empty;
    errdefer {
        for (links.items) |*l| l.deinit(gpa);
        links.deinit(gpa);
    }

    const provider_segment = try paths_mod.sanitizeName(gpa, f.candidate.provider);
    defer gpa.free(provider_segment);

    for (active) |ctx| {
        for (enabled) |agent| {
            const dir = try targetDir(gpa, agent, ctx, opts);
            defer gpa.free(dir);

            // The install boundary is namespaced as <provider>/<skill>, so
            // packages can ship the same skill name without colliding.
            const target = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ dir, provider_segment, f.name });
            var target_owned = false;
            defer if (!target_owned) gpa.free(target);
            errdefer if (!target_owned) gpa.free(target);
            // Decide whether this path is ours to write. The recorded link
            // alone is not enough: a user may have replaced our symlink with
            // their own directory, and deleting that would destroy their
            // work. Only the on-disk *shape* decides.
            const recorded = recordedMode(st, target);
            const present = util.inspectPath(gpa, io, target);
            defer present.deinit(gpa);

            const mode: util.Materialized = switch (decide(
                present,
                recorded,
                io,
                target,
                f.path,
                opts.force,
            )) {
                .create => blk: {
                    const m = try util.materialize(gpa, io, f.path, target, opts.config.link_mode);
                    if (previous == null) outcome.linked += 1 else outcome.updated += 1;
                    break :blk m;
                },
                .keep => |m| blk: {
                    outcome.unchanged += 1;
                    break :blk m;
                },
                .conflict => {
                    try conflicts.append(gpa, .{
                        .path = try gpa.dupe(u8, target),
                        .holder = try gpa.dupe(u8, conflict_holder(present, recorded)),
                        .claimant = try gpa.dupe(u8, f.candidate.provider),
                    });
                    continue;
                },
            };

            try links.append(gpa, .{
                .agent = try gpa.dupe(u8, agent.id),
                .scope = ctx.scope,
                .path = target,
                .mode = mode,
                .project_root = if (ctx.project_root) |r| try gpa.dupe(u8, r) else null,
            });
            target_owned = true;
        }
    }

    // Record the claim even when every target conflicted, so `zymposium list`
    // still shows where the skill would have come from.
    const entry = state.Skill{
        .name = try gpa.dupe(u8, f.name),
        .provider = try gpa.dupe(u8, f.candidate.provider),
        .source_kind = f.candidate.source_kind,
        .source_url = try gpa.dupe(u8, f.candidate.source_url),
        .commit = try gpa.dupe(u8, f.candidate.commit),
        .version = try gpa.dupe(u8, f.candidate.version),
        .skill_path = try gpa.dupe(u8, f.path),
        .description = if (f.description) |d| try gpa.dupe(u8, d) else null,
        .provisioned_at = blk: {
            const stamp = util.nowRfc3339(io);
            break :blk try gpa.dupe(u8, &stamp);
        },
        .links = try links.toOwnedSlice(gpa),
    };

    if (st.skills.getPtr(identity)) |p| p.deinit(gpa);
    _ = st.skills.orderedRemove(identity);
    try st.skills.put(gpa, try gpa.dupe(u8, identity), entry);
}

/// The mode a path was recorded as, if the manifest claims it.
fn recordedMode(st: *const state.State, path: []const u8) ?util.Materialized {
    for (st.skills.values()) |s| {
        for (s.links) |l| {
            if (std.mem.eql(u8, l.path, path)) return l.mode;
        }
    }
    return null;
}

const Decision = union(enum) {
    /// Nothing is there; write the link.
    create,
    /// The path already holds what we want, in this mode.
    keep: util.Materialized,
    /// Something we did not put there occupies the path.
    conflict,
};

/// Decide whether a path may be written, based on what is actually on disk
/// rather than only on what the manifest claims.
///
/// The distinction that matters: a symlink is unambiguously ours if we put
/// one there, even if the target has since moved, so it is repaired. A real
/// directory where we recorded a symlink means the user replaced it, and is
/// never deleted. A copy we recorded is kept as-is, because a copy the user
/// has edited is indistinguishable from one they have not.
fn decide(
    present: util.Existing,
    recorded: ?util.Materialized,
    io: Io,
    target: []const u8,
    skill_path: []const u8,
    force: bool,
) Decision {
    if (present == .absent) return .create;

    // Already exactly what this run would write.
    const correct = if (recorded) |m| switch (m) {
        .symlink => util.linksTo(io, target, skill_path),
        .copy => dirExists(io, target),
    } else false;
    if (correct) return .{ .keep = recorded.? };

    // Still shaped the way we left it? A symlink we made stays a symlink even
    // when its target has moved, so it is ours to repoint; a copy we made stays
    // a directory. Anything else was put there by the user.
    const symlink_now = present == .symlink;
    const still_ours = if (recorded) |m| switch (m) {
        .symlink => symlink_now,
        .copy => !symlink_now,
    } else false;

    if (still_ours or force) return .create;
    return .conflict;
}

/// A short, human-readable description of what is occupying a path.
fn conflict_holder(present: util.Existing, recorded: ?util.Materialized) []const u8 {
    return switch (present) {
        .symlink => "a symlink zymposium did not create",
        .directory => if (recorded) |m| switch (m) {
            .symlink => "a directory replacing a zymposium symlink",
            .copy => "a copied skill",
        } else "an existing directory",
        .file => "an existing file",
        .absent => unreachable,
    };
}

fn dirExists(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return st.kind == .directory;
}

/// Absolute skills directory for one agent in one context.
fn targetDir(gpa: std.mem.Allocator, agent: agents_mod.Agent, ctx: Context, opts: Options) ![]u8 {
    return switch (ctx.scope) {
        .global => agent.globalDir(gpa, opts.home orelse return error.NoHomeDirectory),
        .project => agent.projectDir(gpa, ctx.project_root orelse return error.NoHomeDirectory),
    };
}

/// Drop state entries for skills this run was responsible for but did not
/// find. A full run is responsible for every provider, so a skill whose
/// package disappeared — `zest remove`, or a dependency dropped from
/// build.zig.zon — loses its links. A `--tool` run is responsible only for
/// that one provider and leaves every other skill untouched.
fn prune(
    gpa: std.mem.Allocator,
    io: Io,
    st: *state.State,
    provisioned: *std.StringArrayHashMapUnmanaged(void),
    only_provider: ?[]const u8,
    outcome: *Outcome,
) Error!void {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    for (st.skills.keys()) |key| {
        const s = st.skills.get(key).?;
        if (only_provider) |only| {
            if (!std.mem.eql(u8, only, s.provider)) continue;
        }
        if (provisioned.contains(key)) continue;
        try names.append(gpa, try gpa.dupe(u8, key));
    }

    for (names.items) |name| {
        try removeSkill(gpa, io, st, name);
        outcome.removed += 1;
    }
}

/// Delete every link a skill owns and drop it from the manifest.
pub fn removeSkill(gpa: std.mem.Allocator, io: Io, st: *state.State, name: []const u8) Error!void {
    const entry = st.skills.get(name) orelse return;
    for (entry.links) |l| {
        util.removePath(gpa, io, l.path);
    }
    if (st.skills.getPtr(name)) |p| p.deinit(gpa);
    _ = st.skills.orderedRemove(name);
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

pub const Kind = enum {
    /// The link is gone.
    missing,
    /// A symlink pointing somewhere other than the recorded skill.
    dangling,
    /// A copied skill whose directory has disappeared.
    stale_source,
    /// The skill's source package is gone (tool or dependency removed).
    orphaned,

    pub fn name(k: Kind) []const u8 {
        return @tagName(k);
    }
};

pub const Problem = struct {
    /// The link path that is unhealthy.
    path: []u8,
    /// The skill it belongs to.
    skill: []u8,
    kind: Kind,

    pub fn deinit(self: *Problem, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.skill);
    }
};

pub fn freeProblems(gpa: std.mem.Allocator, items: []Problem) void {
    for (items) |*p| p.deinit(gpa);
    gpa.free(items);
}

/// Check every recorded link against the filesystem.
pub fn doctor(gpa: std.mem.Allocator, io: Io, st: *const state.State) ![]Problem {
    var out: std.ArrayList(Problem) = .empty;
    errdefer {
        for (out.items) |*p| p.deinit(gpa);
        out.deinit(gpa);
    }

    for (st.skills.values()) |s| {
        const source_alive = dirExists(io, s.skill_path);
        for (s.links) |l| {
            const present = util.inspectPath(gpa, io, l.path);
            defer present.deinit(gpa);
            const problem_kind: ?Kind = switch (present) {
                .absent => if (source_alive) .missing else .orphaned,
                .symlink => |t| if (!std.mem.eql(u8, t, s.skill_path)) .dangling else null,
                else => if (!source_alive) .stale_source else null,
            };
            if (problem_kind) |k| try out.append(gpa, .{
                .path = try gpa.dupe(u8, l.path),
                .skill = try gpa.dupe(u8, s.name),
                .kind = k,
            });
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

// Exercise `decide` against a real filesystem. The case that matters most
// is a user replacing one of our symlinks with a directory of their own:
// that must be a conflict, never a silent delete.
test "decide never clobbers a path the user replaced" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // One resolved root; every path below is built from it so the symlink
    // target and the recorded path are byte-for-byte identical.
    try dir.createDirPath(io, "src/skill");
    const root = try dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(root);

    const child = struct {
        fn make(g: std.mem.Allocator, base: [:0]const u8, name: []const u8) ![]u8 {
            return std.fmt.allocPrint(g, "{s}/{s}", .{ base, name });
        }
    };
    const skill_src = try child.make(gpa, root, "skill");
    defer gpa.free(skill_src);
    const moved_src = try child.make(gpa, root, "skill-moved");
    defer gpa.free(moved_src);
    try dir.createDirPath(io, "src/skill-moved");

    // 1. Nothing there yet: create.
    const absent = try child.make(gpa, root, "nope");
    defer gpa.free(absent);
    {
        const e = util.inspectPath(gpa, io, absent);
        defer e.deinit(gpa);
        try std.testing.expect(e == .absent);
        try std.testing.expectEqual(Decision.create, decide(e, null, io, absent, skill_src, false));
    }

    // 2. Our symlink pointing at the right place: keep it.
    try dir.symLink(io, skill_src, "src/link", .{});
    const link = try child.make(gpa, root, "link");
    defer gpa.free(link);
    {
        const e = util.inspectPath(gpa, io, link);
        defer e.deinit(gpa);
        try std.testing.expectEqualStrings(skill_src, e.symlink);
        try std.testing.expectEqual(
            Decision{ .keep = .symlink },
            decide(e, .symlink, io, link, skill_src, false),
        );
    }

    // 3. Our symlink whose source moved: repair it.
    {
        const e = util.inspectPath(gpa, io, link);
        defer e.deinit(gpa);
        try std.testing.expectEqual(
            Decision.create,
            decide(e, .symlink, io, link, moved_src, false),
        );
    }

    // 4. A real directory where we recorded a symlink: the user took it over.
    //    This is the case that used to destroy their files.
    try dir.createDirPath(io, "src/replaced");
    try dir.writeFile(io, .{ .sub_path = "src/replaced/NOTES.md", .data = "precious" });
    const replaced = try child.make(gpa, root, "replaced");
    defer gpa.free(replaced);
    {
        const e = util.inspectPath(gpa, io, replaced);
        defer e.deinit(gpa);
        try std.testing.expectEqual(
            Decision.conflict,
            decide(e, .symlink, io, replaced, skill_src, false),
        );
        // ...unless the user insists.
        try std.testing.expectEqual(
            Decision.create,
            decide(e, .symlink, io, replaced, skill_src, true),
        );
    }

    // 5. A copy we recorded stays as it is; we cannot tell an edited copy from
    //    an unedited one, so it is never recreated.
    try dir.createDirPath(io, "src/copied");
    const copied = try child.make(gpa, root, "copied");
    defer gpa.free(copied);
    {
        const e = util.inspectPath(gpa, io, copied);
        defer e.deinit(gpa);
        try std.testing.expectEqual(
            Decision{ .keep = .copy },
            decide(e, .copy, io, copied, skill_src, false),
        );
    }

    // 6. Occupied but never recorded: a conflict.
    {
        const e = util.inspectPath(gpa, io, replaced);
        defer e.deinit(gpa);
        try std.testing.expectEqual(
            Decision.conflict,
            decide(e, null, io, replaced, skill_src, false),
        );
    }
}

test "different providers can ship the same skill name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.createDirPath(io, "home");
    try dir.createDirPath(io, "pkg-a/skills/common");
    try dir.createDirPath(io, "pkg-b/skills/common");
    try dir.writeFile(io, .{ .sub_path = "pkg-a/skills/common/SKILL.md", .data = "A" });
    try dir.writeFile(io, .{ .sub_path = "pkg-b/skills/common/SKILL.md", .data = "B" });

    const abs = try dir.realPathFileAlloc(io, "pkg-a", gpa);
    defer gpa.free(abs);
    const home = try dir.realPathFileAlloc(io, "home", gpa);
    defer gpa.free(home);
    const root_a = abs;
    const root_b = try dir.realPathFileAlloc(io, "pkg-b", gpa);
    defer gpa.free(root_b);
    const path_a = try std.fmt.allocPrint(gpa, "{s}/skills/common", .{root_a});
    defer gpa.free(path_a);
    const path_b = try std.fmt.allocPrint(gpa, "{s}/skills/common", .{root_b});
    defer gpa.free(path_b);

    var cfg = try @import("config.zig").Config.parse(gpa,
        \\{"version":1,"agents":["claude"],"link_mode":"symlink","scope":"global"}
    );
    defer cfg.deinit();

    var found = [_]sources.Found{
        .{
            .name = try gpa.dupe(u8, "common"),
            .description = null,
            .path = try gpa.dupe(u8, path_a),
            .candidate = .{
                .provider = try gpa.dupe(u8, "pkg-a"),
                .source_kind = .project_dep,
                .source_url = try gpa.dupe(u8, "file:///pkg-a"),
                .commit = try gpa.dupe(u8, "a"),
                .version = try gpa.dupe(u8, ""),
                .root = try gpa.dupe(u8, root_a),
            },
        },
        .{
            .name = try gpa.dupe(u8, "common"),
            .description = null,
            .path = try gpa.dupe(u8, path_b),
            .candidate = .{
                .provider = try gpa.dupe(u8, "pkg-b"),
                .source_kind = .project_dep,
                .source_url = try gpa.dupe(u8, "file:///pkg-b"),
                .commit = try gpa.dupe(u8, "b"),
                .version = try gpa.dupe(u8, ""),
                .root = try gpa.dupe(u8, root_b),
            },
        },
    };
    defer {
        for (&found) |*item| item.deinit(gpa);
    }

    var st: state.State = .{ .gpa = gpa };
    defer st.deinit();
    var outcome = try sync(gpa, io, &st, .{ .config = &cfg, .home = home }, &found);
    defer outcome.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), st.skills.count());
    try std.testing.expectEqual(@as(usize, 2), outcome.linked);
    try std.testing.expectEqual(@as(usize, 0), outcome.conflicts.len);
    const pkg_a = std.fs.path.join(gpa, &.{ home, ".claude", "skills", "pkg-a", "common" }) catch unreachable;
    defer gpa.free(pkg_a);
    const pkg_b = std.fs.path.join(gpa, &.{ home, ".claude", "skills", "pkg-b", "common" }) catch unreachable;
    defer gpa.free(pkg_b);
    try std.testing.expect(util.linksTo(io, pkg_a, path_a));
    try std.testing.expect(util.linksTo(io, pkg_b, path_b));
    try std.testing.expectEqual(state.State.Selector.ambiguous, st.resolveSelector("common"));
    try std.testing.expect(st.resolveSelector("pkg-a/common") == .found);
}
