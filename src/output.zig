const std = @import("std");
const json_parser = @import("json_parser.zig");
const cli = @import("cli.zig");

/// Write results in NDJSON format (one JSON object per line)
pub fn writeNdjson(
    writer: anytype,
    objects: []const json_parser.JsonObject,
    select_fields: ?[]const []const u8,
) !void {
    for (objects) |obj| {
        try writeJsonObject(writer, &obj, select_fields, false);
        try writer.writeByte('\n');
    }
}

/// Write results as a JSON array
pub fn writeJson(
    writer: anytype,
    objects: []const json_parser.JsonObject,
    select_fields: ?[]const []const u8,
    pretty: bool,
) !void {
    try writer.writeByte('[');

    if (pretty and objects.len > 0) {
        try writer.writeByte('\n');
    }

    for (objects, 0..) |obj, i| {
        if (pretty) {
            try writer.writeAll("  ");
        }

        try writeJsonObject(writer, &obj, select_fields, pretty);

        if (i < objects.len - 1) {
            try writer.writeByte(',');
        }

        if (pretty) {
            try writer.writeByte('\n');
        }
    }

    try writer.writeByte(']');

    if (pretty) {
        try writer.writeByte('\n');
    }
}

/// Write results in CSV format
pub fn writeCsv(
    writer: anytype,
    objects: []const json_parser.JsonObject,
    select_fields: ?[]const []const u8,
) !void {
    if (objects.len == 0) return;

    // Write header
    if (select_fields) |sf| {
        for (sf, 0..) |field, i| {
            if (i > 0) try writer.writeByte(',');
            try writeCsvField(writer, field);
        }
    } else {
        // Use fields from first object
        const first_obj_fields = objects[0].fields;
        for (first_obj_fields, 0..) |field, i| {
            if (i > 0) try writer.writeByte(',');
            try writeCsvField(writer, field.key);
        }
    }
    try writer.writeByte('\n');

    // Write data rows
    for (objects) |obj| {
        if (select_fields) |sf| {
            for (sf, 0..) |field_name, i| {
                if (i > 0) try writer.writeByte(',');
                if (obj.get(field_name)) |value| {
                    try writeCsvValue(writer, value);
                }
            }
        } else {
            const obj_fields = obj.fields;
            for (obj_fields, 0..) |field, i| {
                if (i > 0) try writer.writeByte(',');
                try writeCsvValue(writer, field.value);
            }
        }
        try writer.writeByte('\n');
    }
}

/// Write a single JSON object
fn writeJsonObject(
    writer: anytype,
    obj: *const json_parser.JsonObject,
    select_fields: ?[]const []const u8,
    pretty: bool,
) anyerror!void {
    try writer.writeByte('{');

    var first = true;

    if (select_fields) |fields| {
        // Only output selected fields
        for (fields) |field_name| {
            if (obj.get(field_name)) |value| {
                if (!first) {
                    try writer.writeByte(',');
                    if (pretty) try writer.writeByte(' ');
                }
                first = false;

                try writer.writeByte('"');
                try writer.writeAll(field_name);
                try writer.writeAll("\":");
                if (pretty) try writer.writeByte(' ');
                try writeJsonValue(writer, value);
            }
        }
    } else {
        // Output all fields
        for (obj.fields) |field| {
            if (!first) {
                try writer.writeByte(',');
                if (pretty) try writer.writeByte(' ');
            }
            first = false;

            try writer.writeByte('"');
            try writer.writeAll(field.key);
            try writer.writeAll("\":");
            if (pretty) try writer.writeByte(' ');
            try writeJsonValue(writer, field.value);
        }
    }

    try writer.writeByte('}');
}

/// Write a JSON value
fn writeJsonValue(writer: anytype, value: json_parser.JsonValue) anyerror!void {
    switch (value) {
        .null_value => try writer.writeAll("null"),
        .bool_value => |b| try writer.writeAll(if (b) "true" else "false"),
        .number => |slice| try writer.writeAll(slice),
        .string => |s| {
            try writer.writeByte('"');
            // TODO: Proper JSON string escaping
            try writer.writeAll(s);
            try writer.writeByte('"');
        },
        .object => |obj| {
            try writeJsonObject(writer, &obj, null, false);
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr, 0..) |elem, i| {
                if (i > 0) try writer.writeByte(',');
                try writeJsonValue(writer, elem);
            }
            try writer.writeByte(']');
        },
    }
}

/// Write a CSV field (header)
fn writeCsvField(writer: anytype, field: []const u8) !void {
    // Quote if contains comma, quote, or newline
    const needs_quote = std.mem.indexOfAny(u8, field, ",\"\n") != null;

    if (needs_quote) {
        try writer.writeByte('"');
        for (field) |c| {
            if (c == '"') {
                try writer.writeAll("\"\""); // Escape quotes
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(field);
    }
}

/// Write a CSV value
fn writeCsvValue(writer: anytype, value: json_parser.JsonValue) !void {
    switch (value) {
        .null_value => {},
        .bool_value => |b| try writer.writeAll(if (b) "true" else "false"),
        .number => |slice| try writer.writeAll(slice),
        .string => |s| try writeCsvField(writer, s),
        .object => try writer.writeAll("{}"),
        .array => try writer.writeAll("[]"),
    }
}

// Tests
test "output: write ndjson" {
    const allocator = std.testing.allocator;

    var fields = [_]json_parser.JsonObject.Field{
        .{
            .key = "name",
            .value = .{ .string = "Alice" },
        },
        .{
            .key = "age",
            .value = .{ .number = "30" },
        },
    };

    const obj1 = json_parser.JsonObject{
        .fields = &fields,
        .allocator = allocator,
    };

    const objects = [_]json_parser.JsonObject{obj1};

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try writeNdjson(buffer.writer(allocator), &objects, null);

    const expected = "{\"name\":\"Alice\",\"age\":30}\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "output: write json array" {
    const allocator = std.testing.allocator;

    var fields = [_]json_parser.JsonObject.Field{
        .{
            .key = "name",
            .value = .{ .string = "Alice" },
        },
    };

    const obj1 = json_parser.JsonObject{
        .fields = &fields,
        .allocator = allocator,
    };

    const objects = [_]json_parser.JsonObject{obj1};

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try writeJson(buffer.writer(allocator), &objects, null, false);

    try std.testing.expect(std.mem.startsWith(u8, buffer.items, "["));
    try std.testing.expect(std.mem.endsWith(u8, buffer.items, "]"));
}

test "output: write csv" {
    const allocator = std.testing.allocator;

    var fields = [_]json_parser.JsonObject.Field{
        .{
            .key = "name",
            .value = .{ .string = "Alice" },
        },
        .{
            .key = "age",
            .value = .{ .number = "30" },
        },
    };

    const obj1 = json_parser.JsonObject{
        .fields = &fields,
        .allocator = allocator,
    };

    const objects = [_]json_parser.JsonObject{obj1};

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try writeCsv(buffer.writer(allocator), &objects, null);

    // Should have header + data row
    var lines = std.mem.splitScalar(u8, buffer.items, '\n');
    const header = lines.next() orelse "";
    const row = lines.next() orelse "";

    try std.testing.expect(header.len > 0);
    try std.testing.expect(row.len > 0);
}

test "output: field projection" {
    const allocator = std.testing.allocator;

    var fields = [_]json_parser.JsonObject.Field{
        .{
            .key = "name",
            .value = .{ .string = "Alice" },
        },
        .{
            .key = "age",
            .value = .{ .number = "30" },
        },
        .{
            .key = "city",
            .value = .{ .string = "NYC" },
        },
    };

    const obj1 = json_parser.JsonObject{
        .fields = &fields,
        .allocator = allocator,
    };

    const objects = [_]json_parser.JsonObject{obj1};
    const select_fields = [_][]const u8{ "name", "city" };

    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try writeNdjson(buffer.writer(allocator), &objects, &select_fields);

    // Should only contain name and city, not age
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "name") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "city") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "age") == null);
}
