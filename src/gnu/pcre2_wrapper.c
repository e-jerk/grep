// PCRE2 wrapper for Perl-compatible regular expressions (-P flag)
// Uses PCRE2 library for full Perl regex support

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>
#include <stdlib.h>
#include <string.h>

// Context structure for PCRE2 matching
typedef struct {
    pcre2_code *code;
    pcre2_match_data *match_data;
    pcre2_match_context *match_context;
    int error_code;
    PCRE2_SIZE error_offset;
} PcreContext;

// Match result structure
typedef struct {
    size_t start;
    size_t end;
    int valid;
} PcreMatch;

// Compile a Perl regex pattern
// Returns NULL on error, error_code will be set
PcreContext* pcre2_compile_pattern(
    const char *pattern,
    size_t pattern_len,
    int case_insensitive,
    int multiline
) {
    PcreContext *ctx = (PcreContext*)malloc(sizeof(PcreContext));
    if (!ctx) return NULL;

    memset(ctx, 0, sizeof(PcreContext));

    uint32_t flags = PCRE2_UTF;
    if (case_insensitive) flags |= PCRE2_CASELESS;
    if (multiline) flags |= PCRE2_MULTILINE;

    ctx->code = pcre2_compile(
        (PCRE2_SPTR8)pattern,
        pattern_len,
        flags,
        &ctx->error_code,
        &ctx->error_offset,
        NULL
    );

    if (!ctx->code) {
        // Compilation failed - ctx contains error info
        return ctx;
    }

    // JIT compile for better performance
    pcre2_jit_compile(ctx->code, PCRE2_JIT_COMPLETE);

    ctx->match_data = pcre2_match_data_create_from_pattern(ctx->code, NULL);
    ctx->match_context = pcre2_match_context_create(NULL);

    if (!ctx->match_data || !ctx->match_context) {
        pcre2_code_free(ctx->code);
        pcre2_match_data_free(ctx->match_data);
        pcre2_match_context_free(ctx->match_context);
        free(ctx);
        return NULL;
    }

    return ctx;
}

// Check if compilation succeeded
int pcre2_is_valid(PcreContext *ctx) {
    return ctx && ctx->code != NULL;
}

// Get compilation error message
void pcre2_wrapper_get_error_message(PcreContext *ctx, char *buffer, size_t buffer_len) {
    if (!ctx || !buffer || buffer_len == 0) return;

    if (ctx->code) {
        buffer[0] = '\0';
        return;
    }

    pcre2_get_error_message(ctx->error_code, (PCRE2_UCHAR8*)buffer, buffer_len);
}

// Get compilation error offset
size_t pcre2_get_error_offset(PcreContext *ctx) {
    return ctx ? ctx->error_offset : 0;
}

// Find first match starting at offset
// Returns 1 if found, 0 if not found, negative on error
int pcre2_find_first(
    PcreContext *ctx,
    const char *text,
    size_t text_len,
    size_t start_offset,
    PcreMatch *result
) {
    if (!ctx || !ctx->code || !text || !result) return -1;

    result->valid = 0;

    int rc = pcre2_match(
        ctx->code,
        (PCRE2_SPTR8)text,
        text_len,
        start_offset,
        0,
        ctx->match_data,
        ctx->match_context
    );

    if (rc < 0) {
        if (rc == PCRE2_ERROR_NOMATCH) {
            return 0;
        }
        return rc;  // Other error
    }

    PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(ctx->match_data);
    result->start = ovector[0];
    result->end = ovector[1];
    result->valid = 1;

    return 1;
}

// Find all matches in text
// Returns number of matches found, or negative on error
// results array must be pre-allocated with max_results capacity
int pcre2_find_all(
    PcreContext *ctx,
    const char *text,
    size_t text_len,
    PcreMatch *results,
    size_t max_results
) {
    if (!ctx || !ctx->code || !text || !results) return -1;

    size_t offset = 0;
    int count = 0;

    while (offset < text_len && (size_t)count < max_results) {
        int rc = pcre2_match(
            ctx->code,
            (PCRE2_SPTR8)text,
            text_len,
            offset,
            0,
            ctx->match_data,
            ctx->match_context
        );

        if (rc < 0) {
            if (rc == PCRE2_ERROR_NOMATCH) {
                break;  // No more matches
            }
            return rc;  // Error
        }

        PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(ctx->match_data);
        results[count].start = ovector[0];
        results[count].end = ovector[1];
        results[count].valid = 1;
        count++;

        // Move past this match
        offset = ovector[1];
        if (ovector[0] == ovector[1]) {
            // Empty match - advance by one to prevent infinite loop
            offset++;
        }
    }

    return count;
}

// Free PCRE2 context
void pcre2_free_context(PcreContext *ctx) {
    if (!ctx) return;

    if (ctx->match_context) pcre2_match_context_free(ctx->match_context);
    if (ctx->match_data) pcre2_match_data_free(ctx->match_data);
    if (ctx->code) pcre2_code_free(ctx->code);
    free(ctx);
}
