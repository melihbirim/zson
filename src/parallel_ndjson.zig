const std = @import("std");
const json_parser = @import("json_parser.zig");
const query = @import("query.zig");
const simd = @import("simd.zig");

/// Result of processing a chunk of NDJSON data
pub const ChunkResult = struct {
    matches: std.ArrayList(json_parser.JsonObject),
    lines_processed: usize,
    allocator: std.mem.Allocator,
    mmap_data: ?[]align(16384) const u8, // Memory-mapped data (needs munmap, not free)
    owned_data: ?[]u8, // Allocated data (needs free)
    output_buffer: ?std.ArrayList(u8), // Pre-serialized output for parallel generation

    pub fn init(allocator: std.mem.Allocator) ChunkResult {
        return .{
            .matches = std.ArrayList(json_parser.JsonObject){},
            .lines_processed = 0,
            .allocator = allocator,
            .mmap_data = null,
            .owned_data = null,
            .output_buffer = null,
        };
    }

    pub fn deinit(self: *ChunkResult) void {
        for (self.matches.items) |*obj| {
            obj.deinit();
        }
        self.matches.deinit(self.allocator);

        // Free output buffer if present
        if (self.output_buffer) |*buf| {
            buf.deinit(self.allocator);
        }

        // Unmap memory-mapped data
        if (self.mmap_data) |data| {
            std.posix.munmap(data);
        }

        // Free owned data
        if (self.owned_data) |data| {
            self.allocator.free(data);
        }
    }
};

/// Configuration for parallel processing
pub const Config = struct {
    num_threads: usize = 7,
    chunk_size: usize = 1024 * 1024, // 1MB chunks
};

/// Input format: auto-detected from the first non-whitespace byte.
pub const Format = enum { ndjson, json_array };

/// Detect whether data is NDJSON (objects separated by newlines) or a JSON array ([...]).
pub fn detectFormat(data: []const u8) Format {
    for (data) |b| {
        switch (b) {
            ' ', '\t', '\n', '\r' => continue,
            '[' => return .json_array,
            else => break,
        }
    }
    return .ndjson;
}

/// Convert a JSON array ([{...},{...},...]) to NDJSON (one object per line).
/// Handles nested objects and strings correctly via a depth counter.
/// Returns an owned slice; caller must free with allocator.free().
pub fn jsonArrayToNdjson(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    const len = data.len;

    // Skip to opening '['
    while (i < len and data[i] != '[') : (i += 1) {}
    if (i >= len) return out.toOwnedSlice(allocator);
    i += 1;

    while (i < len) {
        // Skip whitespace and commas between objects
        while (i < len) : (i += 1) {
            const b = data[i];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == ',') continue;
            break;
        }
        if (i >= len or data[i] == ']') break;
        if (data[i] != '{') {
            i += 1;
            continue;
        }

        // Extract one balanced {...} object
        const start = i;
        var depth: usize = 0;
        var in_string = false;
        while (i < len) : (i += 1) {
            const b = data[i];
            if (in_string) {
                if (b == '\\') {
                    i += 1; // skip escaped character
                } else if (b == '"') {
                    in_string = false;
                }
            } else {
                switch (b) {
                    '"' => in_string = true,
                    '{' => depth += 1,
                    '}' => {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }

        try out.appendSlice(allocator, data[start..i]);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

/// Context passed to each worker thread
const WorkerContext = struct {
    data: []const u8,
    filter: *const query.Filter,
    result: *ChunkResult,
    allocator: std.mem.Allocator,
};

/// Process a single line of NDJSON
fn processLine(line: []const u8, filter: *const query.Filter, result: *ChunkResult) !void {
    if (line.len == 0) return;

    // Parse the JSON object
    var obj = json_parser.parseObject(line, result.allocator) catch |err| {
        // Skip malformed lines
        std.debug.print("Warning: failed to parse line: {}\n", .{err});
        return;
    };

    // Evaluate against filter
    const matches = query.matches(&obj, filter);

    if (matches) {
        try result.matches.append(result.allocator, obj);
    } else {
        obj.deinit();
    }

    result.lines_processed += 1;
}

/// Worker thread function
fn workerThread(ctx: *WorkerContext) void {
    var line_start: usize = 0;

    // Process each line in this chunk
    for (ctx.data, 0..) |byte, i| {
        if (byte == '\n') {
            const line = ctx.data[line_start..i];
            processLine(line, ctx.filter, ctx.result) catch |err| {
                std.debug.print("Error processing line: {}\n", .{err});
            };
            line_start = i + 1;
        }
    }

    // Handle last line if no trailing newline
    if (line_start < ctx.data.len) {
        const line = ctx.data[line_start..];
        processLine(line, ctx.filter, ctx.result) catch |err| {
            std.debug.print("Error processing last line: {}\n", .{err});
        };
    }
}

/// Split data into chunks aligned on newline boundaries
fn splitIntoChunks(data: []const u8, num_chunks: usize, allocator: std.mem.Allocator) ![][]const u8 {
    var chunks = try allocator.alloc([]const u8, num_chunks);

    if (num_chunks == 1) {
        chunks[0] = data;
        return chunks;
    }

    const chunk_size = data.len / num_chunks;
    var start: usize = 0;

    for (0..num_chunks) |i| {
        if (i == num_chunks - 1) {
            // Last chunk gets remainder
            chunks[i] = data[start..];
        } else {
            // Find next newline after chunk_size
            var end = @min(start + chunk_size, data.len);

            // Scan forward to find newline
            while (end < data.len and data[end] != '\n') {
                end += 1;
            }

            if (end < data.len) {
                end += 1; // Include the newline
            }

            chunks[i] = data[start..end];
            start = end;
        }
    }

    return chunks;
}

/// Context for count-only worker (no allocations, just an atomic counter)
const CountWorkerContext = struct {
    data: []const u8,
    filter: *const query.Filter,
    count: std.atomic.Value(usize),

    pub fn init(data: []const u8, filter: *const query.Filter) CountWorkerContext {
        return .{
            .data = data,
            .filter = filter,
            .count = std.atomic.Value(usize).init(0),
        };
    }
};

fn countWorkerThread(ctx: *CountWorkerContext) void {
    const alloc = std.heap.c_allocator;
    var local: usize = 0;
    var line_start: usize = 0;

    for (ctx.data, 0..) |byte, i| {
        if (byte == '\n') {
            const line = ctx.data[line_start..i];
            if (line.len > 0) {
                var obj = json_parser.parseObject(line, alloc) catch {
                    line_start = i + 1;
                    continue;
                };
                defer obj.deinit();
                if (query.matches(&obj, ctx.filter)) local += 1;
            }
            line_start = i + 1;
        }
    }
    // Handle last line without trailing newline
    if (line_start < ctx.data.len) {
        const line = ctx.data[line_start..];
        if (line.len > 0) {
            var obj = json_parser.parseObject(line, alloc) catch {
                _ = ctx.count.fetchAdd(local, .monotonic);
                return;
            };
            defer obj.deinit();
            if (query.matches(&obj, ctx.filter)) local += 1;
        }
    }

    _ = ctx.count.fetchAdd(local, .monotonic);
}

/// Count matching records without materialising any objects.
/// Much faster than processFile() for --count mode.
pub fn processFileCount(
    file_path: []const u8,
    filter: *const query.Filter,
    config: Config,
    allocator: std.mem.Allocator,
) !usize {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    if (file_size == 0) return 0;

    const data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(data);

    // Normalise to NDJSON (JSON arrays are converted; NDJSON passes through untouched)
    var ndjson_owned: ?[]u8 = null;
    defer if (ndjson_owned) |d| allocator.free(d);
    const ndjson: []const u8 = if (detectFormat(data) == .json_array) blk: {
        ndjson_owned = try jsonArrayToNdjson(data, allocator);
        break :blk ndjson_owned.?;
    } else data;

    const num_threads = @min(config.num_threads, std.Thread.getCpuCount() catch 4);
    const chunks = try splitIntoChunks(ndjson, num_threads, allocator);
    defer allocator.free(chunks);

    var contexts = try allocator.alloc(CountWorkerContext, num_threads);
    defer allocator.free(contexts);
    for (0..num_threads) |i| contexts[i] = CountWorkerContext.init(chunks[i], filter);

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);
    for (0..num_threads) |i| threads[i] = try std.Thread.spawn(.{}, countWorkerThread, .{&contexts[i]});
    for (threads) |t| t.join();

    var total: usize = 0;
    for (contexts) |*ctx| total += ctx.count.load(.monotonic);
    return total;
}

/// Process NDJSON file - reads file into memory to preserve slice validity
pub fn processFile(
    file_path: []const u8,
    filter: *const query.Filter,
    config: Config,
    allocator: std.mem.Allocator,
) !ChunkResult {
    // Read entire file into memory
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) {
        return ChunkResult.init(allocator);
    }

    // Memory-map the file for true zero-copy reading
    const mmap_data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );

    // Normalise to NDJSON. JSON arrays are converted (mmap freed immediately after);
    // NDJSON passes through and the mmap is held alive via merged.mmap_data.
    var ndjson_owned: ?[]u8 = null;
    const data: []const u8 = if (detectFormat(mmap_data) == .json_array) blk: {
        ndjson_owned = try jsonArrayToNdjson(mmap_data, allocator);
        std.posix.munmap(mmap_data);
        break :blk ndjson_owned.?;
    } else mmap_data;

    // Use parallel processing
    const num_threads = @min(config.num_threads, std.Thread.getCpuCount() catch 4);

    // Split into chunks aligned on newline boundaries
    const chunks = try splitIntoChunks(data, num_threads, allocator);
    defer allocator.free(chunks);

    // Create results for each thread
    var results = try allocator.alloc(ChunkResult, num_threads);
    defer {
        for (results) |*r| {
            r.matches.deinit(r.allocator);
        }
        allocator.free(results);
    }

    for (0..num_threads) |i| {
        results[i] = ChunkResult.init(allocator);
    }

    // Create worker contexts
    var contexts = try allocator.alloc(WorkerContext, num_threads);
    defer allocator.free(contexts);

    for (0..num_threads) |i| {
        contexts[i] = .{
            .data = chunks[i],
            .filter = filter,
            .result = &results[i],
            .allocator = allocator,
        };
    }

    // Spawn worker threads
    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Merge results from all threads
    var merged = ChunkResult.init(allocator);
    // Keep backing data alive as long as merged: mmap (NDJSON) or owned buf (JSON array)
    if (ndjson_owned) |d|
        merged.owned_data = d
    else
        merged.mmap_data = mmap_data;

    for (results) |*result| {
        merged.lines_processed += result.lines_processed;
        for (result.matches.items) |obj| {
            try merged.matches.append(merged.allocator, obj);
        }
        result.matches.clearRetainingCapacity();
    }

    return merged;
}

/// Process NDJSON data from memory (useful for testing)
pub fn processData(
    data: []const u8,
    filter: *const query.Filter,
    config: Config,
    allocator: std.mem.Allocator,
) !ChunkResult {
    // Normalise to NDJSON (JSON arrays are converted; NDJSON passes through)
    var ndjson_owned: ?[]u8 = null;
    const ndjson: []const u8 = if (detectFormat(data) == .json_array) blk: {
        ndjson_owned = try jsonArrayToNdjson(data, allocator);
        break :blk ndjson_owned.?;
    } else data;

    // Determine optimal number of threads
    const num_threads = @min(config.num_threads, std.Thread.getCpuCount() catch 4);

    // Split into chunks aligned on newline boundaries
    const chunks = try splitIntoChunks(ndjson, num_threads, allocator);
    defer allocator.free(chunks);

    // Create results for each thread
    var results = try allocator.alloc(ChunkResult, num_threads);
    defer {
        for (results) |*r| {
            r.deinit();
        }
        allocator.free(results);
    }

    for (0..num_threads) |i| {
        results[i] = ChunkResult.init(allocator);
    }

    // Create worker contexts
    var contexts = try allocator.alloc(WorkerContext, num_threads);
    defer allocator.free(contexts);

    for (0..num_threads) |i| {
        contexts[i] = .{
            .data = chunks[i],
            .filter = filter,
            .result = &results[i],
            .allocator = allocator,
        };
    }

    // Spawn worker threads
    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerThread, .{&contexts[i]});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Merge results from all threads
    var merged = ChunkResult.init(allocator);
    // If we converted a JSON array, the merged result owns the NDJSON buffer
    if (ndjson_owned) |d| merged.owned_data = d;

    for (results) |*result| {
        merged.lines_processed += result.lines_processed;
        for (result.matches.items) |obj| {
            try merged.matches.append(merged.allocator, obj);
        }
        // Clear items without deinit since we moved ownership
        result.matches.clearRetainingCapacity();
    }

    return merged;
}

/// Process NDJSON file with parallel output generation (sieswi-style optimization)
/// Each thread processes its chunk AND generates output simultaneously
/// Returns concatenated output buffer ready for single write() syscall
pub fn processFileWithOutput(
    file_path: []const u8,
    filter: *const query.Filter,
    config: Config,
    select_fields: ?[]const []const u8,
    allocator: std.mem.Allocator,
) !std.ArrayList(u8) {
    const output_mod = @import("output.zig");

    // Read entire file into memory
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size == 0) {
        const empty = std.ArrayList(u8){};
        return empty;
    }

    // Memory-map the file for true zero-copy reading
    const data = try std.posix.mmap(
        null,
        file_size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(data);

    // Normalise to NDJSON (JSON arrays are converted; NDJSON passes through untouched)
    var ndjson_owned: ?[]u8 = null;
    defer if (ndjson_owned) |d| allocator.free(d);
    const ndjson: []const u8 = if (detectFormat(data) == .json_array) blk: {
        ndjson_owned = try jsonArrayToNdjson(data, allocator);
        break :blk ndjson_owned.?;
    } else data;

    // Use parallel processing
    const num_threads = @min(config.num_threads, std.Thread.getCpuCount() catch 4);

    // Split into chunks aligned on newline boundaries
    const chunks = try splitIntoChunks(ndjson, num_threads, allocator);
    defer allocator.free(chunks);

    // Context for worker threads that generate output
    const OutputWorkerContext = struct {
        data: []const u8,
        filter: *const query.Filter,
        select_fields: ?[]const []const u8,
        output_buffer: std.ArrayList(u8),
        allocator: std.mem.Allocator,
        lines_processed: usize = 0,
    };

    // Create results for each thread
    var contexts = try allocator.alloc(OutputWorkerContext, num_threads);
    defer {
        for (contexts) |*ctx| {
            ctx.output_buffer.deinit(allocator);
        }
        allocator.free(contexts);
    }

    for (0..num_threads) |i| {
        contexts[i] = .{
            .data = chunks[i],
            .filter = filter,
            .select_fields = select_fields,
            .output_buffer = .{},
            .allocator = allocator,
        };
    }

    // Worker function that processes AND generates output
    const workerFunc = struct {
        fn process(ctx: *OutputWorkerContext) void {
            const writer = ctx.output_buffer.writer(ctx.allocator);

            var line_iter = std.mem.splitScalar(u8, ctx.data, '\n');
            while (line_iter.next()) |line| {
                if (line.len == 0) continue;
                ctx.lines_processed += 1;

                // Parse JSON object
                var obj = json_parser.parseObject(line, ctx.allocator) catch continue;
                defer obj.deinit();

                // Evaluate filter
                if (!query.matches(&obj, ctx.filter)) {
                    continue;
                }

                // Generate output directly (zero-copy: obj fields are slices into mmap'd data)
                output_mod.writeNdjson(writer, &[_]json_parser.JsonObject{obj}, ctx.select_fields) catch continue;
            }
        }
    }.process;

    // Spawn worker threads
    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, workerFunc, .{&contexts[i]});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Concatenate all output buffers into one (still no locks!)
    // Calculate total size first to avoid reallocations
    var total_size: usize = 0;
    for (contexts) |*ctx| {
        total_size += ctx.output_buffer.items.len;
    }

    var final_output = try std.ArrayList(u8).initCapacity(allocator, total_size);
    for (contexts) |*ctx| {
        try final_output.appendSlice(allocator, ctx.output_buffer.items);
    }

    return final_output;
}

// ============================================================================
// Tests
// ============================================================================

test "parallel: process single line" {
    const allocator = std.testing.allocator;

    const data = "{\"name\": \"Alice\", \"age\": 30}\n";
    const query_str = "{\"age\": {\"$gt\": 25}}";

    var filter = try query.parseQuery(query_str, allocator);
    defer filter.deinit(allocator);

    var result = try processData(data, &filter.filter, .{ .num_threads = 1 }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.lines_processed);
    try std.testing.expectEqual(@as(usize, 1), result.matches.items.len);
}

test "parallel: process multiple lines" {
    const allocator = std.testing.allocator;

    const data =
        \\{"name": "Alice", "age": 30}
        \\{"name": "Bob", "age": 25}
        \\{"name": "Charlie", "age": 35}
        \\
    ;

    const query_str = "{\"age\": {\"$gte\": 30}}";

    var filter = try query.parseQuery(query_str, allocator);
    defer filter.deinit(allocator);

    var result = try processData(data, &filter.filter, .{ .num_threads = 1 }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.lines_processed);
    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}

test "parallel: multi-threaded processing" {
    const allocator = std.testing.allocator;

    // Create larger dataset for meaningful parallelization
    var data_list = std.ArrayList(u8){};
    defer data_list.deinit(allocator);

    const writer = data_list.writer(allocator);
    for (0..100) |i| {
        try writer.print("{{\"id\": {d}, \"value\": {d}}}\n", .{ i, i * 2 });
    }

    const query_str = "{\"value\": {\"$gte\": 100}}";

    var filter = try query.parseQuery(query_str, allocator);
    defer filter.deinit(allocator);

    var result = try processData(data_list.items, &filter.filter, .{ .num_threads = 4 }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 100), result.lines_processed);
    try std.testing.expectEqual(@as(usize, 50), result.matches.items.len);
}

test "parallel: chunk splitting" {
    const allocator = std.testing.allocator;

    const data =
        \\{"a": 1}
        \\{"b": 2}
        \\{"c": 3}
        \\{"d": 4}
        \\
    ;

    const chunks = try splitIntoChunks(data, 2, allocator);
    defer allocator.free(chunks);

    try std.testing.expectEqual(@as(usize, 2), chunks.len);

    // Each chunk should end with a newline or be the last chunk
    for (chunks[0 .. chunks.len - 1]) |chunk| {
        try std.testing.expect(chunk[chunk.len - 1] == '\n');
    }
}

test "jsonArrayToNdjson: basic conversion" {
    const allocator = std.testing.allocator;
    const input = "[{\"name\": \"Alice\", \"age\": 30},{\"name\": \"Bob\", \"age\": 25}]";
    const ndjson = try jsonArrayToNdjson(input, allocator);
    defer allocator.free(ndjson);

    // Should produce two lines
    var lines = std.mem.splitScalar(u8, ndjson, '\n');
    const line1 = lines.next() orelse "";
    const line2 = lines.next() orelse "";
    try std.testing.expect(std.mem.startsWith(u8, line1, "{"));
    try std.testing.expect(std.mem.startsWith(u8, line2, "{"));
}

test "processData: JSON array input" {
    const allocator = std.testing.allocator;

    const data = "[{\"name\": \"Alice\", \"age\": 30},{\"name\": \"Bob\", \"age\": 25},{\"name\": \"Charlie\", \"age\": 35}]";
    const query_str = "{\"age\": {\"$gte\": 30}}";

    var filter = try query.parseQuery(query_str, allocator);
    defer filter.deinit(allocator);

    var result = try processData(data, &filter.filter, .{ .num_threads = 1 }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.matches.items.len);
}
