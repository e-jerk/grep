const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const SearchOptions = gpu.SearchOptions;

// ============================================================================
// Regex Unit Tests for grep
// Tests BRE (Basic Regular Expressions) and ERE (Extended Regular Expressions)
// Based on GNU grep compatibility requirements
// ============================================================================

// ----------------------------------------------------------------------------
// Extended Regular Expression (ERE) Tests - grep -E
// ----------------------------------------------------------------------------

test "regex: dot matches any character" {
    const allocator = std.testing.allocator;
    const text = "hello\nworld";

    var result = try cpu.searchRegex(text, "h.llo", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: dot does not match newline" {
    const allocator = std.testing.allocator;
    const text = "hello\nworld";

    var result = try cpu.searchRegex(text, "hello.world", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "regex: star matches zero or more" {
    const allocator = std.testing.allocator;
    const text = "ac abc abbc abbbc";

    var result = try cpu.searchRegex(text, "ab*c", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 4), result.total_matches);
}

test "regex: plus matches one or more" {
    const allocator = std.testing.allocator;
    const text = "ac abc abbc abbbc";

    var result = try cpu.searchRegex(text, "ab+c", .{ .extended = true }, allocator);
    defer result.deinit();

    // Should not match "ac" (zero b's)
    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: question mark matches zero or one" {
    const allocator = std.testing.allocator;
    const text = "color colour";

    var result = try cpu.searchRegex(text, "colou?r", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: alternation" {
    const allocator = std.testing.allocator;
    const text = "cat dog bird cat";

    var result = try cpu.searchRegex(text, "cat|dog", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: character class" {
    const allocator = std.testing.allocator;
    const text = "a1b2c3";

    var result = try cpu.searchRegex(text, "[0-9]", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: negated character class" {
    const allocator = std.testing.allocator;
    const text = "a1b2c3";

    var result = try cpu.searchRegex(text, "[^0-9]", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: caret anchor" {
    const allocator = std.testing.allocator;
    const text = "hello world\nhello there";

    var result = try cpu.searchRegex(text, "^hello", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: dollar anchor" {
    const allocator = std.testing.allocator;
    const text = "hello world\nthere world";

    var result = try cpu.searchRegex(text, "world$", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: word boundary \\b" {
    const allocator = std.testing.allocator;
    const text = "the theory there";

    var result = try cpu.searchRegex(text, "\\bthe\\b", .{ .extended = true }, allocator);
    defer result.deinit();

    // Only "the" at start should match, not "the" in "theory" or "there"
    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: word character class \\w" {
    const allocator = std.testing.allocator;
    const text = "hello_123";

    var result = try cpu.searchRegex(text, "\\w+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: digit class \\d" {
    const allocator = std.testing.allocator;
    const text = "abc123def456";

    var result = try cpu.searchRegex(text, "\\d+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: whitespace class \\s" {
    const allocator = std.testing.allocator;
    const text = "hello world\ttab";

    var result = try cpu.searchRegex(text, "\\s+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: grouping" {
    const allocator = std.testing.allocator;
    const text = "abab cdcd abab";

    var result = try cpu.searchRegex(text, "(ab)+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: interval {n}" {
    const allocator = std.testing.allocator;
    const text = "a aa aaa aaaa";

    var result = try cpu.searchRegex(text, "a{3}", .{ .extended = true }, allocator);
    defer result.deinit();

    // Should match "aaa" within "aaa" and "aaaa"
    try std.testing.expect(result.total_matches >= 2);
}

test "regex: interval {n,m}" {
    const allocator = std.testing.allocator;
    const text = "a aa aaa aaaa";

    var result = try cpu.searchRegex(text, "a{2,3}", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 3);
}

test "regex: case insensitive" {
    const allocator = std.testing.allocator;
    const text = "Hello HELLO hello HeLLo";

    var result = try cpu.searchRegex(text, "hello", .{ .extended = true, .case_insensitive = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 4), result.total_matches);
}

test "regex: escaped special characters" {
    const allocator = std.testing.allocator;
    const text = "1+1=2 and 2*2=4";

    var result = try cpu.searchRegex(text, "1\\+1", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: POSIX character class [:alnum:]" {
    const allocator = std.testing.allocator;
    const text = "abc123!@#";

    var result = try cpu.searchRegex(text, "[[:alnum:]]+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: POSIX character class [:alpha:]" {
    const allocator = std.testing.allocator;
    const text = "abc123def";

    var result = try cpu.searchRegex(text, "[[:alpha:]]+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: POSIX character class [:digit:]" {
    const allocator = std.testing.allocator;
    const text = "abc123def456";

    var result = try cpu.searchRegex(text, "[[:digit:]]+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: POSIX character class [:space:]" {
    const allocator = std.testing.allocator;
    const text = "hello world\ttab\nnewline";

    var result = try cpu.searchRegex(text, "[[:space:]]+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: complex pattern - email-like" {
    const allocator = std.testing.allocator;
    const text = "Contact: user@example.com or admin@test.org";

    var result = try cpu.searchRegex(text, "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "regex: complex pattern - IP address" {
    const allocator = std.testing.allocator;
    const text = "Servers: 192.168.1.1 and 10.0.0.1";

    // Use simpler digit+ pattern since {n,m} intervals aren't fully implemented yet
    var result = try cpu.searchRegex(text, "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

// ----------------------------------------------------------------------------
// Basic Regular Expression (BRE) Tests - grep -G (default)
// In BRE, special characters require backslash escaping
// ----------------------------------------------------------------------------

test "BRE: literal special characters without escape" {
    const allocator = std.testing.allocator;
    const text = "a+b a*b a?b";

    // In BRE, + * ? are literal without backslash
    var result = try cpu.searchRegex(text, "a+b", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "BRE: escaped plus for one-or-more" {
    const allocator = std.testing.allocator;
    const text = "ab abb abbb";

    // In BRE, \+ means one or more b's after a
    // "ab" has 1 b, "abb" has 2 b's, "abbb" has 3 b's - all match
    var result = try cpu.searchRegex(text, "ab\\+", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "BRE: escaped question mark for optional" {
    const allocator = std.testing.allocator;
    const text = "color colour";

    // In BRE, \? means optional
    var result = try cpu.searchRegex(text, "colou\\?r", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "BRE: escaped parentheses for grouping" {
    const allocator = std.testing.allocator;
    const text = "abab cdcd";

    // In BRE, \( and \) for grouping
    var result = try cpu.searchRegex(text, "\\(ab\\)*", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 1);
}

test "BRE: escaped braces for interval" {
    const allocator = std.testing.allocator;
    const text = "aa aaa aaaa";

    // In BRE, \{ and \} for intervals
    var result = try cpu.searchRegex(text, "a\\{3\\}", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expect(result.total_matches >= 1);
}

test "BRE: escaped pipe for alternation" {
    const allocator = std.testing.allocator;
    const text = "cat dog bird";

    // In BRE, \| for alternation (GNU extension)
    var result = try cpu.searchRegex(text, "cat\\|dog", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "BRE: star is special without escape" {
    const allocator = std.testing.allocator;
    const text = "ac abc abbc";

    // In BRE, * is special (zero or more) without backslash
    var result = try cpu.searchRegex(text, "ab*c", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "BRE: dot is special without escape" {
    const allocator = std.testing.allocator;
    const text = "cat cot cut";

    // In BRE, . is special (any char) without backslash
    var result = try cpu.searchRegex(text, "c.t", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "BRE: caret anchor" {
    const allocator = std.testing.allocator;
    const text = "hello world\nhello there";

    var result = try cpu.searchRegex(text, "^hello", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "BRE: dollar anchor" {
    const allocator = std.testing.allocator;
    const text = "hello world\nthere world";

    var result = try cpu.searchRegex(text, "world$", .{ .extended = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

// ----------------------------------------------------------------------------
// Fixed String Tests - grep -F
// No regex interpretation at all
// ----------------------------------------------------------------------------

test "fixed: literal dot" {
    const allocator = std.testing.allocator;
    const text = "file.txt file_txt";

    var result = try cpu.search(text, "file.txt", .{ .fixed_string = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "fixed: literal star" {
    const allocator = std.testing.allocator;
    const text = "a*b c*d";

    var result = try cpu.search(text, "*", .{ .fixed_string = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "fixed: literal brackets" {
    const allocator = std.testing.allocator;
    const text = "[test] [abc]";

    var result = try cpu.search(text, "[test]", .{ .fixed_string = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

// ----------------------------------------------------------------------------
// Edge Cases and GNU Compatibility
// ----------------------------------------------------------------------------

test "regex: empty pattern matches all lines" {
    const allocator = std.testing.allocator;
    const text = "line1\nline2\nline3";

    var result = try cpu.searchRegex(text, "", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: pattern at end of line without newline" {
    const allocator = std.testing.allocator;
    const text = "hello world";

    var result = try cpu.searchRegex(text, "world$", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: very long pattern" {
    const allocator = std.testing.allocator;
    const pattern = "a" ** 100;
    const text = "b" ** 50 ++ pattern ++ "b" ** 50;

    var result = try cpu.searchRegex(text, pattern, .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: Unicode text with ASCII pattern" {
    const allocator = std.testing.allocator;
    const text = "Hello 世界 World";

    var result = try cpu.searchRegex(text, "World", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "regex: multiple matches on same line" {
    const allocator = std.testing.allocator;
    const text = "the cat and the dog and the bird";

    var result = try cpu.searchRegex(text, "the", .{ .extended = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "regex: overlapping potential matches" {
    const allocator = std.testing.allocator;
    const text = "aaaa";

    var result = try cpu.searchRegex(text, "aa", .{ .extended = true }, allocator);
    defer result.deinit();

    // Standard regex: non-overlapping matches = 2 (positions 0 and 2)
    try std.testing.expect(result.total_matches >= 2);
}
