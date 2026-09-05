# MS-DOS64 — 64-bit BIOS-bootable DOS

A flat 64-bit long-mode OS that boots via legacy BIOS MBR, derived from
Microsoft MS-DOS v1.25 (MIT). It preserves DOS semantics — FAT12, FCBs,
PSPs, `INT 21h`, `COMMAND`-style builtins — on native 64-bit code with no
BIOS calls after the boot handoff.

On boot the kernel runs a 72-check self-test suite (serial + VGA log), then
drops into an interactive `COMMAND64` shell.

## Status

Boots on QEMU (`qemu-system-x86_64 -serial stdio`) and Bochs (256 MiB,
`ryzen` profile). Self-tests: **72/72 PASS**, then the shell prompt.
Per-subsystem design notes live in `docs/`; `docs/18-*.md` + `docs/19-*.md`
are the audit trail for the last correctness pass.

## What works

- **Boot:** 512 B MBR (A20, `INT 13h` LBA with CHS fallback) → stage2
  (`real → protected → long`: CPUID LM check, PAE, 4-level paging with
  0–8 MiB identity map, `EFER.LME`, GDT64) → kernel at `0x100000`.
- **Console:** native VGA text driver (`0xB8000`, 80×25, cursor, scroll) +
  COM1 serial (`0x3F8`) for logging and shell I/O. No `INT 10h` in long mode.
- **Disk:** ATA PIO LBA28 driver (`0x1F0`, polling, CHS→LBA conversion).
  No `INT 13h` in long mode.
- **Keyboard:** PS/2 controller (`0x60`/`0x64`) with 128-byte queue and
  US shift/caps tables; polled in tests, IRQ-driven once the shell starts.
  No `INT 16h` in long mode.
- **Memory:** byte-based first-fit allocator over `0x200000+` with split,
  prev+next coalesce, in-place resize, aligned/page allocation, validation,
  and page-table `RW/NX` protection. `INT 21h AH=48h/49h/4Ah`.
- **Filesystem:** FAT12 engine (BPB→DPB, 12-bit chain walk, root-dir search,
  multi-cluster read, alloc-on-write with FAT+root write-through) mounted on
  a real on-image volume (see Disk layout). Full FCB record I/O core
  (sequential + random + block, `RR`-addressed).
- **Processes:** 64-bit PSP + environment blocks, raw-`.COM` and `MZ64`
  loaders, spawn/terminate/reap lifecycle. `INT 21h AH=4Bh/4Ch`, `INT 20h`.
- **Syscalls:** `INT 21h` IDT gate (DPL3) with a 77-entry dispatcher covering
  consoles, drives, interrupt vectors, handle R/W, AUX/COM/LIST, CMOS RTC
  date/time, VERIFY, disk pointers, and the whole FCB file cluster. Only
  DOS-reserved slots stay stubbed, as in DOS 1.25 itself.
- **Shell:** `COMMAND64` REPL with prompt expansion, line editing over PS/2
  and serial, volume-backed builtins, batch files (`%1`–`%9`), and `*.COM`
  execution.
- **Interrupts:** full 256-entry IDT; CPU vectors 0–31 with diagnostics
  (vector/error/`RIP` counters); PIC remapped to master `0x28`/slave `0x30`
  so IRQ1 no longer collides with DOS `0x21`; timer IRQ0, keyboard IRQ1
  (installed), disk IRQ14.
- **ABI:** System V AMD64 throughout — 16-byte `RSP` alignment, `RDI RSI RDX
  RCX R8 R9` args, callee-saved `RBX RBP R12–R15`, near `CALL/RET` only,
  stack canaries; IST stacks reserved.

## Memory map

| Range | Use |
|---|---|
| `0x0000–0x0FFF` | IVT/BDA preserved |
| `0x1000/0x2000/0x3000` | PML4 / PDPT / PD (identity map 0–8 MiB, 4×2 MiB pages) |
| `0x7C00–0x7DFF` | MBR load address |
| `0x7E00+` | Stage2 load address |
| `0x80000` | Kernel staging buffer (copied to `0x100000`) |
| `0x90000` | Initial `RSP` top (16-aligned); syscall `IOSTACK`/`DSKSTACK` are separate 4 KiB BSS stacks (16-aligned tops) |
| `0xB8000` | VGA text buffer |
| `0x100000+` | Kernel (linked flat at 1 MiB, ~64 KiB / ~129 sectors) |
| `0x200000+` | Heap (`MCB64` chain, first-fit) |

## Disk layout (`build/dos64.img`, 10 MiB)

| LBA | Contents |
|---|---|
| 0 | MBR + boot signature `55 AA` |
| 1–15 | Stage2 |
| 16+ | Kernel binary (up to 176 sectors) |
| 200, 500–511 | ATA/filesystem scratch (kept clear of kernel and volume) |
| 512–3391 | Real FAT12 volume (1.44 M geometry, stamped at build by `tools/mkfat12.py`) |

Volume files: `HELLO.TXT` (1 cluster), `README.TXT` (2-cluster chain),
`TEST.COM` (single `RET`, EXEC target), `DATA.BIN` (512 B pattern).

## Shell

```
A> DIR
A> TYPE HELLO.TXT
A> COPY README.TXT BACKUP.TXT
A> DEL BACKUP.TXT
A> REN OLD.TXT NEW.TXT
A> DATE / TIME [MM-DD-YY / HH:MM[:SS]]
A> CLS / VER / PROMPT / PATH / ECHO text / REM comment / PAUSE
A> TEST            (loads TEST.COM from the volume and spawns it)
A> HELP / EXIT
```

Batch files support `REM`, `%1`–`%9` parameters, and `%%` escapes.
Input works from the PS/2 keyboard and over serial, so the shell is
drivable from a pipe under QEMU.

## System calls (`INT 21h`, `AH=`)

Consoles `01/02/06–0C`, READER/PUNCH/LIST `03/04/05`, disk reset/select
`0D/0E`, drive `19`, FCB files `0F–17/21–24/27–29`, pointers `1B/1C/1F`,
attrs `1D/1E`, NEWBASE `26`, date/time `2A–2D` (CMOS RTC), VERIFY `2E`,
vectors `25/35`, DMA `1A`, handles `3F/40`, alloc `48/49/4A`, EXEC/EXIT
`4B/4C`, plus `INT 20h` terminate. Record I/O is `RR`-addressed;
sequential position mirrors `extent*128+nr` exactly for the DOS 1.x
`recsiz=128` case. DMA defaults to unset and fails honestly — set it with
`AH=1Ah` before FCB transfers.

## Quick start

Requires `nasm ≥ 2.15`, `ld`/`objcopy` (binutils), `python3`, and
`qemu-system-x86_64` or Bochs.

```bash
make            # MBR + stage2 + kernel + dos64.img (stamps FAT12 volume)
make run-qemu   # serial stdio (recommended)
make run-bochs  # target emulator; clears stale lock first
make clean
```

Verify (QEMU is the primary proof path):

```bash
timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# tail: Summary: 72 passed, 0 failed ... MS-DOS64 shell (COMMAND64). Type HELP for commands.

printf '\rDIR\rTYPE HELLO.TXT\rHELP\rEXIT\r' | timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none

rm -f bochs.log serial.log build/dos64.img.lock && make && timeout 25 bochs -f bochsrc.txt -q; cat serial.log
```

## Source layout

```
src/boot/      mbr.asm (A20, INT13 LBA/CHS) + stage2.asm (mode switch, chunked loads) + gdt.asm
src/kernel/    main.asm (entry @0x100000, 72-test harness) + shell64.asm (REPL)
               cmd64.asm (COMMAND64 parser/builtins/exec/batch) + fat64.asm (UNPACK/PACK)
               fs64.asm (FAT12 mount/read/flush/alloc + FCB record-I/O core)
               mem64.asm (MCB64 manager) + proc64.asm (PSP64/env/loader/spawn)
               syscall64.asm (INT 21h dispatcher, 77 entries)
               idt64.asm (IDT, PIC master 0x28/slave 0x30: timer IRQ0@0x28, kbd IRQ1@0x29 installed, disk IRQ14@0x36) + stack64.asm (ABI/canary)
src/drivers/   vga.asm (0xB8000 text) + ata.asm (0x1F0 PIO LBA28) + kbd.asm (PS/2 0x60/0x64)
src/lib/       string64.asm + bcd64.asm (AAM/AAD->DIV, CBW equiv.) + addr64.asm (seg:off->linear)
include/       fcb.inc/dpb.inc/psp.inc/mcb.inc/regs.inc/fs.inc/stack.inc (64-bit structures)
tools/         mkfat12.py (stamps the FAT12 volume during make)
MSDOS.ASM / IO.ASM / COMMAND.ASM   original MS-DOS v1.25 sources (reference only; STDDOS.ASM is the legacy wrapper — the 64-bit build uses src/ via Makefile)
linker.ld      flat link at 0x100000 (.text.start first)   bochsrc.txt   Bochs config
```

## Limitations (by design, not bugs)

- ATA is PIO polling; no DMA. Disk IRQ only counts + EOIs.
- IST stacks reserved, IDT `IST==0` (no TSS yet).
- Executables are raw `.COM` and `MZ64` only (no MZ/PE loader); EXEC spawns
  but does not context-switch into the image.
- FCB sequential math is exact at `recsiz=128`; other sizes address by `RR`.
- Writes are record-granular (`COPY` truncates to exact length).
- Serial RX is 1 byte deep (typing is fine; paste bursts can overrun).
- `TYPE` shows the first 4 KiB; printer output goes to the COM1 capture.
- PIT runs at the BIOS rate.

## Origin and license

Derived from Microsoft MS-DOS v1.25 (Tim Paterson 86-DOS), MIT licensed —
see `LICENSE`. The 16-bit sources (`MSDOS.ASM`, `IO.ASM`, `COMMAND.ASM`)
are kept as reference; the running system is the 64-bit rewrite under
`src/` described above.
