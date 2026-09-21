# N5 audit — N2–N5 surface closure (G1–G6 style)

`docs/19-closure-g1-g6.md` closed the G1–G6 pass (77-entry `INT 21h`, real
FAT12, REPL, PIC `0x28`/`0x30`). This file audits everything added since:
the N2 execute/file/argv surface, N3 libc, N4B/N4A assemblers, and the N5
integration itself. One row per new surface: backing → test → doc.

## A1. Execute / process surface (N2)

| Surface | Backing | Test | Refs |
|---|---|---|---|
| Cooperative enter/return (`proc_enter64`, `RET`-trampoline, `AH=4Ch` convergence) | `src/kernel/proc64.asm` + `exec_caller_rsp` | 84–86 (PURE) | `docs/22-n2-exec-design.md` |
| EXEC-from-path + whole-file staging (`fs_vol_file_size64`; 4 KiB cap removed) | `src/kernel/shell64.asm` `sh_do_exec` | 90 | PLAN item 7 |
| argv (`RDI=PSP` + raw tail; `crt_parse_args`) + env defaults (`PATH=.`/`COMSPEC`) | `src/libc/crt0.asm`, `proc64.asm:1506` | 90 + §10 fix | `docs/24-c-cross-target.md` |
| Exit codes → zombie → reap → `sh_last_exit` / `%ERRORLEVEL%` | `proc_exit_current64`, `cmd64.asm` batch | 85/90 | PLAN item 7 |
| EXE64 (`'MZ64'`, 48 B hdr) + `R_X86_64_RELATIVE` relocation apply at load | `elf2exe64.py`, `proc_load_image64`, `userland.ld` `:NONE` | N4A.4 corpus | `docs/25-n4a1-trim.md` §8 |
| `.bss`-beyond-image accounting (`mem_size` hdr field) | `proc_spawn64` | §8 | `docs/25-n4a1-trim.md` §8 |
| 256 KiB child stacks (`PROC_STACK_SIZE` 2 KiB → 256 KiB) | `proc64.asm` | N4A.4 runs | `docs/25-n4a1-trim.md` §7 |
| SSE enablement (`CR4.OSFXSR/OSXMMEXCPT`) + 672 B `PSP64` (16-aligned load) | `stage2.asm`, `include/psp.inc` | all C programs | PLAN item 11 |
| Zeroed `malloc` payload (Linux-parity) | `src/libc/libc64.asm` | NASM run | `docs/25-n4a1-trim.md` §7 |

## A2. Handle file surface (N2b/N2c)

| Surface | Backing | Test |
|---|---|---|
| `3Dh` OPEN read-only + `3Eh` CLOSE over `PSP64.fd_table` (fds 0–2 console, 3–15 files) | `fs_fcb_open64`/`close64` | 87 READ-ONLY |
| `3Ch` CREATE + file `3Fh`/`40h` (byte-exact, `recsiz=1`, FAT-first commit) + `42h` LSEEK (`0..size`) | `fs_fcb_io64` | 88/89 destructive |
| Descs embed the FCB (13 qwords, no sync protocol) | `syscall64.asm` | 88/89 |

Honest refusals (locked, not TODO): `3Dh` modes 1/2, wildcards, subdirs;
`3Eh` on 0–2/double-close; `42h` outside `0..size` (no sparse).

## A3. C toolchain surface (N3)

| Surface | Backing | Test |
|---|---|---|
| `libc64` (memcpy/memset/strcmp/strlen, `printf`-subset, heap over `48h/49h/4Ah`, `exit`) | `src/libc/libc64.asm` | 91 |
| `stdio64` (`fopen/fread/fwrite/fseek/fclose`, text-mode `"t"`/`"m"`, `fo_syserr` errno) + `vsnprintf`/`vfprintf` (`F_MEM`) | `src/libc/stdio64.asm` | 92/94/95 |
| `crt0` (`_start`, `RDI=PSP` argv, BSS-zeroing for truncated NOBITS) | `src/libc/crt0.asm` | CHELLO + §10 |
| Cross-target (`-fPIE` + `userland.ld` base-0 + `objcopy -O binary`; slide-safety bar: entry 0, no relocs/GOT/`syscall`) | `Makefile`, `docs/24-c-cross-target.md` | CHELLO runs `Exit 0` |

## A4. Assembler surface (N4B/N4A)

| Surface | Backing | Test |
|---|---|---|
| `ASM64.COM` two-pass `-f bin` subset + `-o`/`-l`, exit 0/1/2 | `src/tools/`, `tools.ld`+`truncate` BSS image | 93 PURE + `make asm64-check` 4/4 |
| `NASM64.COM` (trimmed 3.02: `trim.mk`, `dos64-config.h`, raw stdmac, `dos64-nasm-shim.c`) on `dos64-tools.img` | `tools/nasm-dos64/`, `make nasm-cross` | 4/4 byte-identical + `OHELLO.COM` runs |
| `dos64-tools.img` (8 MiB, 12288-sector vol, 4 sec/clus, `SKIP_SELFTEST` kernel, reused mbr/stage2) | `Makefile` tools block, `TOOLS_LAYOUT_DEFINE` | boots/mounts/loads |

## A5. N5 integration surface (this milestone)

| Surface | Backing | Verification |
|---|---|---|
| `handler_conout` serial mirror (VGA + bounded `serial_try_putc64`, CF ignored) — closes §10 "VGA-only" gap; covers `02h/06h/09h/0Ah-echo/40h` fds 1/2 | `syscall64.asm:513` | `HELLO` + `NASM64 -v` + `AHELLO` on serial (QEMU pipe runs, 2026-09-21) |
| `HELP` tools/`%ERRORLEVEL%` lines; lookup documented root-only | `shell64.asm` `sh_help` | pipe `HELP` run |
| `PATH` semantics: stored per shell, defaulted into child env; no dir search (no subdirs — PLAN §6) | `cmd_path_set/get64`, `proc64.asm:1506` | documented in `docs/06-…` extensions |
| No new harness tests: kernel budget exhausted (full 16 B free of 256 sectors) — next kernel change opens with slot growth per N4A.3 precedent | — | smoke 89+6 / full 95/95 |

## Kernel budget wall (measured 2026-09-21, after N5.1)

| Image | Size | Free of 256 sectors |
|---|---|---|
| smoke `build/kernel.bin` | 130816 B (255.50) | 256 B |
| full `build/full/kernel.bin` | 131056 B (255.97) | **16 B** |
| lean `build/lean/kernel.bin` | — | ample |

N5.1 (mirror ~10 B text + ~118 B HELP rodata) fits. Anything further —
tests, handlers, strings — requires growing `KERNEL_SECTORS` first
(extent `[16,272)` → e.g. `[16,288)`, volume at 512 stays clear;
`make check-layout` + test 82 lock the values, same drill as N4B-pre).

## Regression record (N5 close-out)

- `make` smoke 89 + 6 SKIP, `make full` 95/95, `make lean` boots — QEMU.
- `check-layout` / `check-layout-neg` / `check-kbc` / `check-serial` /
  `check-selftest-modes` / `check-debug-symbols` green (build prerequisites).
- `check_volume_clean.py` pre/post CLEAN on smoke/full/lean.
- `make asm64-check` 4/4; `dos64-nasm.img` smoke 89 + `HELLO` `Exit 0`;
  `dos64-tools.img` `NASM64 -v` + 4/4 corpus byte-identity re-verified.
