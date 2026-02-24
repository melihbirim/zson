const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <output_file> <num_rows>\n", .{args[0]});
        std.debug.print("Example: {s} bench_data.ndjson 1000000\n", .{args[0]});
        std.process.exit(1);
    }

    const output_path = args[1];
    const num_rows = try std.fmt.parseInt(usize, args[2], 10);

    std.debug.print("Generating {d} rows to {s}...\n", .{ num_rows, output_path });

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var line_buffer: [1024]u8 = undefined;

    // Use a simple pseudo-random approach
    var seed: u64 = 42;

    const names = [_][]const u8{ "Alice", "Bob", "Charlie", "Diana", "Eve", "Frank", "Grace", "Henry", "Ivy", "Jack" };
    const cities = [_][]const u8{ "NYC", "LA", "Chicago", "Houston", "Phoenix", "Philadelphia", "San Antonio", "San Diego", "Dallas", "San Jose" };
    const departments = [_][]const u8{ "Engineering", "Sales", "Marketing", "HR", "Finance", "Operations", "Support", "Legal" };
    const statuses = [_][]const u8{ "active", "inactive", "pending", "suspended" };

    for (0..num_rows) |i| {
        // Simple LCG for pseudo-random numbers
        seed = seed *% 1103515245 +% 12345;
        const r1 = @as(u32, @truncate(seed >> 16));
        seed = seed *% 1103515245 +% 12345;
        const r2 = @as(u32, @truncate(seed >> 16));
        seed = seed *% 1103515245 +% 12345;
        const r3 = @as(u32, @truncate(seed >> 16));

        const age = 18 + (r1 % 53);
        const salary = 30000 + (r2 % 120000);
        const experience = r3 % 26;
        const active = (r1 % 2) == 0;

        const line = try std.fmt.bufPrint(
            &line_buffer,
            "{{\"id\":{d},\"name\":\"{s}\",\"age\":{d},\"city\":\"{s}\",\"department\":\"{s}\",\"salary\":{d},\"experience\":{d},\"status\":\"{s}\",\"active\":{s}}}\n",
            .{
                i + 1,
                names[r1 % names.len],
                age,
                cities[r2 % cities.len],
                departments[r3 % departments.len],
                salary,
                experience,
                statuses[(r1 >> 8) % statuses.len],
                if (active) "true" else "false",
            },
        );

        _ = try file.write(line);

        // Progress indicator
        if ((i + 1) % 100000 == 0) {
            std.debug.print("  Generated {d} rows...\n", .{i + 1});
        }
    }

    const file_size = try file.getEndPos();
    const mb = @as(f64, @floatFromInt(file_size)) / (1024.0 * 1024.0);
    std.debug.print("Done! Generated {d} rows ({d:.2} MB)\n", .{ num_rows, mb });
}
