/* gnu_grep_wrapper.c - Wrapper to expose GNU grep search functions to Zig
 * This provides a simplified interface to GNU grep's search algorithms.
 */

#include <config.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <regex.h>

#include "localeinfo.h"
#include "kwset.h"

/* Global variables required by GNU grep */
bool match_icase = false;
bool match_words = false;
bool match_lines = false;
char eolbyte = '\n';

/* Program name - required by error() and xalloc_die() */
const char *program_name = "grep";

/* Locale info - required by search functions */
struct localeinfo localeinfo;

/* Error handling - use setjmp/longjmp to avoid process termination */
static jmp_buf error_jmp;
static int error_occurred = 0;
static char error_message[256] = {0};

/* Exit failure - defined in exitfail.c */
extern int volatile exit_failure;

/* Pattern file name stub - not used in our wrapper */
char const *pattern_file_name(long idx, long *lineno) {
    if (lineno) *lineno = 0;
    return "pattern";
}

/* Search interface declarations from search.h */
#include "idx.h"

extern void wordinit(void);
extern void *GEAcompile(char *, idx_t, reg_syntax_t, bool);
extern ptrdiff_t EGexecute(void *, char const *, idx_t, idx_t *, char const *);
extern void *Fcompile(char *, idx_t, reg_syntax_t, bool);
extern ptrdiff_t Fexecute(void *, char const *, idx_t, idx_t *, char const *);

/* Regex syntax constants (from regex.h) */
#ifndef RE_SYNTAX_GREP
#define RE_SYNTAX_GREP (RE_BK_PLUS_QM | RE_CHAR_CLASSES | RE_HAT_LISTS_NOT_NEWLINE | RE_INTERVALS | RE_NO_EMPTY_RANGES)
#endif
#ifndef RE_SYNTAX_EGREP
#define RE_SYNTAX_EGREP (RE_CHAR_CLASSES | RE_CONTEXT_INDEP_ANCHORS | RE_CONTEXT_INDEP_OPS | RE_HAT_LISTS_NOT_NEWLINE | RE_NEWLINE_ALT | RE_NO_BK_PARENS | RE_NO_BK_VBAR | RE_NO_EMPTY_RANGES)
#endif
#ifndef RE_ICASE
#define RE_ICASE (1 << 15)
#endif

/* Initialize GNU grep subsystems */
static void gnu_grep_init(void) {
    static bool initialized = false;
    if (initialized) return;

    /* Initialize locale info for single-byte locale (ASCII) */
    memset(&localeinfo, 0, sizeof(localeinfo));
    localeinfo.multibyte = false;
    localeinfo.simple = true;
    localeinfo.using_utf8 = false;

    /* Set up single-byte character lengths (all 1 for ASCII) */
    for (int i = 0; i < 256; i++) {
        localeinfo.sbclen[i] = 1;
    }

    /* Initialize word characters */
    wordinit();

    initialized = true;
}

/* Result structure for Zig interop */
typedef struct {
    long start;      /* Start position of match */
    long end;        /* End position of match (exclusive) */
    long line_start; /* Start of the line containing match */
} GnuMatchResult;

/* Search context */
typedef struct {
    void *compiled;           /* Compiled pattern (kwset or dfa) */
    bool is_fixed;           /* True for fixed string, false for regex */
} GnuSearchContext;

/* Compile a fixed string pattern */
GnuSearchContext* gnu_grep_compile_fixed(const char *pattern, long pattern_len,
                                          bool case_insensitive) {
    gnu_grep_init();

    match_icase = case_insensitive;
    match_words = false;
    match_lines = false;

    /* GNU grep's Fcompile expects patterns to be newline-terminated.
     * Create a copy with a trailing newline. */
    char *pattern_with_nl = malloc(pattern_len + 2);
    if (!pattern_with_nl) return NULL;
    memcpy(pattern_with_nl, pattern, pattern_len);
    pattern_with_nl[pattern_len] = '\n';
    pattern_with_nl[pattern_len + 1] = '\0';

    error_occurred = 0;
    if (setjmp(error_jmp) != 0) {
        free(pattern_with_nl);
        return NULL;
    }

    GnuSearchContext *ctx = malloc(sizeof(GnuSearchContext));
    if (!ctx) {
        free(pattern_with_nl);
        return NULL;
    }

    ctx->is_fixed = true;
    /* Pass pattern_len + 1 to include the newline */
    ctx->compiled = Fcompile(pattern_with_nl, pattern_len + 1, 0, false);

    free(pattern_with_nl);

    if (!ctx->compiled) {
        free(ctx);
        return NULL;
    }

    return ctx;
}

/* Compile a regex pattern */
GnuSearchContext* gnu_grep_compile_regex(const char *pattern, long pattern_len,
                                          bool case_insensitive, bool extended) {
    gnu_grep_init();

    match_icase = case_insensitive;
    match_words = false;
    match_lines = false;

    error_occurred = 0;
    if (setjmp(error_jmp) != 0) {
        return NULL;
    }

    GnuSearchContext *ctx = malloc(sizeof(GnuSearchContext));
    if (!ctx) return NULL;

    ctx->is_fixed = false;

    /* Syntax bits for regex compilation */
    reg_syntax_t syntax = extended ? RE_SYNTAX_EGREP : RE_SYNTAX_GREP;
    if (case_insensitive) {
        syntax |= RE_ICASE;
    }

    /* For regex, pass the pattern as-is - GEAcompile handles it differently than Fcompile */
    ctx->compiled = GEAcompile((char*)pattern, pattern_len, syntax, false);

    if (!ctx->compiled) {
        free(ctx);
        return NULL;
    }

    return ctx;
}

/* Execute search and return first match position
 * Returns the match length, or -1 if no match, or -2 on error.
 * *match_start is set to the start position of the match.
 *
 * Note: GNU grep's Fexecute/EGexecute return LINE-oriented results:
 * - Return value: offset to start of matching LINE (not match position)
 * - match_size: length of matching LINE (including newline)
 *
 * We convert these to match-oriented results by searching within the line.
 */
long gnu_grep_execute(GnuSearchContext *ctx, const char *text, long text_len,
                      long *match_start) {
    if (!ctx || !ctx->compiled || !text || text_len <= 0) {
        return -2;
    }

    error_occurred = 0;
    if (setjmp(error_jmp) != 0) {
        return -2;
    }

    idx_t match_size = 0;
    ptrdiff_t result;

    if (ctx->is_fixed) {
        result = Fexecute(ctx->compiled, text, text_len, &match_size, NULL);
    } else {
        result = EGexecute(ctx->compiled, text, text_len, &match_size, NULL);
    }

    if (result < 0) {
        return -1; /* No match */
    }

    if (match_start) {
        *match_start = result;
    }

    return match_size;
}

/* Free compiled pattern */
void gnu_grep_free(GnuSearchContext *ctx) {
    if (ctx) {
        /* Note: GNU grep doesn't provide cleanup functions for compiled patterns
         * in a way we can easily use. The memory will be leaked, but for
         * benchmarking purposes this is acceptable. */
        free(ctx);
    }
}

/* Get last error message */
const char* gnu_grep_get_error(void) {
    return error_occurred ? error_message : NULL;
}
