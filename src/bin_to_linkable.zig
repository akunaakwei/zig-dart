const std = @import("std");
const clap = @import("clap");
const mimalloc = @import("mimalloc");
const Target = std.Target;

const allocator = mimalloc.basic_allocator;

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\--output <str>         output assembly file name
        \\--input <str>          input binary blob file
        \\--symbol_name <str>
        \\--executable
        \\--target <str>
        \\--size_symbol_name <str>
        \\--incbin
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
    };

    // Initialize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    const stderr = std.io.getStdErr().writer();
    const output_path = res.args.output orelse {
        _ = try stderr.write("--output not specified\n");
        return;
    };
    const input_path = res.args.input orelse {
        _ = try stderr.write("--input not specified\n");
        return;
    };
    const symbol_name = res.args.symbol_name orelse {
        _ = try stderr.write("--symbol_name not specified\n");
        return;
    };
    const executable = res.args.executable == 1;
    const incbin = res.args.incbin == 1;

    const target_str = res.args.target orelse {
        _ = try stderr.write("--target not specified\n");
        return;
    };
    const target_query = Target.Query.parse(.{
        .arch_os_abi = target_str,
    }) catch {
        _ = try stderr.write("could not parse target\n");
        return;
    };
    const target = std.zig.system.resolveTargetQuery(target_query) catch {
        _ = try stderr.write("could not resolve target\n");
        return;
    };

    const input_file = std.fs.Dir.openFile(std.fs.cwd(), input_path, .{}) catch |err| {
        _ = try stderr.write("Failed to open input file\n");
        return err;
    };
    defer input_file.close();
    const input = input_file.reader();

    const output_file = std.fs.Dir.createFile(std.fs.cwd(), output_path, .{}) catch |err| {
        _ = try stderr.write("Failed to create output file\n");
        return err;
    };
    defer output_file.close();
    var output = std.io.bufferedWriter(output_file.writer());

    if (target.os.tag == .macos or target.os.tag == .ios) {
        if (executable) {
            try print(&output, ".text\n", .{});
        } else {
            try print(&output, ".const\n", .{});
        }
        try print(&output, ".global _{s}\n", .{symbol_name});
        try print(&output, ".balign 32\n", .{});
        try print(&output, "_{s}:\n", .{symbol_name});
    } else if (target.os.tag == .windows and !target.abi.isGnu()) {
        try print(&output, "ifndef _ML64_X64\n", .{});
        try print(&output, ".model flat, C\n", .{});
        try print(&output, "endif\n", .{});
        if (executable) {
            try print(&output, ".code\n", .{});
        } else {
            try print(&output, ".const\n", .{});
        }
        try print(&output, "public {s}\n", .{symbol_name});
        try print(&output, "{s} label byte\n", .{symbol_name});
    } else if (target.os.tag == .windows and target.abi.isGnu()) {
        if (executable) {
            try print(&output, ".text\n", .{});
        } else {
            try print(&output, ".section .rodata\n", .{});
        }
        try print(&output, ".global {s}\n", .{symbol_name});
        try print(&output, ".balign 32\n", .{});
        try print(&output, "{s}:\n", .{symbol_name});
    } else {
        if (executable) {
            try print(&output, ".text\n", .{});
            try print(&output, ".type {s} STT_FUNC\n", .{symbol_name});
        } else {
            try print(&output, ".section .rodata\n", .{});
            try print(&output, ".type {s} STT_OBJECT\n", .{symbol_name});
        }
        try print(&output, ".global {s}\n", .{symbol_name});
        try print(&output, ".balign 32\n", .{});
        try print(&output, "{s}:\n", .{symbol_name});
    }

    var size: usize = 0;
    while (true) {
        const b = input.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (target.os.tag == .windows and !target.abi.isGnu()) {
            try print(&output, "byte {d}\n", .{b});
        } else {
            if (!incbin) {
                try print(&output, ".byte {d}\n", .{b});
            }
        }
        size = size + 1;
    }
    if (incbin) {
        try print(&output, ".incbin \"{s}\"\n", .{input_path});
    }
    if (target.os.tag != .macos and target.os.tag != .ios and target.os.tag != .windows) {
        try print(&output, ".size {s}, .-{s}\n", .{ symbol_name, symbol_name });
    }
    if (res.args.size_symbol_name) |size_symbol_name| {
        const is64bit = Target.ptrBitWidth(&target) == 64;

        if (target.os.tag == .windows and !target.abi.isGnu()) {
            try print(&output, "public {s}\n", .{size_symbol_name});
            try print(&output, "{s} label byte\n", .{size_symbol_name});
            if (is64bit) {
                try print(&output, "qword {d}\n", .{size});
            } else {
                try print(&output, "dword {d}\n", .{size});
            }
        } else {
            if (target.os.tag == .macos or target.os.tag == .ios) {
                try print(&output, ".global _{s}\n", .{size_symbol_name});
                try print(&output, "_{s}:\n", .{size_symbol_name});
            } else {
                try print(&output, ".global {s}\n", .{size_symbol_name});
                try print(&output, "{s}:\n", .{size_symbol_name});
            }
            if (is64bit) {
                try print(&output, ".quad {d}\n", .{size});
            } else {
                try print(&output, ".long {d}\n", .{size});
            }
        }
    }
    if (target.os.tag == .windows and !target.abi.isGnu()) {
        try print(&output, "end\n", .{});
    }
    try output.flush();
}

inline fn print(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, fmt, args);
    _ = try writer.write(line);
}
