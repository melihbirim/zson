const std = @import("std");
const cli = @import("cli.zig");
const query = @import("query.zig");
const parallel = @import("parallel_ndjson.zig");
const output = @import("output.zig");
const json_parser = @import("json_parser.zig");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Parse command-line arguments
    var options = cli.parseArgs(allocator) catch |err| {
        if (err == error.UnknownOption or err == error.TooManyArgs or err == error.MissingValue) {
            std.debug.print("\nError: Invalid arguments\n\n", .{});
            var buf = std.ArrayList(u8){};
            defer buf.deinit(allocator);
            cli.printHelp(buf.writer(allocator)) catch {};
            std.debug.print("{s}", .{buf.items});
            std.process.exit(1);
        }
        return err;
    };
    defer options.deinit();

    // Show help if requested
    if (options.show_help) {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        try cli.printHelp(buf.writer(allocator));
        std.debug.print("{s}", .{buf.items});
        return;
    }

    // Parse the MongoDB query
    var parsed_query = query.parseQuery(options.query, allocator) catch |err| {
        std.debug.print("Error parsing query: {}\n", .{err});
        std.debug.print("Query: {s}\n", .{options.query});
        std.process.exit(1);
    };
    defer parsed_query.deinit(allocator);

    // Check we have an input file
    const file_path = options.input_file orelse {
        std.debug.print("Error: No input file specified\n", .{});
        std.debug.print("Usage: zson '{{query}}' <file.ndjson>\n", .{});
        std.process.exit(1);
    };

    // ── file path: use fast streaming output when flags allow it ─────────────
    if (!std.mem.eql(u8, file_path, "-")) {
        if (options.count_only and options.limit == null) {
            // Fast count-only path: no object materialisation, just atomic counters
            const count = try parallel.processFileCount(
                file_path,
                &parsed_query.filter,
                .{ .num_threads = options.threads },
                allocator,
            );
            var buf: [32]u8 = undefined;
            const count_str = try std.fmt.bufPrint(&buf, "{d}\n", .{count});
            _ = try std.posix.write(std.posix.STDOUT_FILENO, count_str);
            return;
        }

        if (options.output_format == .ndjson and options.limit == null) {
            // Fast default output path: worker threads serialize NDJSON directly.
            var output_buffer = try parallel.processFileWithOutput(
                file_path,
                &parsed_query.filter,
                .{ .num_threads = options.threads },
                options.select_fields,
                allocator,
            );
            defer output_buffer.deinit(allocator);
            _ = try std.posix.write(std.posix.STDOUT_FILENO, output_buffer.items);
            return;
        }

        var result = try parallel.processFile(
            file_path,
            &parsed_query.filter,
            .{ .num_threads = options.threads },
            allocator,
        );
        defer result.deinit();

        const objects = limitedObjects(result.matches.items, options.limit);
        try writeResults(objects, options, allocator);
        return;
    }

    // ── stdin path ────────────────────────────────────────────────────────────
    var result = try processStdin(&parsed_query.filter, options, allocator);
    defer result.deinit();

    // Apply limit if specified
    const objects = limitedObjects(result.matches.items, options.limit);
    try writeResults(objects, options, allocator);
}

fn limitedObjects(
    objects: []const json_parser.JsonObject,
    limit: ?usize,
) []const json_parser.JsonObject {
    if (limit) |n| return objects[0..@min(n, objects.len)];
    return objects;
}

fn writeResults(
    objects: []const json_parser.JsonObject,
    options: cli.CliOptions,
    allocator: std.mem.Allocator,
) !void {
    if (options.count_only) {
        var buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&buf, "{d}\n", .{objects.len});
        _ = try std.posix.write(std.posix.STDOUT_FILENO, count_str);
        return;
    }

    var output_buf: std.ArrayList(u8) = .{};
    defer output_buf.deinit(allocator);
    const writer = output_buf.writer(allocator);

    switch (options.output_format) {
        .ndjson => try output.writeNdjson(writer, objects, options.select_fields),
        .json => try output.writeJson(writer, objects, options.select_fields, options.pretty),
        .csv => try output.writeCsv(writer, objects, options.select_fields),
    }

    _ = try std.posix.write(std.posix.STDOUT_FILENO, output_buf.items);
}

fn processStdin(
    filter: *const query.Filter,
    options: cli.CliOptions,
    allocator: std.mem.Allocator,
) !parallel.ChunkResult {
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const data = try stdin_file.readToEndAlloc(allocator, 4 * 1024 * 1024 * 1024); // up to 4 GB
    const cfg = parallel.Config{ .num_threads = options.threads };
    var result = try parallel.processData(data, filter, cfg, allocator);
    if (result.owned_data == null) {
        // NDJSON: matched field slices point into data; transfer ownership to result
        result.owned_data = data;
    } else {
        // JSON array: processData owns the converted NDJSON buffer; free original
        allocator.free(data);
    }
    return result;
}
