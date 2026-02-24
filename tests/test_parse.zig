const std = @import("std");
const json_parser = @import("json_parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Read sample.ndjson and parse each line
    const file = try std.fs.cwd().openFile("examples/sample.ndjson", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    std.debug.print("Parsing NDJSON file...\n\n", .{});

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        line_num += 1;

        var obj = json_parser.parseObject(line, allocator) catch |err| {
            std.debug.print("Line {d}: Error parsing - {}\n", .{ line_num, err });
            continue;
        };
        defer obj.deinit();

        std.debug.print("Line {d}: Parsed {d} fields\n", .{ line_num, obj.fields.len });

        // Print all fields
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
        std.debug.print("\n", .{});
    }

    std.debug.print("✅ Successfully parsed {d} NDJSON lines!\n", .{line_num});
}
