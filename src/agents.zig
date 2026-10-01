//! The agent boundaries zymposium can provision skills into.
//!
//! Each agent is identified by a stable `id` that appears in `config.json` and
//! in the provisioning manifest, and maps to two skill directories: one under
//! the user's home (global) and one under a project root (project-local).
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;

pub const Agent = struct {
    /// Stable identifier used in config and state. Never renamed.
    id: []const u8,
    /// Human-readable name for `zymposium agents` output.
    display: []const u8,
    /// Skills dir relative to the user's home, e.g. ".claude/skills".
    global_subdir: []const u8,
    /// Skills dir relative to a project root, e.g. ".claude/skills".
    project_subdir: []const u8,

    /// Absolute global skills directory. Caller owns memory.
    pub fn globalDir(self: Agent, gpa: std.mem.Allocator, home: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, self.global_subdir });
    }

    /// Absolute project-local skills directory. Caller owns memory.
    pub fn projectDir(self: Agent, gpa: std.mem.Allocator, project_root: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ project_root, self.project_subdir });
    }
};

/// Every agent zymposium knows how to provision into.
pub const all = [_]Agent{
    .{
        .id = "claude",
        .display = "Claude Code",
        .global_subdir = ".claude/skills",
        .project_subdir = ".claude/skills",
    },
    .{
        .id = "codex",
        .display = "Codex (OpenAI)",
        .global_subdir = ".codex/skills",
        .project_subdir = ".codex/skills",
    },
    .{
        .id = "agent",
        .display = "Generic .agent",
        .global_subdir = ".agent/skills",
        .project_subdir = ".agent/skills",
    },
};

/// Default target set: every known agent. Users narrow this in config.json.
pub const default_ids = [_][]const u8{ "claude", "codex", "agent" };

pub fn byId(id: []const u8) ?Agent {
    for (all) |a| {
        if (std.mem.eql(u8, a.id, id)) return a;
    }
    return null;
}

/// Comma-separated ids of every known agent, for error messages.
pub fn idList(gpa: std.mem.Allocator) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (all, 0..) |a, i| {
        if (i > 0) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(a.id);
    }
    return aw.toOwnedSlice();
}

test "byId resolves known agents and rejects unknown" {
    try std.testing.expectEqualStrings("claude", byId("claude").?.id);
    try std.testing.expectEqualStrings("agent", byId("agent").?.id);
    try std.testing.expect(byId("cursor") == null);
    try std.testing.expect(byId("") == null);
}

test "agent ids are unique" {
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
}

test "default_ids covers every known agent" {
    try std.testing.expectEqual(all.len, default_ids.len);
    for (all) |a| {
        var found = false;
        for (default_ids) |id| found = found or std.mem.eql(u8, id, a.id);
        try std.testing.expect(found);
    }
}
