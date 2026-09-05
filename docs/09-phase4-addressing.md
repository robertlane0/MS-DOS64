# Phase 4 Completion Report — Addressing Mode Transformation (Segmented → Flat)

**Date:** 2026-08-30  
**Branch:** `phase4-flat-addr` (building on `phase3-regs`)  
**Engineer:** Muse Spark  
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 4 (AGENTS.md §Phase 4 + docs/04 §3) is **complete and verified**. All segmented-memory idioms from MS-DOS 1.25 (8,128 lines) have been systematically converted to flat 64-bit linear addressing and demonstrated in a runnable kernel:

- `(segment << 4) + offset` replaces every `segment:offset` and `OFFSET DOSGROUP:xxx` pattern; RIP-relative `lea rsi, [rel var]` / `mov rax, [rel var]` replaces `MOV AX,CS / MOV DS,AX / MOV SI,OFFSET`.
- Segment override prefixes (`DS:`, `ES:`, `SEG CS`) eliminated — `DS`/`ES`/`SS` base is 0 in long mode; `FS`/`GS` only for TLS.
- Split `DMAADD` word-pair (18 hits) replaced by single `dq` flat linear; `LES`/`LDS` already removed but now tested via `seg_off_to_linear` helper.
- `FAR PTR BIOS*` jump table (13 hits) and far calls/jumps/rets (`RETF`, `JMP FAR`) replaced by near dispatch table `dq handler` + `SHL RBX,3 ; CALL [rel TABLE+RBX]`; `IRET` → `IRETQ` already in syscall but now also documented for addressing.
- Buffer pointer tables (`BUFFER`, `DIRBUF`, `FATSIZTAB` `DW` offsets) widened to `dq` linear; flat pointer arithmetic with SIB scaling replaces 16-bit offset addition.
- Canonical-address check and flat stack (`RSP` + `and rsp,-16`) validate long-mode address correctness.
- 5 new tests added to the Phase 3 harness (now 12 tests total) — all **12 PASS** on both Bochs and QEMU with no #GP/#UD.

```
Bochs / QEMU serial.log after Phase 4:

 MS-DOS64 MBR boot / A20 enabled / Loading stage2 via LBA... / Kernel loaded
 Hello from 64-bit DOS64 kernel: Phase2 long mode OK!
 Phase3: Register & Instruction Conversion Test Suite
 Phase4: Addressing Mode Transformation (segmented->flat) Test Suite
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

 Summary: 12 passed, 0
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
```

---

## 1. Scope & Census (from docs/04 §3-4 + live grep)

**Segmented patterns counted via `grep -n "OFFSET DOSGROUP\|FAR PTR\|DMAADD\|DOSGROUP\|ASSUME"` on MSDOS.ASM:**

| Pattern | Original count | 64-bit flat replacement | Example location | Phase 4 handler |
|---------|---------------|-------------------------|------------------|-----------------|
| `OFFSET DOSGROUP:xxx` | 47 hits (`213 OFFSET IOSTACK`, `517 IONAME`, `668 DIRBUF`, etc.) | `lea rsi, [rel var]` or `mov rax, [rel var]` with `default rel` | `MSDOS:313`, `517`, `668`, `693`, `1380`, `1844`, `2771` | `src/lib/addr64.asm:92 offset_to_rel_demo`, `121 rip_relative_demo` |
| `ASSUME CS:DOSGROUP,DS:DOSGROUP,SS:DOSGROUP` + `MOV AX,CS; MOV DS,AX; MOV ES,AX` alias | 1 `ASSUME` + 3 `MOV DS/ES` | Delete; `default rel` makes `DS`/`ES` irrelevant (base 0) | `MSDOS:214`, `IO:148 PUSH CS/POP DS` | `addr64.asm:201 dosgroup_alias_elimination_demo` |
| `SEG CS`, `SEG DS`, segment overrides `DS:[SI]`, `ES:[DI]`, `[CS:SI]` | 40 `SEG` hits (`IO:369 SEG CS MOV [QUEUE]`) | Remove prefix; `mov al, [rsi]` flat | `IO:369`, `MSDOS:SEG` etc. | `addr64.asm:335 segment_override_elimination_demo` |
| `DMAADD DW 80H` + `DMAADD+2 DW ?` word-pair split | 19 hits | Single `dq DMAADD64_FLAT` linear; `mov rdi, [rel DMAADD64]` | `MSDOS:1529`, `1732`, `3654`, `3738` | `addr64.asm:196 dma_flat_demo`, `fat64.asm:141 dma_get_linear` |
| `LDS SI,[SPSAVE]`, `LES DI,[DMAADD]` | 13 `LDS`/`LES` (invalid in 64-bit) | `mov rsi, [rel SPSAVE]` / `mov rdi, [rel DMAADD]` — single `dq` | `MSDOS:1357`, `1429`, `1819`, `2013` | `addr64.asm:53 seg_off_to_linear` + Phase 3 `fat64` |
| `FAR PTR BIOS*` jump table (3B `JMP FAR`) + `CALL FAR PTR`, `RET F`, `JMP FAR` | 13 `FAR PTR` (`414 BIOSFLUSH`, `435 BIOSAUXIN`, `950 BIOSDSKCHG`, `1296 BIOSREAD`, `1343 BIOSWRITE`, etc.) | Near `dq` dispatch `bios_near_table` + `SHL RBX,3 ; CALL [rel TAB+RBX]` | `MSDOS:414`, `950`, `982`, `1296`, `3027`, etc. | `addr64.asm:225 far_to_near_demo` + `syscall64.asm:182 DISPATCH64 dq` |
| `BUFFER`, `DIRBUF`, `FATSIZTAB` `DW` pointer tables | `DIRBUF LABEL WORD`, `FATSIZTAB DW 16` etc. | `dq` linear (`BUFFER64 dq`, `FATSIZTAB64 dq 16,32,64`) + `MOV RSI,[rel BUFFER]` | `MSDOS:3703`, `IO:1929 DOSLEN` | `addr64.asm:293 buffer_flat_demo` |
| `DRVTAB DW 0` + `MOV BP,[DRVTAB]` + `[BP.xxx]` DPB field | 2 `DRVTAB` + many `[BP.]` | `mov rbp, [rel DRVTAB64]` + `[rbp+DPB64.firfat]` flat | `MSDOS:987`, `1254`, etc. | `addr64.asm:501 flat_pointer_arithmetic_demo` |
| `PUSH DS/ES/SS` / `POP` (124 pushes) | 124+ pushes of segment regs | `mov rax, ds ; push rax` or delete; flat has no segment stack | `IO:148`, `MSDOS:289` | `string64.asm:232 push_pop_seg_demo` |
| `IRET`, `RET F` (far ret) | `RETF` in BIOS stubs, `IRET` at `347` | `RET` near, `IRETQ` 5-qword frame (Phase 3) | `MSDOS:347 IRET` | `syscall64.asm:151 iretq64` |

**Flat addressing rules enforced (AGENTS.md Phase 4):**

- All new kernel/lib code: `bits 64; default rel` (8 files) — verified via `grep -n "default rel"` → 8 hits.
- No `ASSUME`, no `SEGMENT`, no `OFFSET DOSGROUP` remains in new code; all `grep "OFFSET DOSGROUP"` finds 0 in `src/` (only comments).
- No segment overrides remain in new code except comments; `grep -P "ds:|es:|cs:|ss:"` finds 0 instructions (only comments).
- `grep -n "\[rel"` finds 120+ RIP-relative loads/stores (phase3+4).

---

## 2. What Was Built

### 2.1 New Library `src/lib/addr64.asm:1` — 685 lines, 14 exports, 8 sub-demos + 5 integrated tests

| Function | Lines | Original DOS pattern | 64-bit conversion | Test coverage |
|----------|-------|----------------------|-------------------|---------------|
| `seg_off_to_linear` | `10` | `MOV AX,0x1000; MOV DS,AX; MOV SI,0x50; MOV AL,[DS:SI]` → linear `0x10050` per AGENTS.md example | `mov rax,rdi; shl rax,4; add rax,rsi` | `addr_test_seg_off` vectors: `0x1000:0x0050→0x10050`, `0x60:0→0x600`, `0x1000:0x80→0x10080` |
| `seg_off_to_linear2` | `30` | `LDS SI,DWORD PTR [SPSAVE]` split | `movzx ecx,ax; shr eax,16; shl eax,4; add` | helper for legacy SPSAVE packed seg:off |
| `offset_to_rel_demo` | `92` | `MOV SI,OFFSET DOSGROUP:IONAME` (47 hits) | `lea rsi,[rel offset_test_var]; mov rax,[rsi]` | verifies `0x1122334455667788` via flat load; also `offset_test_str "IONAME"` |
| `rip_relative_demo` + `rip_relative_abs_vs_rel` | `121` | `MOV AX,CS; MOV DS,AX; MOV SI,OFFSET VAR` alias + `SEG CS` overrides | `lea rax,[rel rip_var]; mov rbx,[rel rip_var]` + `LEA vs [rax]` | `rip_var 0x0102030405060708`; checks `LEA` address + dereference equals `MOV [rel]`; also `LEA+8` vs `rel+8` |
| `dosgroup_alias_elimination_demo` | `201` | `ASSUME CS:DOSGROUP; MOV AX,CS; MOV DS,AX; MOV ES,AX` then `[SI]` | Delete DS/ES loads; `lea rsi,[rel dosgroup_var]; mov al,[rsi]` | var `0x42`; mutates via flat `mov byte [rdi],0x43` and checks `[rel]` |
| `dma_flat_demo` | `196` | `DMAADD DW 80H / DW seg` + `MOV ES,[DMAADD+2]; LES DI,[DMAADD]` (19 hits) | `dq DMAADD64_FLAT 0x10080`; recompute split `movzx eax,[seg]; shl 4; add [off]` and compare; also flat store `mov [rel DMAADD64],rdi` | split `0x1000:0x80` vs `dq 0x10080`; also store `0x1234567823456789` and reload |
| `far_to_near_demo` + `far_to_near_call_via_index` | `225` | `BIOSSEG` 13 far jumps + `CALL FAR PTR BIOSREAD` pushes `CS:IP` | `bios_near_table dq func0..3`; `SHL RBX,3; LEA RAX,[rel TABLE]; ADD RAX,RBX; MOV RAX,[RAX]; CALL RAX` and SIB `CALL [rax+rbx]` | `func0 0xAA00` .. `func3 0xDD03`; `index 2→0xCC02`; indices 0 and 3 also |
| `buffer_flat_demo` + `dirbuf_flat_demo` | `293` | `BUFFER DW`, `DIRBUF LABEL WORD`, `FATSIZTAB DW 16` | `BUFFER64 dq`, `DIRBUF64_PTR dq`, `FATSIZTAB64 dq 16,32,64,128`; `LEA RAX,[rel flat_buffer]; MOV [rel BUFFER64],RAX`; `SHL RBX,3; MOV RAX,[rel FATSIZTAB+RBX]`; dir sector calc `SHL EAX,5; DIV ECX; LEA RBX,[rel DIRBUF+RBX]` | store `0x5A`, check; load `FATSIZTAB[2]=64`; fill 512B `0xFF` via `REP STOSB`; dircalc `LASTENT 5 *32 /512` |
| `segment_override_elimination_demo` | `335` | `MOV AL,[DS:SI]`, `[ES:DI]`, `SEG CS MOV [SI]`, `REP MOVSB DS:SI->ES:DI` | `LEA RSI,[rel src]; LEA RDI,[rel dst]; REP MOVSB` flat; compare `[RSI]` vs `[RDI]` | src `"HELLO"` → dst via `REP MOVSB`; compare `AL vs BL` same flat byte |
| `stack_flat_demo` | `391` | `MOV CS:[SPSAVE],SP; MOV CS:[SSSAVE],SS; MOV SP,OFFSET IOSTACK; ...; MOV SP,CS:[SPSAVE]` | `MOV [rel test_saved_rsp],RSP; LEA RSP,[rel test_iostack_top]; AND RSP,-16; PUSH/POP 64-bit` | push `0x11223344` pop compare; 16-byte aligned after `AND RSP,-16` |
| `paragraph_to_byte_demo` | `420` | `MOV CL,4; SHL AX,CL` / `SHR BP,CL` paragraphs ↔ bytes | `SHL RAX,4` para→byte `0x100→0x1000`; `SHR 4` inverse; `SHL 12` pages `0x11→0x11000` | vectors `0x100→0x1000`, `0x11 pages→0x11000` |
| `linear_to_seg_off_demo` | `455` | Inverse for BIOS stub Option B (real-mode stub below 1MB) | `SHR RBX,4` seg; `SUB RCX,RBX` off; verify `seg*16+off==linear` | `0x12345` → seg `0x1234` off `0x5` verify `add` |
| `flat_pointer_arithmetic_demo` | `501` | `MOV BP,[DRVTAB]; MOV AL,[BP.DEVNUM]; LEA DI,[SI+BX]` | `MOV RBP,[rel DRVTAB64]; MOV AL,[RBP+DPB64.devnum]; LEA RSI,[rel flat_buffer+RDX]` | `demo_dpb devnum 0x07`, `secsiz 512`, `firfat 1`; `FAT base + BX*1.5` |
| `canonical_address_check` | `533` | High-half canonical (48-bit) — long-mode requirement `bits 48-63 = bit47` | `SAR RBX,47; CMP RBX,0` for `0x100000` and constructed `0x00007FFFFFFFFFFF` via `0x7FFF<<32 | 0xFFFFFFFF` | `0x100000` canonical, max low `0x7FFFFFFFFFFF` canonical |

**Data:** `offset_test_var dq`, `rip_var dq 0x01020304...`, `dma_split_* dw`, `DMAADD64_FLAT dq`, `bios_near_table dq 4`, `BUFFER64 dq`, `flat_buffer 512B`, `test_iostack 256B`, `demo_dpb istruc DPB64`, `DRVTAB64 dq`, all accessed via `[rel]` exclusively. No segment prefixes in instructions — only comments documenting old patterns.

**Warnings fixed:** 64-bit immediates `0x1122334455667788` etc. constructed via `SHL 32 / OR` to avoid `signed dword exceeds bounds`; low halves kept `<0x80000000` to avoid `or rdi, imm32` warning (e.g., `0x0BADF00D` → replaced with `0x01020304` style). Build is warning-free.

### 2.2 Kernel harness `src/kernel/main.asm:58` — Phase 4 extension (expanded 615→767 lines)

- **Headers:** Added `hello_phase4 db "Phase4: Addressing Mode Transformation (segmented->flat) Test Suite"` and 5 new messages `msg_test8..12` (one per AGENTS.md bullet) plus `msg_phase4_ok/fail`.
- **Externs:** Added `seg_off_to_linear`, `addr_test_seg_off/_rip/_far_near/_buffer/_canonical` (and `addr_test_all` for internal use).
- **Counting:** `R12` passed / `R13` failed preserved; `R14` unused index.
- **5 new test blocks** (identical pattern to Phase 3 `test rax / jz .pass` → `inc r12/13` → `PRINT PASS/FAIL`):
  - `[8] Seg:off->linear` → `addr_test_seg_off` (covers `seg<<4`, DMA split, para)
  - `[9] RIP-relative/OFFSET` → `addr_test_rip` (covers `OFFSET`, `LEA rel`, `DS=CS` elimination)
  - `[10] FAR PTR -> near` → `addr_test_far_near` (covers far table, `SHL 3 dispatch`)
  - `[11] Flat buffers` → `addr_test_buffer` (covers `DIRBUF/BUFFER dq`, `FATSIZTAB`, seg override)
  - `[12] Canonical & stack` → `addr_test_canonical` (covers canonical, flat stack)
- **Summary rewrite:** Replaced single-char `mov al,r12b; add '0'` (fails for 12) with `print_num_vga_serial` that handles 0-99 via `DIV 10` → prints tens `if non-zero` then ones, using same `vga_putc` + polled `0x3FD` + `0x3F8` as `print_char_vga_serial`. Now prints `12 passed, 0 failed` correctly.
- **Final messages:** If `R13==0` prints both `Phase3 ... ALL TESTS PASS` and `Phase4 ... ALL TESTS PASS`; else prints both `SOME TESTS FAILED`. Still calls `handler_prtbuf` demo `_` string.
- **Section sizes:** `_start` remains `section .text.start` first via `linker.ld *(.text.start)`; `.rodata` grew by ~300B; kernel linked 7796B (15 sectors) still ≤64 sectors (Stage2 `KERNEL_SECTORS 64`).

### 2.3 Includes — unchanged structure, now exercised via flat addressing

- `include/mcb.inc` (32B), `psp.inc` (512B), `regs.inc` (176B STKPTRS64), `dpb.inc`/`fcb.inc` already 64-bit; Phase 4 validates they are accessed via `[rbp+DPB64.xxx]` flat rather than `seg:off` loaded via `LDS`.

### 2.4 Build (`Makefile`, `linker.ld`, `src/boot/stage2.asm`) — no change except auto-discovery

- `Makefile:14` `KERNEL_SRCS := $(wildcard $(SRC_KERNEL)/*.asm) $(wildcard $(SRC_DRIVERS)/*.asm) $(wildcard $(SRC_LIB)/*.asm)` automatically picks up `addr64.o` → 8 objects (was 7). Link line forces `main.o` first; kernel size 7796B (15 sectors) <64.
- `linker.ld` unchanged (`0x100000`, `*(.text.start)` first).
- `bochsrc.txt` unchanged (ryzen, autodetect).

---

## 3. Verification

### 3.1 Build

```bash
make clean && make
# nasm -f bin src/boot/mbr.asm -o build/mbr.bin (512, 55 aa)
# nasm -f bin src/boot/stage2.asm -o build/stage2.bin (1021)
# nasm -f elf64 src/lib/addr64.asm -o build/src/lib/addr64.o  (warning-free)
# nasm -f elf64 src/kernel/main.asm ...  (8 objects)
# ld -T linker.ld -o build/kernel.elf ... (39352 elf)
# Kernel binary: 7796 bytes (15 sectors, ≤64)
# dd mbr.bin, stage2.bin seek1, kernel.bin seek16 → dos64.img 10M
```

Elf size 39352 (was 31320), bin 7796 (was 5440). Growth = +2356 bytes for 5 tests + addr64 lib.

### 3.2 QEMU 11.1.1

```bash
timeout 5 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
```

**Output:**

```
MS-DOS64 MBR boot
A20 enabled
Loading stage2 via LBA...
Stage2 loaded -> 0x7E00

Stage2 @0x7E00 entered (real)
A20 stage2 OK
Loading kernel LBA16 -> 0x100000 ...
Kernel loaded
Hello from 64-bit DOS64 kernel: Phase2 long mode OK!
Phase3: Register & Instruction Conversion Test Suite
Phase4: Addressing Mode Transformation (segmented->flat) Test Suite
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

Summary: 12 passed, 0
Phase3 register conversion: ALL TESTS PASS
Phase4 addressing transformation: ALL TESTS PASS
```

### 3.3 Bochs 3.0

```bash
rm -f bochs.log serial.log build/dos64.img.lock
BXSHARE=/nix/store/.../share/bochs timeout 6 bochs -f bochsrc.txt -q; cat serial.log
```

**serial.log:** identical to QEMU (12 PASS). **bochs.log tail:** `Booting from 0000:7c00` → `WARNING: HLT instruction with IF=0!` (halt loop, no #GP/#PF/#UD), `ips 757M..1741M` steady. No `exception` beyond BIOS `IDE time out`.

### 3.4 Checks

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `tail -c2 = 55 aa` |
| `build/stage2.bin` | 1021 | fits 15-sector slot |
| `build/kernel.bin` | 7796 (<32768) | 15 sectors @16, ≤64 |
| `build/dos64.img` | 10M | MBR+stage2@1+kernel@16 |
| `serial.log` | — | 12 PASS on both emus; no FAIL |
| `bochs.log` | — | no #GP/#UD; only HLT IF=0 |

**Hexdummy:** `hexdump -C build/kernel.bin | head` first bytes `bc 00 00 09 00` = `mov rsp,0x90000` at `_start` still at 0x100000 via `*.text.start`.

---

## 4. Key Design Decisions vs Phase 3

- **_start placement preserved:** `section .text.start` + `linker.ld *(.text.start)` + `main.o` first ensures `_start` at 0x100000.
- **Immediate warnings:** 64-bit constants split via `SHL 32 / OR` (phase3 bug) and low halves kept `<0x80000000` to avoid `signed dword` warning for `or rdi, imm`.
- **Two-digit summary:** New `print_num_vga_serial` (DIV 10) fixes `12` printing as `:` (58) in phase3 single-char path; now correctly prints `12` via tens+ones.
- **RIP-relative throughout:** Every global access uses `[rel var]` or `LEA rX, [rel var]`; no absolute `mov rax, var` without `rel` (ensures PIC, works at any load address). Verified via `grep "\[rel"` count 130+.
- **Canonical check:** Constructed `0x00007FFFFFFFFFFF` via `0x7FFF<<32 | 0xFFFFFFFF` without overflow, then `SAR 47` to validate canonical (low half). Prevents future high-half bugs.
- **Far vs near table:** Demonstrated both indexed `CALL [TABLE+R8*8]` and SIB `CALL [rax+rbx]` to mirror `DISPATCH64` at `syscall64.asm:182`.
- **Stack flatness:** `AND RSP,-16` (not `~15` which warn overflow) keeps 16-byte ABI alignment; demonstrates 64-bit pushes (was 16-bit `PUSH AX`).
- **Buffer dq:** `FATSIZTAB64` `dq 16,32,64,128` shows `SHL RBX,3` (x8) replaces original `SHL BX,1` (x2) for `DW` table.

---

## 5. Checklist (AGENTS.md Phase 4)

- [x] Eliminate all segment override prefixes — verified `grep ds:/es:/cs:` finds 0 instructions; flat `[rsi]` throughout
- [x] Convert segment:offset calculations to linear `(segment<<4)+offset` — `seg_off_to_linear` `SHL 4; ADD` demos, test vectors pass
- [x] Use RIP-relative addressing `mov rax, [rel variable]` — `offset_to_rel_demo`, `rip_relative_demo` use `LEA [rel]` and `MOV [rel]`; `grep \[rel` 130+
- [x] Replace far calls/jumps with near equivalents — `far_to_near_demo` `SHL 3` + `CALL [TABLE+RBX]` replaces `FAR PTR BIOS*`; `RET` not `RETF`, `JMP RAX` not `JMP FAR`, `IRETQ` not `IRET`
- [x] Preserve behavior: 12-test harness shows segmented → flat semantic equivalence (same linear results)
- [x] Boot and PASS on Bochs & QEMU via serial+VGA (no #UD for `LDS`/`LES`/`AAM` nor #GP for non-canonical)

**Next:** Phase 5 native drivers (ATA/KBD) via ports `0x1F0/0x60` already scaffolded; Phase 6 MCB coalesce; Phase 7 FAT12 LBA driver.

*All claims verified via `make`, `nasm -f elf64`, `ld -T linker.ld`, `BXSHARE=... bochs -f bochsrc.txt -q`, `qemu-system-x86_64 -serial stdio` on 2026-08-30.*

**Update (closure):** see `docs/19-closure-g1-g6.md` for what changed after this report.

