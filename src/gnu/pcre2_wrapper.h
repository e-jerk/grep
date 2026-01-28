// PCRE2 wrapper header for Zig interop
#ifndef PCRE2_WRAPPER_H
#define PCRE2_WRAPPER_H

#include <stddef.h>

// Opaque context type
typedef struct PcreContext PcreContext;

// Match result structure
typedef struct {
    size_t start;
    size_t end;
    int valid;
} PcreMatch;

// Compile a Perl regex pattern
// Returns NULL on error
PcreContext* pcre2_compile_pattern(
    const char *pattern,
    size_t pattern_len,
    int case_insensitive,
    int multiline
);

// Check if compilation succeeded
int pcre2_is_valid(PcreContext *ctx);

// Get compilation error message
void pcre2_wrapper_get_error_message(PcreContext *ctx, char *buffer, size_t buffer_len);

// Get compilation error offset
size_t pcre2_get_error_offset(PcreContext *ctx);

// Find first match starting at offset
// Returns 1 if found, 0 if not found, negative on error
int pcre2_find_first(
    PcreContext *ctx,
    const char *text,
    size_t text_len,
    size_t start_offset,
    PcreMatch *result
);

// Find all matches in text
// Returns number of matches found, or negative on error
int pcre2_find_all(
    PcreContext *ctx,
    const char *text,
    size_t text_len,
    PcreMatch *results,
    size_t max_results
);

// Free PCRE2 context
void pcre2_free_context(PcreContext *ctx);

#endif // PCRE2_WRAPPER_H
