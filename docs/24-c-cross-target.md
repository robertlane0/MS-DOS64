# N3.5 — C cross-target for MS-DOS64 (gcc → flat `.COM`)

How to build C programs that run on DOS64, exact flags, and the three
load-bearing lessons (slide-safety, BSS, 4 KB staging). Acceptance was
`samples/hello.c` running on QEMU (puts/malloc/fopen/fwrite, `Exit 0`).

## Recipe (see `Makefile`: `UCFLAGS`, `userland.ld`, `chello.elf`)

```bash
gcc -ffreestanding -nostdlib -m64 -fPIE -mno-red-zone -fno-stack-protector \
    -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Werror -Os \
    -c samples/hello.c -o build/hello.o
ld -T src/libc/userland.ld -o build/chello.elf \
    build/libc/crt0.o build/hello.o build/libc/libc64.o build/libc/stdio64.o \
    -nostdlib --fatal-warnings        # crt0.o FIRST: _start at offset 0
objcopy -O binary build/chello.elf build/CHELLO.COM
```

Ship via `mkfat12.py --extra-file CHELLO.COM=build/CHELLO.COM`
(`dos64-nasm.img`, the with-programs variant; default images stay
pristine). Demo: `A> CHELLO` → `Exit 0`, `A> TYPE HELLOC.TXT` shows the
64 B malloc pattern, `A> DEL HELLOC.TXT` cleans up.

## Why these flags

The loader (`proc_load_image64`) does a raw copy with NO relocation to
a heap-varying address (`PSP+PSP_SIZE`), so the image must be
slide-safe: only relative calls/jumps, only RIP-relative data access,
no GOT, no dynamic relocs. `-fPIE` generates that shape; the static
(non-`-pie`) link relaxes cross-object GOT refs to RIP-relative LEA;
`--fatal-warnings` keeps the link honest (it caught the initial RWX
single-segment — fixed with proper R+E/RW `PHDRS` in `userland.ld`).

## Acceptance checks (all required, all in the N3.5 run)

- `readelf -r chello.elf`: **no relocations** (any `.rela.dyn` =
  absolute addressing slipped in → fix flags, never silence it).
- `readelf -S`: **no `.got`** (kept visible in the script on purpose —
  silently discarding it would hide breakage).
- `objdump -b binary -m i386:x86-64 -d CHELLO.COM | grep syscall`:
  **empty** (no Linux syscalls; only `INT 21h` traps).
- Disassembly audit: no `movabs`-to-address, no absolute memory
  operands (only immediates like trap numbers/`HEAP_MAGIC`), no
  indirect `call */jmp *`, entry point `0x0`.
- QEMU: program runs, `Exit 0`, volume file round-trips.

## C-author constraints (no headers yet — declare the shim calls)

- `-mno-red-zone` (live IRQs share the stack), `-fno-stack-protector`
  (no `__stack_chk_fail` in the shim).
- No 64-bit `/` `%` (no libgcc; 32-bit `idiv` is one insn and fine).
- No `float`/`double`, no `switch` (jump-table addressing models vary).
- `main` returns `int`; low 8 bits become the `AH=4Ch` exit code.
- Modes `"r"`/`"w"` only (`"a"`/`"+"` return `NULL` — kernel limit,
  see `stdio64.asm`); `argv[0]` is `""` (no program path from kernel).

## Lessons (each cost a debug cycle)

1. **Verify slide-safety, don't assume it.** `readelf` + the
   disassembly scan above are the proof; the QEMU run alone is not
   (a base-0 accident can pass once).
2. **Flat `.COM` has no BSS content.** `objcopy -O binary` truncates
   trailing NOBITS (data `LOAD` shows `FileSiz 0`), so the loader
   copies stale bytes over BSS. `crt0` zeroes `[_bss_start,_bss_end)`
   first thing (symbols from `userland.ld`; LEA keeps it slide-safe).
   Symptom was `fopen` → `NULL` (garbage `FILE` flags).
3. **Shell EXEC staged through a 4 KB static buffer** (`sh_file` +
   `mov rdx, 4096`), silently truncating larger programs (a 4515 B
   `CHELLO.COM` lost its string tail → empty-string args). Fixed with
   exact-size staging via new `fs_vol_file_size64` + whole-file read;
   short reads now fail honestly instead of running partial images.
   `sh_file` stays for `TYPE`'s documented 4 KiB window.
4. **PSP must be saved before BSS-zeroing** (`rep stosb` advances
   `RDI`; `mov rbx, rdi` belongs first). Harmless for `main(void)`
   today, fatal for any argv/env user.
