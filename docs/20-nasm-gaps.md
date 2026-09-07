# N0 — NASM gap analysis: strace map + sizes + MZ64 contract

Baseline: `nasm/` @ `fbdc88565ccccfa0e8c69b21b1953d1eded02e89`
(`nasm-3.02-50-gfbdc88565`, `nasm/version` = `3.02`).
Port baseline is **NASM 3.02**. Host probe binary is system NASM 3.02
(`NASM version 3.02 compiled on Jun 30 2026`, `/usr/bin/nasm`), same
major version as the submodule. `strace` was installed sudoless via
`nix-env -iA nixpkgs.strace` (strace 7.1).

## 1. What was traced

Minimal DOS64-target probe (`org 0x100`, `bits 64`, `AH=09h` print +
`AH=4Ch` exit — the exact subset `docs/21-nasm-cross.md` blesses):

```nasm
org 0x100
bits 64
mov ah, 0x09
lea rsi, [rel msg]
int 0x21
mov eax, 0x4C00
xor ebx, ebx
int 0x21
msg db 'Hello from DOS64$'
```

Commands (both runs clean, `EXIT:0` on the happy path):

```bash
strace -f -e trace=file,mmap,munmap,mprotect,process,signal \
  -o strace.log nasm -f bin hello.asm -o hello.com
strace -f -e trace=file,mmap,munmap,mprotect,process,signal,desc \
  -o strace2.log nasm -f bin macro.asm -o macro.com -l macro.lst
```

Second probe adds `%define`/`%macro`/`%include` + `-l` listing to force
the include-search and listing-write paths. A failing include
(`inc.asm` absent) was traced deliberately to capture the error path:
`openat("inc.asm") = ENOENT` → `write(2, "error: ...")` → `unlink(output)`.

Raw logs are host scratch (not committed); the mapping below is the
committed artifact.

## 2. strace → `INT 21h` (DISPATCH64) map

Each Linux syscall NASM needs becomes one `INT 21h` handler or a named
gap. Handler numbers are `src/kernel/syscall64.asm:319-396` (`AH=00h–4Ch`).

| Linux call (observed) | NASM use | DOS64 equivalent today | Gap? |
|---|---|---|---|
| `execve("/usr/bin/nasm", ["nasm","-f","bin",in,"-o",out])` | process start with argv | `proc_spawn64` (`AH=4Bh` EXEC) takes memory image + 127 B `cmd_tail`; shell does not tokenize argv, no `EXEC-from-path` | **P0 gap (N2)**: argv convention + load-from-volume |
| `openat(in, O_RDONLY)` ×1–5 (preproc re-reads source per pass) | read source, re-read per pass, `%include` search | FCB open/read (`0Fh/14h/21h`) real; handle `3Dh` OPEN is `handler_inuse` stub | **P0 gap (N2)**: `3Dh` OPEN |
| `mmap(NULL, len, PROT_READ, MAP_SHARED, fd, 0)` + `munmap` per open | map source file (via `nasm/nasmlib/mmap.c:81` `mmap(NULL, alen, PROT_READ, MAP_SHARED, fileno(fp), astart)`) | No `mmap` analogue; `AH=48h/49h/4Ah` heap (`mem_alloc64` first-fit over `0x200000+`) is real | **P1 shim (N3)**: replace `mmap` with read-into-heap; no kernel change |
| `openat(out, O_WRONLY\|O_CREAT\|O_TRUNC)` then implicit `write`/`close` on success; `unlink(out)` on assembly error | write `.COM`/listing output; delete partial output on error | FCB create/write (`16h/15h`) real but wrong interface for C stdio; handle `3Ch` CREATE / `40h` WRITE / `3Eh` CLOSE: `40h` real, `3Ch/3Eh` are `handler_inuse` stubs | **P0 gap (N2)**: `3Ch` CREATE + `3Eh` CLOSE (`40h` already real) |
| `openat("inc.asm", O_RDONLY) = ENOENT` + `write(2, "file:line: error")` | include miss → stderr diagnostic | `AH=02h/09h/40h` consoles real (VGA `0xB8000` + bounded `serial_try_putc64`); handle 2 = stderr path via `40h` real | No gap for the message path; include *search* needs `3Dh` (above) |
| `openat("/etc/localtime")` + `read` + `lseek`/`close` | tz lookup for listing timestamps | `AH=2Ah–2Dh` date/time via CMOS RTC (`time64.asm` leaf) real | No gap |
| `lseek(fd, off, SEEK_SET/SEEK_CUR)` on source + listing | `fseek`/`ftell` in `file.c`/`fileio.c`/`listing.c` | Handle `42h` LSEEK is `handler_inuse` stub | **P0 gap (N2)**: `42h` LSEEK |
| `mmap` of `/usr/lib/libz.so.1`, `libc.so.6` + `mprotect` ×4 | dynamic loader + libz (compressed `uncompress.c` macro packages) | No ELF loader, no shared libs, no Linux-syscall emulation (explicit non-goal, PLAN §6) | By design: static `libc64` shim (N3), drop libz/compressed-input support |
| `access("/etc/ld.so.preload")`, `newfstatat("/etc/ld.so.cache")`, `fstat` | loader + `stat` family (`nasm.c`, `path.c`, `realpath.c`) | No `stat`; `FCB` search (`11h/12h`) + `23h` FILESIZE real | **P1 shim (N3)**: implement `stat`-subset over directory search; cut `realpath` |
| `exit_group(0/1)` | exit code 0/1 (error path also `unlink`s partial output) | `AH=4Ch` EXIT real (`handler_exit_process` → zombie); shell has no `ERRORLEVEL` query yet | **P1 (N2)**: propagate code zombie → reap → shell `ERRORLEVEL` analogue |
| `getrlimit`/`setrlimit` (in `rlimit.c`, not hit on this tiny run but linked) | address-space probe | No `rlimit`; heap budget is static (6 MiB spawn cap, `MEM_END_ADDR 0x800000`) | Cut: fixed-budget alloc, no kernel change |
| `readlink`/`realpath` (in `realpath.c`, linked, not hit here) | canonicalize `%include` paths | No symlinks on FAT12 | Cut for first port |
| DWARF/macho/coff backends (`output/outmacho.c`, `outcoff.c`, `outobj.c`, `outas86.c`, `outieee.c`, `codeview.c`, `dwarf/`) | `-f elf/macho/coff/obj` etc. | Only `-f bin` (flat `.COM`) + `MZ64` payload path needed | Cut at submodule build config (N4 Track A) |

Summary: **4 syscalls block everything — `3Ch` CREATE, `3Dh` OPEN,
`3Eh` CLOSE, `42h` LSEEK** (`syscall64.asm:380-386`, all
`handler_inuse` today). Everything else NASM touches on the happy path
already has a real handler (`09h` print, `4Ch` exit, `2Ah–2Dh` time,
`40h` write, `48h/49h/4Ah` alloc) or is a deliberate cut
(`mmap→heap`, `realpath/rlimit/macho/coff/dwarf→drop`).

## 3. Size measurements (host, 2026-09-07)

`size /usr/bin/nasm` (system NASM 3.02, dynamic, with libz):

```text
text    695255
data   1165769
bss      24136
dec    1885160   (0x1cc3e8, file 1874416 bytes)
```

`size -A` top sections: `.text 352990`, `.rodata 282419`,
`.relr.dyn 18504`, `.eh_frame 30184` — i.e. roughly half the `dec`
is reloc/debug/dynamic overhead a `-ffreestanding -nostdlib` DOS64
target would shed, but the remainder is still **hundreds of KiB**.

Heap high-water (`getrusage ru_maxrss`, Linux reports KiB):

| Input | `ru_maxrss` | Output |
|---|---|---|
| 124 B hello (`AH=09h/4Ch` probe) | 13856 KiB | 37 B `.COM` |
| 138912 B generated (10000× `mov rax, imm` + `ret`) | 13780 KiB | 50001 B `.COM` |

Caveat: `ru_maxrss` includes the whole process (libc, loader); NASM's
own heap is a fraction. Still, the order of magnitude stands: NASM
wants **tens of MiB of address space headroom on Linux**, while DOS64
offers a **6 MiB spawn budget** (`proc_spawn64`: `total = PSP + payload
+ 2048 < 6 MiB`, `proc64.asm:1320-1326`) under an 8 MiB identity map
(`MEM_END_ADDR 0x800000`, PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000`,
4×2 MiB). A 50 KiB payload (the 10k-line test) fits the *payload* side
trivially (`50 KiB + 664 B PSP + 2048 B stack + 1024 B env ≈ 54 KiB`),
but the assembler's *working set* (sources + tables + heap) must also
live inside the same 6 MiB proc block. Small sources (KiB-scale, the
N1 samples) fit; a full self-build of NASM's own `x86` tables does not
without paging past 8 MiB — one more reason Track B (KiB-scale
mini-assembler) precedes Track A.

Volume decision (feeds N4): the on-image FAT12 volume is 2880 sectors
(`VOL_LBA=512`, `VOL_SECTORS=2880`, `Makefile:23-28`; `build/` is
1.44 M geometry stamped by `tools/mkfat12.py`). Four files live there
today (`HELLO.TXT`, `README.TXT`, `TEST.COM`, `DATA.BIN`, ~2 KiB
total). A trimmed static NASM (hundreds of KiB even after dropping
`outmacho/outcoff/outobj/outas86/outieee/codeview/dwarf` and keeping
`outbin.c` + `outelf.c`-iff-needed) **does not fit alongside kernel
growth headroom**. Options, in preference order: (a) accept the
mini-assembler as the on-image tool (KiB-scale, fits today); (b) grow
`VOL_SECTORS`/`IMG_MB` via the layout-block change + `check-layout`
update; (c) ship `NASM.COM` on a second optional image
(`dos64-tools.img`). Never squeeze the 176-sector kernel slot.

Line counts (for scale, not exactness): `wc -l nasm/*/*.c` ≈ 53 kLOC
total including vendored `zlib/`; the PLAN §3 figure (~44 kLOC hosted C
across `asm/output/nasmlib/x86/common/disasm`) is the same tree minus
vendored deps. Either way: porting is months, the shim is weeks, the
mini-assembler is days.

## 4. `MZ64` toolchain contract (for N2/N3 builders)

Header (32 B, `proc64.asm:68-69`, verified `proc_verify_image64`,
loaded by `proc_load_image64` at `PSP+PSP_SIZE` — 664, not the `PSP+512`
of older comments; test 86 caught the drift):

| Off | Size | Field | Rule |
|---|---|---|---|
| +0 | 4 | magic | `0x34365A4D` (`'MZ64'`, bytes `4D 5A 36 34`) else treated as raw `.COM` |
| +4 | 4 | `hdr_size` | must == 32 |
| +8 | 8 | `image_size` | payload bytes after header; `> 0`, `<= size-32`, `<= 8 MiB` |
| +16 | 4 | `entry_off` | `< image_size`; entry = `PSP+PSP_SIZE+entry_off` (`.COM`: entry = `PSP+PSP_SIZE`, 664) |
| +20 | 4 | `stack_size` | `0..65536` (advisory; spawn always reserves 2048 B child stack today) |
| +24 | 8 | reserved | zero |

Entry ABI (as built; N2a keeps it, N2d extends it): image is copied
to `PSP+PSP_SIZE` (`PSP_SIZE = PSP64_size = 664`, `PROC_STACK_SIZE = 2048`,
`PROC_ENV_SIZE = 1024`, `proc64.asm:65-67`); `proc_spawn64` records
`pid/entry/stack_top = PSP+total/env` in the 16-slot table and returns
`(pid, psp)` — it never `call`s the entry today. Cooperative model
stays: child `RET` / `AH=4Ch` / `INT 20h` returns to the caller; no
timer preemption; caller preserves `RBX RBP R12–R15` + 16 B `RSP`
alignment (System V AMD64, `stack64.asm` discipline).

Argv convention (N2 target, reserved today): shell tokenizes the
command tail into the 127 B `PSP64.cmd_tail` (`psp.inc: +0xA0 len,
+0xA1 tail`, NUL-joined `argv` block + `argc` register + pointer in a
PSP extension or above-stack slot — exact register to be pinned in the
N2 patch). `cmd_tail` remains the DOS-compatible fallback; `ENV`
defaults (`PATH=.`, `COMSPEC=COMMAND64`, `env_init64`/`env_set64` at
spawn) are inherited, never replaced, until N2 says otherwise.

Env ownership: the 1024 B env block is allocated at spawn
(`mem_alloc64`, owner = PSP) and freed with the proc block; children
get a copy, never the parent's pointer.

Host cross-target recipe (N3, no kernel change): `gcc -ffreestanding
-nostdlib -m64` + linker script emitting a flat payload, `objcopy -O
binary` to `.COM`/`MZ64` (mirrors `Makefile:171-174` kernel path);
`crt0` (`_start`) builds `argc/argv/envp` from the N2 convention and
returns the code via `AH=4Ch`. Validate with `objdump`: no Linux
syscalls in the binary.

## 5. Re-estimates for N1–N3 (from N0 actuals)

- **N1 (days, no kernel risk):** unchanged. strace confirms the happy
  path needs only `open/read/write/close/lseek`-shaped I/O host-side;
  the `.COM` constraints (`org`, `bits 64`, `AH=09h/4Ch`) in the probe
  above are the doc core.
- **N2 (weeks, the hard prerequisite):** confirmed as 4 handle calls +
  `EXEC-from-path` + `call entry` + argv/exit-code plumbing. Order:
  `3Eh`-first slice (close is the smallest useful end-to-end test),
  then `3Ch/3Dh/42h`, then enter/return. Each step keeps `make` /
  `make full` / `make lean` + Bochs trio green and extends
  `check_volume_clean.py` + self-tests 84+ in the scratch namespace.
- **N3 (weeks, after N2 stable):** `libc64` (`memcpy/memset/strcmp/
  strlen`, `malloc/realloc/free` over `48h/49h/4Ah`, `printf`-subset
  over `02h/09h/40h`, `exit` over `4Ch`) + `stdio64` over the 4 new
  handle calls (static `FILE` table, read-fully-into-heap — matches the
  `mmap.c` finding) + `crt0`. No `mmap`/`realpath`/`rlimit` emulation.
