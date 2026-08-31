# MS-DOS64 — 64-bit BIOS Bootable DOS (from MS-DOS 1.25)

> Phase 1 (Architecture Analysis) **complete**. Phase 2 (Boot & Long Mode) **complete** — boots via BIOS MBR → 64-bit on Bochs & QEMU.

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

### Build & Run (Phase 2)

```bash
make            # builds build/mbr.bin (512B, 55AA checked) + stage2 + kernel + dos64.img
make run-bochs  # Bochs 3.0 ryzen, 256MiB, serial.log + VGA at 0xB8000
make run-qemu   # qemu-system-x86_64 -serial stdio alternative (also 64-bit)
make clean
```

**Verify boot:**

```bash
# Bochs (target)
rm -f bochs.log serial.log && make && BXSHARE=/nix/store/.../share/bochs timeout 8 bochs -f bochsrc.txt -q; cat serial.log
# Expected serial.log:
# MS-DOS64 MBR boot / A20 enabled / Loading stage2 via LBA... / Stage2 @0x7E00 ... / Kernel loaded
# Hello from 64-bit DOS64 kernel: Phase2 long mode OK!

# QEMU alternative
qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# Same visible via serial + VGA (0xB8000).
```

### Project Layout

```
AGENTS.md          conversion spec (12 phases + checklist)
MSDOS.ASM          kernel (4030 lines, DOSGROUP)
IO.ASM             IO.SYS + BIOS jump table (1933)
COMMAND.ASM        resident/transient shell (2165)
STDDOS.ASM         build wrapper (23)
src/boot/          mbr.asm (512B MBR, A20, INT13 LBA/CHS) + stage2.asm (real→protected→long) + gdt.asm
src/kernel/        main.asm (flat 0x100000, VGA+serial, 64-bit)
src/drivers/       vga.asm (0xB8000 text, cursor, scroll) — Phase 2 native driver
include/           fcb.inc/dpb.inc (64-bit strucs)
docs/              00-phase1-summary + 01..06 analysis + 07-phase2-boot (Phase 2 report)
bochsrc.txt        Bochs 3.0 ryzen, 256MiB, ata0 10MiB flat, VBE, serial.log
linker.ld          flat link at 0x100000
build/             mbr.bin, stage2.bin (≈1K), kernel.bin, dos64.img (10M)
```

## Source License

MIT, Copyright (c) Microsoft Corporation (see `LICENSE`).

## Phase 2 Status — Boot Chain Implemented

- **MBR** `src/boot/mbr.asm:1` 512B, A20 via port 0x92 + KBC 0x64/0x60, preserves `DL`, INT13h AH=42h LBA with CHS fallback, DAP at `0x7E00`, far `jmp 0:0x7E00`
- **Stage2** `src/boot/stage2.asm:8` @`0x7E00`, GDT32 `0x08/0x10` flat 4G, `lgdt`→`CR0.PE`→`JMP 0x08:pmode`, CPUID `0x80000001` LM check (EDX:29), `CR4.PAE`, zero `0x1000/0x2000/0x3000`, `PML4[0]=0x2003`, `PDPT[0]=0x3003`, `PD[0..3]=2MiB*4` (`0x83`) covering 0–8MiB, `CR3=0x1000`, `EFER.LME` via `0xC0000080`, `CR0.PG`, `lgdt64` (code `0xAF9A`, data `0xCF92`), `JMP 0x08:long_entry`, staging copy `0x80000→0x100000`
- **Kernel** `src/kernel/main.asm:8` `_start` at `0x100000`, `RSP=0x90000`, `init_serial64` COM1 38400, `vga_print_stub` @`0xB8000` (white-on-black) + `serial_print64`
- **Drivers** `src/drivers/vga.asm:1` native 0xB8000 driver (replaces INT10h), cursor via `0x3D4/0x3D5`, scroll, 80×25
- **Test** Bochs 3.0 `ryzen` + QEMU 11.1.1 both show `MS-DOS64 MBR boot … Hello from 64-bit DOS64 kernel: Phase2 long mode OK!` via serial (`serial.log`) and VGA.

See `docs/07-phase2-boot-implementation.md` for full mode-transition trace and validation.

