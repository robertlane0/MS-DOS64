/* CHELLO.COM — N3.5 acceptance sample: first C program on MS-DOS64.
 *
 * Cross-built on the host (gcc -ffreestanding -nostdlib -m64, see
 * docs/24-c-cross-target.md) and linked with crt0 + libc64 + stdio64.
 * Exercises exactly the PLAN.md N3.5 surface: puts + malloc + fopen +
 * fwrite (+ fclose to flush). Writes HELLOC.TXT to the volume, prints
 * both lines to the console, exits 0 (shell shows "Exit 0").
 * Demo:  A> CHELLO  then  A> TYPE HELLOC.TXT  then  A> DEL HELLOC.TXT
 *
 * C-author constraints (see docs/24): no 64-bit division (no libgcc),
 * no float, no switch (jump tables), -mno-red-zone, freestanding only.
 * Only the declared shim calls exist — no headers yet (N4 needs them).
 */

typedef struct FILE FILE;   /* opaque: only pointers cross the API */

int puts(const char *s);
void *malloc(unsigned long n);
void free(void *p);
FILE *fopen(const char *path, const char *mode);
unsigned long fwrite(const void *ptr, unsigned long size,
                     unsigned long nmemb, FILE *fp);
int fclose(FILE *fp);

int main(void)
{
    char *buf;
    FILE *f;
    unsigned long w;
    int i;
    int rc = 0;

    buf = (char *)malloc(64);
    if (!buf)
        return 1;
    for (i = 0; i < 63; i++)
        buf[i] = (char)('A' + (i % 26));
    buf[63] = '\n';

    puts("hello from C");

    f = fopen("HELLOC.TXT", "w");
    if (!f) {
        free(buf);
        return 2;
    }
    w = fwrite(buf, 1, 64, f);
    free(buf);
    if (w != 64)
        rc = 3;
    if (fclose(f) != 0)
        rc = 4;
    else if (rc == 0)
        puts("wrote HELLOC.TXT");
    return rc;
}
