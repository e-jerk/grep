const std = @import("std");
const build_options = @import("build_options");

// Import e_jerk_gpu library for GPU detection and auto-selection
pub const e_jerk_gpu = @import("e_jerk_gpu");

// Re-export library types for use across grep
pub const GpuCapabilities = e_jerk_gpu.GpuCapabilities;
pub const AutoSelector = e_jerk_gpu.AutoSelector;
pub const AutoSelectConfig = e_jerk_gpu.AutoSelectConfig;
pub const WorkloadInfo = e_jerk_gpu.WorkloadInfo;
pub const SelectionResult = e_jerk_gpu.SelectionResult;

pub const metal = if (build_options.is_macos) @import("metal.zig") else struct {
    pub const MetalSearcher = void;
};
pub const vulkan = @import("vulkan.zig");

// Configuration
pub const BATCH_SIZE: usize = 1024 * 1024;
pub const MAX_GPU_BUFFER_SIZE: usize = 64 * 1024 * 1024;
pub const MIN_GPU_SIZE: usize = 128 * 1024;
pub const MAX_PATTERN_LEN: u32 = 256;
pub const MAX_RESULTS: u32 = 1000000;

pub const EMBEDDED_METAL_SHADER = if (build_options.is_macos) @import("metal_shader").EMBEDDED_METAL_SHADER else "";

// Grep-specific data structures
pub const SearchConfig = extern struct {
    text_len: u32,
    pattern_len: u32,
    num_patterns: u32,
    flags: u32,
    positions_per_thread: u32,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    _pad3: u32 = 0,
};

pub const SearchFlags = struct {
    pub const CASE_INSENSITIVE: u32 = 1;
    pub const WORD_BOUNDARY: u32 = 2;
    pub const INVERT_MATCH: u32 = 16;
    pub const FIXED_STRING: u32 = 32;
};

pub const MatchResult = extern struct {
    position: u32,
    pattern_idx: u32,
    match_len: u32,
    line_start: u32,
};

pub const SearchOptions = struct {
    case_insensitive: bool = false,
    word_boundary: bool = false,
    invert_match: bool = false,
    fixed_string: bool = true,

    pub fn toFlags(self: SearchOptions) u32 {
        var flags: u32 = 0;
        if (self.case_insensitive) flags |= SearchFlags.CASE_INSENSITIVE;
        if (self.word_boundary) flags |= SearchFlags.WORD_BOUNDARY;
        if (self.invert_match) flags |= SearchFlags.INVERT_MATCH;
        if (self.fixed_string) flags |= SearchFlags.FIXED_STRING;
        return flags;
    }
};

pub const SearchResult = struct {
    matches: []MatchResult,
    total_matches: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SearchResult) void {
        self.allocator.free(self.matches);
    }
};

pub fn buildSkipTable(pattern: []const u8, case_insensitive: bool) [256]u8 {
    var skip_table: [256]u8 = undefined;
    const default_skip: u8 = @intCast(@min(pattern.len, 255));
    @memset(&skip_table, default_skip);

    if (pattern.len > 1) {
        for (pattern[0 .. pattern.len - 1], 0..) |c, i| {
            const skip: u8 = @intCast(pattern.len - 1 - i);
            skip_table[c] = skip;
            if (case_insensitive) {
                if (c >= 'A' and c <= 'Z') skip_table[c + 32] = skip;
                if (c >= 'a' and c <= 'z') skip_table[c - 32] = skip;
            }
        }
    }
    return skip_table;
}

// Use library's Backend enum
pub const Backend = e_jerk_gpu.Backend;

pub fn detectBestBackend() Backend {
    if (build_options.is_macos) return .metal;
    return .vulkan;
}

pub fn shouldUseGpu(text_len: usize) bool {
    return text_len >= MIN_GPU_SIZE;
}

pub fn formatBytes(bytes: usize) struct { value: f64, unit: []const u8 } {
    if (bytes >= 1024 * 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024), .unit = "GB" };
    if (bytes >= 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024), .unit = "MB" };
    if (bytes >= 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / 1024, .unit = "KB" };
    return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
}
