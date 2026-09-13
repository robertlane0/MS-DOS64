/* tools/nasm-dos64/dos64-config.h — NASM feature config for MS-DOS64 (N4A).
 *
 * Force-included FIRST on every cross-compile command line:
 *   gcc ... -include tools/nasm-dos64/dos64-config.h ...
 * (never -DHAVE_CONFIG_H: without it compiler.h takes the "unknown
 * compiler" branch — unknown.h assumes the worst — plus unconfig.h,
 * which is exactly the degradation ladder this file tunes.)
 *
 * Strategy: define ONLY what DOS64 + gcc-freestanding truly provides and
 * leave everything else UNDEFINED, so nasm degrades to the pure-stdio
 * paths it already ships. Each block below names the fallback selected
 * and the libc64/stdio64 symbol that serves it (see docs/25-n4a1-trim.md
 * for the full nm-derived gap table).
 */

#ifndef NASM_DOS64_CONFIG_H
#define NASM_DOS64_CONFIG_H

/* The cross-target is gcc (typeof, _Bool, inttypes all real). */
#define HAVE_INTTYPES_H 1
#define HAVE_STDBOOL_H 1
#define HAVE_TYPEOF 1

/* x86-64 is little-endian with flat addressing (compiler.h would
 * conclude this on its own from __x86_64__, listed for explicitness). */
#define WORDS_LITTLEENDIAN 1
#define X86_MEMORY 1

/* ---- Deliberately ABSENT (each absence selects a fallback) ----
 *
 * HAVE_MMAP / HAVE_FILENO absent
 *   -> nasmlib/mmap.c compiles the NULL stub; callers (incbin in
 *      asm/assemble.c) fall back to fread loops. Needs: fread (have).
 *      NO kernel change, NO backend swap for mmap.
 * HAVE_STAT / HAVE_FSTAT / HAVE_STRUCT_STAT absent
 *   -> nasmlib/file.c stubs os_stat/os_fstat; nasm_file_size() falls
 *      back to fseeko/ftello seek-to-end. Needs: fseek/ftell (have).
 *      nasm_compare_paths() degrades to strcmp (FAT12 has no links).
 *      No backend swap for stat either.
 * HAVE_FSEEKO absent (and no _FSEEKI64)
 *   -> nasmlib.h maps fseeko->fseek, ftello->ftell, off_t->long
 *      (64-bit long on this target, so no range lost). Needs: fseek
 *      SEEK_END working on read streams (true: slurp-into-heap image).
 * HAVE_ACCESS / HAVE_FACCESSAT absent
 *   -> nasm_file_exists() falls back to fopen-probe. Needs: fopen (have).
 * HAVE_SNPRINTF / HAVE_VSNPRINTF / HAVE_STRLCPY / HAVE_STRNLEN absent
 *   -> compiler.h declares them, nasm/stdlib/{snprintf,vsnprintf,
 *      strlcpy,strnlen}.c PROVIDE them. No libc64 work needed.
 * HAVE_REALPATH / canonicalize_file_name: never defined
 *   -> nasmlib/realpath.c is NOT compiled for this target (N4A.2 drops
 *      the file from the build list; %include search needs no
 *      canonicalization on FAT12).
 * HAVE_RLIMIT / getrlimit: never defined
 *   -> nasm/nasmlib/rlimit.c is dropped from the build list (fixed
 *      6 MiB spawn budget instead; PLAN §6 cut).
 * zlib (uncompress.c): dropped from the build list; the stdmac blob is
 *   decompressed HOST-side into a plain table (N4A.2 codegen, same
 *   pattern as the pre-generated *.ph tables).
 */

#endif /* NASM_DOS64_CONFIG_H */
