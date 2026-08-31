# MS-DOS64 — 64-bit BIOS Bootable DOS (from MS-DOS 1.25)

> Phase 1 (Architecture Analysis) complete. Phase 2 boot implementation pending.

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

### Build (scaffold)

```bash
make            # builds build/mbr.bin (512B, 55AA checked) + stage2 + kernel + dos64.img
make run-bochs  # requires Bochs with BIOS-bochs-latest
make run-qemu   # qemu-system-x86_64 alternative
make clean
```

Phase 1 builds stubs that print "Phase2 pending" and halt — intended.

### Project Layout

```
AGENTS.md          conversion spec (12 phases + checklist)
MSDOS.ASM          kernel (4030 lines, DOSGROUP)
IO.ASM             IO.SYS + BIOS jump table (1933)
COMMAND.ASM        resident/transient shell (2165)
STDDOS.ASM         build wrapper (23)
src/boot/          mbr.asm, stage2.asm, gdt.asm (Phase 2)
src/kernel/        main.asm (flat 0x100000), syscall/fat12 placeholders
src/drivers/       vga/ata/kbd/rtc (to replace BIOS far calls)
include/           fcb.inc/dpb.inc (64-bit strucs)
docs/              5 analysis + summary + syscall ref (Phase 1 deliverables)
bochsrc.txt        Bochs 256MiB, ata0 10MiB flat, cpu x86_64
linker.ld          flat link at 0x100000
```

## Source License

MIT, Copyright (c) Microsoft Corporation (see `LICENSE`).

## Next (Phase 2)

Implement `src/boot/mbr.asm`→`stage2.asm` real→protected→long (A20, CPUID LM, PAE, EFER.LME, PML4/PDPT identity map, GDT64), then `src/drivers/vga.asm` at 0xB8000. Verify with `bochs -q r` then `DEBUG` print.

