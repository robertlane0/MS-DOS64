# Phase 9 Completion Report — System Call Interface (INT 21h IDT gate)

**Date:** 2026-09-04
**Branch:** `phase9-syscall` (building on `phase8-process`)
**Engineer:** Muse Spark
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 9 (AGENTS.md §Phase 9, docs/06 syscall reference) is **complete and verified**.
DOS 1.25's `INT 21h` dispatcher (`DISPATCH MSDOS.ASM:349`, `SETVECT:3342`,
`CONIN/BUFIN/PRTBUF/SELDSK/GETDRV MSDOS.ASM:2705/2698/2683/3130/3172`) is now a
flat 64-bit system-call layer via a real long-mode **IDT gate at vector 0x21
(Option B, DOS-compatible)**: 256-entry IDT (16 B each), DPL=3 interrupt gate
(`0xEE`) for `INT 0x21`, DPL=0 (`0x8E`) for exceptions 0–31 (error-code aware),
`int21_entry` preserving DOS `AH`-function convention (`AH=func`,
`AL=subfunc/vector`, `DL=char/drive`, `BX=handle`, `CX=count`, `RDX=buffer`,
`R8=env`), `CF` propagated to `IRETQ` frame, results via trap frame
(`STKPTRS64`) + `RAX/RBX`.

12 `AH` handlers required by AGENTS.md are real (was stubs): `01 CONIN`,
`02 CONOUT`, `09 PRTBUF`, `0A BUFIN`, `0D DSKRESET`, `0E SELDSK`, `19 GETDRV`,
`25 SETVECT`, `35 GETVECT` (DOS 2.0 ext), `3F READ`, `40 WRITE`, `4C EXIT`
(Phase 8). Console group `06 RAWIO / 07 RAWINP / 08 IN / 0B CONSTAT / 0C FLUSHKB`
also real via native VGA/KBD (Phase 5, Option C). File `3F/40` cover console
handles `0=stdin / 1=stdout / 2=stderr` (Phase 10+ extends to FS handles).

8 new tests extend the harness to **42 total — all 42 PASS** on Bochs and QEMU,
no `#UD/#GP/#PF`, no BIOS calls, no triple faults.

```
 Bochs / QEMU serial.log after Phase 9 (tail):

  [35] IDT init/load + INT 0x21 gate... PASS
  [36] Console 01/08/0B/0C (kbd+vga)... PASS
  [37] Buffered input 0A (line edit)... PASS
  [38] Drive 0E/19 + reset 0D... PASS
  [39] Vectors 25/35 via IDT... PASS
  [40] Read 3F stdin handle 0... PASS
  [41] Write 40 stdout handles 1/2... PASS
  [42] INT 0x21 round-trip via CPU INT... PASS

 Summary: 42 passed, 0 failed
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
 Phase6 memory management (MCB64): ALL TESTS PASS
 Phase7 filesystem adaptation (FAT12): ALL TESTS PASS
 Phase8 process management (PSP64): ALL TESTS PASS
 Phase9 syscall interface (INT 21h): ALL TESTS PASS
```

> Diagnostic note: `[30]/[32]/[33]` still emit single-letter progress markers
> (`A–N`, `a–h`, `p–$`) before `PASS` (fail-point isolation, cf. Phase 8).
> Phase 9 tests emit no markers on pass (clean `... PASS`).

---

## 1. Scope (AGENTS.md Phase 9 checklist)

| Requirement | Implementation | Test |
|---|---|---|
| Set up IDT with INT 0x21 gate | `src/kernel/idt64.asm`: 4096 B IDT, `IDT_CODE_SEL 0x08`, `0xEE` for `0x21`, `0x8E` else, `idt_init/load/set/get`, `int21_entry` (push 15 GPRs → `SPSAVE` → `IOSTACK/DSKSTACK` → `DISPATCH64[AH]` → CF to `IRETQ` frame → pop → `iretq`), PIC masked (`0x21/0xA1=0xFF`, polling drivers) | `[35]` init/load/vectors + real `int 0x21` (`AH=02/09`, bad `FF→AL=0`) |
| Implement INT 0x21 dispatcher in 64-bit | `syscall_dispatch64` now preserves user `RAX/RBX/R8` via `R10/R11` temps (was `RAX/RBX/R8` clobber — see §3 bug 1); `int21_entry` same; `MAXCOM 0x4C`, `IOSTACK≤12/DSKSTACK`, `CF` survives pops, `IRETQ` frame `RFLAGS.CF` updated | `[42]` full `int 0x21` round-trip (`02/09/0E/19/0D/01/3F/40`) |
| `01` Char in w/ echo | `handler_conin`: `handler_in` + `handler_conout` echo (skip echo if empty), frame `rax_save AL=char` | `[36]` queue `0x30→'b'` + dispatch `AH=01` (`0x21→'f'`) |
| `02` Char out | `handler_conout`: `AL=DL` → `vga_putc` (was `movzx rdi,dl` leaving `AL` stale — see §3 bug 2) | `[35]/[42]` `int 0x21 AH=02 DL='* /'Q'` |
| `09` Print `-string` | `handler_prtbuf` (kept): `RDX` linear, `$`-term, loop `OUT` | `[35]/[42]` `int 0x21 AH=09 RDX=$-str` |
| `0A` Buffered input | `handler_bufin`: `RDX=[max][count][chars]`, `BACKSPACE 08/7F`, `BELL 07` on full, `CR 13` ends + `CRLF` echo, `max≤128`, non-blocking drain (DOS would block) | `[37]` `"HI"+CR`, `"AB" BS "C" CR→"AC"`, empty, bad-buf, dispatch `AH=0A` |
| `0D` Reset disks | `handler_dskreset`: no dirty bufs in Phase 7 RAM → `AL=0` | `[38]` + dispatch/int `AH=0D→AL=0` |
| `0E` Select drive | `handler_seldsk`: `DL<NUMDRV(2)` → `CURDRV=DL`, `AL=NUMDRV` (MSDOS `SELDSK:2698` returns `NUMDRV`) | `[38]` `1→1`, `0→0`, `99→stays 0`, dispatch/int |
| `19` Get cur drive | `handler_getdrv`: `AL=CURDRV` (MSDOS `GETDRV:2683`) | `[38]` + `[42]` `int 0x21 AH=19` |
| `25` Set vector | `handler_setvect`: `AL=vec`, `RDX=RIP` → `idt_set_vector64` (`0xEE`), `AL=0/CF` (was `ES:[BX]=DX/DS`) | `[39]` `0x21→0x12345000`, `0x80→int21`, bad `RDX=0→fail` |
| `35` Get vector | `handler_getvect` (DOS 2.0 ext): `AL=vec` → `RBX=RIP` (was `ES:BX`), frame `rbx_save`, `AL=0` | `[39]` direct + dispatch `AH=35h AL=0x80→RBX=int21` |
| `3F` Read file | `handler_read_file`: `BX=0 stdin` (kbd queue/hw → `[RDX]`, `RAX=bytes`, short-read on empty), `BX=3+→AH=6/CF`, `RDX=0→fail`, `CX` 16-bit compat | `[40]` `'x'`, zero-count, bad-handle/buf, dispatch `AH=3F` |
| `40` Write file | `handler_write_file`: `BX=1/2 stdout/stderr` (loop `conout`, `RAX=count`), else `AH=6/CF` | `[41]` `"Hi!"×3`, `1/2`, zero, bad-handle, dispatch `AH=40` |
| `4C` Exit | Kept Phase 8 `handler_exit_process` (`AL` when `AH==4Ch` else `RDI`) | `[33]` (Phase 8) + `[42]` indirectly (no exit in 42) |

Console extras (same drivers): `06 RAWIO` (`DL=FF→input CF/ZF` else output),
`07 RAWINP` (=`08`), `08 IN` (queue→hw→`translate`, `CF` on empty),
`0B CONSTAT` (`FF` avail else `0`, queue peek via pop/push),
`0C FLUSHKB` (flush + redispatch `1/6/7/8/0A`, `MSDOS:412`).

New exports (`syscall64.asm`): `handler_conin/rawio/rawinp/bufin/constat/flushkb/
dskreset/seldsk/getdrv/setvect/getvect/read_file/write_file`,
`SPSAVE64/SSSAVE64/IOSTACK_TOP/DSKSTACK_TOP/DISPATCH64/CURDRV/THISDRV/NUMDRV/
DMAADD64_SC`. New module (`idt64.asm`, 7 globals): `idt_init/load/set_vector/
get_vector/get_base`, `int21_entry`, `idt_default_handler[_err]`,
`idt_test_vectors`, `idt_table/ptr`.

---

## 2. What Was Built

### 2.1 `idt64.asm` — IVT → IDT (Option B)

`idt_set_entry_raw(RDI=vec,RSI=RIP,RDX=type)`: `vec*16+table`,
`offset_low=RIP&FFFF`, `selector=0x08`, `IST=0`, `type`, `mid=RIP>>16`,
`high=RIP>>32`, `reserved=0`. `idt_init64` fills 256 (`0x21→int21_entry/0xEE`,
error vectors `8/10/11/12/13/14/17/21→err stub` which `add rsp,8; iretq`,
rest `→iretq/0x8E`), builds `IDTR(limit 4095, base)`. `idt_load64` masks PIC
(`0xFF→0x21/0xA1`, see §3 bug 3), `lidt`, `sti`. `idt_set/get_vector64` back
`25h/35h`. `idt_test_vectors` checks `0x21==int21_entry/DPL3`, `0x00 DPL0/0x08`.

`int21_entry` (CPL0→CPL0, 3-qword CPU frame `RIP/CS/RFLAGS`): push 15 GPRs
(`r15..rax`, matches `STKPTRS64`), `SPSAVE=rsp`, `SS→SSSAVE` via `R11`
(preserves `RAX`, see §3 bug 1), `AH=[RSP]>>8&FF` via `R10`, `>0x4C→bad
(AL=0)`, `≤12→IOSTACK else DSKSTACK`, `and rsp,~15`, `sti`, `R11=AH*8`,
`R10=DISPATCH[R11]`, `call R10` (user `RAX/RBX/R8` intact — `R10/R11` temps),
`pushfq/pop→CF→int21_cf_save`, `cli`, `rsp=SPSAVE`, pop 15, patch
`[RSP+32].CF` (CPU `RFLAGS`), `iretq`.

### 2.2 `syscall64.asm` — stubs → drivers

`syscall_init` sets `NUMDRV=2`. `DISPATCH64[0x35]=handler_getvect`,
`[0x3F]=handler_read_file`, `[0x40]=handler_write_file` (was `inuse`).
`syscall_dispatch64` rewritten to use `R10/R11` temps + `mov r11,ss`
(preserves `RAX`, see §3 bug 1); `CF` survives pops (pops don't touch flags);
`leave64` unchanged (`cli`, `rsp=SPSAVE`, pop 15, `ret`).

`handler_kbd_read_ascii` (internal): `queue_pop→translate` else
`poll→translate`, `AL=0/CF=1` on empty/shift-consumed (test-safe
non-blocking; DOS `IN` would block). All console handlers loop on it.
`BUFIN` caps `128`, `BS` echoes `BS SPACE BS`, `CR` echoes `CRLF`.
`CONSTAT` peeks queue via pop/push (single-char exact; multi-char rotates
once, count preserved — documented limitation, future `kbd_count` export).
`FLUSHKB` flushes *before* redispatch (MSDOS semantics) — pre-pushed keys
cleared, redispatch sees empty (`AL=0`, see §3 bug 4).
`READ/WRITE` use `BX/CX` low 16 (DOS compat, 64-bit ext zero-extends);
`CX` full 64-bit ignored high (documented).

### 2.3 `main.asm` — 34 → 42 tests

`hello_phase9`, `msg_test35–42`, `msg_phase9_ok/fail`, `p9_dollar="P9$INT21$
via INT$"`, `p9_hello3="Hi!"`, `p9_bufin 32B`, `p9_rwbuf 64B`. Tests call
handlers directly + via `syscall_dispatch64` + via CPU `int 0x21` (after
`[35]` loads IDT). `[35]` also checks bad `AH=FF→AL=0` via `int`.

### 2.4 Capacity — 64 → 128 sectors

Kernel `31772→36364 B` (62→71 sectors). `stage2.asm KERNEL_SECTORS 64→128`
(64 KiB, `0x100000–0x110000` ⊂ 0–8 MiB identity map), `Makefile` check
`64*512→128*512`. Image layout unchanged (`MBR@0`, `stage2@1`,
`kernel@16`, scratch `500+` safe).

---

## 3. Bugs Found & Fixed (via QEMU serial + Bochs `check_cs` + GDB map)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `[39]` dispatch `AH=35h` returns wrong `RBX` (direct ok) | `dispatch`/`int21_entry` clobbered `RAX` (handler addr), `RBX` (`index*8`), `R8D` (`AH`) before `call` — handlers needing `AL` (vector), `BX` (handle), `R8` (env) got garbage. Latent since Phase 6 (para test used `RBX=16` but got `576=0x48*8`, still allocatable → masked). | Use `R10/R11` temps for `AH/index/handler` + `mov r11,ss` (was `mov rax,ss` clobbering `AL`) in both `dispatch` and `int21_entry`; user `RAX/RBX/R8` survive (saved in frame, restored by `leave`/`iretq`). |
| 2 | `INT 21h AH=02` prints `NUL`, not `DL` | `handler_conout` did `movzx rdi,dl` but `vga_putc` takes `AL` — `AL` stale (`AH=02` → `AL=00`). Masked (test 7 didn't check VGA). | `mov al,dl` before `vga_putc` (preserved via push/pop). |
| 3 | `[35]` hangs on first `int 0x21`, Bochs `check_cs(0x0246)` loop (layout-dependent: 2×`NOP` or serial `IN/OUT` shifted layout → sometimes passed) | `sti` in `int21_entry` (first `sti` in boot; tests 1–34 never `sti`) enables timer `IRQ0` which fires as `INT 8` (PIC overlap, no remap yet). Vector 8 uses `#DF` err stub (`add rsp,8`) but IRQ pushes no error → stack corrupt → `iretq` loads bogus `CS=0x0246`. Timing-dependent → layout-dependent. | Mask PIC in `idt_load64` (`0xFF→0x21/0xA1`, polling drivers need no IRQ); `sti` then safe. Phase 11 will remap PIC to `0x20+`. Removed `NOP` workaround. |
| 4 | `[36]` `FLUSHKB AL=8` expects `'e'` but gets `0` | Test pre-pushed `0x12` before `FLUSHKB`, but `FLUSHKB` flushes *before* redispatch (MSDOS `PUSH AX/CALL FLUSH/POP`) → queue cleared → `IN` sees empty. Test wrong, not code. | Test expects `AL=0` empty for redispatch-after-flush (still proves redispatch calls `IN` without fault); documents blocking vs non-blocking. |
| 5 | Test-only `mov al,'c'` clobbers `AL` return before `cmp al,2` (`[42]` `abcFAIL`) | Debug markers `mov al,'c'; call print` overwrote `SELDSK` return `AL=2` before check (like Phase 8 `AL`-before-save). | `push rax`/`pop rax` around markers (then removed markers entirely for clean `PASS`). |

Total: 5 defects (1 trap-frame clobber, 1 driver ABI, 1 PIC/IRQ stack corruption,
1 test-semantics, 1 test-debug clobber), all reproduced on QEMU before fixing;
Bochs confirms. Debug markers (`A–M`, `RBX` hex, `a–g`) used for isolation then
removed (clean output, cf. Phase 8 markers kept for `[30]/[32]/[33]`).

---

## 4. Verification

```bash
make clean && make
# mbr.bin 512 (55 aa), stage2.bin ~1K, kernel.elf 117784, kernel.bin 36364 (71 sectors ≤ 128)

# QEMU
timeout 12 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# → 42 passed, 0 failed + 7× ALL TESTS PASS

# Bochs (target)
rm -f bochs.log serial.log build/dos64.img.lock && timeout 25 bochs -f bochsrc.txt -q
# → serial.log identical 42 PASS; bochs.log: no #GP/#UD/#PF/check_cs (only ROM notice)
```

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | ~1K | ≤ 15-sector slot |
| `build/kernel.bin` | 36364 (71 sectors @16) | ≤ 128 (`KERNEL_SECTORS`) |
| `build/dos64.img` | 10 M | MBR + stage2@1 + kernel@16 |

Heap discipline: Phase 9 tests are RAM/queue/VGA-only (no `mem_alloc` except
via prior phases' cleanup; `proc_free_all` not needed as no spawns in 35–42).
Scratch stays Phase 7 `LBA 500–511` (untouched). `IOSTACK/DSKSTACK` 4 KiB each
cover `int→conout/vga` + `bufin→conout` depth. PIC masked, `sti` safe.

---

## 5. Checklist (AGENTS.md Phase 9)

- [x] Set up IDT with INT 0x21 gate (`idt64.asm`, `0xEE` DPL3, `lidt`, PIC mask)
- [x] Implement INT 0x21 dispatcher in 64-bit (`dispatch` + `int21_entry`, `AH` via `R10`, `CF` to `IRETQ`)
- [x] Convert each AH handler (`01/02/09/0A/0D/0E/19/25/35/3F/40/4C`, + `06/07/08/0B/0C`)
- [x] Boot + 42 PASS on Bochs & QEMU, no faults

**Next:** Phase 10 command interpreter (`COMMAND64` on top of `INT 21h`:
`DIR/COPY/DEL/TYPE` via `FCB64` + `09/0A/3F/40`, `EXEC` via `4Bh`, batch via
`0A`; `VER/PROMPT/PATH` via `ENV`).
