//! User configuration: which agents to provision into, how to link, and which
//! scopes are enabled.
//!
//! Stored at `$XDG_CONFIG_HOME/zymposium/config.json`. Every field is optional;
//! an absent file yields the defaults, so zymposium works before `zymposium init`
//! and `init` merely makes the choice explicit on disk.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const agents_mod = @import("agents.zig");
const util = @import("util.zig");

pub const Scope = enum {
    /// Only `~/.claude/skills` and friends.
    global,
    /// Only `<project>/.claude/skills` and friends; requires a project.
    project,
    /// Global always, plus project-local when run inside a project.
    both,

    pub fn parse(s: []const u8) ?Scope {
        inline for (@typeInfo(Scope).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn name(sc: Scope) []const u8 {
        return @tagName(sc);
    }

    pub fn includes(sc: Scope, s: Scope) bool {
        return sc == .both or sc == s;
    }
};

/// Configuration is either readable and well-formed or `error.InvalidConfig`;
/// malformed JSON is folded into that rather than leaking parser internals.
pub const Error = error{
    InvalidConfig,
} || std.mem.Allocator.Error || util.ReadFileError || Io.Cancelable || Io.UnexpectedError;

/// On-disk shape. Nullable so an absent field falls back to the default rather
/// than failing the parse.
const File = struct {
    version: ?u32 = null,
    agents: ?[]const []const u8 = null,
    link_mode: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    version: u32 = 1,
    /// Enabled agent ids, validated against `agents_mod.all`. Owned strings.
    agent_ids: [][]const u8,
    link_mode: util.LinkMode = .auto,
    scope: Scope = .both,

    pub fn defaults(gpa: std.mem.Allocator) !Config {
        // Duplicate rather than alias the comptime literals so every Config,
        // however it was built, owns its strings uniformly.
        const ids = try gpa.alloc([]const u8, agents_mod.default_ids.len);
        var filled: usize = 0;
        errdefer {
            for (ids[0..filled]) |s| gpa.free(s);
            gpa.free(ids);
        }
        for (agents_mod.default_ids, 0..) |id, i| {
            ids[i] = try gpa.dupe(u8, id);
            filled += 1;
        }
        return .{ .gpa = gpa, .agent_ids = ids };
    }

    pub fn deinit(self: *Config) void {
        self.freeIds();
    }

    /// Release the agent id list and every string in it.
    fn freeIds(self: *const Config) void {
        for (self.agent_ids) |id| self.gpa.free(id);
        self.gpa.free(self.agent_ids);
    }

    /// The resolved `Agent` values for this config, in registry order.
    pub fn enabledAgents(self: *const Config, gpa: std.mem.Allocator) ![]agents_mod.Agent {
        var out: std.ArrayList(agents_mod.Agent) = .empty;
        errdefer out.deinit(gpa);
        for (agents_mod.all) |a| {
            for (self.agent_ids) |id| {
                if (std.mem.eql(u8, id, a.id)) {
                    try out.append(gpa, a);
                    break;
                }
            }
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn load(gpa: std.mem.Allocator, io: Io, path: []const u8) Error!Config {
        const bytes = util.readFileAlloc(Io.Dir.cwd(), io, gpa, path) catch |err| switch (err) {
            error.FileNotFound => return Config.defaults(gpa),
            else => |e| return e,
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    /// Build a config from JSON text. Unknown fields are ignored; an unknown
    /// agent id, link mode, or scope is `error.InvalidConfig` rather than a
    /// silent fallback, because a typo there would quietly provision nothing.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Config {
        var cfg = Config.defaults(gpa) catch return error.OutOfMemory;
        errdefer cfg.deinit();

        var parsed = std.json.parseFromSlice(File, gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidConfig,
        };
        defer parsed.deinit();

        const file = parsed.value;
        if (file.version) |v| cfg.version = v;
        if (file.agents) |ids| {
            const resolved = try gpa.alloc([]const u8, ids.len);
            var filled: usize = 0;
            errdefer {
                for (resolved[0..filled]) |s| gpa.free(s);
                gpa.free(resolved);
            }
            // Validate every id before committing: a typo in one entry must
            // not leave half the agent list applied.
            for (ids) |id| {
                if (agents_mod.byId(id) == null) return error.InvalidConfig;
            }
            for (ids, 0..) |id, i| {
                resolved[i] = try gpa.dupe(u8, id);
                filled += 1;
            }
            cfg.freeIds();
            cfg.agent_ids = resolved;
        }

        if (file.link_mode) |m| {
            cfg.link_mode = util.LinkMode.parse(m) orelse return error.InvalidConfig;
        }
        if (file.scope) |s| {
            cfg.scope = Scope.parse(s) orelse return error.InvalidConfig;
        }
        return cfg;
    }

    /// Serialize as pretty JSON. Caller owns memory.
    pub fn render(self: *const Config) ![]u8 {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\n  \"version\": {d},\n  \"agents\": [", .{self.version});
        for (self.agent_ids, 0..) |id, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("{f}", .{std.json.fmt(id, .{})});
        }
        try w.print("],\n  \"link_mode\": {f},\n  \"scope\": {f}\n}}\n", .{
            std.json.fmt(self.link_mode.name(), .{}),
            std.json.fmt(self.scope.name(), .{}),
        });
        return aw.toOwnedSlice();
    }

    pub fn save(self: *const Config, io: Io, path: []const u8) !void {
        const bytes = try self.render();
        defer self.gpa.free(bytes);
        // The config file lives inside a directory that may not exist yet.
        if (std.fs.path.dirname(path)) |dir| {
            Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        try util.writeFileAtomic(Io.Dir.cwd(), io, self.gpa, path, bytes);
    }
};

test "defaults enable every known agent" {
    const gpa = std.testing.allocator;
    var cfg = try Config.defaults(gpa);
    defer cfg.deinit();
    try std.testing.expectEqual(agents_mod.all.len, cfg.agent_ids.len);
    try std.testing.expectEqual(util.LinkMode.auto, cfg.link_mode);
    try std.testing.expectEqual(Scope.both, cfg.scope);
}

test "parse reads agents link_mode and scope" {
    const gpa = std.testing.allocator;
    var cfg = try Config.parse(gpa,
        \\{"version": 1, "agents": ["claude"], "link_mode": "symlink", "scope": "project"}
    );
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.agent_ids.len);
    try std.testing.expectEqualStrings("claude", cfg.agent_ids[0]);
    try std.testing.expectEqual(util.LinkMode.symlink, cfg.link_mode);
    try std.testing.expectEqual(Scope.project, cfg.scope);
}

test "parse fills defaults for absent fields and ignores unknowns" {
    const gpa = std.testing.allocator;
    var cfg = try Config.parse(gpa,
        \\{"version": 1, "future_option": true}
    );
    defer cfg.deinit();
    try std.testing.expectEqual(util.LinkMode.auto, cfg.link_mode);
    try std.testing.expectEqual(Scope.both, cfg.scope);
    try std.testing.expectEqual(agents_mod.all.len, cfg.agent_ids.len);
}

test "parse rejects unknown agent, link mode, and scope" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidConfig,
        Config.parse(gpa,
            \\{"version": 1, "agents": ["cursor"]}
        ),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        Config.parse(gpa,
            \\{"version": 1, "link_mode": "hardlink"}
        ),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        Config.parse(gpa,
            \\{"version": 1, "scope": "everywhere"}
        ),
    );
    try std.testing.expectError(error.InvalidConfig, Config.parse(gpa, "{ not json"));
}

test "enabledAgents resolves in registry order" {
    const gpa = std.testing.allocator;
    var cfg = try Config.parse(gpa,
        \\{"version": 1, "agents": ["agent", "claude"]}
    );
    defer cfg.deinit();
    const enabled = try cfg.enabledAgents(gpa);
    defer gpa.free(enabled);
    try std.testing.expectEqual(@as(usize, 2), enabled.len);
    try std.testing.expectEqualStrings("claude", enabled[0].id);
    try std.testing.expectEqualStrings("agent", enabled[1].id);
}

test "render round trips through parse" {
    const gpa = std.testing.allocator;
    var cfg = try Config.parse(gpa,
        \\{"version": 1, "agents": ["codex"], "link_mode": "copy", "scope": "global"}
    );
    defer cfg.deinit();
    const text = try cfg.render();
    defer gpa.free(text);

    var reloaded = try Config.parse(gpa, text);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("codex", reloaded.agent_ids[0]);
    try std.testing.expectEqual(util.LinkMode.copy, reloaded.link_mode);
    try std.testing.expectEqual(Scope.global, reloaded.scope);
}

test "Scope.includes covers both" {
    try std.testing.expect(Scope.both.includes(.global));
    try std.testing.expect(Scope.both.includes(.project));
    try std.testing.expect(!Scope.global.includes(.project));
    try std.testing.expect(Scope.project.includes(.project));
}
