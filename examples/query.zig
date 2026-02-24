//! Demonstrates running MongoDB-style queries against NDJSON data.
//!
//!   zig build example-query

const std = @import("std");
const zson = @import("zson");
const json_parser = zson.json_parser;
const query = zson.query;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Load sample data
    const file = try std.fs.cwd().openFile("examples/sample.ndjson", .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Parse all objects
    var objects = std.ArrayList(json_parser.JsonObject).empty;
    defer {
        for (objects.items) |*obj| obj.deinit();
        objects.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try objects.append(allocator, try json_parser.parseObject(line, allocator));
    }

    std.debug.print("Loaded {d} records from examples/sample.ndjson\n\n", .{objects.items.len});

    // Queries to demonstrate
    const cases = [_]struct { desc: []const u8, q: []const u8 }{
        .{ .desc = "age > 30", .q = "{\"age\":{\"$gt\":30}}" },
        .{ .desc = "active users in NYC", .q = "{\"city\":\"NYC\",\"active\":true}" },
        .{ .desc = "salary >= 90000", .q = "{\"salary\":{\"$gte\":90000}}" },
        .{ .desc = "age between 28 and 35", .q = "{\"age\":{\"$gte\":28,\"$lte\":35}}" },
        .{ .desc = "not in Chicago", .q = "{\"city\":{\"$ne\":\"Chicago\"}}" },
    };

    for (cases) |c| {
        var q = try query.parseQuery(c.q, allocator);
        defer q.deinit(allocator);

        var count: usize = 0;
        for (objects.items) |*obj| {
            if (query.matches(obj, &q.filter)) count += 1;
        }
        std.debug.print("  [{s}]  {d} match(es)\n", .{ c.desc, count });
    }
}
