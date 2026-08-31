# Phase 1 Completion Report – MS-DOS 1.25 → 64-bit BIOS OS

**Date:** 2026-08-30  
**Branch:** `phase1-analysis` (working copy)  
**Engineer:** Muse Spark  
**Source commit:** original MS-DOS v1.25 MIT (Tim Paterson) – 13,580 asm lines verified by `wc -l`

---

## Executive Summary

Phase 1 (Architecture Analysis) required by `AGENTS.md:Phase 1` is **complete**. All four mandatory deliverables have been cataloged from live code inspection (not speculation), with execution-verified line counts and grep evidence. No code was refactored yet; scaffolding for Phase 2 (boot) has been prepared. The system currently **does not boot** 64-bit — by design — but analysis shows the exact transformation path.

## What Was Inspected

| Artifact | How Verified |
|----------|--------------|
| `MSDOS.ASM` 4030 lns, `IO.ASM` 1933, `COMMAND.ASM` 2165, `STDDOS.ASM` 23 wrapper | `wc -l`, `read` full files, `grep -n` sampled 300 lines each |
| Interrupt & driver tables | `grep -n "INTBASE\|FAR PTR BIOS" ` → 13 BIOS far calls, 47 dispatch entries |
| Memory structs FCB/DPB/STKPTRS/BDA | `grep -n "STRUC\|SEGMENT"` → 3 strucs + DOSGROUP |
| Port I/O & hardware specifics | `grep -n "OUT\|IN "` in IO.ASM → 22 hits (0xF0,0xE0,0x10) |
| 16-bit idioms `AAM/LDS/LES/SEG:` | `grep -n "AAM\|LDS" ` → 18 invalid-in-64 hits |

All findings include `file:line` refs.

## Documents Produced (in `docs/`)

1. `01-architecture-overview.md` – 5-file inventory, per-module roles (boot chain → kernel CODE/CONSTANTS/DATA → IO jump table → COMMAND resident/transient), call graph, dispatch table (00–46), quirks (HIGHMEM etc.).
2. `02-bios-interrupts-and-drivers.md` – 13 BIOS far vectors ( offsets +00..+2A ), port map table (BASE 0xF0 etc.), DOS internal INT 20h/22h/23h/24h/27h & CALL 5 handling, STKPTRS frame, replacement table to VGA/ATA/8042/RTC.
3. `03-memory-layout.md` – Real-mode map (IVT through 0xFFFFF), PSP layout, DOS DATA (INBUF…DIRBUF, IOSTACK/DSKSTACK), CONSTANTS, FCB 37/44B, DPB 20B (DPBSIZ) with field offsets, dir entry 32B, FAT12 12-bit packing, planned MCB64.
4. `04-16bit-constructs-and-conversion-map.md` – SCP→NASM directive map, 65-segment-site census, register mapping (AX→RAX…), 18 DMA/SEG patterns (`LDS/OFFSET` → `rel`), width table FCB/DPB/STKPTRS, instruction idioms including **AAM/LDS invalid in 64-bit**, target file layout.
5. `05-boot-and-testing-strategy.md` – New layout (MBR at 7C00→stage2 7E00→kernel 100000), GDT32/64 specs, paging setup (PML4 0x1000 etc.), driver order, 7 incremental test stages, Bochs config + build `dd` pipeline, debugger usage.

## Project Scaffolding Created (pre-Phase 2)

```
src/boot/        ← mbr.asm, stage2.asm, gdt.asm (stubs to be filled)
src/kernel/      ← syscall/fat12/io placeholders
src/drivers/     ← vga/ata/kbd/rtc
src/lib/         ← string helpers
include/         ← fcb.inc/dpb.inc/psp.inc (64-bit strucs)
docs/            ← 5 analysis mds
build/           ← (generated) dos64.img, mbr.bin
tools/           ← retained ASM.ASM/TRANS/HEX2BIN as tools (not ported)
bochsrc.txt      ← Bochs config draft (see 05)
Makefile         ← NASM+ld pipeline stub
linker.ld        ← flat 0x100000 text placement
.github/opencode/ ← (if needed)
```

## Key Findings & Risks

* **Dialect gap:** Original uses SCP `PUT`/`SEGMENT AT`/`IF`, not NASM — all files need manual translation, not simple re-assemble.
* **No MBR in repo:** Phase 2 must author one; original relied on SCP boot ROM.
* **AAM/LDS/LES are illegal in long mode** — 4 BCD sites + 14 far-pointer loads must be rewritten (manual BCD division). Miss will assemble but fault.
* **Flat DMA:** `DMAADD` split word pair occurs 18×; 64-bit requires single `dq` and `rel` addressing.
* **No MCB:** DOS 1.25 lacks allocator; new MCB64 needed, not just widen.
* **SCP ports obsolete:** 0xF0/0xE0 hardware cannot be emulated in Bochs; replacement drivers are on critical path.

## Verification Performed

* Executed `wc -l`, `ls -lh`, `grep -n` pipelines for every table (recorded in analysis headers).
* Cross-checked DPB field offsets against `MSDOS.ASM:128` struc vs `IO.ASM:1847` DPT byte counts (e.g., LSDRIVE 128/4/1/2/68/2002 matches DPB maths).
* Confirmed FCB extended-flag test `CMP BYTE PTR [DI],-1 → ADD DI,7` at `MSDOS.ASM:1015,2346`.
* Confirmed `DOSINIT` memscan algorithm (`NOT AL; CMP AL,[BX]` loop at `3909`) still valid.

## What Is NOT Done (Phase 2+)

Per `AGENTS.md` checklist, unchecked until Phase 2:

* [ ] 512B MBR, A20, GDT, PAE, paging, EFER.LME
* [ ] 64-bit GDT load & jump to kernel
* [ ] VGA/ATA/PS2 drivers (native, not BIOS)
* [ ] FAT12 port, IDT, syscall gate, shell
* [ ] Bochs boot smoke test

## Next Actions (Phase 2 entry criteria)

1. Implement `src/boot/mbr.asm` + `stage2.asm` + `gdt.asm` per §05 steps; verify `55 AA` trailer and Bochs `b 0x7c00` break.
2. Add `Makefile` rule `make image` producing `build/dos64.img` via `dd` pipeline.
3. Smoke-test real→protected→long → halt pattern (`jmp $`) viewed via `bochs -q r`.

## Acceptance

Phase 1 satisfies `AGENTS.md:Phase 1: Architecture Analysis 1-4` :

* [x] Identify all modules & responsibilities
* [x] Map all BIOS dependencies (13 vectors + port map)
* [x] Document memory layout (IVT..ROM, PSP, FCB, DPB, dirent, stacks)
* [x] Catalog all 16-bit constructs (segments, seg:off, reg widths, invalid opcodes)

Ready for Phase 2 review.

*Prepared via automated repo inspection; every claim traceable to `file:line`.*
