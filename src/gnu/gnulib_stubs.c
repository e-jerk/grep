/* gnulib_stubs.c - Stub implementations for missing gnulib/grep functions */

#include <config.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <locale.h>
#include <limits.h>
#include <wchar.h>

/*
 * Compatibility functions for gnulib
 * These are implementations of functions that may be missing on some platforms.
 */

/* reallocarray - realloc with overflow checking */
void *reallocarray(void *ptr, size_t nmemb, size_t size) {
    if (nmemb && size > SIZE_MAX / nmemb) {
        errno = ENOMEM;
        return NULL;
    }
    return realloc(ptr, nmemb * size);
}

/* rawmemchr - like memchr but assumes the byte exists (no length limit) */
void *rawmemchr(const void *s, int c) {
    const unsigned char *p = (const unsigned char *)s;
    while (*p != (unsigned char)c)
        p++;
    return (void *)p;
}

/* memrchr - reverse memchr, find last occurrence */
void *memrchr(const void *s, int c, size_t n) {
    const unsigned char *p = (const unsigned char *)s + n;
    while (n--) {
        if (*--p == (unsigned char)c)
            return (void *)p;
    }
    return NULL;
}

/* mbslen - length of multibyte string in characters */
size_t mbslen(const char *s) {
    size_t len = 0;
    mbstate_t state;
    memset(&state, 0, sizeof(state));

    while (*s) {
        size_t bytes = mbrlen(s, MB_LEN_MAX, &state);
        if (bytes == (size_t)-1 || bytes == (size_t)-2) {
            /* Invalid or incomplete - count as one byte */
            s++;
        } else if (bytes == 0) {
            break;
        } else {
            s += bytes;
        }
        len++;
    }
    return len;
}

/* setlocale_null_r - thread-safe locale query */
int setlocale_null_r(int category, char *buf, size_t bufsize) {
    const char *locale = setlocale(category, NULL);
    if (!locale) {
        if (bufsize > 0)
            buf[0] = '\0';
        return EINVAL;
    }
    size_t len = strlen(locale);
    if (len >= bufsize) {
        if (bufsize > 0) {
            memcpy(buf, locale, bufsize - 1);
            buf[bufsize - 1] = '\0';
        }
        return ERANGE;
    }
    memcpy(buf, locale, len + 1);
    return 0;
}

/* fgrep_to_grep_pattern - converts fgrep patterns to grep
 * We don't use this functionality, so just return the pattern as-is */
char *fgrep_to_grep_pattern(size_t *len, char *keys) {
    /* Return keys unchanged */
    return keys;
}

/* usage - called by argmatch on failure
 * We don't want to exit, so just print error and return */
void usage(int status) {
    (void)status;
    fprintf(stderr, "GNU grep wrapper: invalid usage\n");
}

/* gl_dynarray_resize - gnulib dynamic array resize
 * Used by regex internals */
bool gl_dynarray_resize(void *list, size_t size, void *scratch, size_t element) {
    /* This is an internal gnulib function.
     * The actual implementation is complex - for now, return false to signal failure.
     * This may cause regex to fail on very complex patterns. */
    (void)list;
    (void)size;
    (void)scratch;
    (void)element;
    return false;
}

/* rotr_sz - rotate right for size_t
 * Used by hash.c */
size_t rotr_sz(size_t x, int n) {
    int bits = sizeof(size_t) * 8;
    n = n % bits;
    if (n == 0) return x;
    return (x >> n) | (x << (bits - n));
}

/*
 * Override xmalloc family to use simple malloc without complex error handling.
 * This avoids the gnulib error() chain which has initialization issues.
 */

void xalloc_die(void) {
    fprintf(stderr, "grep: memory exhausted\n");
    abort();
}

void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (!p && n != 0) {
        xalloc_die();
    }
    return p;
}

void *xcalloc(size_t n, size_t s) {
    void *p = calloc(n, s);
    if (!p && n != 0 && s != 0) {
        xalloc_die();
    }
    return p;
}

void *xrealloc(void *p, size_t n) {
    void *r = realloc(p, n);
    if (!r && n != 0) {
        xalloc_die();
    }
    return r;
}

void *xnmalloc(size_t n, size_t s) {
    return xmalloc(n * s);
}

void *xzalloc(size_t n) {
    return xcalloc(n, 1);
}

char *xstrdup(const char *s) {
    char *p = strdup(s);
    if (!p) {
        xalloc_die();
    }
    return p;
}

/* Additional xmalloc variants used by gnulib */

void *xmemdup(const void *p, size_t s) {
    void *r = xmalloc(s);
    memcpy(r, p, s);
    return r;
}

char *xcharalloc(size_t n) {
    return (char *)xmalloc(n);
}

/* idx_t variants (idx_t is typically ptrdiff_t or similar) */
void *ximalloc(size_t s) {
    return xmalloc(s);
}

void *xicalloc(size_t n, size_t s) {
    return xcalloc(n, s);
}

void *xirealloc(void *p, size_t s) {
    return xrealloc(p, s);
}

void *xizalloc(size_t s) {
    return xzalloc(s);
}

void *ximemdup0(const void *p, size_t s) {
    char *r = (char *)xmalloc(s + 1);
    memcpy(r, p, s);
    r[s] = '\0';
    return r;
}

/* xpalloc - grow an array, used for dynamic arrays */
void *xpalloc(void *pa, size_t *pn, size_t n_incr_min, ptrdiff_t n_max, size_t s) {
    size_t n = *pn;
    size_t n_incr = n;

    /* Grow by at least n_incr_min */
    if (n_incr < n_incr_min)
        n_incr = n_incr_min;

    /* Don't exceed n_max if specified */
    if (n_max >= 0 && n + n_incr > (size_t)n_max)
        n_incr = (size_t)n_max - n;

    size_t new_n = n + n_incr;
    *pn = new_n;

    return xrealloc(pa, new_n * s);
}

void *xreallocarray(void *p, size_t n, size_t s) {
    /* Check for overflow */
    if (s != 0 && n > (size_t)-1 / s) {
        xalloc_die();
    }
    return xrealloc(p, n * s);
}

void *x2realloc(void *p, size_t *pn) {
    return xpalloc(p, pn, 1, -1, 1);
}

void *x2nrealloc(void *p, size_t *pn, size_t s) {
    return xpalloc(p, pn, 1, -1, s);
}
