# Tier 3 — Fundable milestones (N3 → N4 → N5)

Not attempted in one jump (PLAN §5). Each milestone below is sized S/M/L,
lands independently behind the previous tier's green suite, and states its
own acceptance. Prerequisites: N2 design (`docs/22-…`) implemented and
stable; `make` / `make full` / `make lean` green throughout.

## N3 — `libc64` shim (enables C programs generally, NASM specifically)

| ID | Milestone | Size | Acceptance |
|---|---|---|---|
| N3.1 | `src/lib/libc64.asm`: `memcpy/memset/strcmp/strlen`, `printf`-subset over `AH=02h/09h/40h`, `exit` over `AH=4Ch` (System V ABI, 16 B align, callee-saved per `stack64.asm`) | S | unit tests in harness (pure, smoke-safe) |
| N3.2 | heap `malloc/realloc/free` over `AH=48h/49h/4Ah` (`mem_alloc64` first-fit/split/coalesce) | S | alloc/free/realloc stress incl. coalesce, `mem_validate64` clean |
| N3.3 | `stdio64` over N2 handles: `fopen/fclose/fread/fwrite/fseek/ftell`, static `FILE` table (≤ 13 entries: 16 fds minus 0/1/2), read-fully-into-heap (no `mmap` — matches `docs/20-…` §2) | M | file round-trip in scratch namespace (destructive-gated) |
| N3.4 | `crt0` `_start`: build `argc/argv/envp` from the N2b convention, call `main`, return code via `AH=4Ch` | S | — |
| N3.5 | host cross-target: `gcc -ffreestanding -nostdlib -m64` + linker script → flat payload → `objcopy -O binary` → `.COM`/`MZ64` (mirrors `Makefile:171-174`); `hello.c` (puts/fopen/fwrite/malloc) runs on DOS64; `objdump` shows no Linux syscalls | M | `hello.c` demo on QEMU |

Cuts (final): `mmap` (→ heap), `realpath`/`rlimit` (→ drop), compressed-input
libz path (→ drop), `isatty` (→ honest stub).

## N4 Track B — native mini-assembler `ASM64.COM` (first)

| ID | Milestone | Size | Acceptance |
|---|---|---|---|
| N4B.1 | spec `docs/22-asm64-spec.md` (new file): directives/instructions subset, `-o`/`-l` flags, `file:line: error` format, limits sized from N0 + `TYPE` 4 KiB note | S | spec merged |
| N4B.2 | `src/tools/` two-pass `ASM64` in NASM asm (`-f bin`): parse → fixup → emit; labels, `db/dw/dq`, `mov/add/sub/jmp/call/ret/int/syscall`, `times/equ/%define`-subset, 64-bit regs; 8.3 source/output via N2 handle I/O; errors via `AH=09h`; exit codes for `ERRORLEVEL` | L | — |
| N4B.3 | ship on volume + shell demo `ASM64 HELLO.ASM -o HELLO.COM`; self-tests assemble the N1 samples and `memcmp` byte-identical vs host-`nasm` output for the subset | M | on-image `ASM64` assembles `HELLO.ASM` → working `HELLO.COM`, no host involved |

## N4 Track A — full NASM port (after B is stable)

| ID | Milestone | Size | Acceptance |
|---|---|---|---|
| N4A.1 | submodule build variant: `configure --disable-*`, keep `asm/parser/preproc`, `nasmlib` minus `mmap/realpath/rlimit`, `output/outbin.c` (+ `outelf.c` iff `MZ64` output wanted), `x86` tables pre-generated host-side (never run Perl on DOS64); patches as `nasm/dos64-*.patch` stack, not a fork | M | host cross-build of trimmed NASM succeeds |
| N4A.2 | backend swap: `nasmlib/mmap.c`, `file.c`/`fileio.c` → `stdio64` calls; `getopt`-long subset vendored | M | trimmed NASM passes its own test subset on Linux against the shim headers |
| N4A.3 | size solution from N0 numbers: (a) accept mini-assembler as the on-image tool, or (b) grow `VOL_SECTORS`/`IMG_MB` via the layout block + `check-layout` disk geometry, or (c) ship `NASM.COM` on `dos64-tools.img`. Never squeeze the 224-sector kernel slot | S | decision recorded + image boots |
| N4A.4 | on-image `NASM -f bin` assembles the N1+N4B corpus byte-identically to host NASM 3.02 | L | byte-identical corpus |

`NDISASM` explicitly deferred (no new syscalls; file as follow-up).

## N5 — Integration + hardening

| ID | Milestone | Size | Acceptance |
|---|---|---|---|
| N5.1 | shell: `ASM64`/`NASM` in `HELP`, PATH search, batch-friendly `ERRORLEVEL`, pipe-driven `make run-qemu` demo | S | `printf 'ASM64 HELLO.ASM\rHELLO\rEXIT\r'` demo |
| N5.2 | harness: assembler round-trip tests (smoke-safe: memory/scratch; destructive volume writes behind `SELFTEST_DESTRUCTIVE`); `check-serial`/`check-kbc` patterns hold | M | suite green, counts documented |
| N5.3 | docs: `README.md` shell chapter, `AGENTS.md` status + memory/disk deltas, `docs/06-…` new `3Ch/3Dh/3Eh/42h` rows, G1–G6-style audit for new surface | S | docs merged |
| N5.4 | regression: `make`, `make full`, `make lean` + `check_volume_clean.py` pre/post clean | S | all green |

Ordering: N3.1 → N3.2 → N2b-handles (if not yet done, they block N3.3) →
N3.3 → N3.4 → N3.5 → N4B.1 → N4B.2 → N4B.3 → N4A.* → N5. Track B (N4B)
validates the OS primitives Track A needs at ~1/10th the cost — do not
skip it even if full-port funding arrives early.
