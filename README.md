# MS-DOS64 — 64-bit BIOS Bootable DOS (from MS-DOS 1.25)

> Phase 1 (Architecture Analysis) **complete**. Phase 2 (Boot & Long Mode) **complete** — boots via BIOS MBR → 64-bit on Bochs & QEMU. **Phase 3 (Register & Instruction Conversion) complete** — 7/7 self-tests PASS on both emulators.

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

### Build & Run (Phase 3)

```bash
make            # builds 512B MBR + stage2 (1K) + kernel (5.4K, 7 objs) + dos64.img (10M)
make run-bochs  # Bochs 3.0 ryzen, 256MiB, serial.log + VGA at 0xB8000
make run-qemu   # qemu-system-x86_64 -serial stdio alternative (also 64-bit)
make clean
```

**Verify boot (Phase 3):**

```bash
# Bochs (target) — remove stale lock first
rm -f bochs.log serial.log build/dos64.img.lock && make && BXSHARE=/nix/store/.../share/bochs timeout 8 bochs -f bochsrc.txt -q; cat serial.log
# Expected serial.log:
# MS-DOS64 MBR boot / A20 enabled / Loading stage2 via LBA... / Stage2 @0x7E00 ... / Kernel loaded
# Hello from 64-bit DOS64 kernel: Phase2 long mode OK!
# Phase3: Register & Instruction Conversion Test Suite / 7 PASS / ALL TESTS PASS

# QEMU alternative (also shows Phase3 suite)
timeout 5 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none

# Quick QEMU verify:
# Phase3: Register & Instruction Conversion Test Suite / [1]...PASS ... [7]...PASS / Summary: 7 passed, 0 failed
```

### Project Layout

```
AGENTS.md          conversion spec (12 phases + checklist)
MSDOS.ASM          kernel (4030 lines, DOSGROUP)
IO.ASM             IO.SYS + BIOS jump table (1933)
COMMAND.ASM        resident/transient shell (2165)
STDDOS.ASM         build wrapper (23)
src/boot/          mbr.asm (512B MBR, A20, INT13 LBA/CHS) + stage2.asm (real→protected→long, 64 sectors) + gdt.asm
src/kernel/        main.asm (Phase3 harness, 7 tests, _start @0x100000) + fat64.asm (UNPACK/PACK) + mem64.asm (MCB64) + syscall64.asm (SAVREGS/DISPATCH)
src/drivers/       vga.asm (0xB8000 text, cursor, scroll) — native driver
src/lib/           string64.asm (REP/LOOP/XLAT) + bcd64.asm (AAM/AAD→DIV, CBW etc.)
include/           fcb.inc/dpb.inc/psp.inc/mcb.inc/regs.inc (64-bit strucs, STKPTRS64)
docs/              00-phase1-summary + 01..06 analysis + 07-phase2-boot + 08-phase3-register-conversion (Phase 3 report)
bochsrc.txt        Bochs 3.0 ryzen, 256MiB, ata0 10MiB flat, VBE, serial.log
linker.ld          flat link at 0x100000 (*.text.start first)
build/             mbr.bin, stage2.bin (≈1K), kernel.bin (5.4K, 10 sec), kernel.elf (31K), dos64.img (10M)
```

## Source License

MIT, Copyright (c) Microsoft Corporation (see `LICENSE`).

## Phase 2 Status — Boot Chain Implemented (retained)

- **MBR** `src/boot/mbr.asm:1` 512B, A20 via port 0x92 + KBC 0x64/0x60, preserves `DL`, INT13h AH=42h LBA with CHS fallback, DAP at `0x7E00`, far `jmp 0:0x7E00`
- **Stage2** `src/boot/stage2.asm:8` @`0x7E00`, GDT32 `0x08/0x10` flat 4G, `lgdt`→`CR0.PE`→`JMP 0x08:pmode`, CPUID `0x80000001` LM check (EDX:29), `CR4.PAE`, zero `0x1000/0x2000/0x3000`, `PML4[0]=0x2003`, `PDPT[0]=0x3003`, `PD[0..3]=2MiB*4` (`0x83`) covering 0–8MiB, `CR3=0x1000`, `EFER.LME` via `0xC0000080`, `CR0.PG`, `lgdt64` (code `0xAF9A`, data `0xCF92`), `JMP 0x08:long_entry`, staging copy `0x80000→0x100000` (64 sectors)
- **Kernel (Phase2)** `_start` at `0x100000` via `*.text.start` first, `RSP=0x90000`, `init_serial64` COM1 38400, `vga_print` @`0xB8000`
- **Drivers** `src/drivers/vga.asm:1` native 0xB8000 driver (replaces INT10h), cursor via `0x3D4/0x3D5`, scroll, 80×25
- **Test** Bochs 3.0 `ryzen` + QEMU 11.1.1 both show `MS-DOS64 MBR boot … Hello from 64-bit DOS64 kernel: Phase2 long mode OK!`.

See `docs/07-phase2-boot-implementation.md` for full mode-transition trace. See `docs/08-phase3-register-conversion.md` for Phase 3 (register/instruction) proof.

## Phase 3 Status — Register & Instruction Conversion Complete

- **Census** 1,200+ register hits converted (`AX→RAX`/`BX→RBX`/`CX→RCX`/`DX→RDX`/`SI→RSI`/`DI→RDI`/`BP→RBP`/`SP→RSP`), `R8–R15` new temps, 47 `dw`→`dq` dispatch, flat `rel` addressing.
- **Invalid opcodes** 8× `AAM`/`AAD` replaced via `DIV 10`/`IMUL 10` (`src/lib/bcd64.asm:1`), 13× `LDS`/`LES` replaced via `mov rsi,[rel DMAADD64]` (`src/kernel/fat64.asm:1`), `LOOP`→`DEC RCX/JNZ`, `XLAT`→`MOV [RBX+RAX]`, `CBW`→`MOVSX/CDQE/CQO` (`src/lib/string64.asm:1`).
- **Kernel modules** `fat64` (UNPACK/PACK), `syscall64` (SAVREGS/LEAVE 64-bit stack switch `IOSTACK64/DSKSTACK64`, `SHL RBX,3` dispatch), `mem64` (MCB64 32B, para `SHL 4`→byte), `string64`/`bcd64` libs.
- **Includes** `psp.inc` (512B), `mcb.inc` (32B), `regs.inc` (STKPTRS64 176B, IRETQ 5 qwords).
- **Harness** `src/kernel/main.asm:16` `_start` (`section .text.start`) runs 7 self-tests: register/R8-R15, REP string, BCD, FAT, MCB, DMA, syscall. Prints via `vga_print` + `serial_print64` (polled `0x3FD`).
- **Build** `Makefile:44` builds 7 `elf64` objects, `ld -T linker.ld` places `main.o` first, `KERNEL_SECTORS=64` (32 KiB) for 5.4K kernel (10 sectors used). `make` → `build/kernel.bin` (5440B) + `dos64.img` (10M).
- **Test** Both emulators show **`[1]...PASS` through `[7]...PASS / Summary: 7 passed, 0 failed / Phase3 register conversion: ALL TESTS PASS`** (see serial.log). No `#UD`/`#GP` (AAM etc. would fault).

