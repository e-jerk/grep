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
pub const regex_compiler = @import("regex_compiler.zig");

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
    batch_offset: u32 = 0,
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
    line_num: u32 = 0, // 1-based line number (computed on GPU)
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    _pad3: u32 = 0,
};

pub const SearchOptions = struct {
    case_insensitive: bool = false,
    word_boundary: bool = false,
    invert_match: bool = false,
    fixed_string: bool = true,
    extended: bool = false, // ERE mode (-E), when false uses BRE (-G)
    perl: bool = false, // PCRE mode (-P) for Perl-compatible regex

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

// ============================================================================
// GPU Regex Types (match shader structs in regex_ops.h / regex_ops.glsl)
// ============================================================================

pub const MAX_REGEX_STATES: u32 = 256;
pub const MAX_CAPTURE_GROUPS: u32 = 16;
pub const BITMAP_WORDS_PER_CLASS: u32 = 8; // 256 bits = 8 x 32-bit words

/// NFA state types - must match shader enums
pub const RegexStateType = enum(u8) {
    literal = 0, // Match single character
    char_class = 1, // Match character class using bitmap
    dot = 2, // Match any character except newline
    split = 3, // Epsilon split to two states
    match = 4, // Accept state
    group_start = 5, // Capture group start
    group_end = 6, // Capture group end
    word_boundary = 7, // \b
    not_word_boundary = 8, // \B
    line_start = 9, // ^
    line_end = 10, // $
    any = 11, // . including newline
    // PCRE extensions
    lookahead_pos = 12, // (?=...) positive lookahead
    lookahead_neg = 13, // (?!...) negative lookahead
    lookbehind_pos = 14, // (?<=...) positive lookbehind
    lookbehind_neg = 15, // (?<!...) negative lookbehind
    atomic_group = 16, // (?>...) atomic group (no backtrack)
    non_greedy = 17, // Non-greedy quantifier marker
};

/// Compiled regex state (GPU-aligned, matches shader struct)
pub const RegexState = extern struct {
    type: u8, // RegexStateType
    flags: u8, // case_insensitive, negated, etc.
    out: u16, // Next state index
    out2: u16, // Second output for split states
    literal_char: u8, // For literal states
    group_idx: u8, // For group_start/end
    bitmap_offset: u32, // Offset into bitmap buffer for char_class

    pub const FLAG_CASE_INSENSITIVE: u8 = 0x01;
    pub const FLAG_NEGATED: u8 = 0x02;
    pub const FLAG_NON_GREEDY: u8 = 0x04;
};

/// Compiled regex header (uploaded with pattern)
pub const RegexHeader = extern struct {
    num_states: u32,
    start_state: u32,
    num_groups: u32,
    flags: u32,

    pub const FLAG_ANCHORED_START: u32 = 0x01;
    pub const FLAG_ANCHORED_END: u32 = 0x02;
    pub const FLAG_CASE_INSENSITIVE: u32 = 0x04;
};

/// GPU regex search config
pub const RegexSearchConfig = extern struct {
    text_len: u32,
    num_states: u32,
    start_state: u32,
    header_flags: u32,
    num_bitmaps: u32,
    max_results: u32,
    flags: u32, // Standard SearchFlags
    line_offset: u32 = 0, // Batch offset for line numbers (for batched dispatch)
};

/// GPU regex match result
pub const RegexMatchResult = extern struct {
    start: u32,
    end: u32,
    line_start: u32,
    flags: u32, // valid, etc.
    line_num: u32 = 0, // 1-based line number (computed on GPU)
    _pad1: u32 = 0,
    _pad2: u32 = 0,
    _pad3: u32 = 0,

    pub const FLAG_VALID: u32 = 0x01;
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
