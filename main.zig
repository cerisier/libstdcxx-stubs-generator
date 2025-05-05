const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const log = std.log;
const fs = std.fs;
const path = fs.path;
const Version = std.SemanticVersion;

const usage =
    \\Usage: ./libstd++-stubs-generator baseline_symbols_path
    \\
    \\    Parse a baseline_symbols of libstd++-v3 for a given target and generate assembly files to build a libstdc++ stub.
    \\
    \\Options:
    \\  -h, --help             Print this help and exit
    \\  -target [name]         <arch><sub>-<os>-<abi> see the targets command (linux only)
    \\  -o, --output-dir       The base output directory for the generated files
    \\
;

fn wordDirective(target: std.Target) []const u8 {
    // Based on its description in the GNU `as` manual, you might assume that `.word` is sized
    // according to the target word size. But no; that would just make too much sense.
    return if (target.ptrBitWidth() == 64) ".quad" else ".long";
}

const ParseError = error{
    MissingUnderscore,
    InvalidVersion,
    MissingMajor,
    MissingMinor,
    InvalidInteger,
};

const SymbolVersion = struct {
    name: []const u8,
    major: u32,
    minor: u32,
    patch: ?u32,
};

pub fn parseVersionLine(line: []const u8) anyerror!SymbolVersion {
    var underscore_index: ?usize = null;
    for (line, 0..) |c, i| {
        if (c == '_') {
            underscore_index = i;
            break;
        }
    }
    if (underscore_index == null) {
        return ParseError.MissingUnderscore;
    }

    const name = line[0..underscore_index.?];
    const version_str = line[underscore_index.? + 1 ..];

    var it = std.mem.splitScalar(u8, version_str, '.');
    const major_str = it.next() orelse return ParseError.MissingMajor;
    const minor_str = it.next() orelse return ParseError.MissingMinor;
    const patch_str = it.next(); // optional

    const major = std.fmt.parseInt(u32, major_str, 10) catch return ParseError.InvalidInteger;
    const minor = std.fmt.parseInt(u32, minor_str, 10) catch return ParseError.InvalidInteger;
    var patch: ?u32 = null;
    if (patch_str) |ps| {
        patch = std.fmt.parseInt(u32, ps, 10) catch return ParseError.InvalidInteger;
    }

    return SymbolVersion{
        .name = name,
        .major = major,
        .minor = minor,
        .patch = patch,
    };
}

const SymbolType = enum(u32) {
    FUNC = std.mem.bytesToValue(u32, "FUNC"),
    OBJECT = std.mem.bytesToValue(u32, "OBJECT"),
    _,
};

pub fn buildSharedObjects(o_directory: *fs.Dir, target: std.Target, baseline_symbols_path: []const u8) anyerror!void {
    var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = general_purpose_allocator.allocator();

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const infile = try std.fs.cwd().openFile(baseline_symbols_path, .{});
    defer infile.close();

    var stubs_asm_funcs = std.ArrayList(u8).init(gpa);
    defer stubs_asm_funcs.deinit();

    var stubs_asm_objects = std.ArrayList(u8).init(gpa);
    defer stubs_asm_objects.deinit();

    var map_contents = std.ArrayList(u8).init(gpa);
    defer map_contents.deinit();

    var versions_written = std.StringArrayHashMap(void).init(gpa);
    defer versions_written.deinit();

    try stubs_asm_funcs.appendSlice(".text\n");

    var line_buffer: [256]u8 = undefined;

    while (infile.reader().readUntilDelimiter(&line_buffer, '\n') catch null) |line| {
        if (std.mem.startsWith(u8, line, "#") or line.len == 0) {
            continue;
        }

        var parts = std.mem.splitScalar(u8, line, ':');
        const typ = parts.next() orelse continue;

        switch (std.mem.bytesToValue(SymbolType, typ)) {
            .FUNC => {
                const sym_with_ver = parts.next() orelse continue;

                var want_default: bool = false;
                if (std.mem.indexOf(u8, sym_with_ver, "@@") != null) {
                    want_default = true;
                } else if (std.mem.indexOf(u8, sym_with_ver, "@") != null) {
                    want_default = false;
                } else {
                    continue;
                    // fatal("no version in symbol: {s}", .{sym_with_ver});
                }

                const at_sign_str = if (want_default) "@@" else "@";
                var sym_parts = std.mem.splitSequence(u8, sym_with_ver, at_sign_str);
                const sym_name = sym_parts.next() orelse continue;
                const version = sym_parts.next() orelse continue;

                var version_suffix_buffer: [256]u8 = [_]u8{0} ** 256;
                _ = std.mem.replace(u8, version, ".", "_", &version_suffix_buffer);

                const version_suffix = version_suffix_buffer[0..version.len];
                const sym_plus_ver = if (want_default)
                    sym_name
                else
                    try std.fmt.allocPrint(
                        arena,
                        "{s}_{s}",
                        .{ sym_name, version_suffix },
                    );

                try stubs_asm_funcs.writer().print(
                    \\.balign {d}
                    \\.globl {s}
                    \\.type {s}, %function;
                    \\.symver {s}, {s}{s}{s}
                    \\{s}: {s} 0
                    \\
                , .{
                    target.ptrBitWidth() / 8,
                    sym_plus_ver,
                    sym_plus_ver,
                    sym_plus_ver,
                    sym_name,
                    at_sign_str,
                    version,
                    sym_plus_ver,
                    wordDirective(target),
                });

                const result = try versions_written.getOrPut(version);
                if (result.found_existing == false) {
                    result.key_ptr.* = try arena.dupe(u8, version);
                    try map_contents.writer().print("{s} {{ }};\n", .{version});
                }
            },
            .OBJECT => {
                const size_str = parts.next() orelse continue;
                const size = try std.fmt.parseInt(usize, size_str, 10);

                const sym_with_ver = parts.next() orelse continue;

                var want_default: bool = false;
                if (std.mem.indexOf(u8, sym_with_ver, "@@") != null) {
                    want_default = true;
                } else if (std.mem.indexOf(u8, sym_with_ver, "@") != null) {
                    want_default = false;
                } else {
                    continue;
                    // fatal("no version in symbol: {s}", .{sym_with_ver});
                }

                const at_sign_str = if (want_default) "@@" else "@";
                var sym_parts = std.mem.splitSequence(u8, sym_with_ver, at_sign_str);
                const sym_name = sym_parts.next() orelse continue;
                const version = sym_parts.next() orelse continue;

                var version_suffix: [255]u8 = [_]u8{0} ** 255;
                _ = std.mem.replace(u8, version, ".", "_", &version_suffix);

                const sym_plus_ver = if (want_default)
                    sym_name
                else
                    try std.fmt.allocPrint(
                        arena,
                        "{s}_{s}",
                        .{ sym_name, version_suffix },
                    );

                try stubs_asm_objects.writer().print(
                    \\.balign {d}
                    \\.globl {s}
                    \\.type {s}, %object;
                    \\.size {s}, {d};
                    \\.symver {s}, {s}{s}{s}
                    \\{s}: .fill {d}, 1, 0
                    \\
                , .{
                    target.ptrBitWidth() / 8,
                    sym_plus_ver,
                    sym_plus_ver,
                    sym_plus_ver,
                    size,
                    sym_plus_ver,
                    sym_name,
                    at_sign_str,
                    version,
                    sym_plus_ver,
                    size,
                });

                const result = try versions_written.getOrPut(version);
                if (result.found_existing == false) {
                    result.key_ptr.* = try arena.dupe(u8, version);
                    try map_contents.writer().print("{s} {{ }};\n", .{version});
                }
            },
            else => continue,
        }
    }

    var f = try o_directory.createFile("libstdc++.S", .{ .truncate = true });
    try f.writer().print(".text\n", .{});
    try f.writer().writeAll(stubs_asm_funcs.items);
    try f.writer().print(".data\n", .{});
    try f.writer().writeAll(stubs_asm_objects.items);
    defer f.close();

    try o_directory.writeFile(.{ .sub_path = "all.map", .data = map_contents.items });
}

pub fn main() anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);

    var target_arch_os_abi: ?[]const u8 = null;
    var o_base_directory_path: []const u8 = "build";
    var baseline_symbols_path: ?[]const u8 = null;
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                    const stdout = std.io.getStdOut().writer();
                    try stdout.writeAll(usage);
                    return std.process.cleanExit();
                } else if (mem.eql(u8, arg, "-target")) {
                    if (i + 1 >= args.len) fatal("expected parameter after {s}", .{arg});
                    i += 1;
                    target_arch_os_abi = args[i];
                } else if (mem.eql(u8, arg, "-o") or mem.eql(u8, arg, "--output-dir")) {
                    if (i + 1 >= args.len) fatal("expected parameter after {s}", .{arg});
                    i += 1;
                    o_base_directory_path = args[i];
                } else {
                    fatal("unrecognized parameter: '{s}'", .{arg});
                }
            } else if (baseline_symbols_path != null) {
                fatal("unexpected extra parameter: '{s}'", .{arg});
            } else {
                baseline_symbols_path = arg;
            }
        }
    }

    if (target_arch_os_abi == null) {
        fatal("missing required parameter: '-target'", .{});
    }

    if (baseline_symbols_path == null) {
        const stdout = std.io.getStdErr().writer();
        try stdout.writeAll(usage);
        std.process.exit(1);
    }

    const target_query = std.zig.parseTargetQueryOrReportFatalError(arena, .{
        .arch_os_abi = target_arch_os_abi.?,
    });
    const target = std.zig.resolveTargetQueryOrFatal(target_query);

    var o_directory: fs.Dir = try fs.cwd().makeOpenPath(o_base_directory_path, .{});

    try buildSharedObjects(&o_directory, target, baseline_symbols_path.?);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}
