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

    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(&stderr.interface, err) catch {};
        return err;
    };
    defer res.deinit();

    const output_path = res.args.output orelse {
        _ = try stderr.interface.write("--output not specified\n");
        return;
    };
    const input_path = res.args.input orelse {
        _ = try stderr.interface.write("--input not specified\n");
        return;
    };
    const symbol_name = res.args.symbol_name orelse {
        _ = try stderr.interface.write("--symbol_name not specified\n");
        return;
    };
    const executable = res.args.executable == 1;
    const incbin = res.args.incbin == 1;

    const target_str = res.args.target orelse {
        _ = try stderr.interface.write("--target not specified\n");
        return;
    };
    const target_query = Target.Query.parse(.{
        .arch_os_abi = target_str,
    }) catch {
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "could not parse {s} as target\n", .{target_str});
        _ = try stderr.interface.write(line);
        return;
    };
    const target = std.zig.system.resolveTargetQuery(target_query) catch {
        _ = try stderr.interface.write("could not resolve target\n");
        return;
    };

    const input_file = std.fs.Dir.openFile(std.fs.cwd(), input_path, .{}) catch |err| {
        _ = try stderr.interface.write("Failed to open input file\n");
        return err;
    };
    defer input_file.close();
    const input = input_file.deprecatedReader();

    const output_file = std.fs.Dir.createFile(std.fs.cwd(), output_path, .{}) catch |err| {
        _ = try stderr.interface.write("Failed to create output file\n");
        return err;
    };
    defer output_file.close();
    try stderr.interface.flush();

    var output_buffer: [2048]u8 = undefined;
    var output_writer = output_file.writer(&output_buffer);

    if (target.os.tag == .macos or target.os.tag == .ios) {
        if (executable) {
            try output_writer.interface.print(".text\n", .{});
        } else {
            try output_writer.interface.print(".const\n", .{});
        }
        try output_writer.interface.print(".global _{s}\n", .{symbol_name});
        try output_writer.interface.print(".balign 32\n", .{});
        try output_writer.interface.print("_{s}:\n", .{symbol_name});
    } else if (target.os.tag == .windows and !target.abi.isGnu()) {
        try output_writer.interface.print("ifndef _ML64_X64\n", .{});
        try output_writer.interface.print(".model flat, C\n", .{});
        try output_writer.interface.print("endif\n", .{});
        if (executable) {
            try output_writer.interface.print(".code\n", .{});
        } else {
            try output_writer.interface.print(".const\n", .{});
        }
        try output_writer.interface.print("public {s}\n", .{symbol_name});
        try output_writer.interface.print("{s} label byte\n", .{symbol_name});
    } else if (target.os.tag == .windows and target.abi.isGnu()) {
        if (executable) {
            try output_writer.interface.print(".text\n", .{});
        } else {
            try output_writer.interface.print(".section .rodata\n", .{});
        }
        try output_writer.interface.print(".global {s}\n", .{symbol_name});
        try output_writer.interface.print(".balign 32\n", .{});
        try output_writer.interface.print("{s}:\n", .{symbol_name});
    } else {
        if (executable) {
            try output_writer.interface.print(".text\n", .{});
            try output_writer.interface.print(".type {s} STT_FUNC\n", .{symbol_name});
        } else {
            try output_writer.interface.print(".section .rodata\n", .{});
            try output_writer.interface.print(".type {s} STT_OBJECT\n", .{symbol_name});
        }
        try output_writer.interface.print(".global {s}\n", .{symbol_name});
        try output_writer.interface.print(".balign 32\n", .{});
        try output_writer.interface.print("{s}:\n", .{symbol_name});
    }

    var size: usize = 0;
    while (true) {
        const b = input.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (target.os.tag == .windows and !target.abi.isGnu()) {
            try output_writer.interface.print("byte {d}\n", .{b});
        } else {
            if (!incbin) {
                try output_writer.interface.print(".byte {d}\n", .{b});
            }
        }
        size = size + 1;
    }
    if (incbin) {
        try output_writer.interface.print(".incbin \"{s}\"\n", .{input_path});
    }
    if (target.os.tag != .macos and target.os.tag != .ios and target.os.tag != .windows) {
        try output_writer.interface.print(".size {s}, .-{s}\n", .{ symbol_name, symbol_name });
    }
    if (res.args.size_symbol_name) |size_symbol_name| {
        const is64bit = Target.ptrBitWidth(&target) == 64;

        if (target.os.tag == .windows and !target.abi.isGnu()) {
            try output_writer.interface.print("public {s}\n", .{size_symbol_name});
            try output_writer.interface.print("{s} label byte\n", .{size_symbol_name});
            if (is64bit) {
                try output_writer.interface.print("qword {d}\n", .{size});
            } else {
                try output_writer.interface.print("dword {d}\n", .{size});
            }
        } else {
            if (target.os.tag == .macos or target.os.tag == .ios) {
                try output_writer.interface.print(".global _{s}\n", .{size_symbol_name});
                try output_writer.interface.print("_{s}:\n", .{size_symbol_name});
            } else {
                try output_writer.interface.print(".global {s}\n", .{size_symbol_name});
                try output_writer.interface.print("{s}:\n", .{size_symbol_name});
            }
            if (is64bit) {
                try output_writer.interface.print(".quad {d}\n", .{size});
            } else {
                try output_writer.interface.print(".long {d}\n", .{size});
            }
        }
    }
    if (target.os.tag == .windows and !target.abi.isGnu()) {
        try output_writer.interface.print("end\n", .{});
    }
    try output_writer.interface.flush();
}
