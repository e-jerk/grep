#include <metal_stdlib>
#include "string_ops.h"
using namespace metal;

// ============================================================================
// GPU-Accelerated String Search for grep
// ============================================================================
//
// Each thread checks a range of positions for pattern matches.
// Uses Boyer-Moore-Horspool skip table for fast rejection.
// Optimized with uchar4 vector types for SIMD operations.
// ============================================================================

// Search flags
constant uint FLAG_CASE_INSENSITIVE = 1u;
constant uint FLAG_WORD_BOUNDARY = 2u;
constant uint FLAG_INVERT_MATCH = 16u;

struct SearchConfig {
    uint text_len;
    uint pattern_len;
    uint num_patterns;
    uint flags;
    uint positions_per_thread;
    uint _pad1;
    uint _pad2;
    uint _pad3;
};

struct MatchResult {
    uint position;
    uint pattern_idx;
    uint match_len;
    uint line_start;
};

// Common functions from string_ops.h:
// to_lower, to_lower4, char_match, match4, is_word_char, is_newline,
// match_at_position, check_word_boundary, find_line_start

// ============================================================================
// Boyer-Moore-Horspool Search Kernel
// ============================================================================

kernel void bmh_search(
    device const uchar* text [[buffer(0)]],
    device const uchar* pattern [[buffer(1)]],
    device const uchar* skip_table [[buffer(2)]],
    device const SearchConfig* config [[buffer(3)]],
    device MatchResult* results [[buffer(4)]],
    device atomic_uint* result_count [[buffer(5)]],
    device atomic_uint* total_matches [[buffer(6)]],
    uint tid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    uint text_len = config->text_len;
    uint pattern_len = config->pattern_len;
    uint flags = config->flags;

    if (pattern_len == 0 || text_len < pattern_len) return;

    bool case_insensitive = (flags & FLAG_CASE_INSENSITIVE) != 0;
    bool word_boundary = (flags & FLAG_WORD_BOUNDARY) != 0;
    bool invert = (flags & FLAG_INVERT_MATCH) != 0;

    // Calculate this thread's search range
    uint chunk_size = (text_len + num_threads - 1) / num_threads;
    uint start_pos = tid * chunk_size;
    uint end_pos = min(start_pos + chunk_size + pattern_len - 1, text_len);

    if (start_pos >= text_len) return;

    uint pos = start_pos;

    while (pos + pattern_len <= end_pos) {
        uchar last_text_char = text[pos + pattern_len - 1];
        uchar last_pattern_char = pattern[pattern_len - 1];

        if (case_insensitive) {
            last_text_char = to_lower(last_text_char);
            last_pattern_char = to_lower(last_pattern_char);
        }

        if (last_text_char == last_pattern_char) {
            if (match_at_position(text, text_len, pos, pattern, pattern_len, case_insensitive)) {
                bool valid = true;

                if (word_boundary) {
                    valid = check_word_boundary(text, text_len, pos, pos + pattern_len);
                }

                if (valid != invert) {
                    uint idx = atomic_fetch_add_explicit(result_count, 1, memory_order_relaxed);

                    if (idx < 1000000) {
                        results[idx].position = pos;
                        results[idx].pattern_idx = 0;
                        results[idx].match_len = pattern_len;
                        results[idx].line_start = find_line_start(text, pos);
                    }

                    atomic_fetch_add_explicit(total_matches, 1, memory_order_relaxed);
                }
            }
        }

        uint skip = skip_table[text[pos + pattern_len - 1]];
        pos += max(skip, 1u);
    }
}

// ============================================================================
// Build Skip Table Kernel
// ============================================================================

kernel void build_skip_table(
    device const uchar* pattern [[buffer(0)]],
    device uchar* skip_table [[buffer(1)]],
    device const SearchConfig* config [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint pattern_len = config->pattern_len;
    bool case_insensitive = (config->flags & FLAG_CASE_INSENSITIVE) != 0;

    if (tid < 256) {
        uchar skip = (uchar)min(pattern_len, 255u);

        for (uint i = 0; i < pattern_len - 1; i++) {
            uchar pc = pattern[i];
            uchar tc = (uchar)tid;

            if (case_insensitive) {
                pc = to_lower(pc);
                tc = to_lower(tc);
            }

            if (pc == tc) {
                skip = (uchar)(pattern_len - 1 - i);
            }
        }

        skip_table[tid] = skip;

        if (case_insensitive) {
            if (tid >= 'A' && tid <= 'Z') {
                skip_table[tid + 32] = skip;
            } else if (tid >= 'a' && tid <= 'z') {
                skip_table[tid - 32] = skip;
            }
        }
    }
}
