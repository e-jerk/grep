const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const SearchOptions = gpu.SearchOptions;

// ============================================================================
// Unit Tests for grep
// Tests basic functionality with small inputs to verify correctness
// ============================================================================

// ----------------------------------------------------------------------------
// CPU Tests
// ----------------------------------------------------------------------------

test "cpu: simple pattern match" {
    const allocator = std.testing.allocator;
    const text = "hello world hello";
    const pattern = "hello";

    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
    try std.testing.expectEqual(@as(u32, 0), result.matches[0].position);
    try std.testing.expectEqual(@as(u32, 12), result.matches[1].position);
}

test "cpu: case insensitive match" {
    const allocator = std.testing.allocator;
    const text = "Hello HELLO hello HeLLo";
    const pattern = "hello";

    var result = try cpu.search(text, pattern, .{ .case_insensitive = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 4), result.total_matches);
}

test "cpu: no matches" {
    const allocator = std.testing.allocator;
    const text = "hello world";
    const pattern = "xyz";

    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: empty pattern" {
    const allocator = std.testing.allocator;
    const text = "hello\nworld";
    const pattern = "";

    // Empty pattern matches all lines (GNU grep behavior)
    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: pattern longer than text" {
    const allocator = std.testing.allocator;
    const text = "hi";
    const pattern = "hello";

    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: single character pattern" {
    const allocator = std.testing.allocator;
    const text = "aaa";
    const pattern = "a";

    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: multiline text" {
    const allocator = std.testing.allocator;
    const text = "line1 the\nline2 the\nline3 the";
    const pattern = "the";

    var result = try cpu.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: word boundary" {
    const allocator = std.testing.allocator;
    const text = "the theory there";
    const pattern = "the";

    var result = try cpu.search(text, pattern, .{ .word_boundary = true }, allocator);
    defer result.deinit();

    // Only "the" at position 0 should match (not theory or there)
    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "cpu: invert match" {
    const allocator = std.testing.allocator;
    const text = "line with pattern\nline without\nanother with pattern";
    const pattern = "pattern";

    var result = try cpu.search(text, pattern, .{ .invert_match = true }, allocator);
    defer result.deinit();

    // Only the line without "pattern" should match
    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

// ----------------------------------------------------------------------------
// Metal GPU Tests (macOS only)
// ----------------------------------------------------------------------------

test "metal: shader compilation" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // This tests that the shader compiles without errors
    const searcher = gpu.metal.MetalSearcher.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // If we get here, shader compiled successfully
}

test "metal: simple pattern match" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalSearcher.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const text = "hello world hello";
    const pattern = "hello";

    var result = try searcher.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "metal: matches cpu results" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalSearcher.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // Test various patterns
    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
        options: SearchOptions,
    }{
        .{ .text = "the cat sat on the mat", .pattern = "the", .options = .{} },
        .{ .text = "Hello HELLO hello", .pattern = "hello", .options = .{ .case_insensitive = true } },
        .{ .text = "abcabc", .pattern = "abc", .options = .{} },
        .{ .text = "line1\nline2\nline3", .pattern = "line", .options = .{} },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.search(tc.text, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var metal_result = try searcher.search(tc.text, tc.pattern, tc.options, allocator);
        defer metal_result.deinit();

        if (cpu_result.total_matches != metal_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}' in '{s}':\n", .{ tc.pattern, tc.text });
            std.debug.print("  CPU: {d}, Metal: {d}\n", .{ cpu_result.total_matches, metal_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}

// ----------------------------------------------------------------------------
// Vulkan GPU Tests
// ----------------------------------------------------------------------------

test "vulkan: shader compilation" {
    const allocator = std.testing.allocator;

    // This tests that the SPIR-V shader loads without errors
    const searcher = gpu.vulkan.VulkanSearcher.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // If we get here, shader loaded successfully
}

test "vulkan: simple pattern match" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanSearcher.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const text = "hello world hello";
    const pattern = "hello";

    var result = try searcher.search(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "vulkan: matches cpu results" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanSearcher.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // Test various patterns
    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
        options: SearchOptions,
    }{
        .{ .text = "the cat sat on the mat", .pattern = "the", .options = .{} },
        .{ .text = "Hello HELLO hello", .pattern = "hello", .options = .{ .case_insensitive = true } },
        .{ .text = "abcabc", .pattern = "abc", .options = .{} },
        .{ .text = "line1\nline2\nline3", .pattern = "line", .options = .{} },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.search(tc.text, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var vulkan_result = try searcher.search(tc.text, tc.pattern, tc.options, allocator);
        defer vulkan_result.deinit();

        if (cpu_result.total_matches != vulkan_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}' in '{s}':\n", .{ tc.pattern, tc.text });
            std.debug.print("  CPU: {d}, Vulkan: {d}\n", .{ cpu_result.total_matches, vulkan_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}
