# Phase 5 Completion Report — BIOS Interrupt Replacement (Native Drivers, Option C)

**Date:** 2026-08-30  
**Branch:** `phase5-native-drivers` (building on `phase4-flat-addr`)  
**Engineer:** Muse Spark  
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode, **Option C** (native 64-bit drivers)

---

## Executive Summary

Phase 5 (AGENTS.md §Phase 5, docs/02, docs/05 §6 — **Option C: Native 64-bit Drivers**) is **complete and verified**. All BIOS dependencies from MS-DOS 1.25 (13 far `CALL BIOS*` vectors at `BIOSSEG:0`, plus underlying `INT 10h/13h/16h` conceptual equivalents) are now replaced by direct hardware drivers that run in long mode without any BIOS calls or mode switches:

- **INT 10h (Video)** → native VGA text driver at `0xB8000` (ports `0x3D4/0x3D5`) — `src/drivers/vga.asm:1` (already Phase 2, retained and verified for 80×25, cursor, scroll, attribute `0x0F`)
- **INT 13h (Disk)** → ATA PIO LBA28 driver on primary channel `0x1F0-0x1F7/0x3F6` — `src/drivers/ata.asm:1` (843 lines, 13 exports, polling, `0x20`/`0x30`/`0xEC`, CHS→LBA helpers)
- **INT 16h (Keyboard)** → PS/2 8042 driver on `0x60/0x64` — `src/drivers/kbd.asm:1` (350+ lines, scancode set 1, shift/caps, 128B circular queue)

4 new tests added to the Phase 4 harness (now **16 tests total**) — all **16 PASS** on both Bochs and QEMU, no `#GP/#UD`, no BIOS `INT` in long mode.

```
Bochs / QEMU serial.log after Phase 5:

 MS-DOS64 MBR boot / A20 enabled / Loading stage2 via LBA... / Kernel loaded
 Hello from 64-bit DOS64 kernel: Phase2 long mode OK!
 Phase3: Register & Instruction Conversion Test Suite
 Phase4: Addressing Mode Transformation (segmented->flat) Test Suite
 Phase5: BIOS Interrupt Replacement — Native Drivers (Option C)
  [1] Register mapping (AX->RAX, R8-R15)... PASS
  [2] String ops (REP MOVSB, SCASB, LOOP->DEC)... PASS
  [3] BCD (AAM/AAD -> DIV/MUL, CBW, MUL/DIV)... PASS
  [4] FAT12 UNPACK/PACK (BX->RBX, SHL, LES)... PASS
  [5] Memory MCB64 (para*16->byte, alloc)... PASS
  [6] DMA flat (LES/LDS elimination)... PASS
  [7] Syscall dispatch (SAVREGS, far->near)... PASS
  [8] Seg:off->linear (seg<<4+off, DMA, para)... PASS
  [9] RIP-relative/OFFSET DOSGROUP->rel... PASS
  [10] FAR PTR BIOS -> near dispatch... PASS
  [11] Flat buffers DIRBUF/BUFFER, seg override elim... PASS
  [12] Canonical & flat stack... PASS
  [13] ATA PIO MBR read + CHS->LBA (INT13h)... PASS
  [14] ATA write/readback verify... PASS
  [15] Keyboard status/queue (INT16h)... PASS
  [16] Kbd translation + VGA native... PASS

 Summary: 16 passed, 0
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
```

---

## 1. Scope & Census (from docs/02, AGENTS.md Phase 5)

**BIOS / hardware sites replaced (live `grep -n` on MSDOS.ASM/IO.ASM):**

| Original mechanism | Count | 64-bit native replacement | Ports / addresses | Driver | Test |
|---|---|---|---|---|---|
| `CALL FAR PTR BIOSREAD/BIOSWRITE` (`MSDOS:1296,1343`, 13 vectors at `BIOSSEG`) | 13 far calls | `CALL [rel DISPATCH]` + direct `ata_read_lba28`/`ata_write_lba28` | `0x1F0` data, `0x1F2` cnt, `0x1F3-0x1F5` LBA, `0x1F6` drive, `0x1F7` cmd/status, `0x3F6` alt | `ata.asm:340 ata_read_lba28`, `441 ata_write_lba28` | `[13] MBR 0xAA55`, `[14] write/readback LBA100` |
| Concept `INT 13h` CHS (`AH=02h` track/head/sector) | 18 CHS sites (`128 DPB`, `950 DSKCHG`) | `chs_to_lba` / `lba_to_chs_demo` `LBA=(C*16+H)*63+S-1` | — | `ata.asm:654 chs_to_lba`, `682 lba_to_chs_demo` | `[13] 1:0:1→1008`, `1008→1:0:1`, `0→0:0:1` |
| `CALL FAR PTR BIOSIN/BIOSSTAT` (`MSDOS:3027`, `IO:360 STATUS`) | 2 vectors | `kbd_poll` / `kbd_has_data` via `0x64 OBF` | `0x60` data, `0x64` status (`0x01 OBF`, `0x02 IBF`) | `kbd.asm:84 kbd_has_data`, `106 kbd_poll` | `[15] status readable, queue` |
| `CALL FAR PTR BIOSOUT` (`OUTP` 566 via `BASE 0xF0`) | 1 | `vga_putc` / `vga_print` direct | `0xB8000` framebuffer, `0x3D4/0x3D5` cursor | `vga.asm:82 vga_putc` | `[16] VGA clear+print+cursor` |
| Scancode `INT 16h` (conceptual, IO.ASM `INP` queue 80B) | 80B queue | `kbd_queue` 128B circular, `scancode_table`/`shift_table` | `0x60` scancode set 1 | `kbd.asm:38 QUEUE 128`, `174 scancode_table` | `[16] 'a'→'A' shift/caps, '1'→'!'` |
| `CONOUT` via `INT 10h` concept | — | `vga_putc` polled, no BIOS | `0xB8000` + `rep stosw` | `vga.asm:39 vga_clear` | `[16] VGA memory `0xB8000='V'` |

**Option C rationale (AGENTS.md):** No V86 monitor (Option A) or real-mode stub (Option B) — pure long-mode `IN`/`OUT` + MMIO. Keeps `IDT` free for future `#GP/#PF` and `INT 21h` gate (Phase 9) without mode-switch overhead.

---

## 2. What Was Built

### 2.1 ATA PIO Driver `src/drivers/ata.asm:1` — 843 lines, 13 exports

| Function | Lines | Original → 64-bit | Details | Test |
|---|---|---|---|---|
| `ata_delay_400ns` | 59 | `IN AL,0x3F6 ×4` | 400ns delay after drive select (ATA spec) | internal |
| `ata_wait_not_busy` / `ata_wait_ready` / `ata_wait_drq` | 76-148 | Poll `BSY/DRDY/DRQ` via `0x1F7`/`0x3F6` with `ATA_TIMEOUT 1M` (4M for `ata_init`) | `CF=0` ready, `CF=1` timeout; uses `0x3F6` altstatus to avoid clearing IRQ | `[13]` + `[14]` |
| `ata_init` | 211 | `OUT 0x3F6,0x04` soft reset → `OUT 0x3F6,0` → `WAIT BSY` → `SELECT 0xE0` → `WAIT DRDY` (gentle, no forced reset if already ready) | Master only, QEMU/Bochs `ata0-master` flat 10M, CHS 20/16/63 autodetect | `[13]` |
| `ata_read_lba28` | 340 | `INT13 AH=42h/02h` → `OUT 0x1F6 (E0\|hi)`, `OUT 0x1F2 cnt`, `OUT 0x1F3-0x1F5 LBA`, `OUT 0x1F7 0x20`, `IN AX,0x1F0 ×256` per sector | LBA28 `0..0x0FFFFFFF`, count `1..256`, `rep` via `IN AX` loop, flat `[rbx]` store, `SHL`/`OR` for high nibble | `[13] LBA0`, `[14] LBA100` |
| `ata_write_lba28` | 441 | `INT13 AH=43h/03h` → `OUT 0x1F7 0x30`, `OUT AX,0x1F0 ×256`, `OUT 0x1F7 0xE7 flush` | Same LBA handling, `OUT AX` loop, cache flush `0xE7` | `[14]` |
| `ata_identify` | 576 | `AH=0` identify → `0xEC` | `OUT` sequence + `DRQ` check, reads 512B | helper (not in harness) |
| `chs_to_lba` | 654 | `(C*HPC+H)*SPT+S-1` via `INT13` CHS → `IMUL RAX,R9` 64-bit | Defaults `HPC=16,SPT=63` (Bochs/QEMU image), uses `R8-R10` temps, `IMUL` not `MUL EDX:EAX` to avoid 32-bit pitfalls | `[13] 1:0:1→1008` |
| `lba_to_chs_demo` | 682 | `DIV` inverse → `C=HPC`, `S=SPT` | 64-bit `DIV R10`/`DIV R9` with `RDX:RAX`, push/pop `RBX`/`RCX` for `BL`/`CL` returns | `[13] 1008→1:0:1` |
| `ata_test_mbr_read` / `ata_test_write_readback` / `ata_test_chs_conversion` | 715- | `DSKREAD` 512B verify | MBR `0xAA55` at `+510`, pattern `0xA5` ascending on LBA100, zero restore | `[13]`/`[14]` |

**Data:** `ata_test_buf: resb 1024` (2 sectors, `global` for debug), `ata_debug_status/error` bytes for failure diagnostics. All accesses `[rel]`, no segment prefixes, `bits 64; default rel`.

**Fixes vs. early prototype:** `ata_init` no longer forces reset (was causing first-read timeout in Bochs); `CHS` helpers rewritten from `MUL EDX` to `IMUL RAX,R9` 64-bit to fix `lba_to_chs_demo` returning sector `0x10` instead of `1` (verified via `CHS2 got C/H/S 0001 00 10` debug).

### 2.2 PS/2 Keyboard Driver `src/drivers/kbd.asm:1` — 368 lines, 12 exports

| Function | Lines | Original → 64-bit | Details | Test |
|---|---|---|---|---|
| `kbd_wait_ibf_clear` / `kbd_wait_obf_set` | ~30 | `IN AL,0x64` bit `IBF 0x02`/`OBF 0x01` | 100k timeout, `CF` | internal |
| `kbd_has_data` | 84 | `TBMT 0x01` at `BASE 0xF0` → `OBF` | Returns `RAX 0/1` | `[15]` |
| `kbd_poll` | 106 | `STATUS: TEST AL,2` → `IN 0x60` | `CF=0 AL=scancode`, `CF=1` no data | `[15]` |
| `kbd_flush` | 124 | `FLUSH` 396 | Drains `0x60` while `OBF`, clears `kbd_head/tail/count/shift` | `[15]` |
| `kbd_init` | 148 | `OUT 0x64,0xAE` enable + `OUT 0x60,0xF4` enable scanning, wait `0xFA` ACK | Tolerates timeout (Bochs/QEMU already enabled) | `[15]` |
| `kbd_queue_push/pop` | 190 | `PQUEUE 128B` at `IO:516` → `kbd_queue: resb 128` | Circular `head/tail &0x7F`, `count` | `[15]` |
| `kbd_handle_scancode` | 250 | `SHL`/`CAPS` handling | `0x2A/0x36` shift make `0xAA/0xB6` break, `0x1D ctrl`, `0x38 alt`, `0x3A caps` toggle bit2 | `[16]` |
| `kbd_scancode_to_ascii` | 285 | `XLAT` table → `MOV [rel table+RBX]` | Two tables `scancode_table`/`shift_table` 128B US layout, `TEST CL,3` shift, caps toggles for letters | `[16]` |
| `kbd_get_scancode` / `kbd_getc` | 340 | `IN` → queue → translate | Non-blocking `CF`, `0` if shift consumed | `[15]` |
| `kbd_test_status` / `kbd_test_queue` / `kbd_test_translation` | 368 | — | Status port readable, queue push `0x1E,0x30` pop order, translation `'a'→'A'` with shift, `'1'→'!'`, caps, space/enter | `[15]`/`[16]` |

**Data:** `kbd_queue 128B`, `kbd_head/tail/count/shift/ctrl/alt`, `scancode_table` 128B (`'1'..'='` etc.) + `shift_table` (`'!'..'+'`), all `[rel]`. No `INT 16h`, no `CLI/STI` required for polling.

### 2.3 VGA Driver `src/drivers/vga.asm:1` — retained, verified for Phase 5

Already 161 lines, 5 exports. `vga_init` clears `0xB8000` with `REP STOSW`, resets `vga_row/col`, `vga_set_cursor` via `0x3D4/0x3D5`. `[16]` now also checks `VGA 'V'` at `0xB8000` after `vga_init` + `vga_print "VGA"` and attribute `0x0F`, plus `vga_putc` CR/LF cursor movement. Covers `INT 10h` AH `0Eh`/`02h`/`06h`.

### 2.4 Kernel Harness `src/kernel/main.asm:1` — Phase 5 extension (967 lines, was 767)

- **Headers:** Added `hello_phase5 db "Phase5: BIOS Interrupt Replacement — Native Drivers (Option C)"` and `msg_test13..16`, `msg_phase5_ok/fail`, plus debug strings `ata_dbg_msg*`, `ata_chs_dbg*`, `vga_test_str "VGA"`.
- **Externs:** 10 new: `ata_*` (7), `kbd_*` (3).
- **Helpers:** `print_hex8`/`print_hex16` (hex via `vga_putc` + `0x3FD`/`0x3F8` polling, similar to `print_num_vga_serial`).
- **4 new test blocks** (same `test rax / jz .pass` pattern):
  - `[13] ATA PIO MBR read + CHS->LBA` → `test_ata_mbr` (`ata_init` → `ata_test_mbr_read` `0xAA55` → inline CHS vectors `1:0:1→1008`, `1008→1:0:1`, `0→0:0:1` with `print_hex16` debug on fail)
  - `[14] ATA write/readback verify` → `test_ata_write` (`ata_test_write_readback` pattern `0xA5` on LBA100)
  - `[15] Keyboard status/queue` → `test_kbd_status` (`kbd_init` → `kbd_test_status` → `kbd_test_queue` → `kbd_has_data`/`kbd_poll` no-hang)
  - `[16] Kbd translation + VGA native` → `test_kbd_translation` (`kbd_test_translation` shift/caps → `vga_init` → `vga_print "VGA"` → check `[0xB8000]='V'`/`[0xB8001]=0x0F` + `vga_putc` CRLF)
- **Summary:** Still `DIV 10` for `R12`/`R13` (now 16 passed), prints `16 passed, 0 failed` correctly; `R13==0` prints all three `Phase3/4/5 ... ALL TESTS PASS`.

**Section sizes:** `_start` still `section .text.start` first; `.rodata` +~300B; kernel linked `52008 elf`, `11212 bin` (21 sectors) ≤64 (Stage2 `KERNEL_SECTORS 64`). Auto-discovery `Makefile:14` now 10 objects (added `ata.o`/`kbd.o`).

### 2.5 Build (`Makefile`, `linker.ld`, `bochsrc.txt`) — unchanged except auto-discovery

- `KERNEL_SRCS` wildcard picks `ata.o`/`kbd.o`; `ld -T linker.ld` `main.o` first; `build/dos64.img` 10M.

---

## 3. Verification

### 3.1 Build

```bash
make clean && make
# nasm -f bin src/boot/mbr.asm -o build/mbr.bin (512, 55 aa)
# nasm -f bin src/boot/stage2.asm -o build/stage2.bin (1021)
# nasm -f elf64 src/drivers/ata.asm -o build/src/drivers/ata.o
# nasm -f elf64 src/drivers/kbd.asm -o build/src/drivers/kbd.o
# nasm -f elf64 src/drivers/vga.asm -o build/src/drivers/vga.o
# ... 10 objects
# ld -T linker.ld -o build/kernel.elf (52008)
# Kernel binary: 11212 bytes (21 sectors, ≤64)
# dd mbr.bin, stage2.bin seek1, kernel.bin seek16 → dos64.img 10M
```

Elf `52008` (was `39352`), bin `11212` (was `7796`), +`3416` for ATA/KBD + debug strings, still warnings-free.

### 3.2 QEMU 11.1.1

```bash
timeout 8 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
```

**Output:** see Executive Summary — `16 passed, 0 failed`, `Phase5 ... ALL TESTS PASS`. No `#GP/#UD`, ATA `IN/OUT` succeeds, keyboard `IN 0x64` succeeds.

### 3.3 Bochs 3.0

```bash
rm -f bochs.log serial.log build/dos64.img.lock
BXSHARE=/nix/store/.../share/bochs timeout 12 bochs -f bochsrc.txt -q; cat serial.log
```

**serial.log:** identical to QEMU (16 PASS). **bochs.log tail:** `autodetect geometry: CHS=20/16/63`, `translation=none`, `BIOS ata0-0: PCHS=20/16/63`, no `exception` vs. earlier `HLT IF=0` halt loop, `ips` steady. Previous `HLT` warning now after all tests (still halt loop).

**Timing fix:** `ata_init` now gentle (no forced reset if ready) + `ATA_TIMEOUT 1M` (4M for init) sufficient for Bochs 50M ips; earlier forced reset caused first-read timeout (1M) and CHS `IMUL` vs `MUL` bug caused `CHS2 got 0001 00 10` (sector 16 vs 1) — both fixed, now Bochs 12s timeout passes.

### 3.4 Checks

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | 1021 | ≤15 sectors |
| `build/kernel.bin` | 11212 (<32768) | 21 sectors @16, ≤64 |
| `build/dos64.img` | 10M | MBR+stage2@1+kernel@16 |
| `serial.log` | — | 16 PASS both emus |
| `bochs.log` | — | no #GP/#UD; geometry autodetect |

---

## 4. Key Design Decisions vs Phase 4

- **PIO polling, not IRQ/DMA:** Simplest for Bochs/QEMU, no IDT `IRQ1/IRQ14` yet (Phase 11). Poll `BSY/DRQ` via `0x3F6`/`0x1F7` with timeout, `IN AX,0x1F0` loop. Future `AHCI` would be Option C alternative but PIO sufficient for 10M image.
- **LBA28 only (28-bit):** Image `20480` sectors < `2^28`, so `0xE0 | hi` + `OUT 0x1F3-0x1F5` covers all; LBA48 not needed. `CHS` helpers keep DOS geometry compatibility for `FATREAD` (Phase 7).
- **Gentle `ata_init`:** Original `SOFT RESET` via `0x3F6 0x04` caused 1M timeout failure on Bochs first read; now only reset if `BSY` persists `4M` cycles, then `SELECT 0xE0` + `WAIT DRDY`. QEMU/Bochs both ready after BIOS without reset.
- **64-bit `IMUL` vs `MUL EDX:EAX`:** `chs_to_lba` had `MUL EDX` 32-bit `EDX:EAX` bug when `EAX` was 64-bit `RAX` with high bits; `IMUL RAX,R9` 64-bit fixed `LBA 1008` (was 1008 correct for CHS→LBA but `LBA→CHS` second vector failed). `lba_to_chs_demo` also fixed to `DIV R10` 64-bit.
- **Keyboard queue 128B:** Power-of-two `&0x7F` mask, not 80B, for simpler `INC & AND`. Tables 128B each, `XLAT` replacement `MOV [rel table+RBX]`.
- **VGA `vga_init` vs `vga_clear` for test:** `vga_clear` leaves `vga_row/col` at old position (12 after 12 tests), so `PRINT "VGA"` at `0xB8000` failed (was space). `vga_init` resets cursor, then check passes.
- **Hex debug helpers:** `print_hex8/16` added for `ATA DBG status` and `CHS` vectors, only on failure → no extra serial noise on PASS, but useful for `CHS2 got 0001 00 10` diagnosis.

---

## 5. Checklist (AGENTS.md Phase 5 – Option C)

- [x] Implement VGA text mode driver (INT 10h replacement) — `0xB8000` buffer, cursor `0x3D4/0x3D5`, scroll, color `0x0F` — `vga.asm:39 vga_clear` `82 vga_putc` `149 vga_print` — `[16] PASS`
- [x] Implement ATA PIO disk driver (INT 13h replacement) — read/write sectors, drive detection via `DRDY`, LBA28 — `ata.asm:340 read`, `441 write`, `211 init` — `[13]`/`[14]` PASS
- [x] Implement PS/2 keyboard driver (INT 16h replacement) — scan code reading via `0x60`, status `0x64`, queue, translate — `kbd.asm:106 poll`, `250 handle`, `285 translate` — `[15]`/`[16]` PASS

**Next:** Phase 6 MCB coalesce & `INT 21h AH=48h` (already scaffolded `mem64.asm`), Phase 7 FAT12 LBA driver (replace `READ`/`WRITE` 838/856).

*All claims verified via `make`, `nasm -f elf64`, `ld -T linker.ld`, `BXSHARE=... bochs -f bochsrc.txt -q`, `qemu-system-x86_64 -serial stdio` on 2026-08-30.*

**Update (closure):** ATA scratch moved `LBA100→200` once the kernel grew past 84 sectors (see `docs/15-phase10-command.md` bug 8 and `docs/19-closure-g1-g6.md`); current scratch is `200`/`500–511`, volume at LBA 512+. See `docs/19-closure-g1-g6.md` for what else changed after this report.

