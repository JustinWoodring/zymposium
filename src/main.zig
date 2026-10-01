//! zymposium CLI entry point: argument dispatch, exit codes, output plumbing.
//! Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
//!
//! SPDX-License-Identifier: MIT
const std = @import("std");
const Io = std.Io;
const zymposium = @import("zymposium");
const dragonfruit = @import("dragonfruit");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err_out = &stderr_file_writer.interface;

    const code = run(gpa, io, out, err_out, init.environ_map, argv[1..]) catch |err| switch (err) {
        error.Usage => {
            err_out.print("zymposium: invalid usage\n\n{s}", .{zymposium.cli.usage_text}) catch {};
            flushBoth(out, err_out);
            std.process.exit(2);
        },
        error.NoHomeDirectory => {
            err_out.print("zymposium: no $HOME (or $USERPROFILE) in the environment\n", .{}) catch {};
            flushBoth(out, err_out);
            std.process.exit(1);
        },
        else => {
            err_out.print("zymposium: internal error: {s}\n", .{@errorName(err)}) catch {};
            flushBoth(out, err_out);
            std.process.exit(1);
        },
    };
    flushBoth(out, err_out);
    std.process.exit(code);
}

fn flushBoth(out: *Io.Writer, err_out: *Io.Writer) void {
    out.flush() catch {};
    err_out.flush() catch {};
}

fn supportsAnsiTerminal(file: Io.File, io: Io) bool {
    if (!(file.isTty(io) catch false)) return false;
    return file.supportsAnsiEscapeCodes(io) catch false;
}

fn run(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    err_out: *Io.Writer,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
) !u8 {
    const cmd = try zymposium.cli.parse(gpa, args);

    switch (cmd) {
        .about => {
            try out.print("{s}", .{zymposium.cli.about_text});
            return 0;
        },
        .help => |topic| {
            if (topic) |t| {
                if (std.mem.eql(u8, t, "help") or std.mem.eql(u8, t, "--help") or std.mem.eql(u8, t, "-h")) {
                    try out.print("{s}", .{zymposium.cli.usage_text});
                    return 0;
                }
                try err_out.print("zymposium: no help topic '{s}'; see `zymposium help`\n", .{t});
                return 2;
            }
            try out.print("{s}", .{zymposium.cli.usage_text});
            return 0;
        },
        .version => {
            try out.print("{s}", .{zymposium.cli.version_text});
            return 0;
        },
        else => {},
    }

    const no_color = if (environ.get("NO_COLOR")) |value| value.len > 0 else false;
    const force_color = if (environ.get("CLICOLOR_FORCE")) |value| value.len > 0 else false;
    const term_is_dumb = if (environ.get("TERM")) |value|
        std.mem.eql(u8, value, "dumb")
    else
        false;
    const out_is_terminal = supportsAnsiTerminal(.stdout(), io);
    const err_is_terminal = supportsAnsiTerminal(.stderr(), io);
    var ctx: zymposium.commands.Ctx = .{
        .gpa = gpa,
        .io = io,
        .out = out,
        .err = err_out,
        .paths = try zymposium.paths.Paths.resolve(gpa, environ),
        .environ = environ,
        .out_style = dragonfruit.Style.resolve(
            .auto,
            out_is_terminal,
            no_color,
            force_color,
            term_is_dumb,
        ),
        .err_style = dragonfruit.Style.resolve(
            .auto,
            err_is_terminal,
            no_color,
            force_color,
            term_is_dumb,
        ),
        .glyphs = .{ .unicode = !term_is_dumb },
    };
    return zymposium.commands.dispatch(&ctx, cmd);
}
