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
  bytesex.h inlines), `HAVE_SNPRINTF`/`HAVE_VSNPRINTF` (snprintf in
  `libc64`, vsnprintf in `stdio64` over an `F_MEM` memory stream),
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
  vaxprintf/axprintf` with verbatim upstream `nasmlib/asprintf.c` logic
  (vsnprintf sizing call + second formatting call, over stdio64
  `vsnprintf`; tracks `_nasm_last_string_size`), `uncompress_stdmac` (raw-blob copy),
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

(Status update 2026-09-16 — see §7 below: N4A.3 done. N4A.4 attempted;
not complete. The 2 KB stack risk flagged above was real and is now
fixed, but running NASM64.COM for the first time surfaced eight other
real bugs plus one deeper architectural gap that blocks completion.)

## §7 — N4A.3 done, N4A.4 attempted (2026-09-16)

### N4A.3: `dos64-tools.img`

Second FAT12 volume, same `VOL_LBA` (512), bigger: `TOOLS_VOL_SECTORS
= 12288` (6 MiB), `TOOLS_SEC_PER_CLUS = 4` (2 KiB clusters). Chosen so
`FATSZ` stays exactly 9 sectors — identical to the canonical volume —
so `FS_VOL_FAT_BYTES`/`FS_VOL_ROOT_BYTES` (the kernel's fixed BSS
staging buffers, `include/fs.inc`) need no size change; `FS_VOL_IOBUF_
BYTES` (32 KiB) already covers up to 64 sec/cluster. `tools/mkfat12.py`
gained `--sec-per-clus` and now computes `FATSZ` iteratively (the
classic circular FAT-sizing formula) instead of hardcoding 9 — verified
byte-identical to the old hardcoded path on the default 2880-sector/
1-sec-cluster geometry, so no existing image's bytes changed.

The volume needs its own kernel build (different `VOL_SECTORS` baked
into `layout.inc` at compile time), but `selftest64.asm` hardcodes the
canonical volume's `2880`-sector geometry in several tests (e.g. test
82's `cmp eax, 2880`) — those must not be compiled against a different
`VOL_SECTORS`. Solution: a `SKIP_SELFTEST` variant (`TOOLS_BUILD`,
mirroring `lean`) compiles that code out entirely, and a new
`LAYOUT_INC_PATH` indirection in `include/fs.inc` (`%ifndef` guard
around the `%include`, defaulting to the unchanged literal, overridable
via `-D`) lets this variant see `build/tools-img/include/layout.inc`
instead of the canonical `build/include/layout.inc`, without touching
that file, `check-layout`, or its single-source-of-truth invariant.
`mbr.bin`/`stage2.bin` are reused as-is (`stage2.asm` only ever reads
`KERNEL_LBA`/`KERNEL_SECTORS`, never `VOL_LBA`/`VOL_SECTORS`).

Verified: boots, mounts, `DIR` lists all shipped files with correct
sizes, `NASM64.COM` byte-for-byte matches the source (checked by
walking the on-disk FAT chain directly in Python, independent of the
kernel). `make tools-img` / `make run-qemu-tools` do the above from a
clean tree.

### N4A.4: on-image byte-identity — attempted, not complete

Nobody had actually *run* `NASM64.COM` before this session — N4A.1/
N4A.2 verified build-time properties only (`readelf` checks, size,
linking). Running it for real surfaced real bugs. Fixed, in order
found, each verified against the full regression trio (smoke 89/89 +
full 95/95) before moving to the next:

1. **`chello.elf` Makefile recipe missing `shim64.o`.** `LIBC_USERLAND`
   already listed it (added when `crt_envp` moved to `shim64.asm`), but
   the literal `ld` command line in the recipe was never updated to
   match — a stale-recipe bug, not a code bug.
2. **Missing `-z noexecstack`.** Mixing gcc-compiled objects (carry
   `.note.GNU-stack`) with NASM-assembled ones (don't) trips newer
   binutils' "implies executable stack" warning, fatal under
   `--fatal-warnings`. Passed explicitly on the `chello.elf` and
   `nasm64.elf` links (the objectively correct policy for freestanding
   binaries anyway).
3. **Missing `__isoc99_*` shim aliases.** `shim64.asm` had `__isoc23_
   {strtol,strtoul,sscanf}` (glibc ≥2.38/gcc ≥16 C23 redirect targets)
   but not the older, still-common `__isoc99_*` targets a gcc-13/
   glibc-2.39 host redirects `sscanf` to. Added both sets side by side.
4. **`fs_vol_read_file64` hardcoded 512 B/cluster.** Its copy-out chunk
   size was `min(512, remaining)` regardless of the volume's actual
   cluster size — correct only when `SecPerClus == 1`. On
   `dos64-tools.img` (4 sec/cluster) it silently dropped 3 of every 4
   sectors per cluster and ran out of FAT chain before satisfying the
   requested size, so EXEC of any multi-cluster file failed with "Bad
   command or file name" (a generic `cmd_exec_external64` failure
   message covering every `proc_spawn64` failure mode alike). This
   function is used *only* to stage a program image for EXEC; the real,
   general file-I/O engine used by actual DOS64 programs (`fs_fcb_
   io64`, used by the handle-based read/write syscalls) already
   computed cluster size correctly from `DPB64.clusmsk`/`.secsiz` — the
   staging helper was a parallel, less-audited duplicate of that logic.
   Fixed to match the same pattern.
5. **CR4 never set `OSFXSR`/`OSXMMEXCPT` (bits 9/10).** Only `PAE` (bit
   5) was ever set, in `stage2.asm`'s 32-bit-to-long-mode transition.
   Per x86 architecture, any SSE instruction with `CR4.OSFXSR == 0`
   raises `#UD`. gcc emits SSE instructions (e.g. `MOVAPS` for struct
   init/copy) by default for x86-64 code *regardless of whether the
   source does floating point* — CHELLO.COM/ASM64.COM's tiny code
   bodies never happened to trigger this codegen pattern, NASM's did
   immediately. Diagnosed by adding a QEMU monitor + `pmemsave`
   memory-signature-search workflow (no debugger available initially):
   `idt_fault_count` was in the tens of millions (a tight refault loop
   — the generic exception handler, `exc_common` in `idt64.asm`,
   records diagnostics and `iretq`s back to the *same* faulting `RIP`,
   so any unhandled fault loops forever rather than terminating the
   process). Fixes every future userland C program, not just NASM.
6. **`PSP64_size` (664 B) wasn't a multiple of 16.** `.COM` images load
   at `PSP + PSP_SIZE` (`proc_load_image64`), and `PSP` is always
   16-byte aligned (the heap allocator's own invariant), so the load
   address was only 8-byte aligned — breaking any SSE instruction with
   a 16-byte-aligned memory operand (found via the same fault-address
   → file-offset → disassembly workflow, landing on a `MOVAPS`).
   Widened `PSP64` to 672 B (`include/psp.inc`, +8 B of `.pad2`). The
   `664` constant was load-bearing in exactly two other places — both
   updated to `672` and re-verified: `samples/echo.asm`'s
   `PSP_SIZE equ 664` (used to recover `PSP` from `RIP` at runtime —
   `nasm-trim-check`/`asm64-check` re-verified byte-identical after the
   edit) and a **hand-assembled machine-code byte sequence** in
   `selftest64.asm` test 86's synthetic child template (`sub rax,664`
   as raw `db` bytes, `0x98,0x02,0x00,0x00` → `0xA0,0x02,0x00,0x00`).
   Rejected fixing this from `userland.ld` instead (tried first): GNU
   ld forces an output section's address to satisfy the *maximum*
   `sh_addralign` of any input section merged into it, regardless of
   the linker script's requested origin — NASM's `.text` objects
   declare align-16 unconditionally (NASM's ELF64 default), so
   `. = 0x8;` silently got rounded back up to `0x10` and fixed nothing;
   `ALIGN()`/`SUBALIGN()` overrides on the output section didn't
   override the *input* sections' own declared alignment either.
   Fixing the true source of the misalignment (`PSP_SIZE`) sidesteps
   this entirely.
7. **`malloc()` didn't zero payload.** Ported C code (NASM's
   `nasmlib/alloc.c` included) very commonly has a latent, technically-
   UB "malloc returns zeroed memory" assumption that is silently true
   on Linux (fresh `mmap` pages are kernel-zeroed) and false on DOS64's
   real, uninitialized `AH=48h`-backed allocator. Diagnosed via GDB
   (`qemu -s -S`, `target remote`): a `#GP` inside `fputs`
   (`stdio64.asm`) reading a garbage `RDI`, traced back through
   `libc64.asm`'s shared `printf`/`sprintf`/`snprintf` format-string
   core (`sp_run`) to a `%s` conversion whose `va_next()`-fetched
   argument was uninitialized heap content — plausibly leftover bytes
   from a just-freed EXEC staging buffer holding another program's
   machine code, reinterpreted as a pointer. Fixed by zeroing the
   payload in `malloc` (`libc64.asm`); `calloc`/`realloc` already
   correctly zero (or, for `realloc`, transitively benefit from the
   fix).
8. **`PROC_STACK_SIZE` was 2 KiB.** Exactly the risk this doc already
   flagged above ("NASM's preproc/eval recursion ran under an 8 MB
   Linux stack") — never load-tested until this session. Raised to
   256 KiB (`proc64.asm`); comfortably under the 6 MiB heap ceiling
   even alongside a multi-MB EXEC staging buffer for the same spawn.

After all eight, `NASM64.COM` runs *far* further than ever before —
past boot, load, string/heap operations, real computation — but still
faults (`#GP`, a garbage `%s` argument reaching `snprintf`). Root-
caused with GDB attached to QEMU's `-s -S` stub (installed this
session; the monitor+`pmemsave` workflow above was the only option
before that, and became impractical for this one — the fault is deep
inside `main()`'s startup, need real breakpoints + register/stack
inspection at the exact call site, not fault-loop signature-matching):

**Ninth issue, not fixed — architectural, and the real N4A.4 blocker:**
gcc-compiled static data that's *initialized to the address of another
static* (`nasm.c`'s `drivers[]` output-format dispatch table, an array
of `&of_bin`/`&of_ith`/`&of_srec`) is emitted as a plain compile-time
constant once the final link resolves it — a completely different
mechanism from the RIP-relative `lea reg, [rip+disp]` CODE addressing
that makes the rest of a "slide-safe" binary correctly position-
independent. `.rela.text`/`.rela.data.rel.ro` entries in the
*intermediate* `.o` (`R_X86_64_PC32`, computed at RIP-relative CODE
sites) get folded by `ld`'s final static link into fixed absolute
*data* values assuming the load address is `0` — exactly what the
existing N3.5 acceptance check (`readelf -r`: zero relocations, `.got`
empty) was designed to confirm exists, but that check only proves no
*dynamic* relocation processing is needed *at base 0*; it does not, and
cannot, prove correctness at any other load address. DOS64 always
loads `.COM` images at `PSP + PSP_SIZE`, a nonzero, heap-allocation-
dependent address that changes from run to run — so any pointer-to-a-
static baked into `.data`/`.rodata` this way is wrong the instant it's
dereferenced.

Confirmed live with GDB (`break *0x107360` at `proc_enter64`, reading
`$rdi` = PSP to compute the run's actual load base, then a breakpoint
at the exact `call snprintf` site found via the faulting return
address): the global `ofmt` (set from `drivers[]` by `ofmt_find()`)
held `0x223ce0` — the raw link-time file offset of `of_bin`, missing
the run's `load_base` entirely — so `ofmt->shortname` (offset +8) read
from address `0x223ce8`, unmapped/uninitialized memory between the
kernel's end and the heap's start, not from `of_bin`'s real,
correctly-relocatable-if-anyone-relocated-it location.
`nasm.c`'s `snprintf(temp, 128, "__?OUTPUT_FORMAT?__=%s", ofmt_alias ?
ofmt_alias->shortname : ofmt->shortname)` (in `define_macros()`,
inlined into `main`) is the specific call that first hits this; the
same class of bug likely lurks in NASM's standard-macro tables,
keyword/directive dispatch tables, and anywhere else the trimmed
source builds a `static const T * const foo[] = {&bar, ...}`-shaped
table — this is a common, idiomatic C pattern, not something specific
to one call site.

The N1/N4B hand-written-asm corpus (and CHELLO.COM/ASM64.COM) never
triggers this: hand-written NASM assembly naturally addresses other
symbols via `[rel foo]` (RIP-relative) at every use site, with no
reason to ever build a table *of* addresses as a data value. Real C
programs of any size routinely do.

Two real fixes, neither attempted this session (both are new
architectural work, not another isolated bug):

- **(a) Genuine load-time relocation processing.** Link `NASM64` (and
  in general, any non-trivial future userland C program) as a real
  position-independent executable, keeping `.rela.dyn`
  `R_X86_64_RELATIVE` entries instead of letting `ld` resolve them away
  assuming base 0. `objcopy -O binary` discards ELF metadata entirely,
  so the flat `.COM` format has nowhere to carry a relocation table —
  this likely means extending the existing `EXE64`/`MZ64`-header path
  (`proc_load_image64` already branches on it) with an embedded
  relocation table the loader walks once after copying the image in,
  adding the true load bias to each entry (the classic technique every
  real OS with position-independent loading uses). Larger scope: new
  header format, new linker-script output, new loader code, new
  verification (replacing the current "zero relocations" check with
  "relocations present and all correctly applied" some way).
- **(b) Fixed, deterministic load address.** This shell is single-
  tasking (one child process at a time) — link `userland.ld` at a
  reserved constant address instead of `0x0`, and have the loader place
  `PSP`+payload *there* directly instead of via `mem_alloc64`'s
  address-agnostic placement, so link-time and run-time addresses
  always coincide (no relocation needed because the assumption "loads
  at 0" becomes "loads at `FIXED`" and stays true). Smaller in scope
  than (a), but: shrinks the general heap by however much is reserved,
  needs its own size budget check against NASM's *internal* `malloc()`
  usage (unmeasured — a real assembler's symbol tables/token lists for
  a nontrivial source file could be substantial even though the 6 MiB
  ceiling comfortably covers `hello.asm`), and shifts the well-
  established "PSP is allocated, entry = PSP + PSP_SIZE follows from
  it" convention (relied on by `samples/echo.asm` et al.) to "entry is
  fixed, PSP = entry − PSP_SIZE follows from it" — a convention
  inversion touching the loader, not just a constant.

N4A.4 (on-image `NASM -f bin` byte-identity vs. host NASM 3.02) remains
open pending one of the above.

## §8 — Option (a) implemented: EXE64 relocations (2026-09-18)

Implemented the "genuine load-time relocation processing" option from
§7's closing list. `NASM64.COM` now ships in **EXE64 format** (magic
`'MZ64'`) instead of a plain `-f bin` flat COM — same filename, no
other userland program's format changed, kernel loader tells the two
apart by the magic bytes already present at offset 0 (`proc_verify_
image64`, unchanged logic, just extended fields).

**Header widened 32 → 48 bytes** (`EXE64_HDR_SIZE`, `src/kernel/
proc64.asm`), backward-compatible in spirit (`reloc_count == 0` behaves
exactly like the old format did) but not in bytes — `hdr_size` itself
is part of the validated header, so old 32-byte hand-built headers
would (correctly) now be rejected. Only test fixtures exist in that
shape (selftest64.asm tests 31/73), both updated to the new layout and
re-verified. New fields:
- `+24 reloc_count` (4B): 0 for every existing plain image.
- `+28 reloc_off` (4B): file offset to the reloc table; validated to
  equal `hdr_size + image_size` (the table always immediately follows
  the payload — no gap, nothing to configure).
- `+32 mem_size` (8B): total memory footprint from the load address,
  covering `.bss` beyond the copied payload. This *also* fixes a
  separate, independent, pre-existing bug found while designing this:
  `proc_spawn64` sized its allocation from `image_size` alone (COM:
  file size; old EXE64: same field) with no accounting for `.bss` —
  `objcopy -O binary` never emits file bytes for `.bss` (NOBITS), so
  any program whose `.bss` extends past its own file size was already
  under-allocating its own process block, letting `crt0.asm`'s BSS-
  zeroing loop write past the allocated region into whatever heap
  content came next. Never observed failing in practice (`CHELLO.COM`'s
  ~1.3 KiB overflow apparently always landed in free heap space) but a
  real, general-purpose memory-safety gap independent of NASM. EXE64
  images now size their allocation from `mem_size`; plain COM images
  are unaffected (still no header, still no way to tell the loader
  about a `.bss` need) — this specific fix only reaches programs
  shipped as EXE64, i.e. currently just `NASM64.COM`.
- Each reloc table entry: 16B, `(dest-relative offset: 8B, base-0-
  linked addend: 8B)`. Loader (`proc_load_image64`) writes `dest +
  addend` to `dest + offset` for every entry, once, right after copying
  the payload in and zeroing the `.bss` gap — the standard
  `R_X86_64_RELATIVE` fixup, applied by hand (no ELF/dynamic-linker
  machinery exists in this kernel; this is the whole of what it needs).

**Build side**: `NASM_X_ELF` now links with `-pie` (`Makefile`) instead
of a plain link, so `ld` keeps `.rela.dyn`'s `R_X86_64_RELATIVE`
entries instead of resolving them away assuming load address 0 — the
exact mechanism that made every prior attempt at running `NASM64.COM`
read garbage from `nasm.c`'s `drivers[]` output-format dispatch table
(`static const struct ofmt * const drivers[] = {&of_bin, ...}`: `&of_
bin` is computed correctly at any address via a RIP-relative `lea` at
the *use* site, but *storing* that computed value into a static array
element bakes in a plain number, correct only for whatever load base
the linker assumed — verified live with GDB, see §7). `-pie` alone
isn't enough: it also pulls in real-dynamic-linker scaffolding this
loader has no use for (`.interp`/`.dynsym`/`.dynstr`/`.hash`/`.gnu.
hash`/`.dynamic`, ~350 B, harmless) and, materially, positions `.rela.
dyn` itself address-contiguous with `.rodata`/`.data` by default —
since every image here extracts its flat payload via `objcopy -O
binary`, which copies every byte from the lowest to the highest
*loaded* address, `.rela.dyn` left in the middle would be copied into
the payload as inert bytes *as well as* being correctly parsed into
the new EXE64 reloc table, wastefully double-counting it (measured:
+1.6 MiB, roughly matching `.rela.dyn`'s own size counted twice). Fixed
in `src/libc/userland.ld`: `.rela.dyn` is placed in its own output
section assigned to `:NONE` (no `PT_LOAD` segment) — note `:NONE` is
required, not just omitting a `:text`/`:data` suffix, since GNU ld's
default orphan-section placement otherwise silently continues the
*preceding* section's segment (confirmed via `readelf -l`, twice, the
first attempt without `:NONE` didn't work) — and `elf2exe64.py` passes
`objcopy -R .rela.dyn` on top, since `:NONE` only fixes `mem_size`
(what a real loader would map), not `image_size` (what `objcopy`'s
flat extraction still sees as address-contiguous SHF_ALLOC content
regardless of segment membership).

**New tool**: `tools/nasm-dos64/elf2exe64.py` — reads the `-pie`-linked
ELF's program headers (for `mem_size` and to sanity-check the `-pie`
link actually happened, i.e. `ET_DYN`) and `.rela.dyn`'s raw content
(rejecting anything other than `R_X86_64_RELATIVE`, which would mean a
real dynamic symbol import/export snuck into the `-nostdlib` link and
this loader genuinely cannot satisfy it), calls `objcopy -O binary -R
.rela.dyn` for the flat payload (byte-identical to the plain-COM path
for the parts it already got right), and assembles the final EXE64
file: 48B header + payload + reloc table.

**Verified**: `readelf -l` confirms `.rela.dyn` outside both `PT_LOAD`
segments post-fix; `elf2exe64.py` reports `image_size` byte-identical
to the plain non-`-pie` build (2,326,420 B, matching the pre-`-pie`
measurement exactly) with 40,336 relocations (645,376 B table) and
5,856 B of `.bss` (matching the `text+data+bss` ELF summary within
alignment rounding); smoke (89/89) and full (95/95) suite re-verified
green with `NASM64.COM` rebuilt in the new format; `nasm-samples`
(`CHELLO.COM`/`ASM64.COM`, both still plain COM) re-verified unaffected
by the `userland.ld` changes; live with GDB, confirmed `ofmt` (global,
set from `drivers[]`) now holds `load_base + 0x223ce0` (the correctly
relocated address) rather than the raw `0x223ce0` file offset seen
before the fix.

**Not yet fixed — N4A.4 still open**: with the position-independence
bug fixed, `NASM64.COM` progresses measurably further (through the
`ofmt`/`drivers[]`-dependent startup code that used to fail
immediately) but still eventually faults (`#GP`, `cmpb $0x0,(%rsi,
%rcx,1)` — a generic strlen-style loop, confirmed instruction-accurate
by disassembling starting exactly at the live fault address rather
than trusting a linear sweep from offset 0, which desyncs into
garbage across the large data regions nearby). This looks like a
*shared* helper called from many sites — a GDB breakpoint on the raw
address caught an early, successful call (a valid `RSI`) rather than
the one specific invocation that eventually receives a bad pointer and
faults, so pinning down the actual bad *caller* needs a conditional
breakpoint or watchpoint keyed on the bad value, not the address alone
— not yet attempted. Given the `ofmt`/`drivers[]` bug is now fixed and
was verified to be exactly the "static data initialized to the address
of another static" pattern the relocation mechanism targets, and NASM
has many more instances of that same C idiom (standard-macro tables,
keyword/directive dispatch, output-driver tables beyond just `ofmt`),
the leading hypothesis is a *different instance of a bug the
relocation fix does not itself have room to leave unfixed* — i.e. most
likely a *second, distinct* uninitialized-memory or argument-count
issue (in the vein of the `malloc`-zeroing fix from §7) rather than a
gap in the relocation mechanism itself, though this is not yet
confirmed. Recommended next step: a conditional GDB breakpoint at the
 fault address that stops only when `RSI` is non-canonical or points
 outside `[load_base, load_base+mem_size)`, to isolate the specific
 call site the way the return-address technique in §7 isolated the
 `ofmt` bug.

## §9 — `vsnprintf` + upstream-parity `nasm_vaxprintf` (candidate for the §8 fault)

`stdio64.asm` gains `vsnprintf` (new `F_MEM` memory-stream kind: the
`stream_putc` mem path counts `len` as would-have-written while storing
at most `cap = size-1` bytes + NUL; `stream_slot` accepts the stack
`FILE64` via a custom path gated on 8-alignment + `F_INUSE` + `F_MEM`)
and `fprintf`'s hand-built `va_list` is corrected to the ABI-faithful
shape (`gp_offset = 16`, `RDX` at `reg_save[16]` — the old compact
`gp_offset = 0` layout read two zero-pad slots as phantom 5th/6th reg
args for calls with 5+ varargs). `dos64-nasm-shim.c`'s `nasm_vaxprintf`
then drops its `vfprintf`-into-heap-image workaround (which could never
have worked: the old `stream_slot` rejected stack `FILE*`, so every
call returned −1 → `NULL`) and follows upstream `nasmlib/asprintf.c`
verbatim (vsnprintf sizing call + second formatting call).
`HAVE_VSNPRINTF` now means "provided by stdio64", not "unneeded".
Why this is a candidate for the §8 `#GP`-in-`strlen` fault: every
`nasm_vaxprintf` caller (`strlist.c` et al.) received `NULL` under the
old code — the exact shape (bad pointer into a shared string helper)
§8 observed. Smoke 89/89 + full 95/95 + `nasm-cross` re-verified;
kernel still 255/256 sectors. On-device `NASM64.COM` run (tools-img)
still needed to confirm N4A.4 closes.

## §10 — N4A.4 closed: argv + text-mode fixes, on-device byte-identity (2026-09-20)

First on-device run after §9 (QEMU `dos64-tools.img`, QMP `send-key`
typing, VGA read back via GDB dump of `0xB8000` — see below for why
GDB was needed) showed `NASM64.COM` alive but sick: bare/`-v` runs
exited 1 printing `nasm: fatal: no input file specified` (correct
behavior for zero args — but `-v` was passed), and any real assemble
died with `unable to open input file`. Two independent bugs, both in
code no earlier program had ever exercised:

1. **`crt0 `_start` never set `RDI=PSP` before `crt_parse_args`.**
   After the BSS-zeroing `rep stosb`, `RDI` holds `_bss_end`; the
   existing `mov rdi, rbx` sat one call too late (before
   `crt_parse_env`, which always worked). The parser therefore read
   `cmd_len` from zeroed BSS as 0 and every C program silently saw
   `argc=1`. One-line fix (`mov rdi, rbx` before the argv call).
   Why hidden until NASM: the N3.4 host harness calls the parsers
   directly with explicit `RDI` (correct), `CHELLO.COM` ignores
   `argv`, and `WRITE.COM` reads the PSP tail by hand, never via
   `crt0` — NASM is the first crt0 program that uses `argv`.
2. **`stdio64 `fopen` rejected text mode.** NASM opens inputs
   `NF_TEXT` (`"rt"`, and `"rtm"` first — the glibc mmap hint,
   emitted because `__linux__` stays defined under `-ffreestanding`).
   `fopen` accepted only `""`/`"b"` as `mode[1]` and returned `NULL`
   before ever reaching `3Dh` (confirmed: GDB breakpoint at
   `handler_open_file` never fired). Fix: accept `'t'`
   (translation-free — DOS64 does no CRLF mapping, binary-clean),
   ignore a trailing `'m'` (streams always slurp, so the hint is a
   no-op), set `errno=EINVAL` on genuinely bad modes, and map
   open/create failures via `fo_syserr` (`2→ENOENT/4→EMFILE/5→EACCES`)
   so C diagnostics (`strerror(errno)` fatals) read correctly.

Test 92 (destructive) covers both: the §(d) readback now opens
`"rtm"` (`t92_rtm`, content-verified by the existing
`fread`+`memcmp`), and §(f) asserts a missing-file open returns
`NULL` with `errno==ENOENT`. Kernel still fits: smoke 255.25/256,
full 255.72/256 (384/144 B free — the next kernel change still opens
with slot growth per §6).

**N4A.4 acceptance, all on `dos64-tools.img` under QEMU:**
`NASM64 -v` → `NASM version 3.02 ...`, `Exit 0`; `NASM64 -f bin
<HELLO,ECHO,CAT,WRITE>.ASM -o O<...>.COM` → four `Exit 0`s;
extracting the outputs by direct on-disk FAT-chain walk and `cmp`
against host NASM 3.02 output: **4/4 byte-identical**
(37/63/186/137 B). Closing the self-hosting loop, the
on-device-assembled `OHELLO.COM` runs: `Hello from DOS64`, `Exit 0`.
Regression trio green: smoke 89 + 6 SKIP, full 95/95, lean boots;
`check_volume_clean.py` CLEAN on all three base images;
`asm64-check` 4/4; `dos64-nasm.img` smoke 89 + `HELLO` `Exit 0`.

Known limitation surfaced by this diagnosis (not fixed here):
child console output (`AH=02h/09h`, `AH=40h` fds 1/2 via
`handler_conout`) is **VGA-only** — absent from `-serial stdio`,
so NASM's messages were read via a GDB VGA dump. N5 candidate:
mirror `handler_conout` through the bounded `serial_try_putc64`
(check-serial-compatible by construction).
