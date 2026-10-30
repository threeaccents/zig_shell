const std = @import("std");

const Command = enum { exit, echo, type, pwd, cd };

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const gpa = init.gpa;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);

    var stdout = std.Io.File.stdout().writer(io, &.{});

    while (true) {
        try stdout.interface.print("$ ", .{});

        const line = try stdin.interface.takeDelimiter('\n') orelse {
            return error.YoMOmma;
        };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var args_list: std.ArrayList([]const u8) = .empty;

        try parseArgs(arena_alloc, &args_list, line);

        const args = args_list.items;

        if (args.len == 0) continue;

        const first_arg = args[0];

        var exec_path_buf: [std.fs.max_path_bytes]u8 = undefined;

        if (is_builtin(first_arg)) {
            const cmd = std.meta.stringToEnum(Command, first_arg) orelse {
                try stdout.interface.print("{s}: command not found\n", .{first_arg});
                continue;
            };

            switch (cmd) {
                .pwd => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const n = try std.process.currentPath(io, &buf);
                    const cwd = buf[0..n];

                    try stdout.interface.print("{s}\n", .{cwd});
                },
                .cd => {
                    const path = if (args.len > 1) args[1] else "~";

                    const target = if (std.mem.eql(u8, path, "~"))
                        init.environ_map.get("HOME") orelse ""
                    else
                        path;

                    std.process.setCurrentPath(io, target) catch {
                        try stdout.interface.print("cd: {s}: No such file or directory\n", .{path});
                    };
                },
                .exit => {
                    break;
                },
                .echo => {
                    const joined = try std.mem.join(gpa, " ", args[1..]);
                    defer gpa.free(joined);

                    try stdout.interface.print("{s}\n", .{joined});

                    continue;
                },
                .type => {
                    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;

                    const type_cmd = if (args.len > 1) args[1] else return error.YoMomma;

                    if (is_builtin(type_cmd)) {
                        try stdout.interface.print("{s} is a shell builtin\n", .{type_cmd});
                        continue;
                    } else if (is_exec(init, type_cmd, &full_path_buf)) |full_path| {
                        try stdout.interface.print("{s} is {s}\n", .{ type_cmd, full_path });
                        continue;
                    } else {
                        try stdout.interface.print("{s} not found\n", .{type_cmd});
                        continue;
                    }
                },
            }
        } else if (is_exec(init, first_arg, &exec_path_buf)) |exec_path| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);

            try argv.append(gpa, first_arg);

            for (args[1..]) |arg| {
                if (arg.len == 0) continue;

                try argv.append(gpa, arg);
            }

            var child = try std.process.spawn(io, .{
                .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = exec_path } },
                .argv = argv.items,
            });
            _ = try child.wait(io);

            continue;
        } else {
            try stdout.interface.print("{s}: command not found\n", .{first_arg});
            continue;
        }
    }
}

fn parseArgs(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8), line: []const u8) !void {
    const Mode = enum { normal, single_quote, double_quote, backslash };
    var mode: Mode = .normal;

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    for (line) |c| {
        switch (mode) {
            .normal => {
                switch (c) {
                    '\'' => mode = .single_quote,
                    '"' => mode = .double_quote,
                    '\\' => mode = .backslash,
                    ' ' => {
                        if (current.items.len > 0) {
                            try args.append(gpa, try current.toOwnedSlice(gpa));
                        }
                    },
                    else => {
                        try current.append(gpa, c);
                    },
                }
            },
            .single_quote => {
                switch (c) {
                    '\'' => {
                        mode = .normal;
                    },
                    else => {
                        try current.append(gpa, c);
                    },
                }
            },
            .double_quote => {
                switch (c) {
                    '"' => {
                        mode = .normal;
                    },
                    else => {
                        try current.append(gpa, c);
                    },
                }
            },
            .backslash => {
                try current.append(gpa, c);
                mode = .normal;
            },
        }
    }

    if (current.items.len > 0) try args.append(gpa, try current.toOwnedSlice(gpa));
}

fn is_builtin(cmd: []const u8) bool {
    _ = std.meta.stringToEnum(Command, cmd) orelse {
        return false;
    };
    return true;
}

fn is_exec(init: std.process.Init, cmd: []const u8, buf: []u8) ?[]u8 {
    const path = init.environ_map.get("PATH") orelse "";

    var dirs = std.mem.splitScalar(u8, path, std.fs.path.delimiter);

    while (dirs.next()) |dir| {
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, cmd }) catch continue;

        std.Io.Dir.cwd().access(init.io, full, .{ .execute = true }) catch continue;

        return full;
    }

    return null;
}
