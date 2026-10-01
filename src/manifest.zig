//! Discovery of agent skills inside a package root.
//!
//! A package declares skills in `<package-root>/skills`. Each immediate
//! subdirectory containing a `SKILL.md` is one skill, keyed by its directory
//! name (which is also the name the agent will see). `SKILL.md` may carry YAML
//! frontmatter; `name` and `description` are surfaced for `zymposium list`.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;

/// Directory name, relative to a package root, that holds skill definitions.
pub const skills_dir_name = "skills";

/// File that must exist inside a skill directory for it to be a skill.
pub const skill_file_name = "SKILL.md";

pub const Skill = struct {
    /// Directory name; the identity the agent sees.
    name: []u8,
    /// Absolute path of the skill directory.
    path: []u8,
    /// `description` from SKILL.md frontmatter, if present.
    description: ?[]u8,
    /// `name` from SKILL.md frontmatter, if present and different from `name`.
    declared_name: ?[]u8,

    pub fn deinit(self: *Skill, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.path);
        if (self.description) |d| gpa.free(d);
        if (self.declared_name) |d| gpa.free(d);
    }
};

pub fn freeSkills(gpa: std.mem.Allocator, skills: []Skill) void {
    for (skills) |*s| s.deinit(gpa);
    gpa.free(skills);
}

pub const Error = error{
    OutOfMemory,
} || Io.Cancelable || Io.UnexpectedError || Io.Dir.OpenError || Io.Dir.StatFileError ||
    util_ReadError;

/// Alias so the error set above stays readable.
const util_ReadError = @import("util.zig").ReadFileError;

/// Scan `<package_root>/skills` and return every valid skill, sorted by name.
///
/// A missing `skills` directory is not an error: most packages declare no
/// skills, which is the common case and must stay quiet.
pub fn discover(gpa: std.mem.Allocator, io: Io, package_root: []const u8) Error![]Skill {
    const root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ package_root, skills_dir_name });
    defer gpa.free(root);

    var out: std.ArrayList(Skill) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(gpa);
        out.deinit(gpa);
    }

    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(gpa),
        else => |e| return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // Skip dotfiles and anything that is not a real directory; following a
        // symlinked skill directory would let a package reach outside its root.
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "..") or std.mem.eql(u8, entry.name, ".")) continue;

        const skill_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, entry.name });
        const manifest_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ skill_path, skill_file_name });
        const has_manifest = blk: {
            const st = cwd.statFile(io, manifest_path, .{ .follow_symlinks = false }) catch
                break :blk false;
            break :blk st.kind == .file;
        };
        if (!has_manifest) {
            gpa.free(skill_path);
            gpa.free(manifest_path);
            continue;
        }

        var skill = Skill{
            .name = try gpa.dupe(u8, entry.name),
            .path = skill_path,
            .description = null,
            .declared_name = null,
        };
        errdefer skill.deinit(gpa);

        if (util_Read(gpa, io, manifest_path)) |text| {
            defer gpa.free(text);
            const front = parseFrontmatter(text);
            if (front.get("description")) |d| skill.description = try gpa.dupe(u8, trimScalar(d));
            if (front.get("name")) |n| {
                const trimmed = trimScalar(n);
                // Only worth surfacing when it disagrees with the directory
                // name, which is the name the agent actually resolves.
                if (!std.mem.eql(u8, trimmed, entry.name)) {
                    skill.declared_name = try gpa.dupe(u8, trimmed);
                }
            }
        } else |_| {
            // A missing or unreadable SKILL.md still yields a usable skill: the
            // directory name is what matters for provisioning.
        }
        gpa.free(manifest_path);

        try out.append(gpa, skill);
    }

    const owned = try out.toOwnedSlice(gpa);
    std.mem.sort(Skill, owned, {}, lessByName);
    return owned;
}

fn util_Read(gpa: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    return @import("util.zig").readFileAlloc(Io.Dir.cwd(), io, gpa, path);
}

fn lessByName(_: void, a: Skill, b: Skill) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

const Frontmatter = std.StringHashMap([]const u8);

/// Parse the leading `---` delimited YAML block of a SKILL.md into simple
/// `key: value` pairs. This is intentionally not a YAML parser: frontmatter in
/// practice is a handful of scalars, and a dependency on a full YAML engine
/// would dwarf the rest of this program. Values keep their surrounding quotes.
pub fn parseFrontmatter(text: []const u8) Frontmatter {
    var map: Frontmatter = .init(std.heap.page_allocator);
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return map;

    // Consume the remainder of the opening delimiter line, but keep the
    // newline itself: it is the boundary between `---` and the body.
    var body = trimmed[3..];
    while (body.len > 0 and (body[0] == ' ' or body[0] == '\t' or body[0] == '\r')) {
        body = body[1..];
    }
    if (body.len == 0 or body[0] != '\n') return map;

    var lines = std.mem.splitScalar(u8, body[1..], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "---")) break;
        if (line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (key.len == 0) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        map.put(key, value) catch continue;
    }
    return map;
}

/// Remove matching surrounding single or double quotes, if present.
pub fn trimScalar(s: []const u8) []const u8 {
    if (s.len >= 2 and
        ((s[0] == '"' and s[s.len - 1] == '"') or (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

test "parseFrontmatter reads name and description" {
    const text =
        \\---
        \\name: zig-idioms
        \\description: "How to write modern Zig"
        \\license: MIT
        \\---
        \\
        \\# Zig idioms
        \\
    ;
    const fm = parseFrontmatter(text);
    try std.testing.expectEqualStrings("zig-idioms", trimScalar(fm.get("name").?));
    try std.testing.expectEqualStrings("How to write modern Zig", trimScalar(fm.get("description").?));
    try std.testing.expectEqualStrings("MIT", fm.get("license").?);
}

test "parseFrontmatter tolerates missing or malformed blocks" {
    const no_fm = parseFrontmatter("# just a heading\n");
    try std.testing.expectEqual(@as(usize, 0), no_fm.count());

    const unterminated = parseFrontmatter("---\nname: x\n");
    try std.testing.expectEqualStrings("x", unterminated.get("name").?);

    const no_newline = parseFrontmatter("---name: x\n");
    try std.testing.expectEqual(@as(usize, 0), no_newline.count());
}

test "trimScalar leaves unquoted and empty values alone" {
    try std.testing.expectEqualStrings("bare", trimScalar("bare"));
    try std.testing.expectEqualStrings("", trimScalar(""));
    try std.testing.expectEqualStrings("\"", trimScalar("\""));
}
