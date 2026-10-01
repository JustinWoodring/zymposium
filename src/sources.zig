//! The set of skill-providing packages zymposium can provision from.
//!
//! A `Candidate` is a package root that may contain a `skills/` directory,
//! together with enough provenance to answer "where did this skill come from
//! and how do I update it" — the question `zymposium list` exists to answer.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const manifest = @import("manifest.zig");
const state = @import("state.zig");

pub const Candidate = struct {
    /// Package name; also the namespace used in the agent's skills directory.
    provider: []u8,
    source_kind: state.SourceKind,
    /// Clone URL, or local package path when the source is local.
    source_url: []u8,
    commit: []u8,
    version: []u8,
    /// Absolute path of the package root, i.e. the parent of `skills/`.
    root: []u8,

    pub fn deinit(self: *Candidate, gpa: std.mem.Allocator) void {
        gpa.free(self.provider);
        gpa.free(self.source_url);
        gpa.free(self.commit);
        gpa.free(self.version);
        gpa.free(self.root);
    }
};

pub fn freeCandidates(gpa: std.mem.Allocator, items: []Candidate) void {
    for (items) |*c| c.deinit(gpa);
    gpa.free(items);
}

/// Deep-copy a candidate so it can outlive the set that produced it.
pub fn cloneCandidate(gpa: std.mem.Allocator, c: Candidate) !Candidate {
    const provider = try gpa.dupe(u8, c.provider);
    errdefer gpa.free(provider);
    const source_url = try gpa.dupe(u8, c.source_url);
    errdefer gpa.free(source_url);
    const commit = try gpa.dupe(u8, c.commit);
    errdefer gpa.free(commit);
    const version = try gpa.dupe(u8, c.version);
    errdefer gpa.free(version);
    const root = try gpa.dupe(u8, c.root);
    errdefer gpa.free(root);
    return .{
        .provider = provider,
        .source_kind = c.source_kind,
        .source_url = source_url,
        .commit = commit,
        .version = version,
        .root = root,
    };
}

/// An ordered set of candidates keyed by provider name.
pub const Set = struct {
    items: std.StringArrayHashMapUnmanaged(Candidate) = .empty,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Set) void {
        for (self.items.keys(), self.items.values()) |k, *v| {
            self.gpa.free(k);
            v.deinit(self.gpa);
        }
        self.items.deinit(self.gpa);
    }

    /// Add a candidate unless its provider is already present. A zest tool is
    /// the richer origin when it is the same package as zymposium's own
    /// self-discovered candidate; otherwise the first package to claim a name
    /// keeps it, so direct and transitive duplicates do not churn.
    /// Ownership of `candidate` always transfers to this set.
    pub fn add(self: *Set, candidate: Candidate) !void {
        if (self.items.getPtr(candidate.provider)) |existing| {
            if (existing.source_kind == .package and candidate.source_kind == .zest_tool) {
                existing.deinit(self.gpa);
                existing.* = candidate;
            } else {
                var duplicate = candidate;
                duplicate.deinit(self.gpa);
            }
            return;
        }

        const key = try self.gpa.dupe(u8, candidate.provider);
        self.items.put(self.gpa, key, candidate) catch |err| {
            self.gpa.free(key);
            var rejected = candidate;
            rejected.deinit(self.gpa);
            return err;
        };
    }

    pub fn count(self: *const Set) usize {
        return self.items.count();
    }

    /// Consume the set and return its candidates in provider order. The
    /// returned slice owns them; the set is left empty.
    pub fn sorted(self: *Set, gpa: std.mem.Allocator) ![]Candidate {
        const out = try gpa.alloc(Candidate, self.items.count());
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |*c| c.deinit(gpa);
            gpa.free(out);
        }
        for (self.items.values()) |c| {
            out[n] = try cloneCandidate(gpa, c);
            n += 1;
        }
        std.mem.sort(Candidate, out, {}, lessByProvider);
        self.deinit();
        self.* = .{ .gpa = gpa };
        return out;
    }
};

fn lessByProvider(_: void, a: Candidate, b: Candidate) bool {
    return std.mem.order(u8, a.provider, b.provider) == .lt;
}

/// A skill discovered in a candidate, paired with where it came from.
pub const Found = struct {
    /// Skill name as the agent will see it inside the provider namespace.
    name: []u8,
    description: ?[]u8,
    /// Absolute path of the skill directory.
    path: []u8,
    /// The candidate that supplies it.
    candidate: Candidate,

    pub fn deinit(self: *Found, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.description) |d| gpa.free(d);
        gpa.free(self.path);
        self.candidate.deinit(gpa);
    }
};

pub fn freeFound(gpa: std.mem.Allocator, items: []Found) void {
    for (items) |*f| f.deinit(gpa);
    gpa.free(items);
}

/// Discover every skill under `candidate`, owning a copy of the candidate.
pub fn discoverIn(gpa: std.mem.Allocator, io: Io, candidate: Candidate) ![]Found {
    const skills = try manifest.discover(gpa, io, candidate.root);
    defer manifest.freeSkills(gpa, skills);

    var out: std.ArrayList(Found) = .empty;
    errdefer {
        for (out.items) |*f| f.deinit(gpa);
        out.deinit(gpa);
    }

    for (skills) |s| {
        const name = try gpa.dupe(u8, s.name);
        errdefer gpa.free(name);
        const description = if (s.description) |d| try gpa.dupe(u8, d) else null;
        errdefer if (description) |d| gpa.free(d);
        const path = try gpa.dupe(u8, s.path);
        errdefer gpa.free(path);
        const owned_candidate = try cloneCandidate(gpa, candidate);
        errdefer {
            var copy = owned_candidate;
            copy.deinit(gpa);
        }
        try out.append(gpa, .{
            .name = name,
            .description = description,
            .path = path,
            .candidate = owned_candidate,
        });
    }
    return out.toOwnedSlice(gpa);
}

test "Set.add keeps the first dependency provider and frees a duplicate" {
    const gpa = std.testing.allocator;
    var set: Set = .{ .gpa = gpa };
    defer set.deinit();

    try set.add(.{
        .provider = try gpa.dupe(u8, "dep"),
        .source_kind = .project_dep,
        .source_url = try gpa.dupe(u8, "https://example.com/a"),
        .commit = try gpa.dupe(u8, "aaa"),
        .version = try gpa.dupe(u8, ""),
        .root = try gpa.dupe(u8, "/cache/a"),
    });
    try set.add(.{
        .provider = try gpa.dupe(u8, "dep"),
        .source_kind = .project_dep,
        .source_url = try gpa.dupe(u8, "https://example.com/b"),
        .commit = try gpa.dupe(u8, "bbb"),
        .version = try gpa.dupe(u8, ""),
        .root = try gpa.dupe(u8, "/cache/b"),
    });

    try std.testing.expectEqual(@as(usize, 1), set.count());
    const only = set.items.get("dep").?;
    try std.testing.expectEqualStrings("https://example.com/a", only.source_url);
    try std.testing.expectEqual(state.SourceKind.project_dep, only.source_kind);
}

test "zest provenance wins when it names zymposium's own package" {
    const gpa = std.testing.allocator;
    var set: Set = .{ .gpa = gpa };
    defer set.deinit();

    try set.add(.{
        .provider = try gpa.dupe(u8, "zymposium"),
        .source_kind = .package,
        .source_url = try gpa.dupe(u8, "/checkout/zymposium"),
        .commit = try gpa.dupe(u8, ""),
        .version = try gpa.dupe(u8, ""),
        .root = try gpa.dupe(u8, "/checkout/zymposium"),
    });
    try set.add(.{
        .provider = try gpa.dupe(u8, "zymposium"),
        .source_kind = .zest_tool,
        .source_url = try gpa.dupe(u8, "https://example.com/zymposium"),
        .commit = try gpa.dupe(u8, "abc123"),
        .version = try gpa.dupe(u8, "v0.1.0"),
        .root = try gpa.dupe(u8, "/data/zest/src/zymposium"),
    });

    const chosen = set.items.get("zymposium").?;
    try std.testing.expectEqual(state.SourceKind.zest_tool, chosen.source_kind);
    try std.testing.expectEqualStrings("v0.1.0", chosen.version);
    try std.testing.expectEqualStrings("/data/zest/src/zymposium", chosen.root);
}

test "Set.sorted deep-copies and orders candidates by provider" {
    const gpa = std.testing.allocator;
    var set: Set = .{ .gpa = gpa };
    defer set.deinit();
    for ([_][]const u8{ "zeta", "alpha", "mid" }) |name| {
        try set.add(.{
            .provider = try gpa.dupe(u8, name),
            .source_kind = .package,
            .source_url = try gpa.dupe(u8, ""),
            .commit = try gpa.dupe(u8, ""),
            .version = try gpa.dupe(u8, ""),
            .root = try gpa.dupe(u8, "/cache"),
        });
    }
    const sorted = try set.sorted(gpa);
    defer freeCandidates(gpa, sorted);
    try std.testing.expectEqualStrings("alpha", sorted[0].provider);
    try std.testing.expectEqualStrings("mid", sorted[1].provider);
    try std.testing.expectEqualStrings("zeta", sorted[2].provider);
}
