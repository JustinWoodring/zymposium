//! Command implementations: init, sync, list, sources, add, remove, update,
//! doctor, agents.
//!
//! Each command prints its own user-facing errors to `Ctx.err` and returns an
//! exit code; only unexpected errors propagate as Zig errors.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const dragonfruit = @import("dragonfruit");
const agents_mod = @import("agents.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const git = @import("git.zig");
const packages = @import("packages.zig");
const paths_mod = @import("paths.zig");
const project_mod = @import("project.zig");
const provision = @import("provision.zig");
const report = @import("report.zig");
const self_mod = @import("self.zig");
const sources = @import("sources.zig");
const state = @import("state.zig");
const util = @import("util.zig");
const zest_link = @import("zest_link.zig");

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    paths: paths_mod.Paths,
    environ: *const std.process.Environ.Map,
    out_style: dragonfruit.Style,
    err_style: dragonfruit.Style,
    glyphs: dragonfruit.Glyphs,

    fn writeStatus(
        c: *Ctx,
        writer: *Io.Writer,
        style: dragonfruit.Style,
        kind: dragonfruit.Status,
        comptime fmt_string: []const u8,
        args: anytype,
    ) !void {
        try dragonfruit.status(writer, style, c.glyphs, kind, fmt_string, args);
    }

    fn note(c: *Ctx, comptime fmt_string: []const u8, args: anytype) !void {
        try c.writeStatus(c.err, c.err_style, .info, "zymposium: " ++ fmt_string, args);
        try c.err.flush();
    }

    fn warning(c: *Ctx, comptime fmt_string: []const u8, args: anytype) !void {
        try c.writeStatus(c.err, c.err_style, .warning, "zymposium: " ++ fmt_string, args);
        try c.err.flush();
    }

    fn failure(c: *Ctx, comptime fmt_string: []const u8, args: anytype) !void {
        try c.writeStatus(c.err, c.err_style, .failure, "zymposium: " ++ fmt_string, args);
    }

    fn success(c: *Ctx, comptime fmt_string: []const u8, args: anytype) !void {
        try c.writeStatus(c.out, c.out_style, .success, fmt_string, args);
    }

    fn info(c: *Ctx, comptime fmt_string: []const u8, args: anytype) !void {
        try c.writeStatus(c.out, c.out_style, .info, fmt_string, args);
    }

    fn packagesFile(c: *Ctx) ![]u8 {
        return std.fmt.allocPrint(c.gpa, "{s}/packages.json", .{c.paths.root});
    }
};

pub fn dispatch(c: *Ctx, cmd: cli.Command) !u8 {
    return switch (cmd) {
        .init => init(c),
        .sync => |s| syncCmd(c, s),
        .list => |l| listCmd(c, l.json),
        .sources => |s| sourcesCmd(c, s.json),
        .add => |a| addCmd(c, a.source, a.name),
        .remove => |r| removeCmd(c, r.skill),
        .update => |u| updateCmd(c, u.skill),
        .doctor => |d| doctorCmd(c, d.json),
        .agents => agentsCmd(c),
        .about, .help, .version => unreachable, // handled in main
    };
}

fn loadConfig(c: *Ctx) !config_mod.Config {
    return config_mod.Config.load(c.gpa, c.io, c.paths.config_file) catch |err| switch (err) {
        error.InvalidConfig => {
            const known = try agents_mod.idList(c.gpa);
            defer c.gpa.free(known);
            try c.failure(
                "{s} is not valid; see `zymposium agents` for known ids ({s})",
                .{ c.paths.config_file, known },
            );
            return error.InvalidConfig;
        },
        else => |e| return e,
    };
}

fn loadState(c: *Ctx) !state.State {
    return state.State.load(c.gpa, c.io, c.paths.state_file) catch |err| switch (err) {
        error.InvalidState => {
            try c.failure(
                "{s} is corrupt; move it aside and re-run `zymposium sync`",
                .{c.paths.state_file},
            );
            return error.InvalidState;
        },
        else => |e| return e,
    };
}

/// Resolve the project root: an explicit `--project`, else the nearest
/// ancestor holding a build.zig.zon.
fn resolveProjectRoot(c: *Ctx, explicit: ?[]const u8) !?[]u8 {
    if (explicit) |p| {
        if (!project_mod.isProject(c.gpa, c.io, p)) {
            try c.failure("{s} has no {s}", .{ p, project_mod.zon_file_name });
            return error.NotAZigProject;
        }
        return try c.gpa.dupe(u8, p);
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = Io.Dir.cwd().realPathFile(c.io, ".", &buf) catch {
        try c.failure("cannot determine the current directory", .{});
        return error.UnexpectedError;
    };
    var dir: ?[]u8 = null;
    var current: []const u8 = buf[0..len];
    while (current.len > 0) {
        if (project_mod.isProject(c.gpa, c.io, current)) {
            dir = try c.gpa.dupe(u8, current);
            break;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;
        current = parent;
    }
    return dir;
}

/// Every skill-providing package zymposium can see right now.
const Gathered = struct {
    candidates: []sources.Candidate,
    notices: []project_mod.Notice,

    fn deinit(self: *Gathered, gpa: std.mem.Allocator) void {
        sources.freeCandidates(gpa, self.candidates);
        project_mod.freeNotices(gpa, self.notices);
    }
};

/// Provider name for the skill zest ships about itself. It matches the tool
/// name so `zymposium sync --tool zest`, and zest's own hook, both target it.
const zest_skill_provider = "zest";

fn gather(
    c: *Ctx,
    project_root: ?[]const u8,
    skip_lazy: bool,
    offline: bool,
) !Gathered {
    var set: sources.Set = .{ .gpa = c.gpa };
    defer set.deinit();

    var notices: std.ArrayList(project_mod.Notice) = .empty;
    errdefer notices.deinit(c.gpa);

    // 0. zymposium itself. It ships skills for itself and for zest, and must
    //    find them however it was installed: through zest the manifest already
    //    points at the clone (source 1 below, which wins on provider name), and
    //    from a plain `zig build` binary it locates its own package root. Added
    //    first so the richer zest provenance is the one that survives.
    // `set.add` takes ownership of the candidate on every path, including the
    // duplicate path where it frees it, so `root` is handed over here.
    if (try self_mod.discoverRoot(c.gpa, c.io)) |root| {
        set.add(.{
            .provider = try c.gpa.dupe(u8, self_mod.provider_name),
            .source_kind = .package,
            .source_url = try c.gpa.dupe(u8, root),
            .commit = try c.gpa.dupe(u8, ""),
            .version = try c.gpa.dupe(u8, ""),
            .root = root,
        }) catch |err| {
            c.gpa.free(root);
            return err;
        };
    }

    const zest_root = try paths_mod.Paths.zestRoot(c.gpa, c.environ);
    defer c.gpa.free(zest_root);
    if (zest_link.collect(c.gpa, c.io, zest_root)) |list| {
        for (list) |t| try set.add(t);
        c.gpa.free(list);
    } else |err| switch (err) {
        error.InvalidState => try c.warning("ignoring unreadable zest state at {s}", .{zest_root}),
        else => |e| return e,
    }

    // zest itself ships a skill describing zest. It is not in the manifest
    // (zest is installed by its own installer, not by zest), so it is located
    // from the source tree that install.sh and `zest self-update` keep at
    // <zest root>/self/src. A zest that is not installed has no tree, and the
    // skill is simply absent — which is the intended behaviour.
    if (try self_mod.discoverZestRoot(c.gpa, c.io, zest_root)) |root| {
        set.add(.{
            .provider = try c.gpa.dupe(u8, zest_skill_provider),
            .source_kind = .zest_tool,
            .source_url = try c.gpa.dupe(u8, root),
            .commit = try c.gpa.dupe(u8, ""),
            .version = try c.gpa.dupe(u8, ""),
            .root = root,
        }) catch |err| {
            c.gpa.free(root);
            return err;
        };
    }

    // 2. Packages added explicitly with `zymposium add`.
    const pkgs_path = try c.packagesFile();
    defer c.gpa.free(pkgs_path);
    var reg: packages.Registry = .{ .gpa = c.gpa };
    if (packages.Registry.load(c.gpa, c.io, pkgs_path)) |loaded| {
        reg = loaded;
    } else |err| switch (err) {
        error.InvalidRegistry => try c.warning("ignoring corrupt package registry at {s}", .{pkgs_path}),
        else => |e| return e,
    }
    defer reg.deinit();
    const added = try reg.toCandidates(c.gpa, c.io);
    for (added) |a| try set.add(a);
    c.gpa.free(added);

    // 3. Dependencies of the current project, followed transitively.
    if (project_root) |root| {
        var res: project_mod.Result = .{ .candidates = &.{}, .notices = &.{} };
        if (project_mod.collect(c.gpa, c.io, root, .{
            .deps_root = c.paths.deps,
            .fetch = !offline,
            .skip_lazy = skip_lazy,
        })) |ok| {
            res = ok;
        } else |err| switch (err) {
            error.ParseZon => try c.warning("skipping unreadable {s} in {s}", .{ project_mod.zon_file_name, root }),
            else => |e| return e,
        }
        // `set.add` takes ownership; `res` must not free them afterwards.
        for (res.candidates) |d| try set.add(d);
        // Notices are deep-copied into the caller's list before `res` releases
        // its own strings.
        for (res.notices) |n| try notices.append(c.gpa, .{
            .dep = try c.gpa.dupe(u8, n.dep),
            .message = try c.gpa.dupe(u8, n.message),
        });
        // `freeNotices` releases the slice itself as well as its strings.
        project_mod.freeNotices(c.gpa, res.notices);
    }

    return .{
        .candidates = try set.sorted(c.gpa),
        .notices = try notices.toOwnedSlice(c.gpa),
    };
}

/// Discover the skills every candidate ships.
fn discoverAll(c: *Ctx, candidates: []const sources.Candidate) ![]sources.Found {
    var out: std.ArrayList(sources.Found) = .empty;
    errdefer sources.freeFound(c.gpa, out.items);
    for (candidates) |cand| {
        const found = sources.discoverIn(c.gpa, c.io, cand) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A package whose skills directory cannot be read is skipped, not
            // fatal: one bad dependency must not break every other skill.
            else => continue,
        };
        for (found) |f| try out.append(c.gpa, f);
        c.gpa.free(found);
    }
    return out.toOwnedSlice(c.gpa);
}

// ---------------------------------------------------------------------------
// init
// ---------------------------------------------------------------------------

pub fn init(c: *Ctx) !u8 {
    var cfg = loadConfig(c) catch |err| switch (err) {
        error.InvalidConfig => return 1,
        else => |e| return e,
    };
    defer cfg.deinit();

    try c.paths.ensureLayout(c.io);
    try cfg.save(c.io, c.paths.config_file);

    const enabled = try cfg.enabledAgents(c.gpa);
    defer c.gpa.free(enabled);

    // Create the global skill directories so an agent sees an empty,
    // well-formed boundary rather than a missing one.
    if (c.paths.home) |home| {
        if (cfg.scope.includes(.global)) {
            for (enabled) |a| {
                const dir = try a.globalDir(c.gpa, home);
                defer c.gpa.free(dir);
                Io.Dir.cwd().createDirPath(c.io, dir) catch {};
            }
        }
    }

    try c.success("wrote {s}", .{c.paths.config_file});
    try c.out.print("agents enabled: ", .{});
    for (cfg.agent_ids, 0..) |id, i| {
        if (i > 0) try c.out.writeAll(", ");
        try c.out.print("{s}", .{id});
    }
    try c.out.writeAll("\n");
    try c.out.print("link mode: {s}, scope: {s}\n", .{ cfg.link_mode.name(), cfg.scope.name() });
    try c.out.print("next: `zymposium sync`\n", .{});
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// sync
// ---------------------------------------------------------------------------

pub fn syncCmd(c: *Ctx, opts: cli.SyncOptions) !u8 {
    var cfg = loadConfig(c) catch |err| switch (err) {
        error.InvalidConfig => return 1,
        else => |e| return e,
    };
    defer cfg.deinit();

    const root = resolveProjectRoot(c, opts.project) catch |err| switch (err) {
        error.NotAZigProject => return 1,
        else => |e| return e,
    };
    defer if (root) |r| c.gpa.free(r);

    try c.paths.ensureLayout(c.io);

    var gathered = try gather(c, root, opts.no_lazy, opts.offline);
    defer gathered.deinit(c.gpa);

    for (gathered.notices) |n| try c.warning("{s}", .{n.message});

    const found = try discoverAll(c, gathered.candidates);
    defer sources.freeFound(c.gpa, found);

    var st = try loadState(c);
    defer st.deinit();

    var result = provision.sync(c.gpa, c.io, &st, .{
        .config = &cfg,
        .home = c.paths.home,
        .project_root = root,
        .force = opts.force,
        .only_provider = opts.tool,
    }, found) catch |err| switch (err) {
        error.NoHomeDirectory => {
            try c.failure("no $HOME in the environment; only project scope is available", .{});
            return 1;
        },
        else => |e| return e,
    };
    defer result.deinit(c.gpa);

    try st.save(c.io, c.paths.state_file);

    if (opts.json) {
        const text = try report.syncJson(c.gpa, result);
        defer c.gpa.free(text);
        try c.out.print("{s}", .{text});
    } else {
        try report.printSync(c.out, c.out_style, c.glyphs, result);
        if (root) |r| {
            try c.out.print("project scope: {s}\n", .{r});
        }
    }
    try c.out.flush();
    return if (result.conflicts.len > 0) 1 else 0;
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

pub fn listCmd(c: *Ctx, json: bool) !u8 {
    var st = try loadState(c);
    defer st.deinit();

    if (json) {
        const text = try report.skillsJson(c.gpa, &st);
        defer c.gpa.free(text);
        try c.out.print("{s}", .{text});
    } else {
        try report.printSkills(c.out, &st);
        // Provenance is the point of this command: say where each skill came
        // from and how to refresh it.
        for (st.skills.values()) |s| {
            if (s.source_url.len == 0) continue;
            try c.out.print("\n{s} ({s}):\n  from    {s}\n", .{
                s.name,
                s.source_kind.name(),
                s.source_url,
            });
            try c.out.print("  update  zymposium update {s}/{s}\n", .{ s.provider, s.name });
            for (s.links) |l| {
                const shown = try report.tildify(c.gpa, c.paths.home, l.path);
                defer c.gpa.free(shown);
                try c.out.print("  link    {s} {s} ({s})\n", .{ l.agent, shown, l.scope.name() });
            }
        }
    }
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// sources
// ---------------------------------------------------------------------------

fn buildSourceRows(
    c: *Ctx,
    found: []const sources.Found,
    st: *const state.State,
) ![]report.SourceRow {
    var rows: std.ArrayList(report.SourceRow) = .empty;
    errdefer rows.deinit(c.gpa);

    var i: usize = 0;
    while (i < found.len) {
        // Group consecutive skills by provider; discoverIn emits them in
        // sorted order, so each provider's skills are contiguous.
        const provider = found[i].candidate.provider;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(c.gpa);
        var provisioned: usize = 0;
        var origin: []const u8 = found[i].candidate.source_url;
        if (origin.len == 0) origin = found[i].candidate.root;
        const version = if (found[i].candidate.version.len > 0)
            found[i].candidate.version
        else
            found[i].candidate.commit[0..@min(12, found[i].candidate.commit.len)];

        while (i < found.len and std.mem.eql(u8, found[i].candidate.provider, provider)) : (i += 1) {
            try names.append(c.gpa, found[i].name);
            const key = try state.State.identityKey(c.gpa, provider, found[i].name);
            defer c.gpa.free(key);
            if (st.skills.contains(key)) provisioned += 1;
        }

        try rows.append(c.gpa, .{
            .provider = provider,
            .kind = found[i - names.items.len].candidate.source_kind,
            .origin = origin,
            .version = version,
            .skills = try names.toOwnedSlice(c.gpa),
            .provisioned = provisioned,
        });
    }
    return rows.toOwnedSlice(c.gpa);
}

pub fn sourcesCmd(c: *Ctx, json: bool) !u8 {
    const root = try resolveProjectRoot(c, null);
    defer if (root) |r| c.gpa.free(r);

    var gathered = try gather(c, root, false, false);
    defer gathered.deinit(c.gpa);
    for (gathered.notices) |n| try c.warning("{s}", .{n.message});

    const found = try discoverAll(c, gathered.candidates);
    defer sources.freeFound(c.gpa, found);

    var st = try loadState(c);
    defer st.deinit();

    const rows = try buildSourceRows(c, found, &st);
    defer {
        for (rows) |r| c.gpa.free(r.skills);
        c.gpa.free(rows);
    }

    if (json) {
        const text = try report.sourcesJson(c.gpa, rows);
        defer c.gpa.free(text);
        try c.out.print("{s}", .{text});
    } else {
        try report.printSources(c.out, rows);
    }
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// add
// ---------------------------------------------------------------------------

pub fn addCmd(c: *Ctx, source: []const u8, name: ?[]const u8) !u8 {
    if (!git.exists(c.gpa, c.io)) {
        try c.failure("`git` is required to add remote packages", .{});
        return 1;
    }
    try c.paths.ensureLayout(c.io);

    const url = git.normalizeGitUrl(source);
    const remote = git.isGitUrl(url);

    const provider = name orelse if (remote)
        std.fs.path.stem(std.fs.path.basename(url))
    else
        std.fs.path.basename(std.fs.path.resolve(c.gpa, &.{source}) catch {
            try c.failure("cannot resolve {s}", .{source});
            return 1;
        });
    if (provider.len == 0) {
        try c.failure("cannot derive a package name from '{s}'; pass --name", .{source});
        return 1;
    }

    var root: []u8 = undefined;
    if (remote) {
        root = try paths_mod.Paths.pkgDir(c.gpa, c.paths.pkgs, provider);
        defer c.gpa.free(root);
        if (!try refreshClone(c, url, root)) return 1;
    } else {
        const resolved = std.fs.path.resolve(c.gpa, &.{source}) catch {
            try c.failure("cannot resolve {s}", .{source});
            return 1;
        };
        defer c.gpa.free(resolved);
        const st = Io.Dir.cwd().statFile(c.io, resolved, .{}) catch {
            try c.failure("{s} is not a directory", .{source});
            return 1;
        };
        if (st.kind != .directory) {
            try c.failure("{s} is not a directory", .{source});
            return 1;
        }
        root = try c.gpa.dupe(u8, resolved);
    }
    defer if (!remote) c.gpa.free(root);

    const pkgs_path = try c.packagesFile();
    defer c.gpa.free(pkgs_path);

    var reg: packages.Registry = .{ .gpa = c.gpa };
    if (packages.Registry.load(c.gpa, c.io, pkgs_path)) |loaded| {
        reg = loaded;
    } else |err| switch (err) {
        error.InvalidRegistry => try c.warning("replacing corrupt registry at {s}", .{pkgs_path}),
        else => |e| return e,
    }
    defer reg.deinit();

    try reg.put(provider, source, root);
    try reg.save(c.io, pkgs_path);

    try c.success("added {s} {s} {s}", .{ provider, c.glyphs.arrow(), root });
    try c.out.flush();

    return syncCmd(c, .{
        .tool = provider,
        .project = null,
        .force = false,
        .no_lazy = false,
        .offline = false,
        .json = false,
    });
}

/// Re-clone `url` into `dir`, reporting failures. Caller owns `dir`.
fn refreshClone(c: *Ctx, url: []const u8, dir: []const u8) !bool {
    Io.Dir.cwd().createDirPath(c.io, c.paths.pkgs) catch {};
    Io.Dir.cwd().deleteTree(c.io, dir) catch {};
    try c.note("fetching {s}…", .{url});
    const res = git.clone(c.gpa, c.io, url, dir, null) catch |err| {
        try c.failure("could not fetch {s} ({s})", .{ url, @errorName(err) });
        return false;
    };
    defer c.gpa.free(res.output);
    if (!res.ok) {
        Io.Dir.cwd().deleteTree(c.io, dir) catch {};
        try c.writeStatus(c.err, c.err_style, .failure, "zymposium: clone failed:", .{});
        try c.err.writeAll(res.output);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// remove
// ---------------------------------------------------------------------------

pub fn removeCmd(c: *Ctx, skill: []const u8) !u8 {
    var st = try loadState(c);
    defer st.deinit();

    const key = switch (st.resolveSelector(skill)) {
        .found => |k| k,
        .missing => {
            try c.failure("'{s}' is not provisioned (see `zymposium list`)", .{skill});
            return 1;
        },
        .ambiguous => {
            try c.failure("'{s}' matches multiple providers; use <provider>/<skill>", .{skill});
            return 1;
        },
    };
    const entry = st.skills.get(key).?;
    const label = try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ entry.provider, entry.name });
    defer c.gpa.free(label);
    try provision.removeSkill(c.gpa, c.io, &st, key);
    try st.save(c.io, c.paths.state_file);

    try c.success("removed {s}", .{label});
    try c.out.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// update
// ---------------------------------------------------------------------------

pub fn updateCmd(c: *Ctx, skill: ?[]const u8) !u8 {
    var st = try loadState(c);
    defer st.deinit();

    var provider_filter: ?[]const u8 = null;

    if (skill) |selector| {
        const key = switch (st.resolveSelector(selector)) {
            .found => |k| k,
            .missing => {
                try c.failure("'{s}' is not provisioned (see `zymposium list`)", .{selector});
                return 1;
            },
            .ambiguous => {
                try c.failure("'{s}' matches multiple providers; use <provider>/<skill>", .{selector});
                return 1;
            },
        };
        const entry = st.skills.get(key).?;
        provider_filter = entry.provider;
        try c.info("updating {s}/{s} from {s}", .{ entry.provider, entry.name, entry.source_url });

        // Only clones zymposium owns are re-fetched. A zest tool's clone
        // belongs to zest: re-cloning it here would race `zest update` and
        // corrupt the staging tree it is building from.
        switch (entry.source_kind) {
            .zest_tool => if (std.mem.eql(u8, entry.provider, "zest"))
                try c.note(
                    "the zest skill refreshes when zest self-updates; run `zest self-update`",
                    .{},
                )
            else
                try c.note(
                    "{s} is a zest tool; run `zest update {s}` and zymposium re-syncs automatically",
                    .{ entry.provider, entry.provider },
                ),
            else => if (entry.source_url.len > 0) {
                // The skill lives at <package root>/skills/<name>; step back
                // two levels to find the package root to re-clone.
                const skills_dir = std.fs.path.dirname(entry.skill_path) orelse
                    return error.UnexpectedError;
                const root = std.fs.path.dirname(skills_dir) orelse
                    return error.UnexpectedError;
                if (!try refreshClone(c, entry.source_url, root)) return 1;
            },
        }
    } else {
        try c.note("re-fetching added packages and project dependencies…", .{});
        const pkgs_path = try c.packagesFile();
        defer c.gpa.free(pkgs_path);
        var reg: packages.Registry = .{ .gpa = c.gpa };
        if (packages.Registry.load(c.gpa, c.io, pkgs_path)) |loaded| {
            reg = loaded;
        } else |err| switch (err) {
            error.InvalidRegistry => try c.warning("ignoring corrupt registry at {s}", .{pkgs_path}),
            else => |e| return e,
        }
        defer reg.deinit();
        for (reg.packages.values()) |e| {
            const url = git.normalizeGitUrl(e.source);
            if (!git.isGitUrl(url)) continue;
            _ = try refreshClone(c, url, e.root);
        }
        const root = try resolveProjectRoot(c, null);
        defer if (root) |r| c.gpa.free(r);
        if (root) |r| {
            // Dependency clones are keyed by URL, not content, so a stale
            // checkout is dropped and the walk re-fetches from scratch.
            Io.Dir.cwd().deleteTree(c.io, c.paths.deps) catch {};
            if (project_mod.collect(c.gpa, c.io, r, .{ .deps_root = c.paths.deps })) |res| {
                var owned = res;
                defer owned.deinit(c.gpa);
            } else |err| switch (err) {
                error.ParseZon => {},
                else => |e| return e,
            }
        }
    }

    return syncCmd(c, .{
        .tool = provider_filter,
        .project = null,
        .force = false,
        .no_lazy = false,
        .offline = false,
        .json = false,
    });
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

pub fn doctorCmd(c: *Ctx, json: bool) !u8 {
    var st = try loadState(c);
    defer st.deinit();

    const problems = try provision.doctor(c.gpa, c.io, &st);
    defer provision.freeProblems(c.gpa, problems);

    if (json) {
        const text = try report.problemsJson(c.gpa, problems);
        defer c.gpa.free(text);
        try c.out.print("{s}", .{text});
    } else {
        try report.printProblems(c.out, c.out_style, c.glyphs, problems);
    }
    try c.out.flush();
    return if (problems.len == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// agents
// ---------------------------------------------------------------------------

pub fn agentsCmd(c: *Ctx) !u8 {
    var cfg = loadConfig(c) catch |err| switch (err) {
        error.InvalidConfig => return 1,
        else => |e| return e,
    };
    defer cfg.deinit();
    try report.printAgents(c.out, cfg.agent_ids, c.paths.home);
    try c.out.flush();
    return 0;
}
