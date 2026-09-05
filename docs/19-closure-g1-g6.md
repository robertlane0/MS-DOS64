# Closure G1–G6 — how each gap was fixed (2026-09-05, 72/72 PASS)

Companion to `docs/18-truth-gap-analysis.md` (the audit). Each section gives
the fix location, the design decision where DOS semantics were simplified,
and the test/transcript that proves it. Final state: clean `make`, QEMU boot
`Summary: 72 passed, 0`, all ten `ALL TESTS PASS` banners, then the shell.

## G5 → done: `fat_dir_read64` is real
`src/kernel/fat64.asm`: the no-op body is now a tail-call to the ATA-backed
`fs_dir_read64` with identical ABI (`RBP`=DPB, `AL`=block, `RDI`=buffer).
No stub ships; no callers needed changing (`fs64` is the primary path).

## G6 → done: emulator config
`bochsrc.txt` pins `cylinders=20, heads=16, spt=63` (was autodetect, which
panicked); `make clean`/`run-bochs` drop the stale `dos64.img.lock`.
QEMU remains the primary proof path (`-serial stdio` also drives the REPL);
Bochs boots with the same image once its lock is cleared.

## G2 → done: a real FAT12 volume on the image
- `tools/mkfat12.py` (run by `make` after the `dd` steps) stamps a 1.44M
  FAT12 (512B, 1 spc, 2×9 FAT, 224 root, 2880 tot) at **LBA 512–3391** with
  `HELLO.TXT` (151B, 1 cluster), `README.TXT` (1000B, 2-cluster chain),
  `TEST.COM` (1B `RET`), `DATA.BIN` (512B pattern). Idempotent; clear of
  kernel (LBA 16+), ATA scratch (200), FS scratch (500–511).
- `src/kernel/fs64.asm`: `fs_mount_volume64` (BPB→absolute DPB, FAT+root
  into RAM, idempotent), `fs_vol_read_file64` (chain walk → ATA, capped at
  `min(size, bufsize)`), `fs_vol_flush_fat64`/`flush_root64` (write-through
  both FATs), `fs_alloc_cluster64`, `fs_file_write_cluster64`.
- Test 67 mounts twice (idempotence), reads both files off disk (prefix +
  exact-size checks), checks truncation + missing-file failure.

## G1 → done: the INT 21h surface is real (except DOS-reserved slots)
`src/kernel/syscall64.asm` + `src/kernel/fs64.asm`. Only `AH=18h/20h/2Fh–34h/
36h–3Eh/41h–47h` stay `mov al,0; ret` — those are DOS-reserved (`INUSE`/
`USERCODE`), which DOS 1.25 itself stubs; documented, not a gap.

| AH | Handler | Backing |
|---|---|---|
| 03/04/05 | READER/PUNCH/LIST | COM1 0x3F8 poll; READER non-blocking (CF=1 empty, documented — a blocking read would hang the suite); LIST routed to the COM1 capture (no LPT in emulator) |
| 0F/10 | OPEN/CLOSE | `fs_fcb_open64` / `fs_fcb_close64` + RTC-packed time/date |
| 11/12 | SRCHFRST/SRCHNXT | `fs_fcb_search64` (`?` wildcards, 0xE5 skip, 0x00 stop), 32B dirent to DMA, `srch_next_slot` state |
| 13/16/17 | DELETE/CREATE/RENAME | chain free/truncate, free-slot alloc, dup-checked rename; write-through |
| 14/15 | SEQRD/SEQWRT | 1 record at `extent*128+nr`, auto-advance; AL=1 EOF-short (CF=0), FF/CF=1 hard fail |
| 1B/1C/1F | GETFATPT(GETDL)/GETDSKPT | RAM FAT pointer + `fatsiz`, DPB pointer (lazy mount) |
| 1D/1E | GETRDONLY/SETATTRIB | media byte 0xF0; attr byte get/set + flush |
| 21/22 | RNDRD/RNDWRT | 1 record at 64-bit RR |
| 23/24 | FILESIZE/SETRNDREC | `RR=ceil(filsiz/recsiz)`; `RR=extent*128+nr` |
| 26 | NEWBASE | max-free paragraphs (fixed 2M–8M heap; DX ignored, documented) |
| 27/28 | BLKRD/BLKWRT | CX records at RR (CX=16-bit, DOS compat), RR advances, frame CX=done |
| 29 | MAKEFCB | `fs_make_fcb64`: `d:name.ext` parse, upper, `*`→`?`, AL=0/1/FF + end ptr |
| 2A–2D | GET/SETDATE/TIME | CMOS RTC 0x70/0x71 (UIP wait, BCD/binary + 12/24h modes, DOS weekday map, 1980+ year heuristic), validated via `cmd_date/time_set64` (also syncs the shell clock); software-clock fallback on RTC failure |
| 2E | VERIFY | flag stored; AL>1 rejected |

Record-I/O core `fs_fcb_io64` (per-record `pos=recno*recsiz`, chain walk with
alloc-on-write, fresh-cluster zeroing so holes read 0, `filsiz` extension,
single FAT+root flush). Position model: absolute RR; SEQ position
`P=extent*128+nr` mirrored on SEQ ops (exact for the default `recsiz=128` —
the only size DOS 1.x SEQ math is defined for; other sizes still address
correctly by RR). DMA comes from `DMAADD64_SC` (AH=1Ah); unset DMA fails
honestly instead of scribbling (documented deviation from the PSP:80h
default). Tests 68 (RTC get/sane/set-restore/invalid/trap routing), 69
(AUX/LIST/VERIFY/NEWBASE/pointers/attr), 70 (MAKEFCB/OPEN/FILESIZE/RNDRD/
BLKRD/SEARCH/CLOSE + dispatch + `int 0x21` paths), 71 (CREATE→BLK/SEQ write→
read-back→RENAME→DELETE with on-image proof of each step).

Bugs caught by the new tests (all fixed): `fs_fcb_create64` dropping its
`RBX`=entry return across pops; `fs_fcb_io64` keeping the record count in
RBX while reusing RBX for cluster temps (loop ran past count — fixed with a
stack local); test-side SEQ/DMA stride misunderstanding (SEQ transfers one
record at a fixed DMA by DOS design — the test, not the kernel, was wrong);
`mov [rel sh_fcb+rdx]` unencodable (base register instead).

## G3 → done: interactive COMMAND64 shell
`src/kernel/shell64.asm` (~2.5KB text, buffers in BSS): prompt loop after
the test suite. PROMPT mini-expansion (`$P` `$N` `$G` `$L` `$B` `$Q` `$$`
`$_` `$D` `$T` `$V`), line
input from **PS/2 and COM1 RX** (so `qemu -serial stdio` drives it from a
pipe), echo + backspace + ESC-clear, parse via `cmd_parse_line64`, builtins
against the mounted volume (DIR lists the real root; TYPE reads real files;
DEL/REN via volume+flush; COPY = read + CREATE + block-write + **truncate to
exact length** + close), DATE/TIME show + set (shell clock **and** RTC),
CLS/VER/PROMPT/PATH/ECHO/REM/PAUSE, HELP, EXIT, and `<name>` → `<name>.COM`
load-and-spawn from the volume (`TEST.COM` works, pid printed). Unknown names print
`Bad command or file name`. The shell syncs its DATE/TIME clock from the RTC
at startup (so they show real values), and ECHO/PAUSE mirror to serial
(`cmd_print_both`) so transcripts are complete. Test 72 covers dispatch non-interactively
(DIR/TYPE/TEST/FOOBAR/empty/EXIT); piped-serial transcripts prove
interactive use end-to-end (DIR, TYPE, COPY→DIR→TYPE→DEL→DIR, TEST→Loaded,
HELP, bad-name, EXIT). Known limits (documented): 1-byte UART RX (paste
bursts can overrun; interactive typing is fine); TYPE shows the first 4KB;
EXEC loads (spawns) but does not context-switch into the image.

## G4 → done: PIC 0x28/0x30, keyboard IRQ installed
`src/kernel/idt64.asm`: master `0x28`/slave `0x30` (above CPU 0–31 **and**
clear of DOS `0x21`; the old `0x20/0x28` map aliased IRQ1 onto `0x21`).
Timer→`0x28`, keyboard→`0x29` **installed** (0x60→queue+EOI, drop-if-full),
disk→`0x36`, DOS `0x21` DPL3 untouched. Masked after remap (deterministic
tests); the shell unmasks IRQ0/IRQ1 on entry (live ticks + keys; polling and
IRQ paths share the queue without loss/duplication). Tests updated:
51 (new vectors + `0x20`-is-not-timer check), 53 (offsets), 54 (`int 0x28`),
55 (real `0x29`, incl. queue round-trip — the `0x2F` spare hack is gone),
56 (`int 0x36`), 57 (save/munge/restore `0x28`), 58, plus stack tests 63/66.
Note: AGENTS.md Phase 11's "disk INT 0x0E→IRQ14" line conflates CPU `#PF`
with the PIC vector; the code (`0x36` + slave+master EOI) is correct.

## Bootloader hardening (found while growing past 128 sectors)
- `stage2.asm` LBA kernel load is now chunked (≤64 sectors/packet; some
  BIOSes cap single packets) and the CHS fallback advances ES across 64K
  boundaries (the old 16-bit `DI` wrapped past 64KB and would corrupt
  staging). `KERNEL_SECTORS` 128→176 (kernel LBA 16+, clear of all scratch
  and the LBA-512 volume). MBR/stage2 sizes unchanged (512B/whole-slot).

## Remaining honest limitations (non-goals, not gaps)
ATA stays PIO polling; IST reserved with IDT `IST==0`; executables are
`MZ64`/raw COM (no MZ/PE loader); SEQ math exact at `recsiz=128`;
writes are record-granular (COPY truncates); serial RX is 1 byte deep;
default DMA must be set explicitly; printer→COM1 capture; PIT at BIOS rate.
