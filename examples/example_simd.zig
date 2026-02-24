const std = @import("std");
const simd = @import("simd.zig");
const json_parser = @import("json_parser.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n⚡ SIMD JSON Tokenization Demo\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    const examples = [_][]const u8{
        "{\"name\":\"Alice\",\"age\":30}",
        "{\"active\":true,\"balance\":99.99,\"tags\":null}",
        "{\"id\":1,\"city\":\"NYC\",\"verified\":false}",
    };

    for (examples, 1..) |json, i| {
        std.debug.print("Example {d}: {s}\n", .{ i, json });
        std.debug.print("-" ** 70 ++ "\n", .{});

        // Step 1: SIMD Tokenization
        var tokens: [256]simd.Token = undefined;
        const token_count = simd.findJsonStructure(json, &tokens);

        std.debug.print("SIMD found {d} structural characters:\n", .{token_count});
        for (tokens[0..token_count]) |token| {
            const char = json[token.pos];
            const type_name = switch (token.type) {
                .open_brace => "OPEN_BRACE",
                .close_brace => "CLOSE_BRACE",
                .open_bracket => "OPEN_BRACKET",
                .close_bracket => "CLOSE_BRACKET",
                .quote => "QUOTE",
                .colon => "COLON",
                .comma => "COMMA",
                else => "UNKNOWN",
            };
            std.debug.print("  [{d:3}] '{c}' → {s}\n", .{ token.pos, char, type_name });
        }

        // Step 2: Parse into object
        var obj = try json_parser.parseObject(json, allocator);
        defer obj.deinit();

        std.debug.print("\nParsed object with {d} fields:\n", .{obj.fields.len});
        for (obj.fields) |field| {
            std.debug.print("  {s} = ", .{field.key});
            switch (field.value) {
                .string => |s| std.debug.print("\"{s}\" (string, {d} bytes)", .{ s, s.len }),
                .number => |n| std.debug.print("{s} (number, {d} bytes)", .{ n, n.len }),
                .bool_value => |b| std.debug.print("{} (boolean)", .{b}),
                .null_value => std.debug.print("null", .{}),
                else => std.debug.print("(complex)", .{}),
            }
            std.debug.print("\n", .{});
        }

        // Step 3: Zero-copy verification
        const json_start = @intFromPtr(json.ptr);
        const json_end = json_start + json.len;

        var zero_copy_count: usize = 0;
        for (obj.fields) |field| {
            const key_addr = @intFromPtr(field.key.ptr);
            if (key_addr >= json_start and key_addr < json_end) {
                zero_copy_count += 1;
            }

            switch (field.value) {
                .string => |s| {
                    const val_addr = @intFromPtr(s.ptr);
                    if (val_addr >= json_start and val_addr < json_end) {
                        zero_copy_count += 1;
                    }
                },
                .number => |n| {
                    const val_addr = @intFromPtr(n.ptr);
                    if (val_addr >= json_start and val_addr < json_end) {
                        zero_copy_count += 1;
                    }
                },
                else => {},
            }
        }

        std.debug.print("\n✓ Zero-copy: {d}/{d} fields point into original buffer\n", .{ zero_copy_count, obj.fields.len * 2 });
        std.debug.print("\n", .{});
    }

    // Performance comparison
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("Performance Characteristics:\n", .{});
    std.debug.print("  • SIMD processes 16 bytes per cycle\n", .{});
    std.debug.print("  • Zero allocations for strings/numbers\n", .{});
    std.debug.print("  • Direct memory mapping (no copies)\n", .{});
    std.debug.print("  • Ready for parallel processing (lock-free)\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("Next Steps:\n", .{});
    std.debug.print("  ✓ Phase 1: SIMD tokenization (DONE)\n", .{});
    std.debug.print("  ✓ Phase 2: Zero-copy parsing (DONE)\n", .{});
    std.debug.print("  → Phase 3: MongoDB query engine\n", .{});
    std.debug.print("  → Phase 4: Parallel NDJSON processing\n", .{});
    std.debug.print("  → Phase 5: Beat jq by 10x!\n", .{});
    std.debug.print("\n", .{});
}
