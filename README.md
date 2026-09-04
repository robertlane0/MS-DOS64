# MS-DOS64 — 64-bit BIOS Bootable DOS (from MS-DOS 1.25)

> Phase 1 (Architecture Analysis) **complete**. Phase 2 (Boot & Long Mode) **complete** — boots via BIOS MBR → 64-bit on Bochs & QEMU. **Phase 3 (Register & Instruction Conversion) complete** — 7/7 PASS. **Phase 4 (Addressing Mode Transformation) complete** — 12/12 PASS. **Phase 5 (BIOS Interrupt Replacement, Option C) complete** — 16/16 PASS (native VGA/ATA/KBD) on both emulators. **Phase 6 (Memory Management Overhaul) complete** — 21/21 PASS (MCB64 coalesce/resize/validate/protection, AH=48h/49h/4Ah) on both emulators. **Phase 7 (File System Adaptation) complete** — 27/27 PASS (FAT12 on LBA: BPB→DPB, chain, dir, FCB64) on both emulators. **Phase 8 (Process Management) complete** — 34/34 PASS (PSP64/env/loader/spawn/exit, AH=4Bh/4Ch, INT20h) on both emulators.

Original source: Microsoft MS-DOS v1.25 (MIT), Tim Paterson 86-DOS. This repo converts the 16-bit real-mode SCP dialect to a flat 64-bit long-mode OS that boots via legacy BIOS MBR on Bochs x86-64.

## Quick Start

### Phase 1 – Read the analysis

* `docs/00-phase1-summary.md` – completion report, scaffolding, risks
* `docs/01-architecture-overview.md` – 5-file inventory, kernel/IO/command roles
* `docs/02-bios-interrupts-and-drivers.md` – 13 BIOS far vectors → VGA/ATA/8042 replacements
* `docs/03-memory-layout.md` – maps 0x00000..0xFFFFF, PSP/FCB/DPB/DIRBUF, stacks
* `docs/04-16bit-constructs-and-conversion-map.md` – SCP→NASM, seg:off→flat, invalid opcodes (AAM/LDS)
* `docs/05-boot-and-testing-strategy.md` – MBR/stage2/paging/GDT plan + Bochs test stages
* `docs/06-syscall-reference.md` – 47 DOS functions (AH 00-46) table

All tables include `file:line` refs and were generated from live `grep -n` over the source.

### Build & Run (Phase 8 — Process Management)

```bash
make            # builds 512B MBR + stage2 (1K) + kernel (32K, 12 objs) + dos64.img (10M)
make run-bochs  # Bochs 3.0 ryzen, 256MiB, serial.log + VGA at 0xB8000
make run-qemu   # qemu-system-x86_64 -serial stdio alternative (also 64-bit)
make clean
```

**Verify boot (Phase 8):**

```bash
# Bochs (target) — remove stale lock first
rm -f bochs.log serial.log build/dos64.img.lock && make && BXSHARE=/nix/store/.../share/bochs timeout 25 bochs -f bochsrc.txt -q; cat serial.log
# Expected serial.log:
# MS-DOS64 MBR boot / A20 enabled / Loading stage2 via LBA... / Stage2 @0x7E00 ... / Kernel loaded
# Hello from 64-bit DOS64 kernel: Phase2 long mode OK!
# Phase3: Register & Instruction Conversion Test Suite / Phase4: Addressing ... / Phase5: BIOS Interrupt Replacement — Native Drivers (Option C)
# Phase6: Memory Management Overhaul — MCB64, para/page, coalesce, protection
# Phase7: File System Adaptation — FAT12 on LBA, DPB/DIR/FCB64
# Phase8: Process Management — PSP64, ENV, Loader, EXEC/EXIT
#  [1]...PASS ... [27]...PASS / [28]...PASS ... [34]...PASS / Summary: 34 passed, 0 failed / Phase8 process management (PSP64): ALL TESTS PASS
# Note: [30]/[32]/[33] emit single-letter progress markers (A–N/a–h/p–$) before PASS (fail-point isolation).

# QEMU alternative (also shows Phase8 suite)
timeout 10 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none

# Quick QEMU verify:
# Phase8: Process Management ... / [1]...PASS ... [34]...PASS / Summary: 34 passed, 0 failed
```

### Project Layout

```
AGENTS.md          conversion spec (12 phases + checklist)
MSDOS.ASM          kernel (4030 lines, DOSGROUP)
IO.ASM             IO.SYS + BIOS jump table (1933)
COMMAND.ASM        resident/transient shell (2165)
STDDOS.ASM         build wrapper (23)
src/boot/          mbr.asm (512B MBR, A20, INT13 LBA/CHS) + stage2.asm (real→protected→long, 64 sectors) + gdt.asm
src/kernel/        main.asm (Phase8 harness, 34 tests, _start @0x100000) + fat64.asm (UNPACK/PACK) + fs64.asm (FAT12 on LBA: BPB/chain/dir/FCB64, 19 exports) + mem64.asm (MCB64: coalesce/resize/validate/protect, 24 exports) + proc64.asm (PSP64/env/loader/spawn/exit, 21 exports) + syscall64.asm (SAVREGS/DISPATCH64 77 entries, AH=48h/49h/4Ah/4Bh/4Ch, I/O+DSK 4K stacks)
src/drivers/       vga.asm (0xB8000 text, cursor, scroll) + ata.asm (0x1F0 PIO LBA28, CHS→LBA) + kbd.asm (0x60/0x64 PS/2, queue, tables) — native Option C
src/lib/           string64.asm (REP/LOOP/XLAT) + bcd64.asm (AAM/AAD→DIV, CBW etc.) + addr64.asm (seg:off→linear, RIP-rel, far→near)
include/           fcb.inc/dpb.inc/psp.inc/mcb.inc/regs.inc/fs.inc (64-bit strucs, STKPTRS64, DIRENT, BPB)
docs/              00-phase1-summary + 01..06 analysis + 07-phase2-boot + 08-phase3-register-conversion + 09-phase4-addressing + 10-phase5-bios-drivers + 11-phase6-memory + 12-phase7-filesystem + 13-phase8-process (Phase 8 report)
bochsrc.txt        Bochs 3.0 ryzen, 256MiB, ata0 10MiB flat, VBE, serial.log
linker.ld          flat link at 0x100000 (*.text.start first)
build/             mbr.bin, stage2.bin (≈1K), kernel.bin (32K, 62 sec), kernel.elf (103K), dos64.img (10M)
```

## Source License

MIT, Copyright (c) Microsoft Corporation (see `LICENSE`).

## Phase 2 Status — Boot Chain Implemented (retained)

- **MBR** `src/boot/mbr.asm:1` 512B, A20 via port 0x92 + KBC 0x64/0x60, preserves `DL`, INT13h AH=42h LBA with CHS fallback, DAP at `0x7E00`, far `jmp 0:0x7E00`
- **Stage2** `src/boot/stage2.asm:8` @`0x7E00`, GDT32 `0x08/0x10` flat 4G, `lgdt`→`CR0.PE`→`JMP 0x08:pmode`, CPUID `0x80000001` LM check (EDX:29), `CR4.PAE`, zero `0x1000/0x2000/0x3000`, `PML4[0]=0x2003`, `PDPT[0]=0x3003`, `PD[0..3]=2MiB*4` (`0x83`) covering 0–8MiB, `CR3=0x1000`, `EFER.LME` via `0xC0000080`, `CR0.PG`, `lgdt64` (code `0xAF9A`, data `0xCF92`), `JMP 0x08:long_entry`, staging copy `0x80000→0x100000` (64 sectors)
- **Kernel (Phase2)** `_start` at `0x100000` via `*.text.start` first, `RSP=0x90000`, `init_serial64` COM1 38400, `vga_print` @`0xB8000`
- **Drivers** `src/drivers/vga.asm:1` native 0xB8000 driver (replaces INT10h), cursor via `0x3D4/0x3D5`, scroll, 80×25
- **Test** Bochs 3.0 `ryzen` + QEMU 11.1.1 both show `MS-DOS64 MBR boot … Hello from 64-bit DOS64 kernel: Phase2 long mode OK!`.

See `docs/07-phase2-boot-implementation.md` for full mode-transition trace. See `docs/08-phase3-register-conversion.md` for Phase 3 proof. See `docs/09-phase4-addressing.md` for Phase 4 proof. See `docs/10-phase5-bios-drivers.md` for Phase 5 Option C (native drivers) proof.

## Phase 3 Status — Register & Instruction Conversion Complete (retained)

- **Census** 1,200+ register hits converted (`AX→RAX`/`BX→RBX`/`CX→RCX`/`DX→RDX`/`SI→RSI`/`DI→RDI`/`BP→RBP`/`SP→RSP`), `R8–R15` new temps, 47 `dw`→`dq` dispatch, flat `rel` addressing.
- **Invalid opcodes** 8× `AAM`/`AAD` replaced via `DIV 10`/`IMUL 10` (`src/lib/bcd64.asm:1`), 13× `LDS`/`LES` replaced via `mov rsi,[rel DMAADD64]` (`src/kernel/fat64.asm:1`), `LOOP`→`DEC RCX/JNZ`, `XLAT`→`MOV [RBX+RAX]`, `CBW`→`MOVSX/CDQE/CQO` (`src/lib/string64.asm:1`).
- **Kernel modules** `fat64` (UNPACK/PACK), `syscall64` (SAVREGS/LEAVE 64-bit stack switch `IOSTACK64/DSKSTACK64`, `SHL RBX,3` dispatch), `mem64` (MCB64 32B, para `SHL 4`→byte), `string64`/`bcd64` libs.
- **Includes** `psp.inc` (512B), `mcb.inc` (32B), `regs.inc` (STKPTRS64 176B, IRETQ 5 qwords).
- **Harness** `src/kernel/main.asm:16` `_start` (`section .text.start`) runs 7 self-tests: register/R8-R15, REP string, BCD, FAT, MCB, DMA, syscall. Prints via `vga_print` + `serial_print64` (polled `0x3FD`).
- **Build** `Makefile:44` builds 7 `elf64` objects, `ld -T linker.ld` places `main.o` first, `KERNEL_SECTORS=64` (32 KiB) for 5.4K kernel (10 sectors used). `make` → `build/kernel.bin` (5440B) + `dos64.img` (10M).
- **Test** Both emulators show **`[1]...PASS` through `[7]...PASS / Summary: 7 passed, 0 failed / Phase3 register conversion: ALL TESTS PASS`** (see serial.log). No `#UD`/`#GP` (AAM etc. would fault).

## Phase 4 Status — Addressing Mode Transformation Complete (retained)

- **Census** 47 `OFFSET DOSGROUP:xxx` → `lea rsi,[rel var]`, 13 `FAR PTR BIOS*` → `dq` near dispatch `SHL 3`, 19 `DMAADD` split `DW`→`dq` linear, 40 `SEG` overrides eliminated, all `LDS`/`LES` → flat `mov r64,[rel]`.
- **Flat conversions** `seg_off_to_linear (seg<<4+off)` (`src/lib/addr64.asm:10`), `OFFSET→rel` (`offset_to_rel_demo`), `RIP-relative` (`rip_relative_demo`), `FAR→near` (`far_to_near_demo` `bios_near_table`), `DIRBUF/BUFFER/FATSIZTAB DW→dq` (`buffer_flat_demo`), `DS=CS` alias elimination (`dosgroup_alias_elimination_demo`), `segment override` → flat `REP MOVSB` (`segment_override_elimination_demo`), `stack flat` (`stack_flat_demo`), `para SHL4`/`SHL12`, `canonical` (`SAR 47`).
- **Kernel modules** `addr64` (685 lines, 14 exports, 8 sub-demos) + updated `main` harness now 12 tests (Phase3 7 + Phase4 5).
- **Build** `Makefile:44` now builds 8 `elf64` objects (added `addr64.o`), `ld -T linker.ld` still `main.o` first, kernel 7796B (15 sectors, ≤64). `make` → `build/kernel.bin` (7.8K) + `dos64.img` (10M).
- **Test** Both emulators now show **`[1]...PASS` through `[12]...PASS / Summary: 12 passed, 0 failed / Phase3 ... ALL TESTS PASS / Phase4 addressing transformation: ALL TESTS PASS`** (serial.log + VGA 0xB8000). No `#GP` for non-canonical or segment-load faults.

## Phase 5 Status — BIOS Interrupt Replacement (Option C) Complete

- **Census** 13 `FAR PTR BIOS*` jump table eliminated, `INT 10h` → `vga.asm` `0xB8000`, `INT 13h` CHS → `ata.asm` LBA28 PIO `0x1F0`, `INT 16h` → `kbd.asm` `0x60/0x64` (docs/02). All `IN`/`OUT` to `0xF0` SCP ports gone.
- **VGA** `src/drivers/vga.asm:1` 161 lines, `vga_init/clear/putc/print/set_cursor/scroll` — `0xB8000` `80×25×2`, `0x3D4/0x3D5`, attribute `0x0F`, verified via `[16] VGA 'V'` at `0xB8000` + CRLF.
- **ATA** `src/drivers/ata.asm:1` 843 lines, 13 exports: `ata_init` gentle wait, `ata_read_lba28`/`ata_write_lba28` `0x20`/`0x30` 256-word `IN AX`/`OUT AX` polling `BSY/DRQ` 1M timeout, `chs_to_lba`/`lba_to_chs_demo` `IMUL` 64-bit (fix `0x10` sector bug), `ata_test_mbr_read` `0xAA55` at LBA0, `ata_test_write_readback` LBA100 pattern `0xA5`, `ATA_TIMEOUT 1M` (4M init).
- **KBD** `src/drivers/kbd.asm:1` 368 lines, 12 exports: `kbd_init` `0xAE`+`0xF4`/`0xFA`, `kbd_poll` `OBF 0x01`, `kbd_queue` 128B `&0x7F`, `scancode_table`/`shift_table` 128B, `kbd_scancode_to_ascii` shift `0x2A/0x36` + caps `0x3A`, `kbd_test_status/queue/translation` (`'a'→'A'`, `'1'→'!'`, caps, space/enter).
- **Kernel modules** `main` now 967 lines, 16 tests (Phase3 7 + Phase4 5 + Phase5 4: `[13] MBR+CHS`, `[14] write`, `[15] kbd queue`, `[16] kbd+VGA`), `print_hex8/16` debug helpers, `ata/kbd` externs.
- **Build** `Makefile:14` now 10 `elf64` objects (+`ata.o`/`kbd.o`), kernel `11212B` (21 sectors, ≤64), `52008 elf`. `make` → `build/kernel.bin` (11K) + `dos64.img` (10M).
- **Test** Both emulators now show **`[1]...PASS` through `[16]...PASS / Summary: 16 passed, 0 failed / Phase3 ... ALL TESTS PASS / Phase4 ... ALL TESTS PASS / Phase5 BIOS replacement (Option C): ALL TESTS PASS`** (serial.log + VGA). No BIOS `INT` in long mode, no `#GP` on ports.

## Phase 6 Status — Memory Management Overhaul (MCB64) Complete

- **Scope** DOS 1.25 had no MCB (only `SETMEM`/`MEMSCAN` paragraphs); Phase 6 adds a full byte-based manager: para/page conversions (`SHL 4`/`SHL 12`), 64-bit `owner dq` chain `0x200000–0x800000`, first-fit split, prev+next coalesce, in-place resize, aligned/page alloc, validation + stats, 2 MiB PS `RW/NX` protection.
- **Kernel modules** `mem64.asm` 1199 lines, 24 exports (`mem_validate/resize/alloc_aligned/pages/total/count/protect_range/...`); `syscall64.asm` `DISPATCH64` 47→77 entries, `AH=48h/49h/4Ah` handlers, `AH`-from-frame dispatch with balanced 15-push `leave64`; `main` 1737 lines, 21 tests (`[17]` para/page, `[18]` coalesce, `[19]` resize, `[20]` protection, `[21]` stress).
- **Build** same 10 `elf64` objects, kernel `16860B` (32 sectors, ≤64), `65784 elf`. `make` → `build/kernel.bin` (17K) + `dos64.img` (10M).
- **Test** Both emulators show **`[1]...PASS` through `[21]...PASS / Summary: 21 passed, 0 failed`** plus all four `ALL TESTS PASS` banners (serial.log + VGA). No `#UD/#GP/#PF`.
- **Bugs fixed under GDB** 6 defects: `bl`/`rbx` clobber in walkers, missing `pop rdx` (resize/aligned), `AL`/`RAX` aliasing (shrink/aligned splits), `~align` vs `~(align-1)` mask, grow-split −40 accounting, dispatch-on-`SS` + 14/15 imbalance.

See `docs/11-phase6-memory.md` for the full report.

## Phase 7 Status — File System Adaptation (FAT12 on LBA) Complete

- **Scope** DOS 1.25 FAT12 (`UNPACK/PACK`, `GETENTRY`, `FATREAD`, `DIRREAD`, `DREAD/DWRITE` via BIOS, CHS) → flat 64-bit on native ATA LBA28 PIO: BPB→DPB init, cluster→LBA (`firrec+(c-2)*spc`), 12-bit chain with EOF/free, root-dir find (deleted/end/wildcard), `DREAD/DWRITE/DIRREAD` wrappers, multi-cluster file read, `FCB64` open with 64-bit `filsiz/rr`/DMA-linear.
- **Kernel modules** `fs64.asm` 19 exports (`fs_bpb_parse64/cluster_to_lba/fat_sector/get/set_cluster/is_eof/free/dir_find/dir_get_*/dread/dwrite/dir_read/write/fcb_open/file_read_cluster` + 6 `fs_test_*`); `include/fs.inc` (`DIRENT`, BPB offsets, `FAT12_*`, scratch LBAs 500–511); `main` 27 tests (`[22]` BPB/LBA, `[23]` chain, `[24]` dir, `[25]` LBA I/O, `[26]` file read, `[27]` FCB64).
- **Build** 11 `elf64` objects (+`fs64.o`), kernel `22644B` (44 sectors, ≤64). `make` → `build/kernel.bin` (23K) + `dos64.img` (10M).
- **Test** Both emulators show **`[1]...PASS` through `[27]...PASS / Summary: 27 passed, 0 failed`** plus all five `ALL TESTS PASS` banners (serial.log + VGA). No `#UD/#GP/#PF`.
- **Bugs fixed** 6 defects: LBA return clobbered by `pop rcx`, HELLO test-entry typo (`OM ` vs `COM`), FAT-base `RSI` clobbered across ATA reads, `DH`-with-REX encoding, `cmp r64,imm64` bounds, 4-byte stores over `attr`/`extent`.

See `docs/12-phase7-filesystem.md` for the full report.

## Phase 8 Status — Process Management (PSP64) Complete

- **Scope** DOS 1.25 `SETMEM`/`ABORT` + `COMMAND COMLOAD/EXELOAD` → flat 64-bit: `PSP64` init/validate/cmd/exit/fd/CR3, `ENV` double-NUL blocks, COM raw + `EXE64 MZ64` loader, spawn/terminate/reap lifecycle (`owner=PSP`), `INT 21h AH=4Bh EXEC/4Ch EXIT` + `INT 20h ABORT` via `DISPATCH64`, 4 KiB trap stacks.
- **Kernel modules** `proc64.asm` 21 exports (`psp_init/validate/cmd/exit`, `env_init/count/get/set/unset`, `verify/load/spawn/terminate/exit_current/reap/free_all` + `next_pid/current/state/pid` introspection); `syscall64.asm` `DISPATCH64[4Bh/4Ch]`, `SAVREGS/LEAVE` frame-correct, `cmp ah` dispatch; `main` 34 tests (`[28]` PSP, `[29]` cmd, `[30]` ENV, `[31]` loader, `[32]` spawn, `[33]` EXEC/EXIT, `[34]` stress).
- **Build** 12 `elf64` objects (+`proc64.o`), kernel `31756B` (62 sectors, ≤64). `make` → `build/kernel.bin` (32K) + `dos64.img` (10M).
- **Test** Both emulators show **`[1]...PASS` through `[34]...PASS / Summary: 34 passed, 0 failed`** plus all six `ALL TESTS PASS` banners (serial.log + VGA). No `#UD/#GP/#PF`. `[30]/[32]/[33]` emit single-letter progress markers before `PASS` (fail-point isolation).
- **Bugs fixed** 10 defects: local-dot `strlen` scoping, RIP+SIB ×37, `RSI` vs `RDI` helper ABI, `env_unset` stack + find-miss, `bl`/`RBX=out_size` clobber, `MCB-32` vs `40` owner smash, `cmp eax` vs `ah` dispatch-always-bad, `push/pop` order + `SPSAVE` byte, replace-tail `RCX` overwrite, test `AL`-before-save.

See `docs/13-phase8-process.md` for the full report.

