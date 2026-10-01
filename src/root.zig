//! Agent skills for Zig projects and CLI tools.
//!
//! A Zig package or CLI tool declares agent skills in `<package-root>/skills`.
//! zymposium discovers those directories, works out where each one came from,
//! and materializes it in the agent skill directories you have enabled.
//!
//! It stands alone: project dependencies and `zymposium add` work with no tool
//! manager installed. Reading the manifest of an installed CLI tool is the one
//! source that needs zest, and it is strictly additive.
//!
//! Package root: `zymposium.cli`, `zymposium.commands`, and friends are the
//! public surface.
//! SPDX-License-Identifier: MIT
const std = @import("std");
pub const packages = @import("packages.zig");

pub const agents = @import("agents.zig");
pub const cli = @import("cli.zig");
pub const commands = @import("commands.zig");
pub const config = @import("config.zig");
pub const git = @import("git.zig");
pub const manifest = @import("manifest.zig");
pub const paths = @import("paths.zig");
pub const project = @import("project.zig");
pub const provision = @import("provision.zig");
pub const report = @import("report.zig");
pub const self = @import("self.zig");
pub const sources = @import("sources.zig");
pub const state = @import("state.zig");
pub const util = @import("util.zig");
pub const zest_link = @import("zest_link.zig");

test {
    std.testing.refAllDecls(@This());
}
