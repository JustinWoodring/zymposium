//! Command-line argument parsing.
//!
//! Usage:
//!   zymposium init
//!   zymposium sync [options]
//!   zymposium list [--json]
//!   zymposium sources [--json]
//!   zymposium add <path|url> [--name <n>]
//!   zymposium remove <skill>
//!   zymposium update [skill]
//!   zymposium doctor [--json]
//!   zymposium agents
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");

pub const SyncOptions = struct {
    /// Restrict the run to one provider, as passed by zest's integration.
    tool: ?[]const u8 = null,
    /// Override the project root; defaults to the nearest ancestor with a
    /// build.zig.zon.
    project: ?[]const u8 = null,
    force: bool = false,
    /// Skip `.lazy` dependencies.
    no_lazy: bool = false,
    /// Do not clone anything that is not already cached.
    offline: bool = false,
    json: bool = false,
};

pub const Command = union(enum) {
    init,
    sync: SyncOptions,
    list: struct { json: bool = false },
    sources: struct { json: bool = false },
    add: struct {
        source: []const u8,
        /// Package name; defaults to the last URL path segment.
        name: ?[]const u8 = null,
    },
    remove: struct { skill: []const u8 },
    update: struct { skill: ?[]const u8 = null },
    doctor: struct { json: bool = false },
    agents,
    about,
    help: ?[]const u8,
    version,

    /// Release the strings `parse` allocated. The CLI itself runs on an
    /// arena, but tests and any embedder on a general-purpose allocator need
    /// this.
    pub fn deinit(cmd: Command, gpa: std.mem.Allocator) void {
        switch (cmd) {
            .sync => |s| {
                if (s.tool) |t| gpa.free(t);
                if (s.project) |p| gpa.free(p);
            },
            .add => |a| {
                gpa.free(a.source);
                if (a.name) |n| gpa.free(n);
            },
            .remove => |r| gpa.free(r.skill),
            .update => |u| {
                if (u.skill) |s| gpa.free(s);
            },
            .help => |t| {
                if (t) |v| gpa.free(v);
            },
            else => {},
        }
    }
};
pub const ParseError = error{ Usage, OutOfMemory };

/// Parse args (excluding argv[0]). All returned strings are gpa-owned.
pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .about;

    const first = args[0];
    if (eqlAny(first, &.{ "-h", "--help" })) return .{ .help = null };
    if (eqlAny(first, &.{ "-V", "--version" })) return .version;
    if (std.mem.eql(u8, first, "help")) {
        if (args.len > 1) return .{ .help = try gpa.dupe(u8, args[1]) };
        return .{ .help = null };
    }

    if (std.mem.eql(u8, first, "init")) {
        if (args.len > 1) return error.Usage;
        return .init;
    }
    if (std.mem.eql(u8, first, "list")) {
        var cmd: Command = .{ .list = .{} };
        for (args[1..]) |arg| {
            if (eqlAny(arg, &.{"--json"})) {
                cmd.list.json = true;
            } else return error.Usage;
        }
        return cmd;
    }
    if (std.mem.eql(u8, first, "sources")) {
        var cmd: Command = .{ .sources = .{} };
        for (args[1..]) |arg| {
            if (eqlAny(arg, &.{"--json"})) {
                cmd.sources.json = true;
            } else return error.Usage;
        }
        return cmd;
    }
    if (std.mem.eql(u8, first, "doctor")) {
        var cmd: Command = .{ .doctor = .{} };
        for (args[1..]) |arg| {
            if (eqlAny(arg, &.{"--json"})) {
                cmd.doctor.json = true;
            } else return error.Usage;
        }
        return cmd;
    }
    if (std.mem.eql(u8, first, "agents")) {
        if (args.len > 1) return error.Usage;
        return .agents;
    }

    if (std.mem.eql(u8, first, "sync")) {
        var cmd: Command = .{ .sync = .{} };
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--json")) {
                cmd.sync.json = true;
            } else if (std.mem.eql(u8, arg, "--force")) {
                cmd.sync.force = true;
            } else if (std.mem.eql(u8, arg, "--no-lazy")) {
                cmd.sync.no_lazy = true;
            } else if (std.mem.eql(u8, arg, "--offline")) {
                cmd.sync.offline = true;
            } else if (std.mem.eql(u8, arg, "--tool")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                cmd.sync.tool = try gpa.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--project")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                cmd.sync.project = try gpa.dupe(u8, args[i]);
            } else {
                return error.Usage;
            }
        }
        return cmd;
    }

    if (std.mem.eql(u8, first, "add")) {
        if (args.len < 2 or args[1].len == 0) return error.Usage;
        var source: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--name")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                name = try gpa.dupe(u8, args[i]);
            } else if (arg.len > 0 and arg[0] == '-') {
                return error.Usage;
            } else if (source == null) {
                source = try gpa.dupe(u8, arg);
            } else {
                return error.Usage;
            }
        }
        if (source == null) return error.Usage;
        return .{ .add = .{ .source = source.?, .name = name } };
    }

    if (std.mem.eql(u8, first, "remove")) {
        if (args.len != 2 or args[1].len == 0) return error.Usage;
        return .{ .remove = .{ .skill = try gpa.dupe(u8, args[1]) } };
    }

    if (std.mem.eql(u8, first, "update")) {
        if (args.len > 2) return error.Usage;
        if (args.len == 2) {
            if (args[1].len == 0) return error.Usage;
            return .{ .update = .{ .skill = try gpa.dupe(u8, args[1]) } };
        }
        return .{ .update = .{ .skill = null } };
    }

    return error.Usage;
}

fn eqlAny(s: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| {
        if (std.mem.eql(u8, s, c)) return true;
    }
    return false;
}

pub const version = "0.1.1";

pub const usage_text =
    \\zymposium: agent skills for Zig projects and CLI tools
    \\
    \\Usage:
    \\  zymposium init                     Write a default config and prepare the data layout
    \\  zymposium sync [options]           Provision skills from every source
    \\                                    --tool <name>   only this provider (used by zest)
    \\                                    --project <dir> project root to scope against
    \\                                    --force         take over paths zymposium does not own
    \\                                    --no-lazy       skip .lazy dependencies
    \\                                    --offline       never fetch; use only what is cached
    \\                                    --json          machine-readable result
    \\  zymposium list [--json]            Show provisioned skills and where they came from
    \\  zymposium sources [--json]         Show packages that ship skills
    \\  zymposium add <path|url> [--name]  Add a package's skills directly
    \\  zymposium remove <provider/skill> Unlink a skill (bare name if unique)
    \\  zymposium update [provider/skill] Re-fetch source and re-sync (bare if unique)
    \\  zymposium doctor [--json]          Check provisioned links against the filesystem
    \\  zymposium agents                   List known agents and their skill directories
    \\  zymposium help [command]           Show help
    \\  zymposium --version                Show version
    \\
    \\A package declares skills in <package-root>/skills/<name>/SKILL.md
    \\
    \\Skill sources, in the order they are considered:
    \\  zest tools        a tool installed by `zest` that ships a skills/ directory.
    \\                    The only source that needs zest: it reads the tool manifest.
    \\  project deps      dependencies of the current build.zig.zon graph (transitive)
    \\  added packages    `zymposium add`
    \\
    \\Recommended install:
    \\  zest install JustinWoodring/zymposium
    \\    https://github.com/JustinWoodring/zest builds and upgrades it for you.
    \\
    \\Standalone also works: `zig build`, then run zig-out/bin/zymposium. Without
    \\zest the sources are project deps plus added packages.
    \\
    \\Config: $XDG_CONFIG_HOME/zymposium/config.json (default ~/.config/zymposium)
    \\State:  $XDG_DATA_HOME/zymposium/state.json (default ~/.local/share/zymposium)
    \\
    \\Author: Justin Woodring
    \\Like zymposium? Consider sponsoring development: https://github.com/sponsors/JustinWoodring
;

pub const logo_text = "zymposium";
pub const about_text = logo_text ++ "\n\n" ++
    " zymposium " ++ version ++ ", agent skills for Zig projects and CLI tools\n" ++
    " discovers <package>/skills and provisions them into your agents\n\n" ++
    " home     https://github.com/JustinWoodring/zymposium\n" ++
    " install  zest install JustinWoodring/zymposium\n" ++
    "          (or `zig build` and use the binary standalone)\n" ++
    " author   Justin Woodring\n" ++
    " sponsor  https://github.com/sponsors/JustinWoodring\n\n" ++
    " try `zymposium --help` for commands\n";
pub const version_text = "zymposium " ++ version ++ "\n";

test "parse rejects unknown commands and stray flags" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Usage, parse(gpa, &.{"nonsense"}));
    try std.testing.expectError(error.Usage, parse(gpa, &.{ "list", "--bogus" }));
    try std.testing.expectError(error.Usage, parse(gpa, &.{ "sync", "--tool" }));
    try std.testing.expectError(error.Usage, parse(gpa, &.{"add"}));
    try std.testing.expectError(error.Usage, parse(gpa, &.{"remove"}));
    try std.testing.expectError(error.Usage, parse(gpa, &.{ "remove", "a", "b" }));
    try std.testing.expectError(error.Usage, parse(gpa, &.{ "agents", "extra" }));
}

test "parse handles bare and help invocations" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(Command.about, try parse(gpa, &.{}));
    try std.testing.expectEqual(Command.version, try parse(gpa, &.{"--version"}));
    try std.testing.expectEqual(Command.init, try parse(gpa, &.{"init"}));
    try std.testing.expectEqual(Command.agents, try parse(gpa, &.{"agents"}));
    try std.testing.expectEqual(Command{ .help = null }, try parse(gpa, &.{"help"}));
}

test "parse reads sync flags" {
    const gpa = std.testing.allocator;
    const full = try parse(gpa, &.{ "sync", "--tool", "zig-cc", "--project", "/w", "--force", "--no-lazy", "--offline", "--json" });
    defer full.deinit(gpa);
    const cmd = full.sync;
    try std.testing.expectEqualStrings("zig-cc", cmd.tool.?);
    try std.testing.expectEqualStrings("/w", cmd.project.?);
    try std.testing.expect(cmd.force);
    try std.testing.expect(cmd.no_lazy);
    try std.testing.expect(cmd.offline);
    try std.testing.expect(cmd.json);

    const bare = try parse(gpa, &.{"sync"});
    defer bare.deinit(gpa);
    try std.testing.expect(bare.sync.tool == null);
    try std.testing.expect(bare.sync.project == null);
}

test "parse reads add, remove and update arguments" {
    const gpa = std.testing.allocator;
    {
        const c = try parse(gpa, &.{ "add", "github.com/a/b" });
        defer c.deinit(gpa);
        try std.testing.expectEqualStrings("github.com/a/b", c.add.source);
        try std.testing.expect(c.add.name == null);
    }
    {
        const c = try parse(gpa, &.{ "add", "../local", "--name", "mylib" });
        defer c.deinit(gpa);
        try std.testing.expectEqualStrings("../local", c.add.source);
        try std.testing.expectEqualStrings("mylib", c.add.name.?);
    }
    {
        const c = try parse(gpa, &.{ "remove", "zig-idioms" });
        defer c.deinit(gpa);
        try std.testing.expectEqualStrings("zig-idioms", c.remove.skill);
    }
    {
        const none = try parse(gpa, &.{"update"});
        defer none.deinit(gpa);
        try std.testing.expect(none.update.skill == null);
    }
    {
        const c = try parse(gpa, &.{ "update", "s" });
        defer c.deinit(gpa);
        try std.testing.expectEqualStrings("s", c.update.skill.?);
    }
}
