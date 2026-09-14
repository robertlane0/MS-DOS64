/* tools/nasm-dos64/dos64-nasm-shim.c — NASM-specific shims for the DOS64
 * cross-target (N4A.2d). Compiled with the same freestanding cross flags
 * as the nasm sources (see trim.mk XCFLAGS); linked into the DOS64 NASM
 * image. NOT a submodule modification: this file lives outside nasm/.
 *
 * Contents (each maps to a file dropped from NASM_DOS64_DROP):
 * - nasm_vasprintf/nasm_asprintf/nasm_vaxprintf/nasm_axprintf: replace
 *   nasmlib/asprintf.c (whose vsnprintf sizing loop has no DOS64
 *   counterpart). Implemented over vfprintf into a heap image (the same
 *   growth path stdio64's "w" streams use: exact-fit realloc, no mmap).
 *   Tracks _nasm_last_string_size like upstream (strlist.c reads it).
 * - uncompress_stdmac: replace asm/uncompress.c + zlib. The DOS64 codegen
 *   (make nasm-stdmac-raw) emits raw blobs (dsize == zsize), so this is a
 *   plain copy — correct for every blob we generate. (A compressed blob
 *   would need inflate; we never generate one — see trim.mk.)
 * - nasm_realpath: replace nasmlib/realpath.c. FAT12 has no symlinks or
 *   case-folding mounts: duplicating the path is canonicalization.
 * - nasm_get_stack_size_limit: replace nasm/nasmlib/rlimit.c. Return
 *   SIZE_MAX exactly like upstream's no-getrlimit fallback (keeps the
 *   default eval-depth limit; see asm/nasm.c init_limits).
 *
 * Only this file's symbols come from C; everything else in the image is
 * NASM asm (libc) or NASM C sources. No Linux syscalls (INT 21h only via
 * libc), no relocations (same slide-safety bar as CHELLO.COM).
 */

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>

/* --- libc (provided by src/libc) --- */
extern void *malloc(size_t);
extern void *realloc(void *, size_t);
extern void free(void *);
extern void *memcpy(void *, const void *, size_t);
extern size_t strlen(const char *);

/* FILE64 layout mirror (must match src/libc/stdio64.asm struc). */
typedef struct {
    int flags;
    int fd;
    char *buf;
    size_t cap;
    size_t len;
    size_t pos;
    long pb;
} file64_t;
extern int vfprintf(file64_t *, const char *, va_list);

/* --- nasm alloc (nasmlib/alloc.c, kept) --- */
extern void *nasm_malloc(size_t);
extern void nasm_free(void *);
extern size_t _nasm_last_string_size;

/* nasm_vaxprintf/nasm_asprintf (upstream contract, minus vsnprintf). */
void *nasm_vaxprintf(size_t extra, const char *fmt, va_list ap)
{
    file64_t f;
    char *img;
    int len;

    img = nasm_malloc(extra + 128);
    if (!img)
        return NULL;
    f.flags = 1 | 2;            /* F_INUSE | F_WRITE (cf. stdio64.asm) */
    f.fd = -1;
    f.buf = img + extra;
    f.cap = 128;
    f.len = 0;
    f.pos = 0;
    f.pb = -1;
    len = vfprintf(&f, fmt, ap);
    if (len < 0) {
        nasm_free(img);
        return NULL;
    }
    /* NUL-terminate inside the image (grow once if exactly full). */
    if (f.pos >= f.cap) {
        char *bigger = nasm_malloc(extra + f.cap + 1);
        if (!bigger) {
            nasm_free(img);
            return NULL;
        }
        memcpy(bigger, img, extra + f.cap);
        nasm_free(img);
        img = bigger;
        f.buf = img + extra;
        f.cap = f.cap + 1;
    }
    f.buf[f.pos] = '\0';
    _nasm_last_string_size = (size_t)len + 1;
    if (extra) {
        /* Zero the user prefix like upstream (memset(strp, 0, extra)). */
        for (size_t i = 0; i < extra; i++)
            img[i] = 0;
        return img;
    }
    return f.buf;
}

char *nasm_vasprintf(const char *fmt, va_list ap)
{
    return nasm_vaxprintf(0, fmt, ap);
}

void *nasm_axprintf(size_t extra, const char *fmt, ...)
{
    va_list ap;
    void *strp;

    va_start(ap, fmt);
    strp = nasm_vaxprintf(extra, fmt, ap);
    va_end(ap);
    return strp;
}

char *nasm_asprintf(const char *fmt, ...)
{
    va_list ap;
    char *strp;

    va_start(ap, fmt);
    strp = nasm_vaxprintf(0, fmt, ap);
    va_end(ap);
    return strp;
}

/* uncompress_stdmac (raw-blob copy; see header note). */
struct builtin_macros {
    unsigned int dsize, zsize;
    const void *zdata;
};

char *uncompress_stdmac(const struct builtin_macros *sm)
{
    char *buf;

    if (!sm || !sm->dsize)
        return NULL;
    buf = nasm_malloc(sm->dsize);
    if (!buf)
        return NULL;
    memcpy(buf, sm->zdata, sm->dsize);
    return buf;
}

/* nasm_realpath (FAT12: no symlinks; duplication is canonicalization). */
char *nasm_strdup(const char *);        /* nasmlib/alloc.c, kept */
char *nasm_realpath(const char *path)
{
    if (!path)
        return NULL;
    return nasm_strdup(path);
}

/* nasm_get_stack_size_limit (unknown platform: SIZE_MAX, like upstream). */
size_t nasm_get_stack_size_limit(void)
{
    return SIZE_MAX;
}

/* abs (general libc, but implemented HERE, not in shim64.asm: `abs` is a
 * NASM keyword and cannot be an asm label. Same ABI/contract as C abs;
 * INT_MIN wraps per C latitude.) */
int abs(int x)
{
    return x < 0 ? -x : x;
}
