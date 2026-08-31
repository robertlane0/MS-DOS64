# MS-DOS64 — 64-bit BIOS Bootable DOS (from MS-DOS 1.25)

> Phase 1 (Architecture Analysis) **complete**. Phase 2 (Boot & Long Mode) **complete** — boots via BIOS MBR → 64-bit on Bochs & QEMU. **Phase 3 (Register & Instruction Conversion) complete** — 7/7 PASS. **Phase 4 (Addressing Mode Transformation) complete** — 12/12 PASS (segmented→flat) on both emulators.

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

### Build & Run (Phase 4)

```bash
make            # builds 512B MBR + stage2 (1K) + kernel (7.8K, 8 objs) + dos64.img (10M)
make run-bochs  # Bochs 3.0 ryzen, 256MiB, serial.log + VGA at 0xB8000
make run-qemu   # qemu-system-x86_64 -serial stdio alternative (also 64-bit)
make clean
```

**Verify boot (Phase 4):**

```bash
# Bochs (target) — remove stale lock first
rm -f bochs.log serial.log build/dos64.img.lock && make && BXSHARE=/nix/store/.../share/bochs timeout 8 bochs -f bochsrc.txt -q; cat serial.log
# Expected serial.log:
# MS-DOS64 MBR boot / A20 enabled / Loading stage2 via LBA... / Stage2 @0x7E00 ... / Kernel loaded
# Hello from 64-bit DOS64 kernel: Phase2 long mode OK!
# Phase3: Register & Instruction Conversion Test Suite / Phase4: Addressing Mode Transformation ... / 12 PASS / ALL TESTS PASS

# QEMU alternative (also shows Phase4 suite)
timeout 5 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none

# Quick QEMU verify:
# Phase4: Addressing Mode Transformation ... / [1]...PASS ... [12]...PASS / Summary: 12 passed, 0 failed
```

### Project Layout

```
AGENTS.md          conversion spec (12 phases + checklist)
MSDOS.ASM          kernel (4030 lines, DOSGROUP)
IO.ASM             IO.SYS + BIOS jump table (1933)
COMMAND.ASM        resident/transient shell (2165)
STDDOS.ASM         build wrapper (23)
src/boot/          mbr.asm (512B MBR, A20, INT13 LBA/CHS) + stage2.asm (real→protected→long, 64 sectors) + gdt.asm
src/kernel/        main.asm (Phase4 harness, 12 tests, _start @0x100000) + fat64.asm (UNPACK/PACK) + mem64.asm (MCB64) + syscall64.asm (SAVREGS/DISPATCH)
src/drivers/       vga.asm (0xB8000 text, cursor, scroll) — native driver
src/lib/           string64.asm (REP/LOOP/XLAT) + bcd64.asm (AAM/AAD→DIV, CBW etc.) + addr64.asm (seg:off→linear, RIP-rel, far→near)
include/           fcb.inc/dpb.inc/psp.inc/mcb.inc/regs.inc (64-bit strucs, STKPTRS64)
docs/              00-phase1-summary + 01..06 analysis + 07-phase2-boot + 08-phase3-register-conversion + 09-phase4-addressing (Phase 4 report)
bochsrc.txt        Bochs 3.0 ryzen, 256MiB, ata0 10MiB flat, VBE, serial.log
linker.ld          flat link at 0x100000 (*.text.start first)
build/             mbr.bin, stage2.bin (≈1K), kernel.bin (7.8K, 15 sec), kernel.elf (39K), dos64.img (10M)
```

## Source License

MIT, Copyright (c) Microsoft Corporation (see `LICENSE`).

## Phase 2 Status — Boot Chain Implemented (retained)

- **MBR** `src/boot/mbr.asm:1` 512B, A20 via port 0x92 + KBC 0x64/0x60, preserves `DL`, INT13h AH=42h LBA with CHS fallback, DAP at `0x7E00`, far `jmp 0:0x7E00`
- **Stage2** `src/boot/stage2.asm:8` @`0x7E00`, GDT32 `0x08/0x10` flat 4G, `lgdt`→`CR0.PE`→`JMP 0x08:pmode`, CPUID `0x80000001` LM check (EDX:29), `CR4.PAE`, zero `0x1000/0x2000/0x3000`, `PML4[0]=0x2003`, `PDPT[0]=0x3003`, `PD[0..3]=2MiB*4` (`0x83`) covering 0–8MiB, `CR3=0x1000`, `EFER.LME` via `0xC0000080`, `CR0.PG`, `lgdt64` (code `0xAF9A`, data `0xCF92`), `JMP 0x08:long_entry`, staging copy `0x80000→0x100000` (64 sectors)
- **Kernel (Phase2)** `_start` at `0x100000` via `*.text.start` first, `RSP=0x90000`, `init_serial64` COM1 38400, `vga_print` @`0xB8000`
- **Drivers** `src/drivers/vga.asm:1` native 0xB8000 driver (replaces INT10h), cursor via `0x3D4/0x3D5`, scroll, 80×25
- **Test** Bochs 3.0 `ryzen` + QEMU 11.1.1 both show `MS-DOS64 MBR boot … Hello from 64-bit DOS64 kernel: Phase2 long mode OK!`.

See `docs/07-phase2-boot-implementation.md` for full mode-transition trace. See `docs/08-phase3-register-conversion.md` for Phase 3 (register/instruction) proof. See `docs/09-phase4-addressing.md` for Phase 4 (addressing) proof.

## Phase 3 Status — Register & Instruction Conversion Complete (retained)

- **Census** 1,200+ register hits converted (`AX→RAX`/`BX→RBX`/`CX→RCX`/`DX→RDX`/`SI→RSI`/`DI→RDI`/`BP→RBP`/`SP→RSP`), `R8–R15` new temps, 47 `dw`→`dq` dispatch, flat `rel` addressing.
- **Invalid opcodes** 8× `AAM`/`AAD` replaced via `DIV 10`/`IMUL 10` (`src/lib/bcd64.asm:1`), 13× `LDS`/`LES` replaced via `mov rsi,[rel DMAADD64]` (`src/kernel/fat64.asm:1`), `LOOP`→`DEC RCX/JNZ`, `XLAT`→`MOV [RBX+RAX]`, `CBW`→`MOVSX/CDQE/CQO` (`src/lib/string64.asm:1`).
- **Kernel modules** `fat64` (UNPACK/PACK), `syscall64` (SAVREGS/LEAVE 64-bit stack switch `IOSTACK64/DSKSTACK64`, `SHL RBX,3` dispatch), `mem64` (MCB64 32B, para `SHL 4`→byte), `string64`/`bcd64` libs.
- **Includes** `psp.inc` (512B), `mcb.inc` (32B), `regs.inc` (STKPTRS64 176B, IRETQ 5 qwords).
- **Harness** `src/kernel/main.asm:16` `_start` (`section .text.start`) runs 7 self-tests: register/R8-R15, REP string, BCD, FAT, MCB, DMA, syscall. Prints via `vga_print` + `serial_print64` (polled `0x3FD`).
- **Build** `Makefile:44` builds 7 `elf64` objects, `ld -T linker.ld` places `main.o` first, `KERNEL_SECTORS=64` (32 KiB) for 5.4K kernel (10 sectors used). `make` → `build/kernel.bin` (5440B) + `dos64.img` (10M).
- **Test** Both emulators show **`[1]...PASS` through `[7]...PASS / Summary: 7 passed, 0 failed / Phase3 register conversion: ALL TESTS PASS`** (see serial.log). No `#UD`/`#GP` (AAM etc. would fault).

## Phase 4 Status — Addressing Mode Transformation Complete

- **Census** 47 `OFFSET DOSGROUP:xxx` → `lea rsi,[rel var]`, 13 `FAR PTR BIOS*` → `dq` near dispatch `SHL 3`, 19 `DMAADD` split `DW`→`dq` linear, 40 `SEG` overrides eliminated, all `LDS`/`LES` → flat `mov r64,[rel]`.
- **Flat conversions** `seg_off_to_linear (seg<<4+off)` (`src/lib/addr64.asm:10`), `OFFSET→rel` (`offset_to_rel_demo`), `RIP-relative` (`rip_relative_demo`), `FAR→near` (`far_to_near_demo` `bios_near_table`), `DIRBUF/BUFFER/FATSIZTAB DW→dq` (`buffer_flat_demo`), `DS=CS` alias elimination (`dosgroup_alias_elimination_demo`), `segment override` → flat `REP MOVSB` (`segment_override_elimination_demo`), `stack flat` (`stack_flat_demo`), `para SHL4`/`SHL12`, `canonical` (`SAR 47`).
- **Kernel modules** `addr64` (685 lines, 14 exports, 8 sub-demos) + updated `main` harness now 12 tests (Phase3 7 + Phase4 5).
- **Build** `Makefile:44` now builds 8 `elf64` objects (added `addr64.o`), `ld -T linker.ld` still `main.o` first, kernel 7796B (15 sectors, ≤64). `make` → `build/kernel.bin` (7.8K) + `dos64.img` (10M).
- **Test** Both emulators now show **`[1]...PASS` through `[12]...PASS / Summary: 12 passed, 0 failed / Phase3 ... ALL TESTS PASS / Phase4 addressing transformation: ALL TESTS PASS`** (serial.log + VGA 0xB8000). No `#GP` for non-canonical or segment-load faults.

