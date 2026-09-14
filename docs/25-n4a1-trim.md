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

## 3. libc gap table (N4A.2 work list — all landed; see §5/§6 record)

Derived from `nm -D /usr/bin/nasm` (full-build undefined set; the trim
drops only `qsort` via `outmacho.c` — everything else below is linked by
the kept core, verified by grep). `HAVE` = in `libc64`/`stdio64` today.

| Symbol | Used by (kept core) | DOS64 plan |
|---|---|---|
| `malloc/calloc/realloc/free`, `memcpy/memmove/memset/memcmp`, `strlen/strcpy/strncpy/strcmp/strncmp/strcat/strchr` | everywhere | HAVE (`libc64.asm`) |
| `fopen/fclose/fread/fwrite/fseek/ftell/fflush/feof/ferror` | `file.c`, preproc, listing | HAVE (`stdio64.asm`) |
| `printf/sprintf/snprintf`, `puts/putchar`, `exit` | diagnostics, `exit_group` path | HAVE (`libc64.asm`) |
| `snprintf/vsnprintf/strlcpy/strnlen` | `compiler.h` fallback decls | VENDORED (`nasm/stdlib/*.c` compile when `HAVE_*` absent — free) |
| `mempcpy` | `nasmlib/string.c` et al. | ADD in shim (over `memmove`; `HAVE_MEMPCPY` defined to kill compiler.h's clashing inline) |
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
in-harness tests, so every ADD grows the kernel slot (245/256 sectors
after N4A.2b + test 95, 11 free ≈ 5.6 KB — was 230/256 at N4A.1,
239/256 at N4A.2a).
The table above totals ~2–4 KB — fits, but N4A.2 must `size` the kernel after each addition. The buffered-`FILE*`
item is the only one that may want its own design note.

## 4. N4A.3 size decision (analysis; decision lands with N4A.2 actuals)

- Stripped trimmed NASM today: **2,214,976 B**. FAT12 volume: 2880
  sectors = **1,474,560 B** total, ~1.457 MB usable (2×9 FAT + 14 root),
  ~40 KB used by N1/N3.5/N4B extras. **It does not fit, by ~0.8 MB** —
  and the DOS64-target static build sheds only reloc/debug overhead
  (already stripped above), not the 1.16 MB tables.
- DOS64-linked actual (N4A.2d, `make nasm-cross`): **NASM64.COM
  2,323,668 B** (text 419 KB, data 1.9 MB — the `.data.rel.ro` pointer
  tables; slide-safe: entry 0, no relocs, no GOT, no `syscall`).
  Confirms the analysis: ~0.9 MB over the volume. Decision: **(c)** —
  ship on a second optional `dos64-tools.img`. Never squeeze the
  256-sector kernel slot (which closed N4A.2 at 255/256 — see §6).
- Spawn budget is NOT the blocker: 2.3 MB payload + heap fits the 6 MiB
  proc block if sources stay small (N0 measured NASM's Linux RSS at
  ~14 MB, but that includes libc/loader; DOS64 heap needs its own
  measurement at N4A.4).
- Options (PLAN §5 N4A.3, preference order stands): (a) `ASM64.COM`
  stays the on-image tool (done, N4B — no action); (b) grow
  `VOL_SECTORS`/`IMG_MB` via the layout block — needs a cluster-size
  change past ~2 MB (FAT12/1-sector-cluster ceiling) and FAT-engine
  review; (c) ship `NASM.COM` on a second optional `dos64-tools.img`
  with a bigger FAT12 volume at the same `VOL_LBA` geometry family.
- Recommendation: (c) — it keeps the base image's layout block,
  `check-layout` arithmetic, and test-82 invariants untouched. Never
  squeeze the 256-sector kernel slot.

## 5. What N4A.2 was (done 2026-09-13; was "shrunk" list, now record)

1. Buffered input (`fgets/fgetc/ungetc`) + `vfprintf`/`stderr` + small
   string/numeric adds in `src/libc/` — done (tests 94/95).
   Supplement (found at cross-link): full `printf`-family subset in all
   three engines — flags `-`/`0`, width (`*`/digits), precision
   (`.`/`.*`), lengths `h`/`l`/`ll`/`z` (64-bit), `%o` — because kept
   sources use `%02X`/`%08x`/`%-20s`/`%li`/`%zu`/`%lld`/`%o`/`%p`
   (measured inventory, §3 table extended in code comments). Verified
   host-side against the real objects (48-verb `printf`, `sprintf` incl.
   `snprintf` bounds, `vfprintf` over a real `va_list`), plus on-device
   test-94 (`sprintf`) and test-95 (`fprintf` to file) extensions.
2. Host-side stdmac codegen — done: `tools/nasm-dos64/stdmac-raw.pl` +
   `make nasm-stdmac-raw` (17 packages, all `dsize == zsize`; submodule
   read-only, output under `build/nasm-raw`).
3. `dos64-*.patch` files: NONE NEEDED — the tree degrades cleanly by
   config + the two mechanism fixes below. No fork, no patch stack.
4. Cross-link — done: `make nasm-cross` (N4A.1 acceptance). 69 kept
   objects + `dos64-nasm-shim.c` + `crt0`/`libc64`/`stdio64`/`shim64`
   via `userland.ld` → slide-safe `NASM64.COM` (see §6).

## 6. N4A.2d cross-link record (2026-09-13)

Recipe (`make nasm-cross`; experiment script was `/tmp` scratch):
throwaway copy → host `autogen/configure/make nasm` (generated
`*.ph`/tables only) → raw stdmac overwrite → cross-compile kept set
with `NASM_XCFLAGS` (trim.mk) → `ld -T userland.ld` → `objcopy -O binary`.

Mechanism fixes required (all in-repo, none in the submodule):
- `dos64-config.h`: `HAVE_MEMPCPY` (we provide it; kills compiler.h's
  clashing `static inline`), `HAVE_HTOLE16/32/64` (glibc macros vs
  bytesex.h inlines), `HAVE_SNPRINTF`/`HAVE_VSNPRINTF` (we provide
  snprintf; vsnprintf unneeded — asprintf reimplemented),
  `__NO_CTYPE` (glibc macro→`__ctype_b_loc` unavailable; real
  functions in shim64 instead), `inline`→`inline` (unknown.h would
  `#define` it away, multiplying every `extern_inline` definition).
- Flags: `-fgnu89-inline` (with the above, `extern_inline` emits no
  out-of-line copies except ilog2.c's), `-U_FORTIFY_SOURCE`
  (no `__*_chk`), `-Wno-comment` (generated macros.c).
- `shim64` additions: `mempcpy`, `memchr`, `strpbrk`, `atoi`,
  `isspace/isdigit/isalpha/isalnum/isxdigit/iscntrl/ispunct`,
  `tolower/toupper`, `fileno`/`_fileno` (-1, honest: stat path compiled
  out but callers evaluate it), `__isoc23_strtol/strtoul/sscanf`
  aliases (glibc ≥2.38 C23 symbols under gcc 16), `errno` already had.
  (`abs` lives in dos64-nasm-shim.c: `abs` is a NASM keyword and cannot
  be an asm label.)
- `dos64-nasm-shim.c` (new, cross-flags C): `nasm_vasprintf/asprintf/
  vaxprintf/axprintf` over `vfprintf` into a heap image (tracks
  `_nasm_last_string_size`), `uncompress_stdmac` (raw-blob copy),
  `nasm_realpath` (`nasm_strdup`; FAT12 has no symlinks),
  `nasm_get_stack_size_limit` (`SIZE_MAX`, like upstream's fallback),
  `abs`.
- Dropped (trim.mk `NASM_DOS64_DROP`): `realpath.c`, `rlimit.c`,
  `uncompress.c`, `asprintf.c`, `vsnprintf.c`, `zlib/`.
- Kept as-is by config: `mmap.c` (NULL stub), `file.c` (pure-stdio
  fallbacks), `fileio.c` (zero-fill loop; ftruncate branch out).

Result: `NASM64.COM` 2,323,668 B — entry `0x0`, no relocations, no
`.got`, no `syscall` (all asserted by the target). 71→69 compiled
objects (2 dropped) + shim + libc.

Kernel-slot pressure (all libc links into the kernel for the harness):
smoke 230→255/256, full 230→255/256 through N4A.2 (format engines ≈
5 KB, shims ≈ 2 KB, tests ≈ 2 KB). **1 sector free.** Any further
kernel change (including N4A.4 debug) must open with the slot-growth
procedure (PLAN item 8 pattern: relocate scratch first, then bump
`KERNEL_SECTORS`; test 82 + `check-layout` lock it). The cross-link
itself needs no kernel change.

Next (not this slice): N4A.3 `dos64-tools.img` (bigger FAT12 volume
for the 2.3 MB binary) → N4A.4 on-image `NASM -f bin` byte-identity
corpus → N5 integration. The 2 KB child stack (`PROC_STACK_SIZE`,
`stack_size` advisory 2048) is the top N4A.4 risk after delivery:
NASM's preproc/eval recursion ran under an 8 MB Linux stack; measure
heap/stack high-water on first execution.
