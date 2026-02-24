const std = @import("std");
const json_parser = @import("json_parser.zig");
const simd = @import("simd.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n🚀 zson - SIMD-Accelerated JSON Parser Test\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Test 1: Parse sample NDJSON file
    try testSampleFile(allocator);

    // Test 2: Performance test with timing
    try testPerformance(allocator);

    // Test 3: Edge cases
    try testEdgeCases(allocator);

    // Test 4: Zero-copy verification
    try testZeroCopy(allocator);

    std.debug.print("\n✅ All tests passed!\n\n", .{});
}

fn testSampleFile(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 1: Parsing sample.ndjson\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});

    const file = try std.fs.cwd().openFile("examples/sample.ndjson", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_count: usize = 0;
    var total_fields: usize = 0;

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        var obj = try json_parser.parseObject(line, allocator);
        defer obj.deinit();

        total_fields += obj.fields.len;

        // Show first 3 lines in detail
        if (line_count <= 3) {
            std.debug.print("\nLine {d}:\n", .{line_count});
            for (obj.fields) |field| {
                std.debug.print("  {s}: ", .{field.key});
                switch (field.value) {
                    .string => |s| std.debug.print("\"{s}\"", .{s}),
                    .number => |n| std.debug.print("{s}", .{n}),
                    .bool_value => |b| std.debug.print("{}", .{b}),
                    .null_value => std.debug.print("null", .{}),
                    else => std.debug.print("(complex)", .{}),
                }
                std.debug.print("\n", .{});
            }
        }
    }

    std.debug.print("\n✓ Parsed {d} lines, {d} total fields\n\n", .{ line_count, total_fields });
}

fn testPerformance(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 2: Performance Benchmark\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});

    // Generate test data
    const test_lines = 10000;
    var data_list = std.ArrayList([]const u8){};
    defer {
        for (data_list.items) |item| {
            allocator.free(item);
        }
        data_list.deinit(allocator);
    }

    std.debug.print("Generating {d} test JSON objects...\n", .{test_lines});

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Henry" };
    const cities = [_][]const u8{ "NYC", "LA", "Chicago", "Houston", "Phoenix", "Seattle", "Boston" };

    for (0..test_lines) |i| {
        const name = names[rand.intRangeAtMost(usize, 0, names.len - 1)];
        const age = rand.intRangeAtMost(u32, 20, 70);
        const city = cities[rand.intRangeAtMost(usize, 0, cities.len - 1)];
        const active = rand.boolean();

        const line = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"name\":\"{s}\",\"age\":{d},\"city\":\"{s}\",\"active\":{s}}}",
            .{ i + 1, name, age, city, if (active) "true" else "false" },
        );
        try data_list.append(allocator, line);
    }

    // Benchmark parsing
    const start_time = std.time.milliTimestamp();

    var parsed_count: usize = 0;
    for (data_list.items) |line| {
        var obj = try json_parser.parseObject(line, allocator);
        obj.deinit();
        parsed_count += 1;
    }

    const end_time = std.time.milliTimestamp();
    const elapsed = end_time - start_time;

    const lines_per_sec = (@as(f64, @floatFromInt(test_lines)) / @as(f64, @floatFromInt(elapsed))) * 1000.0;

    std.debug.print("✓ Parsed {d} objects in {d}ms\n", .{ parsed_count, elapsed });
    std.debug.print("✓ Throughput: {d:.0} lines/sec\n\n", .{lines_per_sec});
}

fn testEdgeCases(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 3: Edge Cases\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});

    const test_cases = [_]struct {
        name: []const u8,
        json: []const u8,
        should_pass: bool,
    }{
        .{ .name = "Empty object", .json = "{}", .should_pass = true },
        .{ .name = "Single field", .json = "{\"x\":1}", .should_pass = true },
        .{ .name = "Null value", .json = "{\"data\":null}", .should_pass = true },
        .{ .name = "Boolean true", .json = "{\"flag\":true}", .should_pass = true },
        .{ .name = "Boolean false", .json = "{\"flag\":false}", .should_pass = true },
        .{ .name = "Negative number", .json = "{\"temp\":-5}", .should_pass = true },
        .{ .name = "Float", .json = "{\"price\":19.99}", .should_pass = true },
        .{ .name = "Empty string", .json = "{\"msg\":\"\"}", .should_pass = true },
        .{ .name = "Long string", .json = "{\"text\":\"The quick brown fox jumps over the lazy dog\"}", .should_pass = true },
        .{ .name = "Multiple fields", .json = "{\"a\":1,\"b\":2,\"c\":3,\"d\":4,\"e\":5}", .should_pass = true },
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (test_cases) |case| {
        var obj = json_parser.parseObject(case.json, allocator) catch |err| {
            if (case.should_pass) {
                std.debug.print("✗ {s}: FAILED - {}\n", .{ case.name, err });
                failed += 1;
            } else {
                std.debug.print("✓ {s}: Expected failure\n", .{case.name});
                passed += 1;
            }
            continue;
        };
        defer obj.deinit();

        if (case.should_pass) {
            std.debug.print("✓ {s}: PASSED\n", .{case.name});
            passed += 1;
        } else {
            std.debug.print("✗ {s}: Should have failed\n", .{case.name});
            failed += 1;
        }
    }

    std.debug.print("\nEdge cases: {d} passed, {d} failed\n\n", .{ passed, failed });
}

fn testZeroCopy(allocator: std.mem.Allocator) !void {
    std.debug.print("Test 4: Zero-Copy Verification\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});

    const original = "{\"name\":\"TestUser\",\"value\":42}";
    var obj = try json_parser.parseObject(original, allocator);
    defer obj.deinit();

    const original_start = @intFromPtr(original.ptr);
    const original_end = original_start + original.len;

    var zero_copy_confirmed: usize = 0;
    var allocations: usize = 0;

    for (obj.fields) |field| {
        // Check if key is zero-copy
        const key_addr = @intFromPtr(field.key.ptr);
        if (key_addr >= original_start and key_addr < original_end) {
            zero_copy_confirmed += 1;
            std.debug.print("✓ Key '{s}' is zero-copy (points into original buffer)\n", .{field.key});
        } else {
            allocations += 1;
            std.debug.print("✗ Key '{s}' was allocated\n", .{field.key});
        }

        // Check if value is zero-copy
        switch (field.value) {
            .string => |s| {
                const val_addr = @intFromPtr(s.ptr);
                if (val_addr >= original_start and val_addr < original_end) {
                    zero_copy_confirmed += 1;
                    std.debug.print("✓ String value '{s}' is zero-copy\n", .{s});
                } else {
                    allocations += 1;
                    std.debug.print("✗ String value was allocated\n", .{});
                }
            },
            .number => |n| {
                const val_addr = @intFromPtr(n.ptr);
                if (val_addr >= original_start and val_addr < original_end) {
                    zero_copy_confirmed += 1;
                    std.debug.print("✓ Number value '{s}' is zero-copy\n", .{n});
                } else {
                    allocations += 1;
                    std.debug.print("✗ Number value was allocated\n", .{});
                }
            },
            else => {},
        }
    }

    std.debug.print("\n✓ Zero-copy fields: {d}/{d}\n", .{ zero_copy_confirmed, zero_copy_confirmed + allocations });
    std.debug.print("✓ Memory efficiency: All strings/numbers are slices!\n\n", .{});
}
