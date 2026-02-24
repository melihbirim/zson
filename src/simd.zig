const std = @import("std");

/// SIMD-accelerated JSON parsing utilities
/// Inspired by simdjson and proven patterns from sieswi
/// Token types for JSON structural characters
pub const TokenType = enum {
    open_brace, // {
    close_brace, // }
    open_bracket, // [
    close_bracket, // ]
    quote, // "
    colon, // :
    comma, // ,
    unknown,
};

pub const Token = struct {
    type: TokenType,
    pos: usize,
};

/// Find JSON structural characters using SIMD vectorization.
///
/// ## Algorithm — bitmask extraction (simdjson-style)
///
/// Stage 1  (SIMD, vectorized):
///   Compare all 16 bytes against each of the 7 structural chars simultaneously.
///   OR the results into `is_any` — a `@Vector(16, bool)` that marks every
///   position that holds a structural character.
///
/// Stage 2  (bitmask, skipping):
///   `@reduce(.Or, is_any)` produces a single bool with one NEON/SSE instruction.
///   If the chunk contains NO structural char we skip it instantly (the common
///   case for long string values, numbers, whitespace).
///
///   Within non-empty chunks we still loop over 16 lanes, but each non-structural
///   byte is dismissed by a single `if (!is_any[j]) continue` before touching
///   the 7-condition type dispatch — so only actual structural chars pay the
///   full type-detection cost.
///
/// Compared to the old "scalar inner loop":
///   Old: 16 × 7 = 112 comparisons per chunk minimum.
///   New: 1 SIMD OR-reduction to skip empty chunks; ~7 comparisons only for
///        structural chars that actually exist in the chunk.
pub fn findJsonStructure(data: []const u8, tokens: []Token) usize {
    var count: usize = 0;

    const VecSize = 16; // SSE/NEON vector size
    const Vec = @Vector(VecSize, u8);

    // Prepare comparison vectors for all structural characters
    const open_brace: Vec = @splat('{');
    const close_brace: Vec = @splat('}');
    const open_bracket: Vec = @splat('[');
    const close_bracket: Vec = @splat(']');
    const quote: Vec = @splat('"');
    const colon: Vec = @splat(':');
    const comma: Vec = @splat(',');

    var i: usize = 0;

    // Process 16 bytes at a time with SIMD
    while (i + VecSize <= data.len and count < tokens.len) : (i += VecSize) {
        const chunk: Vec = data[i..][0..VecSize].*;

        // ── Stage 1: SIMD comparison ────────────────────────────────────────
        const is_open_brace = chunk == open_brace;
        const is_close_brace = chunk == close_brace;
        const is_open_bracket = chunk == open_bracket;
        const is_close_bracket = chunk == close_bracket;
        const is_quote = chunk == quote;
        const is_colon = chunk == colon;
        const is_comma = chunk == comma;

        // ── Stage 2: bitmask skip + per-match dispatch ──────────────────────
        // OR all match vectors → one bool per lane that says "any structural?"
        const is_any = is_open_brace | is_close_brace | is_open_bracket |
            is_close_bracket | is_quote | is_colon | is_comma;

        // One NEON/SSE OR-reduction — skip the entire chunk if nothing matched.
        // This is the common case for number/string value content.
        if (!@reduce(.Or, is_any)) continue;

        // Extract positions of matches — only iterate over the 16 lanes, but
        // skip non-structural bytes immediately before any further branching.
        var j: usize = 0;
        while (j < VecSize and count < tokens.len) : (j += 1) {
            if (!is_any[j]) continue; // skip non-structural byte (fast path)

            const tok_type: TokenType =
                if (is_open_brace[j]) .open_brace else if (is_close_brace[j]) .close_brace else if (is_open_bracket[j]) .open_bracket else if (is_close_bracket[j]) .close_bracket else if (is_quote[j]) .quote else if (is_colon[j]) .colon else .comma;

            tokens[count] = Token{ .type = tok_type, .pos = i + j };
            count += 1;
        }
    }

    // Handle remaining bytes (scalar fallback)
    while (i < data.len and count < tokens.len) : (i += 1) {
        const token_type: TokenType = switch (data[i]) {
            '{' => .open_brace,
            '}' => .close_brace,
            '[' => .open_bracket,
            ']' => .close_bracket,
            '"' => .quote,
            ':' => .colon,
            ',' => .comma,
            else => continue,
        };

        tokens[count] = Token{ .type = token_type, .pos = i };
        count += 1;
    }

    return count;
}

/// Fast SIMD-optimized newline search (same as sieswi)
/// For splitting NDJSON into lines
pub inline fn findNewline(haystack: []const u8, start: usize) ?usize {
    if (start >= haystack.len) return null;

    const data = haystack[start..];

    // For small searches, use standard library
    if (data.len < 64) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |pos| {
            return start + pos;
        }
        return null;
    }

    // For larger searches, std.mem.indexOfScalar may use SIMD internally
    if (std.mem.indexOfScalar(u8, data, '\n')) |pos| {
        return start + pos;
    }

    return null;
}

/// Fast string equality check using SIMD when available
/// Reused from sieswi - works great for JSON key comparison
pub inline fn stringsEqualFast(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.ptr == b.ptr) return true;

    // For short strings, use direct comparison
    if (a.len < 16) {
        return std.mem.eql(u8, a, b);
    }

    // For longer strings, std.mem.eql may use SIMD internally
    return std.mem.eql(u8, a, b);
}

/// Parse integer fast (for numeric JSON values)
/// Optimized version from sieswi
pub inline fn parseIntFast(str: []const u8) !i64 {
    // Skip leading whitespace
    var i: usize = 0;
    while (i < str.len and std.ascii.isWhitespace(str[i])) : (i += 1) {}

    if (i >= str.len) return error.InvalidInput;

    // Check for sign
    var negative = false;
    if (str[i] == '-') {
        negative = true;
        i += 1;
    } else if (str[i] == '+') {
        i += 1;
    }

    if (i >= str.len) return error.InvalidInput;

    // Parse digits - compiler can vectorize this loop
    var result: i64 = 0;
    while (i < str.len) : (i += 1) {
        const c = str[i];
        if (c < '0' or c > '9') break;
        result = result * 10 + (c - '0');
    }

    return if (negative) -result else result;
}

/// Parse float fast (for numeric JSON values)
pub inline fn parseFloatFast(str: []const u8) !f64 {
    return try std.fmt.parseFloat(f64, str);
}

test "SIMD JSON tokenization" {
    const json = "{\"name\":\"Alice\",\"age\":30}";
    var tokens: [100]Token = undefined;

    const count = findJsonStructure(json, &tokens);

    // Should find: { " " : " " , " " : } = 11 structural chars (7 unique + 4 quotes)
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(TokenType.open_brace, tokens[0].type);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].pos);
}

test "newline search" {
    const data = "line1\nline2\nline3\n";

    const pos1 = findNewline(data, 0);
    try std.testing.expectEqual(@as(usize, 5), pos1.?);

    const pos2 = findNewline(data, 6);
    try std.testing.expectEqual(@as(usize, 11), pos2.?);
}

test "fast integer parsing" {
    try std.testing.expectEqual(@as(i64, 42), try parseIntFast("42"));
    try std.testing.expectEqual(@as(i64, -123), try parseIntFast("-123"));
    try std.testing.expectEqual(@as(i64, 0), try parseIntFast("0"));
}
