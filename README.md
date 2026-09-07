# MS-DOS64

MS-DOS v1.25 rebuilt as a 64-bit operating system. It boots from a legacy
BIOS MBR, switches through to long mode, and then behaves like DOS —
FAT12 files, `INT 21h` services, and a `COMMAND`-style shell — using only
native 64-bit drivers. No BIOS calls after boot.

Boot runs a short self-test, then drops you at an `A>` prompt.

## Status

Works on QEMU (recommended) and Bochs. Default build passes 81 checks
with 2 skipped; `make full` runs all 83, then starts the shell either way.
Design notes live in `docs/`; `AGENTS.md` has the full build record.

## Requirements

- `nasm >= 2.15`, `ld` / `objcopy`, `python3`
- `qemu-system-x86_64` or Bochs

## Build and run

```bash
make              # normal build, safe self-test, image in build/dos64.img
make run-qemu     # boot it with serial output in your terminal
make full         # full destructive test image (build/dos64-full.img)
make run-qemu-full
make lean         # skip self-test entirely, straight to shell
make run-qemu-lean
make run-bochs    # boot smoke image (rendered build/bochsrc-dos64.txt)
make run-bochs-full  # boot full image (rendered build/bochsrc-dos64-full.txt)
make run-bochs-lean  # boot lean image (rendered build/bochsrc-dos64-lean.txt)
make clean
```

`make` never creates files on the volume; `make full` exercises file
create/rename/crash recovery in a reserved test namespace and cleans up
after itself. `make lean` does zero device writes.

To check a boot quickly:

```bash
timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
```

You should end at `MS-DOS64 shell (COMMAND64)`. The shell also accepts
serial input, so this works:

```bash
printf '\rDIR\rTYPE HELLO.TXT\rHELP\rEXIT\r' | timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
```

## Using the shell

```
A> DIR
A> TYPE HELLO.TXT
A> COPY README.TXT BACKUP.TXT
A> DEL BACKUP.TXT
A> REN OLD.TXT NEW.TXT
A> DATE / TIME / CLS / VER / PROMPT / PATH / ECHO text / REM comment / PAUSE
A> TEST      (runs TEST.COM from the volume)
A> HELP / EXIT
```

Batch files work with `REM`, `%1`–`%9`, and `%%` escapes. Keyboard and
serial input both work.

## What's inside

- Boot: MBR + stage2, real → protected → long mode, kernel at 1 MiB.
- Console, disk, and keyboard are native drivers (VGA text, ATA PIO, PS/2).
- FAT12 volume stamped at build time with a few sample files.
- `INT 21h` services, 64-bit memory manager, PSP-based program loading.
- `COMMAND64` shell with builtins, batch files, and `.COM` execution.

Exact memory/disk addresses, the syscall list, and source map are in
`AGENTS.md` — start there if you're hacking on it.

## Good to know

- ATA is polling PIO; no DMA. Disk interrupts just count and acknowledge.
- Only raw `.COM` / `MZ64` programs run; EXEC spawns but doesn't
  context-switch.
- Serial output is best-effort (dropped, never hangs); the screen is
  authoritative. Serial input is one byte deep, so pasting can overrun.
- `TYPE` shows the first 4 KiB; printer output goes to COM1.

## Origin and license

Derived from Microsoft MS-DOS v1.25 (Tim Paterson 86-DOS), MIT licensed.
See `LICENSE`. The original 16-bit sources (`MSDOS.ASM`, `IO.ASM`,
`COMMAND.ASM`) are kept for reference; the running system is the rewrite
under `src/`.
