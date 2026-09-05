# MS-DOS64 Truth Gap Analysis — audit baseline 2026-09-05, CLOSED 2026-09-05

> **Status: all six gaps below are now fixed and verified (72/72 PASS on a
> fresh QEMU boot + interactive REPL transcripts). See
> `docs/19-closure-g1-g6.md` for the fix-by-fix evidence. This file is kept
> as the audit trail of what was wrong.**

This document is the honest baseline before the push to 100%. Every claim below
was verified by reading `src/`, `include/`, `Makefile`, `linker.ld`,
`bochsrc.txt`, and by a clean `make` + QEMU boot (66/66 PASS on serial).
It corrects the over-broad "complete on both emulators" language in `README.md`.

## Method

- Read all of `src/boot/`, `src/drivers/`, `src/kernel/`, `src/lib/`, `include/`.
- Grepped 64-bit code for `int`, `aam/aad/xlat/les/lds`, `push ds/es/ss`,
  far jumps — only intentional DOS/IRQ test vectors remain; no BIOS calls in
  long mode; no invalid opcodes executed.
- `make clean && make` → exit 0 (kernel.bin 53244B ≈ 104 sectors ≤ 128,
  stage2.bin 1021B ≤ 15 sectors).
- Fresh QEMU boot of the rebuilt image reproduces `Summary: 66 passed, 0 failed`.

## What is genuinely real (no action needed)

| Phase | Status | Evidence |
|---|---|---|
| 1 Analysis | REAL | `docs/00–06` match the sources (`file:line` refs check out). |
| 2 Boot | REAL | MBR A20 + INT13 LBA/CHS, stage2 CPUID-LM/PAE/PML4→PD 0–8 MiB/EFER/GDT64/`0x80000→0x100000` copy. Boots on QEMU; Bochs path works but config needs hardening (see §Gaps). |
| 3 Registers | REAL | `string64`/`bcd64`, R8–R15, `STKPTRS64`; tests 1–7 exercise real paths. |
| 4 Addressing | REAL | `addr64`: `seg<<4+off`, RIP-rel, far→near, `dq` buffers, canonical; tests 8–12. |
| 5 Drivers | REAL (polling scope) | VGA text, ATA LBA28 PIO (LBA0 `AA55`, LBA200 + LBA500+ write/readback over real ports), PS/2 tables/queue. No IRQ/DMA by design. |
| 6 Memory | REAL | First-fit/split/prev+next coalesce/resize/validate/para-page/RW-NX; tests 17–21. |
| 8 Process | REAL | 16-slot table, PSP64/env/`MZ64`/spawn/terminate/reap, `4B/4C` + `INT20`; tests 28–34. |
| 12 Stack/ABI | REAL | 16B alignment, SysV args, callee-saved, depth, canary, IST reserve (`IST==0`, documented future TSS); tests 59–66. |

## Gaps (what "complete" over-claims)

### G1. INT 21h surface is ~20/77 real — FCB/file/date/time/disk are stubs
`src/kernel/syscall64.asm:992–1023` — ~30 handlers are `mov al,0; ret`:
`open/close/srchfrst/srchnxt/delete/seqrd/seqwrt/create/rename`,
`rndrd/rndwrt/filesize/setrndrec/blkrd/blkwrt/makefcb`,
`getdate/setdate/gettime/settime`, plus `reader/punch/list`,
`getfatpt/getfatptdl/getrdonly/setattrib/getdskpt/usercode/newbase/verify`.
The 12 AGENTS-mandated functions (01/02/09/0A/0D/0E/19/25/35/3F/40/4C) are real;
everything else returns success without doing anything. A caller cannot
open/read/write/delete a file through INT 21h FCB paths today.
**Fix:** back each handler with the subsystem that already exists
(`fs64` dir/chain/cluster I/O, `mem64`, `cmd64` date/time, CMOS RTC, COM1).

### G2. No real FAT12 volume — filesystem proven on synthetic buffers
`fs64.asm` is a correct FAT12 *engine* (BPB→DPB, chain, dir, FCB64, DREAD/DWRITE),
but `dos64.img` contains no FAT12 filesystem: LBA0 is the MBR, LBA1–15 stage2,
LBA16+ raw kernel. All Phase-7 tests use in-RAM templates (`fs_boot144`,
`fs_dir_buf`, `fs_fat_buf*`) plus scratch LBAs 200/500–511. Nothing mounts,
lists, or persists a file on boot.
**Fix:** reserve an on-image FAT12 region (e.g. LBA 512+), format it at build
time with a host tool (BPB/FATs/root with real files), mount it at boot
(`firfat/firdir/firrec` DPB + in-RAM FAT copy), and route FCB/dir handlers to it.

### G3. COMMAND64 is a tested library, not a shell
`cmd64.asm` (3040 lines) implements parser, DIR/TYPE/COPY/DEL/REN, CLS/VER/
PROMPT/PATH/DATE/TIME, EXEC-via-spawn, batch `%1–%9`. But `main.asm` runs tests
1–66 then `cli; hlt` — there is no prompt loop, no keyboard line reader, no
dispatch of typed commands. "Command prompt appears" is not true.
**Fix:** after the test suite, enter a REPL: print prompt, poll `kbd`,
line-edit, `cmd_parse_line64` → `cmd_table_lookup64`/dispatch against the
mounted volume, loop forever.

### G4. Keyboard IRQ exists but is not installed (INT 0x21 collision)
`idt64.asm:irq1_kbd_handler` is implemented and verified via spare vector `0x2F`,
but with PIC master `0x20`, IRQ1 lands on `0x21` — the DOS syscall vector — so
the handler stays uninstalled and IRQ1 stays masked; input is polling-only.
**Fix:** remap PIC to a base that clears `0x21` (e.g. master `0x28`/slave
`0x30`, both above the CPU 0–31 range), install IRQ1 at its new vector,
unmask it, and update the Phase-11 tests/docs that hard-code `0x20/0x28`.

### G5. Dead stub `fat_dir_read64`
`src/kernel/fat64.asm:126` is push/pop/`clc` with no I/O and has no callers;
the real directory-read path is `fs64.asm:fs_dir_read64`.
**Fix:** implement it (tail-call/shared logic) or delete it so no stub ships.

### G6. Emulator config fragility
`bochsrc.txt` omits CHS (BIOS warns `CHS 0/0/0`, HD panics in this environment),
`build/dos64.img.lock` goes stale and blocks Bochs, and the SND panic appears
in `bochs.log`. QEMU is the reliable path today.
**Fix:** pin `cylinders/heads/spt`, remove the lock in `make clean`/`run-bochs`,
document QEMU as primary until Bochs is re-verified.

### Note on AGENTS.md itself
Phase 11's "Disk interrupt (INT 0x0E → IRQ14)" conflates CPU `#PF` (0x0E) with
the PIC vector. The code is right (IRQ14 @ `0x2E` with slave base `0x28`, EOI
slave+master); the spec line is wrong and is noted here rather than followed.

## Roadmap to ~100% (in order) — ALL DONE, see docs/19

1. **Docs (this file)** — baseline. ✅
2. **Quick wins:** G5 (stub), G6 (bochsrc/Makefile). ✅ (`fat_dir_read64`
   now tail-calls the ATA path; `bochsrc.txt` pins CHS; `make clean/run-bochs`
   drop the stale lock.)
3. **INT 21h backlog (G1):** ✅ RTC driver + date/time (2A–2D), AUX/COM/LIST
   (03–05), VERIFY (2E), disk pointers (1B/1C/1D/1E/1F/26), then the full FCB
   file cluster (0F–17, 21–24, 27–29) on the mounted volume. Tests 68–71.
4. **Real volume (G2):** ✅ `tools/mkfat12.py` stamps 1.44M FAT12 @ LBA 512 in
   `make`; `fs_mount_volume64` + `fs_vol_read_file64` + flush/alloc; test 67.
5. **REPL (G3):** ✅ `src/kernel/shell64.asm` prompt loop (PS/2 + COM1 RX,
   DIR/TYPE/COPY/DEL/REN against the volume, EXEC *.COM, HELP/EXIT); test 72
   covers dispatch; serial transcripts prove interactive use.
6. **PIC (G4):** ✅ remap master `0x28`/slave `0x30`, IRQ1 installed @0x29,
   tests 51/53–58 + 63/66 updated, shell unmasks IRQ0/IRQ1 on entry.
7. Re-run full matrix, update `README.md` + phase docs `07–17` to match. ✅
   (this doc + docs/19 + README header/layout).

## Non-goals (documented limitations, not gaps)

- ATA stays PIO polling (no IRQ/DMA driver).
- IST stacks stay reserved with IDT `IST==0` (no TSS yet).
- 64-bit `.EXE` stays `MZ64` (no MZ/PE loader); `.COM` raw loads unchanged.
