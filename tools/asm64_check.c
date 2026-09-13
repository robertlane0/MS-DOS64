/* N4B.3 host check: asm64_core assembles the N1+N2d samples byte-identically
 * to host `nasm -f bin`. Usage: asm64_check <refdir> <sampledir>
 *   refdir/sampledir contain hello/echo/cat/write (.com refs, .asm sources).
 * Exit 0 iff all four match (plus a listing smoke on hello).
 * (Spec: docs/22-asm64-spec.md N4B.3 acceptance, first half.)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int64_t asm64_assemble(const char *src, uint64_t srclen,
                              uint8_t *out, uint64_t outcap,
                              char *list, uint64_t listcap,
                              char *err, uint64_t errcap);

static uint8_t *read_file(const char *path, long *len_out) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 0; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0 || sz > 65535) { fprintf(stderr, "%s: bad size %ld\n", path, sz); fclose(f); return 0; }
    uint8_t *buf = malloc(sz ? sz : 1);
    if (sz && fread(buf, 1, sz, f) != (size_t)sz) { perror("fread"); fclose(f); free(buf); return 0; }
    fclose(f);
    *len_out = sz;
    return buf;
}

static int check_one(const char *refdir, const char *smpdir, const char *name) {
    char sp[512], rp[512];
    snprintf(sp, sizeof sp, "%s/%s.asm", smpdir, name);
    snprintf(rp, sizeof rp, "%s/%s.com", refdir, name);
    long sz = 0, rsz = 0;
    uint8_t *src = read_file(sp, &sz);
    uint8_t *ref = read_file(rp, &rsz);
    if (!src || !ref) { free(src); free(ref); return 1; }
    static uint8_t out[65536];
    static char err[512];
    memset(err, 0, sizeof err);
    int64_t rc = asm64_assemble((char *)src, sz, out, sizeof out, NULL, 0, err, sizeof err);
    int bad = 0;
    if (rc < 0) {
        printf("%-6s FAIL assemble: %s\n", name, err);
        bad = 1;
    } else if (rc != rsz || memcmp(out, ref, rsz) != 0) {
        long at = -1;
        for (long i = 0; i < rc && i < rsz; i++)
            if (out[i] != ref[i]) { at = i; break; }
        if (at < 0) at = rc < rsz ? rc : rsz;
        printf("%-6s FAIL bytes: ours=%ld ref=%ld first-diff@%ld (ours=%02x ref=%02x)\n",
               name, (long)rc, rsz, at,
               at < rc ? out[at] : 0, at < rsz ? ref[at] : 0);
        bad = 1;
    } else {
        printf("%-6s ok (%ld bytes identical)\n", name, (long)rc);
    }
    free(src);
    free(ref);
    return bad;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <refdir> <sampledir>\n", argv[0]);
        return 2;
    }
    static const char *names[] = { "hello", "echo", "cat", "write" };
    int bad = 0;
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++)
        bad |= check_one(argv[1], argv[2], names[i]);
    /* Listing smoke (our format, no NASM parity): hello with listing. */
    if (!bad) {
        char sp[512];
        snprintf(sp, sizeof sp, "%s/hello.asm", argv[2]);
        long sz = 0;
        uint8_t *src = read_file(sp, &sz);
        static uint8_t out[65536];
        static char list[65536];
        static char err[512];
        int64_t rc = asm64_assemble((char *)src, sz, out, sizeof out,
                                    list, sizeof list, err, sizeof err);
        if (rc != 37 || memchr(list, '\n', sizeof list) == 0) {
            printf("listing FAIL (rc=%ld)\n", (long)rc);
            bad = 1;
        } else {
            printf("listing ok (%ld bytes out, listing present)\n", (long)rc);
        }
        free(src);
    }
    printf(bad ? "asm64-check FAIL\n" : "asm64-check PASS (4/4 identical)\n");
    return bad;
}
