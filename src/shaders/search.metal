#include <metal_stdlib>
#include "string_ops.h"
#include "regex_ops.h"
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
    uint batch_offset;          // Starting position for this batch
    uint _pad2;
    uint _pad3;
};

struct MatchResult {
    uint position;
    uint pattern_idx;
    uint match_len;
    uint line_start;
    uint line_num;      // 1-based line number (computed by counting newlines)
    uint _pad1;         // Padding for 16-byte alignment
    uint _pad2;
    uint _pad3;
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
    uint tid [[thread_position_in_grid]]
) {
    uint text_len = config->text_len;
    uint pattern_len = config->pattern_len;
    uint flags = config->flags;
    uint chunk_size = config->positions_per_thread;
    uint batch_offset = config->batch_offset;

    if (pattern_len == 0 || text_len < pattern_len) return;

    bool case_insensitive = (flags & FLAG_CASE_INSENSITIVE) != 0;
    bool word_boundary = (flags & FLAG_WORD_BOUNDARY) != 0;
    bool invert = (flags & FLAG_INVERT_MATCH) != 0;

    // Calculate this thread's search range using config-provided chunk size and batch offset
    uint start_pos = batch_offset + tid * chunk_size;
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
                        uint line_start = find_line_start(text, pos);
                        // Compute line number: 1 + count of newlines before this position
                        uint line_num = 1 + count_newlines_vec(text, 0, line_start);

                        results[idx].position = pos;
                        results[idx].pattern_idx = 0;
                        results[idx].match_len = pattern_len;
                        results[idx].line_start = line_start;
                        results[idx].line_num = line_num;
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

// ============================================================================
// Regex Search Kernel - Thompson NFA execution
// ============================================================================

struct RegexSearchConfig {
    uint text_len;
    uint num_states;
    uint start_state;
    uint header_flags;
    uint num_bitmaps;
    uint max_results;
    uint flags;
    uint line_offset;  // Batch offset for line numbers (for batched dispatch)
};

struct RegexMatchOutput {
    uint start;
    uint end;
    uint line_start;
    uint flags;
    uint line_num;      // 1-based line number (computed by counting newlines)
    uint _pad1;         // Padding for 16-byte alignment
    uint _pad2;
    uint _pad3;
};

kernel void regex_search(
    device const uchar* text [[buffer(0)]],
    constant RegexState* states [[buffer(1)]],
    constant uint* bitmaps [[buffer(2)]],
    constant RegexSearchConfig& config [[buffer(3)]],
    constant RegexHeader& header [[buffer(4)]],
    device RegexMatchOutput* results [[buffer(5)]],
    device atomic_uint* result_count [[buffer(6)]],
    device atomic_uint* total_matches [[buffer(7)]],
    uint tid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    if (tid >= num_threads) return;

    bool invert = (config.flags & FLAG_INVERT_MATCH) != 0;

    // Calculate this thread's search range
    uint chunk_size = (config.text_len + num_threads - 1) / num_threads;
    uint start_pos = tid * chunk_size;
    uint end_pos = min(start_pos + chunk_size, config.text_len);

    if (start_pos >= config.text_len) return;

    // Search for regex matches in this chunk
    uint pos = start_pos;

    while (pos < end_pos) {
        uint match_start, match_end;
        bool found = regex_find(
            &header,
            states,
            bitmaps,
            text,
            config.text_len,
            pos,
            &match_start,
            &match_end
        );

        if (!found) break;
        if (match_start >= end_pos) break;

        // Record this match (apply invert logic)
        bool should_record = found != invert;
        if (should_record) {
            uint idx = atomic_fetch_add_explicit(result_count, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(total_matches, 1, memory_order_relaxed);

            if (idx < config.max_results) {
                uint line_start = find_line_start(text, match_start);
                // Compute line number: 1 + count of newlines before this position
                uint line_num = 1 + count_newlines_vec(text, 0, line_start);

                results[idx].start = match_start;
                results[idx].end = match_end;
                results[idx].line_start = line_start;
                results[idx].flags = 1;  // FLAG_VALID
                results[idx].line_num = line_num;
            }
        }

        // Move past this match
        pos = (match_end > match_start) ? match_end : match_start + 1;
    }
}

// ============================================================================
// Line-based Regex Search Kernel (one thread per line)
// ============================================================================

kernel void regex_search_lines(
    device const uchar* text [[buffer(0)]],
    constant RegexState* states [[buffer(1)]],
    constant uint* bitmaps [[buffer(2)]],
    constant RegexSearchConfig& config [[buffer(3)]],
    constant RegexHeader& header [[buffer(4)]],
    device RegexMatchOutput* results [[buffer(5)]],
    device atomic_uint* result_count [[buffer(6)]],
    device atomic_uint* total_matches [[buffer(7)]],
    device const uint* line_offsets [[buffer(8)]],
    device const uint* line_lengths [[buffer(9)]],
    uint gid [[thread_position_in_grid]],
    uint num_lines [[threads_per_grid]]
) {
    if (gid >= num_lines) return;

    uint line_start = line_offsets[gid];
    uint line_len = line_lengths[gid];
    uint line_end = line_start + line_len;

    bool invert = (config.flags & FLAG_INVERT_MATCH) != 0;

    // For invert mode, we just check if any match exists
    if (invert) {
        uint match_start, match_end;
        bool found = regex_find(
            &header,
            states,
            bitmaps,
            text + line_start,
            line_len,
            0,
            &match_start,
            &match_end
        );

        // Record line if no match found (inverted)
        if (!found) {
            uint idx = atomic_fetch_add_explicit(result_count, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(total_matches, 1, memory_order_relaxed);

            if (idx < config.max_results) {
                results[idx].start = line_start;
                results[idx].end = line_end;
                results[idx].line_start = line_start;
                results[idx].flags = 1;
                results[idx].line_num = config.line_offset + gid + 1;
            }
        }
        return;
    }

    // Normal mode: find all matches on this line
    uint search_pos = 0;
    while (search_pos < line_len) {
        uint match_start, match_end;
        bool found = regex_find(
            &header,
            states,
            bitmaps,
            text + line_start,
            line_len,
            search_pos,
            &match_start,
            &match_end
        );

        if (!found) break;

        // Record this match
        uint idx = atomic_fetch_add_explicit(result_count, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(total_matches, 1, memory_order_relaxed);

        if (idx < config.max_results) {
            results[idx].start = line_start + match_start;
            results[idx].end = line_start + match_end;
            results[idx].line_start = line_start;
            results[idx].flags = 1;
            results[idx].line_num = config.line_offset + gid + 1;
        }

        // Move past this match to find the next one
        search_pos = (match_end > match_start) ? match_end : match_start + 1;
    }
}
