const std = @import("std");
const clap = @import("clap");
const mimalloc = @import("mimalloc");
const zeit = @import("zeit");

const allocator = mimalloc.basic_allocator;

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\--version_str <str>   
        \\--runtime_dir <str>   
        \\--input <str>         input template file
        \\--output <str>        output file name
        \\<str>...
    );

    const parsers = comptime .{
        .str = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        var buffer: [1024]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buffer).interface;
        diag.report(&writer, err) catch {};
        return err;
    };
    defer res.deinit();

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const version_str = res.args.version_str orelse {
        _ = try stderr.write("--version_str not specified\n");
        return error.InvalidArgument;
    };
    const runtime_dir = res.args.runtime_dir orelse {
        _ = try stderr.write("--runtime_dir not specified\n");
        return error.InvalidArgument;
    };

    const input = res.args.input orelse {
        _ = try stderr.write("--input not specified\n");
        return error.InvalidArgument;
    };
    const input_file = std.fs.Dir.openFile(std.fs.cwd(), input, .{}) catch |err| {
        _ = try stderr.write("Failed to create input file\n");
        return err;
    };
    defer input_file.close();
    const input_contents = try input_file.readToEndAlloc(allocator, 16 * 1024 * 1024);

    const output = res.args.output orelse {
        _ = try stderr.write("--output not specified\n");
        return error.InvalidArgument;
    };
    const output_file = std.fs.Dir.createFile(std.fs.cwd(), output, .{}) catch |err| {
        _ = try stderr.write("Failed to create output file\n");
        return err;
    };
    defer output_file.close();
    var output_writer = std.io.bufferedWriter(output_file.deprecatedWriter());

    const files = res.positionals[0];
    if (files.len == 0) {
        _ = try stderr.write("files not specified\n");
        return error.InvalidArgument;
    }

    const snapshot_hash = try makeSnapshotHashString(runtime_dir, files);
    const build_time = try makeBuildTimeString();

    var i: usize = 0;
    while (i < input_contents.len) : (i = i + 1) {
        {
            const needle = "{{VERSION_STR}}";
            if (std.mem.startsWith(u8, input_contents[i..], needle)) {
                _ = try output_writer.write(version_str);
                i = i + needle.len - 1;
                continue;
            }
        }
        {
            const needle = "{{SNAPSHOT_HASH}}";
            if (std.mem.startsWith(u8, input_contents[i..], needle)) {
                _ = try output_writer.write(snapshot_hash);
                i = i + needle.len - 1;
                continue;
            }
        }
        {
            const needle = "{{BUILD_TIME}}";
            if (std.mem.startsWith(u8, input_contents[i..], needle)) {
                _ = try output_writer.write(build_time);
                i = i + needle.len - 1;
                continue;
            }
        }

        _ = try output_writer.write(input_contents[i .. i + 1]);
    }
    try output_writer.flush();
}

fn makeSnapshotHashString(runtime_dir: []const u8, vm_snapshot_files: []const []const u8) ![]const u8 {
    var hash = std.crypto.hash.Md5.init(.{});
    for (vm_snapshot_files) |file_name| {
        const dir_name = try std.fs.path.join(allocator, &[_][]const u8{ runtime_dir, "vm" });
        const dir = try std.fs.cwd().openDir(dir_name, .{ .access_sub_paths = false, .iterate = false, .no_follow = true });
        const file = try std.fs.Dir.openFile(dir, file_name, .{});
        defer file.close();
        const file_contents = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
        defer allocator.free(file_contents);
        hash.update(file_contents);
    }
    var out: [16]u8 = undefined;
    hash.final(&out);
    return &std.fmt.bytesToHex(&out, .lower);
}

fn makeBuildTimeString() ![]const u8 {
    const now = try zeit.instant(.{});
    const time = now.time();
    // Fri Jun 13 12:46:59 2025
    var buf = try allocator.alloc(u8, 128);
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    try time.gofmt(writer, "Mon Jan 2 15:04:05 2006");
    return buf[0..fbs.pos];
}
