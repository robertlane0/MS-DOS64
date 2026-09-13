# N4A.1 — Trimmed NASM build variant: measurements + libc gap + size decision

First N4A slice (PLAN item 11). No kernel change, no submodule change:
a throwaway copy of the pinned `nasm/` tree built host-side with NASM's
own `OF_*` ladder, plus the `tools/nasm-dos64/` config stack for the
future cross-target. `make nasm-trim-check` reproduces everything below.

## 1. Trim measurements (host, 2026-09-12)

Pinned submodule `nasm-3.02-50-gfbdc88565`, host `gcc -O2 -g`,
`./configure --disable-lto --disable-debug` (same flags as
`make nasm-samples`):

| Variant | text | data | bss | file bytes |
|---|---|---|---|---|
| full (`make nasm`) | 1188559 | 1166048 | 24040 | 4665888 |
| `OF_ONLY+OF_BIN` | 1041200 | 1159784 | 4456 | 3649480 |
| `OF_ONLY+OF_BIN+OF_ELF` | 1041352 | 1159784 | 4456 | — |
| bin-only, stripped | — | — | — | 2214976 |

(`-hf` on the trimmed binary lists only `bin/ith/srec`; ELF costs
+152 B text — keep `OF_ELF` for a future `MZ64` output path.)

Findings:

- The output backends are small (~150 KB text all together). The floor
  is ~1.16 MB of `.data.rel.ro` pointer tables (generated `insns`/`regs`
  tables) — no flag removes those; only table surgery would.
- `make nasm-trim-check`: the trimmed binary assembles all four N1
  samples **byte-identically** to system NASM 3.02 (`cmp` vs
  `build/asm64_ref/*.com`).
- Canonical flags: `tools/nasm-dos64/trim.mk`
  (`NASM_TRIM_PPFLAGS = -DOF_ONLY -DOF_BIN -DOF_ELF`).

## 2. Trimmed build list (N4A.1 decision)

Keep: `asm/` (parser/preproc minus `uncompress.c`), `x86/` tables
(pre-generated `*.ph` host-side — never run Perl on DOS64),
`nasmlib/` minus `realpath.c`/`rlimit.c`, `output/outbin.c` (+ `outelf.c`
iff `MZ64` output wanted), `common/`, `stdlib/` fallbacks,
`disasm/` NOT needed (`NDISASM` deferred per PLAN §5).

Drop (`NASM_DOS64_DROP` in `trim.mk`): `nasmlib/realpath.c`,
`nasmlib/rlimit.c`, `asm/uncompress.c`, whole `nasm/zlib/`.
The stdmac blob `uncompress.c` feeds (`uncompress_stdmac`, one caller in
`asm/preproc.c:1409`) is instead decompressed **host-side** into a plain
table at N4A.2 (same codegen pattern as the `*.ph` tables).

`mmap.c` and `file.c` are KEPT with zero changes: under
`tools/nasm-dos64/dos64-config.h` (no `HAVE_MMAP`/`HAVE_FILENO`, no
`HAVE_STAT`/`HAVE_FSTAT`, no `HAVE_FSEEKO`, no `HAVE_ACCESS`) they compile
to the fallbacks NASM already ships — NULL-map with `fread` retry
(`asm/assemble.c` incbin), `fseeko`→`fseek`/`off_t`→`long` (64-bit long
here), seek-to-end filesize, fopen-probe existence. **N4A.2 needs no
`file.c`/`mmap.c` backend swap** — the milestone shrinks to the libc
symbols in §3 plus the stdmac codegen.

## 3. libc gap table (N4A.2 work list)

Derived from `nm -D /usr/bin/nasm` (full-build undefined set; the trim
drops only `qsort` via `outmacho.c` — everything else below is linked by
the kept core, verified by grep). `HAVE` = in `libc64`/`stdio64` today.

| Symbol | Used by (kept core) | DOS64 plan |
|---|---|---|
| `malloc/calloc/realloc/free`, `memcpy/memmove/memset/memcmp`, `strlen/strcpy/strncpy/strcmp/strncmp/strcat/strchr` | everywhere | HAVE (`libc64.asm`) |
| `fopen/fclose/fread/fwrite/fseek/ftell/fflush/feof/ferror` | `file.c`, preproc, listing | HAVE (`stdio64.asm`) |
| `printf/sprintf/snprintf`, `puts/putchar`, `exit` | diagnostics, `exit_group` path | HAVE (`libc64.asm`) |
| `snprintf/vsnprintf/strlcpy/strnlen` | `compiler.h` fallback decls | VENDORED (`nasm/stdlib/*.c` compile when `HAVE_*` absent — free) |
| `mempcpy` | `nasmlib/string.c` et al. | FREE (`compiler.h` inlines it when `HAVE_MEMPCPY` absent) |
| `strcasecmp/strncasecmp` | directives, cmdline, `outbin.c` | ADD (tiny, ~30 lines over `strcmp` core) |
| `strcspn/strspn/strsep` | `directiv.c`, `nasm.c`, `nasmlib/string.c` | ADD (tiny, byte loops) |
| `strtol/strtoul/sscanf` | `nasm.c`, `preproc.c` (`%d:%d` line ranges) | ADD (`strtol/ul` needed; `sscanf` only for one `%d:%d` — a 10-line local parser or minimal `sscanf` subset) |
| `fgets/fgetc/getc/ungetc/fputc/fputs/putc` | response files (`nasm.c`), stdmac scan (`preproc.c`) | ADD over handle I/O (buffered `FILE*` extension — the largest N4A.2 libc item; `stdio64` today is unbuffered slurp/write-image) |
| `fprintf/vfprintf`, `stderr/stdout/stdin` objects | errors (`error.c`), `-e`/`-M` output, `ofile==stdout` paths | ADD (`FILE*` objects + `vfprintf`→format core; note `libc64` format core lives in `sprintf` — reuse, don't duplicate) |
| `setvbuf` | `nasm_open_write` buffering requests | STUB-honest (return 0; our streams have fixed policy) |
| `remove` | error-path `unlink(out)` (`nasm_remove`) | ADD over FCB delete `AH=13h` (real; `AH=41h` handle-unlink is still `handler_inuse`) — parse 8.3, FCB-delete |
| `strerror`, `errno`/`__errno_location` | `file.c`/`fileio.c` fatal messages | ADD (`errno` thread-local→single BSS cell; trap helpers set it; `strerror` minimal table) |
| `getenv` | `NASMENV`, `%!environ` (`nasm.c`, `preproc.c`) | ADD (scan `crt0` envp block — 20 lines) |
| `abort` | `error.c` panic paths | ADD (`AH=4Ch` with code 3 — one jump) |
| `stat/fstat/faccessat/access/fileno` | `file.c` probes | STUB (`stat/fstat` return -1 → seek fallback; `fileno` returns -1 → `os_fstat`/`os_ftruncate` compile out; `access`→fopen-probe fallback already in tree) |
| `ftruncate` | `fileio.c` zero-extend fast path | CUT (conditional on `os_ftruncate`, absent without `fileno` — zero-fill loop remains) |
| `mmap/munmap` | `mmap.c` Unix branch | CUT (branch compiled out; NULL stub kept) |
| `getrlimit/sysconf` | `rlimit.c` / `mmap.c` pagemask | CUT (files/branches dropped; fixed 6 MiB spawn budget) |
| `realpath/canonicalize_file_name` | `realpath.c` | CUT (file dropped; `%include` needs no canonicalization on FAT12) |
| `time/localtime/gmtime/strftime` | `__?DATE?__`/`__?TIME?__` (`nasm.c:377-557`) | STUB to fixed epoch (deterministic output — a feature; document the macro values freeze) |
| `perror` | response-file errors (`nasm.c:1640`) | ADD (3 lines over `strerror`+`stderr`) |
| `inflate/inflateEnd/inflateInit2_` | `uncompress.c` only | CUT with the file (host-side stdmac table instead) |
| `__stack_chk_fail`, `__*_chk` | toolchain hardening | CUT (`-fno-stack-protector -U_FORTIFY_SOURCE` in cross-flags, same as `UCFLAGS`) |
| `__libc_start_main` | host CRT | N/A (`crt0._start` already serves it) |

Kernel-slot note: `libc64`/`stdio64` link into the kernel image for the
in-harness tests, so every ADD grows the kernel slot (now 230/256
sectors, 26 free ≈ 13 KB). The table above totals ~2–4 KB — fits, but
N4A.2 must `size` the kernel after each addition. The buffered-`FILE*`
item is the only one that may want its own design note.

## 4. N4A.3 size decision (analysis; decision lands with N4A.2 actuals)

- Stripped trimmed NASM today: **2,214,976 B**. FAT12 volume: 2880
  sectors = **1,474,560 B** total, ~1.457 MB usable (2×9 FAT + 14 root),
  ~40 KB used by N1/N3.5/N4B extras. **It does not fit, by ~0.8 MB** —
  and the DOS64-target static build sheds only reloc/debug overhead
  (already stripped above), not the 1.16 MB tables.
- Spawn budget is NOT the blocker: 2.2 MB payload + heap fits the 6 MiB
  proc block if sources stay small (N0 measured NASM's Linux RSS at
  ~14 MB, but that includes libc/loader; DOS64 heap needs its own
  measurement at N4A.4).
- Options (PLAN §5 N4A.3, preference order stands): (a) `ASM64.COM`
  stays the on-image tool (done, N4B — no action); (b) grow
  `VOL_SECTORS`/`IMG_MB` via the layout block — needs a cluster-size
  change past ~2 MB (FAT12/1-sector-cluster ceiling) and FAT-engine
  review; (c) ship `NASM.COM` on a second optional `dos64-tools.img`
  with a bigger FAT12 volume at the same `VOL_LBA` geometry family.
- Recommendation: decide at N4A.2 completion with the real DOS64-linked
  binary size in hand; default to (c) — it keeps the base image's
  layout block, `check-layout` arithmetic, and test-82 invariants
  untouched. Never squeeze the 256-sector kernel slot.

## 5. What N4A.2 is now (shrunk by this slice)

1. Buffered input (`fgets/fgetc/ungetc`) + `vfprintf`/`stderr` + small
   string/numeric adds in `src/libc/` (kernel-size-checked per addition).
2. Host-side stdmac decompression codegen (replace `uncompress.c`).
3. `dos64-*.patch` files only if the cross-compile surfaces a real
   incompatibility (none known after this slice — the tree degrades
   cleanly by config alone).
4. Cross-link `nasm` objects with `crt0`+`libc64`+`stdio64` via
   `userland.ld`-family script; acceptance per `docs/24-*`: no relocs,
   no GOT, no `syscall`, entry 0.
