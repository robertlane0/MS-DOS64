# Phase 10 Completion Report — Command Interpreter (COMMAND64)

**Date:** 2026-09-05
**Branch:** `main` (building on Phase 9 `8559b37`)
**Target:** Bochs 3.0 (ryzen) + QEMU, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 10 (AGENTS.md §Phase 10) is **complete and verified**.
DOS 1.25's `COMMAND.ASM` (2165 lines: resident + init + transient,
`COMTAB`, `SWITCH`/`DELIM`/`SCANOFF`, `CATALOG`/`ERASE`/`RENAME`/`TYPEFIL`/
`COPY`/`PAUSE`/`DATE`/`TIME`/`COMLOAD`/`EXELOAD`, batch `%1..%9` with
`GETBATBYT`) is now a flat 64-bit `COMMAND64` module (`src/kernel/cmd64.asm`):
RIP-relative near dispatch (no segments, no FAR, no BIOS `INT`), native
VGA/ATA/KBD drivers (Phase 5), `MCB64` heap (Phase 6), FAT12 `DIRENT` layout
(Phase 7), `PSP64`/ENV/`proc_spawn64` EXEC (Phase 8), `INT 21h` conventions
(Phase 9).

8 new tests extend the harness to **50 total — all 50 PASS** on Bochs and QEMU,
no `#UD/#GP/#PF`, no BIOS calls, no triple faults.

```
 Bochs / QEMU serial.log after Phase 10 (tail):

  [43] Parser SCANOFF/DELIM/SWITCH/drive... PASS
  [44] DIR format + TYPE ^Z... PASS
  [45] COPY/DEL/REN fileops... PASS
  [46] CLS/VER/PROMPT/PATH/REM/PAUSE... PASS
  [47] DATE/TIME get/set/parse... PASS
  [48] External EXEC via spawn... PASS
  [49] Batch open/next/expand... PASS
  [50] Dispatch + stress... PASS

 Summary: 50 passed, 0 failed
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
 Phase6 memory management (MCB64): ALL TESTS PASS
 Phase7 filesystem adaptation (FAT12): ALL TESTS PASS
 Phase8 process management (PSP64): ALL TESTS PASS
 Phase9 syscall interface (INT 21h): ALL TESTS PASS
 Phase10 command interpreter (COMMAND64): ALL TESTS PASS
```

> Diagnostic note: `[30]/[32]/[33]` still emit single-letter progress markers
> (`A–N`, `a–h`, `p–$`) before `PASS` (fail-point isolation, cf. Phase 8).
> Phase 10 tests emit no markers on pass (clean `... PASS`); temporary
> `cmd_dbg_putc` COM1 markers (`A–O`, `a–g`) were used during bring-up to
> isolate the `[47]` hang and `[49]` short-read, then removed.

---

## 1. Scope (AGENTS.md Phase 10 checklist)

| Requirement | Implementation | Test |
|---|---|---|
| Command-line parser (64-bit string handling) | `cmd_parse_line64` (leading-delim skip, optional `X:` drive strip, 8-char upper token, `/W/P/V/A/B` scan, 127B tail), `cmd_skip_delims64` (`SCANOFF`), `cmd_is_delim64` (`DELIM`: space `= , ; TAB`), `cmd_parse_switches64` (`SWITCH`, `SWLIST BAVPW` bits `W=1/P=2/V=4/A=8/B=0x10`), `cmd_toupper_buf64`, `cmd_strlen64` | `[43]` leading spaces, lower→upper, `C:DIR`, empty, delims, `/W /P`, bad ptr |
| `COMTAB` lookup | `cmd_table_lookup64` + `cmd_streq_upper` (`REPE CMPSB` analog, tolerant lower): DIR, RENAME/REN, ERASE/DEL, TYPE, REM, COPY, PAUSE, DATE, TIME, CLS, VER, PROMPT, PATH, ECHO → handler RIP, 0 unknown | `[43]` indirectly; `[48]` unknown→0, DIR→non-0; `[50]` dispatch routing |
| DIR | `cmd_dir_format64` (32B entries, skips `0xE5`/`0x00`-end, `NAME.EXT size\r\n`, `/W` 5-per-line + trailing CRLF, `fs_dir_get_size64` for size, `cmd_u32_to_dec` decimal) | `[44]` 2 files normal + `/W`, bad ptr → −1 |
| TYPE | `cmd_type_buffer64` (copy until `0x1A` `^Z`, NUL-terminate) | `[44]` `HELLO^Z`→5 + NUL, plain→4 |
| COPY | `cmd_copy_buffer64` (binary or ASCII-stop-at-`^Z` via `SW_A`) | `[45]` 8B binary, `ABC^Z`→3 |
| DEL/ERASE | `cmd_del_entry64` (exact 11B match, mark `0xE5`, 1 not-found) | `[45]` del ok + `0xE5`, missing→1 |
| REN/RENAME | `cmd_ren_entry64` (dup-check new, find old, 11B `rep movsb`, 1 not-found / 2 dup) | `[45]` ren ok (`N...`), dup→fail, missing→fail |
| CLS | `cmd_cls64` (`vga_clear`) | `[46]`, `[50]` via `cmd_dispatch64` |
| VER | `cmd_ver64` (`MS-DOS64 1.25-64, Command v1.17-64H`, small-buf fail) | `[46]` content `M...`, 4B→fail, null→fail |
| PROMPT | `cmd_prompt_set64/get64` via `cmd_env` (`PROMPT`, default `$P$G`) | `[46]` set/get `$...` |
| PATH | `cmd_path_set64/get64` via `cmd_env` (`PATH`, default `.`) | `[46]` set/get `/...` |
| DATE/TIME | `cmd_date_get64` (`YYYY-MM-DD`), `cmd_date_set64` (1980–2099, leap `%4`, per-month days), `cmd_date_parse64` (`MM-DD-YY[YY]`, `MM/DD/YYYY`, 2-digit→1900+), `cmd_time_get64` (`HH:MM:SS`), `cmd_time_set64` (23/59/59), `cmd_time_parse64` (`HH[:MM[:SS]]`, bare-hour ok); defaults 1983-04-01 12:00:00 | `[47]` defaults format, leap 1984-02-29 ok / 1983-02-29 fail, month 13 / day 0 fail, parse ok/bad, time set/parse ok/bad |
| PAUSE/REM/ECHO | `cmd_pause64` (prints `PAUSMES`, no blocking wait in test), `cmd_rem64` (no-op), `cmd_echo64` (prints or no-op) | `[46]` all return 0 |
| External execution | `cmd_exec_external64` → `proc_spawn64` (COM, default env; caller terminates/reaps) | `[48]` COM spawn pid/psp + terminate/reap, null/0-size→0 |
| Batch processor | `cmd_batch_open64` (copy script ≤1024, split params space/`TAB , ; =` into 10 slots + `cmd_batch_param_buf`), `cmd_batch_next64` (CRLF/`0x1A`/EOF, `-1` EOF + `active=0`), `cmd_batch_expand64` (`%1..%9`→slot `N-1`, `%0`→empty, `%%`→`%`), `cmd_batch_close64` | `[49]` `DIR %1`→`DIR ARG1` (8), `%%`→`%`, REM passthrough, EOF −1, `%2`→4, oversize→fail |
| Dispatch + stress | `cmd_dispatch64` (parse + lookup; direct `CLS`/`VER`, `REM`/`PAUSE`/`ECHO` no-op, file builtins parsed-ok, unknown→2, empty/null→1) + 50× mixed stress + `mem_validate64` | `[50]` DIR/dir/REM/CLS/VER→0, FOOBAR→2, empty/null→1 |

New exports (`cmd64.asm`, 47 globals): `cmd_init64` (ENV `PATH`/`COMSPEC`/`PROMPT` + date/time + batch reset), string/parser group, `cmd_table_lookup64`/`cmd_streq_upper`/`cmd_dispatch64`, all builtins above, batch group, 8× `cmd_test_*`, `cmd_dbg_putc` (kept, unused), `cmd_env/year/month/day/hour/min/sec` BSS.

---

## 2. What Was Built

### 2.1 `cmd64.asm` — parser + `COMTAB64` + builtins + batch

- **Conventions:** System V (`RDI/RSI/RDX/RCX/R8/R9`), `RAX` 0 ok / 1 fail (counts/`-1` where noted: `dir_format` files/`-1`, `type/copy` bytes/`-1`, `batch_next` len/`-1`, `exec` pid/0). Preserves `RBX/RBP/R12–R15`; `R8–R15` temps; `cld` before string ops; `DEC/JNZ` (no `LOOP`); `DIV` replaces `AAM/AAD` (`OUT2`/`GETNUM`); `REP MOVSB` with `RSI`=src/`RDI`=dst; no segments/FAR/BIOS.
- **FS integration:** DIR size via `fs_dir_get_size64` (`RBX`=entry); `DIRENT` offsets from `include/fs.inc` (32B entries, `+26` firstclus, `+28` size, `+11` attr, `0xE5`/`0x00`); `ENV` via `env_init/set/get`; EXEC via `proc_spawn/terminate/reap`; output via `vga_clear/print`.
- **Batch params:** slots hold offsets into `cmd_batch_param_buf`, `-1` = empty (offset 0 is valid); `%N` (`N`≥1) → slot `N-1` (DOS `%0`=batch name → empty here); `%%` escape; `open` takes exact `strlen` (not padded 64 — trailing NULs are not script).
- **Buffers (BSS):** `cmd_env` 1024, `cmd_batch_buf` 1024 + `params` 10×8 + `param_buf` 256 + `tmp_line` 256, `cmd_test_dirbuf/out/file` 512, `cmd_test_com` 1024, `cmd_dir_flags` 1.

### 2.2 `main.asm` — 42 → 50 tests

`hello_phase10`, `msg_test43–50`, `msg_phase10_ok/fail`; 8 blocks mirroring prior style (`vga_print` + `serial_print64`, `R12` pass / `R13` fail); summary/exit now includes `msg_phase10_*`; `print_num` handles 50 (tens+ones).

### 2.3 Capacity — still 128 sectors

Kernel `36364→45932 B` (71→89 sectors). `stage2.asm KERNEL_SECTORS 128` (64 KiB, `0x100000–0x110000` ⊂ 0–8 MiB map) and `Makefile` 128-sector check unchanged. Image layout unchanged (`MBR@0`, `stage2@1`, `kernel@16`; scratch `200`/`500+` safe — see §3 bug 7).

---

## 3. Bugs Found & Fixed (via QEMU serial + Bochs + GDB `kernel.elf`)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `[44]/[45]` FAIL (DIR 0 files, DEL miss) | Test `rep movsb` had `RSI`/`RDI` swapped (`RDI`=src) — copied garbage→literals, `dirbuf` stayed NUL (end), and corrupted `t44_name*` | `RSI`=src, `RDI`=dst in all 5 dir/fileops setups |
| 2 | `[44]` TYPE len wrong / `[45]` COPY garbage | `BL`/`RBX`-as-index vs char (`type`) and `CL`/`RCX`-as-size vs char (`copy`) clobbers | `R8/R9` (`type`), `R9B` + `R12/R13` lens (`copy`) |
| 3 | `[44]` DIR count/wipe | `ECX` loop index clobbered by `mov ecx,5` (wide `div`) + `R8` flags clobbered by `mov r8,8/3` (trim) + `ESI`=out-ptr mixup in `u32` call | `R9` index, `cmd_dir_flags` mem byte, `ESI`=size/`RDI`=out |
| 4 | `[49]` `%1`→empty (len 4 not 8; `param_buf` = `NUL R G…`) | `mov rax,rdi` for offset destroyed `AL` (char) before `mov [rdi],al` — first char of each param stored address low byte (`NUL`) | Save char in `R11B` across offset math |
| 5 | `nasm` error `cannot use high byte register` (`mov [r12+3],ah`) | `AH/BH/CH/DH` cannot encode with REX (`R12` needs REX) | `DL` temps (`mov dl,ah`) + legacy `RBX` out in `date_get`; `DL` stores with `R12` (low-byte + REX ok) |
| 6 | `[47]` hang after `D` (no `E`; GDB would spin in `#PF→iretq→#PF`) + wrong leap (1984→1986) | (a) `AL=month` + `AX=year` overlap in `days_in_month` ABI (year low clobbered → 1986, 28 d); (b) early-`ret` in `date_set` skipped 4 pops → `ret` to saved `R14` → `#PF` loop; (c) `[rsp+N]` out-ptr math in first `date_get` wrote to caller-`RDX` garbage → `#PF` loop | (a) `RDI=year`/`RSI=month` ABI; (b) validate before push, `bad_pop` path pops; (c) `R12` out rewrite |
| 7 | `[49]` EOF never (`len 64` incl. padding NULs scanned as content) + `%2`→slot2 (empty) vs `ARG2` | (a) `open` len 64 counted `times 64` zero pad; `next` only stops at `CR/LF/1A`/end, NUL copied → extra empty line; (b) `%N`→slot `N` off-by-one (`%0` ambiguous with offset 0) | (a) `strlen` exact len (34); (b) `%N`→slot `N-1`, `%0`→empty, slots init `-1` (offset 0 valid) |
| 8 | Bochs `[4]/[47]/[49]/[50]` FAIL (QEMU 50 PASS) → then QEMU `[4]` FAIL too; GDB at `_start`: `dummy_dpb` zeros (disk `kernel.bin` correct) but `cmd_version` ok; `img` vs `bin` diff 112 B at kern-off 43008 (= disk LBA100) | ATA scratch `LBA100` overlapped kernel once it grew past 84 sectors (was `16..80`, now `16..104`): Phase 5 write/readback + zero-back dirtied `dummy_dpb`/`t47`/`t49` **in the host image** (emulators write through to `build/dos64.img`), poisoning the *next* boot; stale lock-free reruns without `make` then fail | Move ATA scratch `LBA100→200` (beyond kernel max `16..143`, below FS `500+`); `make clean && make` for fresh image; verified fresh + dirty-reuse both 50 PASS |

Total: 8 defects (3 test-operand, 2 encoding/ABI, 2 batch-semantics, 1 image-layout), all reproduced on QEMU before fixing; Bochs confirms. Temporary COM1 markers (`A–O`, `a–g`) isolated `[47]`/`[49]` then removed (clean output).

---

## 4. Verification

```bash
make clean && make
# mbr.bin 512 (55 aa), stage2.bin ~1K, kernel.elf 147024, kernel.bin 45932 (89 sectors ≤ 128)

# QEMU (fresh)
timeout 10 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial file:/tmp/q.log -display none
# → 50 passed, 0 failed + 8× ALL TESTS PASS

# Bochs (target, fresh)
rm -f bochs.log serial.log build/dos64.img.lock && timeout 25 bochs -f bochsrc.txt -q
# → serial.log identical 50 PASS; bochs.log: no #GP/#UD/#PF/check_cs (only ROM/SND notice)
```

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | ~1K | ≤ 15-sector slot |
| `build/kernel.bin` | 45932 (89 sectors @16) | ≤ 128 (`KERNEL_SECTORS`) |
| `build/dos64.img` | 10 M | MBR + stage2@1 + kernel@16 |

Heap discipline: Phase 10 tests free what they alloc (`exec` terminates + reaps; no `mem_alloc` leaks); `mem_validate64` in `[48]`/`[50]`; scratch stays `200` (ATA) + `500–511` (FS); `cmd_init64` per test resets ENV/date/batch. Re-running an emulator on a dirty image is safe (scratch-only writes); `make` restores pristine image.

---

## 5. Checklist (AGENTS.md Phase 10)

- [x] Convert COMMAND.COM → 64-bit COMMAND64 (`cmd64.asm`, flat/RIP-relative/near, no BIOS/segments/FAR)
- [x] Command-line parser (delims/switches/drive/upper/COMTAB64 lookup/dispatch)
- [x] Built-ins DIR/COPY/DEL/ERASE/REN/RENAME/TYPE/CLS/DATE/TIME/VER/PROMPT/PATH (+PAUSE/REM/ECHO)
- [x] External command execution (`proc_spawn64` + terminate/reap)
- [x] Batch processor (open/next/expand `%1..%9`, `%%`, CRLF, EOF)
- [x] Boot + 50 PASS on Bochs & QEMU, no faults

**Next:** Phase 11 interrupt descriptor table completion (PIC remap `0x20+`, IRQ handlers, `INT 27h` TSR) and Phase 12 stack/ABI hardening on top of the COMMAND64 shell.

**Update (closure):** see `docs/19-closure-g1-g6.md` for what changed after this report.
