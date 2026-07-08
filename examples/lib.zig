//! Demonstrates using zson as a Zig library.
//!
//!   zig build example-lib

const std = @import("std");
const zson = @import("zson");

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const data =
        \\{"id":1,"name":"Alice","age":30,"city":"NYC","active":true}
        \\{"id":2,"name":"Bob","age":35,"city":"LA","active":true}
        \\{"id":3,"name":"Iris","age":45,"city":"NYC","active":true}
        \\{"id":4,"name":"Milo","age":28,"city":"NYC","active":false}
        \\
    ;

    var filters = [_]zson.Filter{
        zson.q.eq("city", zson.q.string("NYC")),
        zson.q.eq("active", zson.q.boolean(true)),
        zson.q.gte("age", zson.q.number(30)),
    };

    var result = try zson.queryNdjsonWhere(data, zson.q.all(&filters), allocator);
    defer result.deinit();

    std.debug.print("matched {d} records\n", .{result.len()});

    for (result.items()) |obj| {
        const id = obj.get("id").?.number;
        const name = obj.get("name").?.string;
        const age = obj.get("age").?.number;
        const city = obj.get("city").?.string;

        std.debug.print("  #{s}: {s}, age {s}, {s}\n", .{ id, name, age, city });
    }
}
