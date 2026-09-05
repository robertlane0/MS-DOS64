# Phase 1 – Boot & Testing Strategy for 64-bit Conversion

> **As built (2026-09-05):** this strategy is implemented — MBR → stage2 →
> kernel at `0x100000` boots 72/72 PASS + `COMMAND64` REPL on QEMU (primary)
> and Bochs. Concrete sizes/layout below reflect the code; the step rationale
> is unchanged. See `README.md` + `docs/19-closure-g1-g6.md` for the final
> state (chunked loads, `KERNEL_SECTORS 176`, FAT12 volume at LBA 512+,
> PIC master `0x28`/slave `0x30`).

## 1. Why New Boot Chain Is Needed

Original DOS had no MBR in repo — SCP boot loaded `IO.SYS` + `MSDOS.SYS` via unknown loader (likely absolute sectors). `IO.ASM:INIT` assumes it is already at `BIOSSEG:0` with DOS at `DOSSEG`. For BIOS Bochs we must supply MBR + stage2 that reproduces `real → protected → long` and places kernel at `0x100000`.

## 2. Target Memory Layout (AGENTS.md recommendation, adapted)

```
0x00000000  IVT (preserved for compatibility, but IDT will shadow it)
0x00000400  BDA
0x00000500–0x7BFF free conventional
0x00001000  PML4 (4 KiB) → 0x2000 PDPT → 0x3000 PD (4×2 MiB PS pages, identity 0–8 MiB)
0x00007C00  MBR (512B) loaded by BIOS — stage1
0x00007E00  Stage2 (~1 KiB, performs mode switch, chunked kernel loads)
0x00080000  Kernel staging buffer (BIOS loads here, copied to 0x100000 in long mode)
0x00090000  Initial RSP top (grows down, 16-aligned; IOSTACK/DSKSTACK are separate 4 KiB BSS stacks)
0x00100000  Kernel entry (flat binary, 64-bit, `KERNEL_SECTORS 176` = 88 KiB max, ~129 sectors used)
0x00200000+ Heap (MCB64 chain, first-fit)
0x00A0000–0x00BFFFF Video (B8000 text, will be driven by VGA driver)
0x0C0000–0xFFFFF ROM
```

`DOSINIT` old free-para scan is kept but updated to page granularity (4KiB).

## 3. Stage 1 – MBR (512B, BIOS entry `bits 16; org 0x7C00`)

Responsibilities:

1. `cli; xor ax,ax; mov ds,ax; mov es,ax; mov ss,ax; mov sp,0x7C00`
2. Preserve `DL` (BIOS boot drive).
3. Enable A20 via Fast A20 (port 0x92 bit1) with keyboard fallback (port 0x64) – verify with `int 15h AH=2401`?
4. Load Stage2: use BIOS `INT 13h AH=42h` LBA extended read if available, else CHS (`AH=02h`). Stage2 at 0x7E00 (fits the 15-sector LBA 1–15 slot; ~1 KiB as built). Verify signature 0xAA55.
5. `jmp 0:0x7E00`.

Stage2 loads the kernel in chunks (≤64 sectors/LBA packet; CHS fallback
advances ES across 64 KiB boundaries) to staging `0x80000`, then copies to
`0x100000` in long mode (`rep movsq`, `KERNEL_SECTORS 176`).

Build: `nasm -f bin src/boot/mbr.asm -o build/mbr.bin` – check `stat -c %s =512` and last two bytes `55 AA`.

## 4. Stage 2 – Protected → Long Switch (at 0x7E00)

Steps (AGENTS.md Phase 2 snippet):

```nasm
bits 16
stage2:
  lgdt [gdt32_ptr]
  mov eax, cr0
  or eax, 1
  mov cr0, eax          ; protected
  jmp 0x08:pmode

bits 32
pmode:
  mov ax, 0x10
  mov ds, ax
  mov es, ax
  mov ss, ax
  ; EFER: check CPUID 0x80000001 EDX:29 LM, else halt print
  ; enable PAE: or cr4, 1<<5
  ; build paging: PML4[0]=PDPT, PDPT[0]=PD, PD[0]= PT with 0x83 2MiB? or PT level for fine grained
  mov eax, 0x1000        ; PML4
  mov cr3, eax
  ; EFER MSR 0xC0000080: rdmsr, or 1<<8, wrmsr
  ; cr0 PG: or eax, 1<<31
  lgdt [gdt64_ptr]
  jmp 0x08:long_entry
bits 64
long_entry:
  mov ax, 0x10
  mov ds, ax
  ; jmp to kernel at 0x100000
  jmp 0x08:0x100000
```

**Page-table details:** use `dq` entries with flags `P|RW` (0x3). As built: PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000` with 4×2 MiB PS pages (`0x83`), identity 0–8 MiB — covers stage2, staging `0x80000`, stack `0x90000`, and kernel at `0x100000`.

**GDTs:**

```nasm
; GDT32: null, code 0x08 (base 0, limit 0FFFFFh, 0xCF9A), data 0x10 (0xCF92)
; GDT64: null, code 0x08 (0xAF9A long), data 0x10 (0xAF92)
```

## 5. Kernel Entry (`src/kernel/main.asm : _start`)

* `bits 64; default rel; org 0x100000`
* `mov rsp, 0x90000` (or end of identity-mapped conventional) aligned 16.
* Clear `.bss`, call `kinit` (C or asm) that sets `DRVTAB`, `BUFFER` as 64-bit pointers via `prot_ata_init`, `vga_init`.
* Install IDT (256 entries ×16B, see AGENTS.md):

```nasm
struc IDT_ENTRY
 .off_lo  resw 1
 .sel     resw 1
 .ist     resb 1
 .attr    resb 1
 .off_mid resw 1
 .off_hi  resd 1
 .res     resd 1
endstruc
lidt [idt_ptr]
```
Needed handlers: #DE(0), #GP(13), #PF(14) → fault print to VGA then hlt; IDT gate 0x21 for DOS syscall (DPL3), PIC master `0x28`/slave `0x30` (timer IRQ0@`0x28`, keyboard IRQ1@`0x29` installed, disk IRQ14@`0x36`).

## 6. Driver Replacement Order (per AGENTS.md Priority)

1. **VGA text** – memory-mapped `0xB8000`, ports 0x3D4/0x3D5 cursor. Implements `CONOUT`, `OUTCH`, `CRLF`. Verify by printing "Hello 64-bit DOS!" on `qemu/bochs`.
2. **Keyboard** – port 0x60 data, 0x64 status (OBF 1, IBF 2); translate scancode set 1 to ASCII; circular queue 128B (`KBD_QUEUE_SIZE`, power-of-two mask). Verify echo.
3. **Disk** – ATA PIO LBA28: poll `BSY=0x80` via `0x1F7`, write 0x1F2 sect cnt, 0x1F3-0x1F6 LBA, 0x1F7 cmd 0x20 read / 0x30 write. Alternatively AHCI. Verify read of boot sector 0 and check 0xAA55.

Time/BIOSGETTIME replaced later via CMOS `PORT 0x70/0x71`.

## 7. Incremental Testing (AGENTS.md §Testing Procedure)

Each stage has Bochs run:

*Stage 1 – Boot + mode.* Build mbr only, `dd if=mbr.bin of=dos64.img conv=notrunc; bochs -f bochsrc.txt -q` → check `r` shows `CR0 PE=1`, `EFER LME=1`, `CS long`. Halt with magic `0xEBFE`.

*Stage 2 – VGA.* Add `call dbg_print` → see text.

*Stage 3 – Kbd.* Poll `in al,0x64; test al,1`.

*Stage 4 – Disk.* Read LBA 0 to `0x9000` buffer, compare signature.

*Stage 5 – FS.* `tools/mkfat12.py` stamps a real 1.44M FAT12 volume at LBA 512–3391 during `make`; the kernel mounts it via `fs_mount_volume64` (`firfat/firdir/firrec` DPB + in-RAM FAT copy) and serves FCB/dir handlers from it. Scratch stays `200`/`500–511`.

*Stage 6 – Syscalls.* Exercise `INT 21h` gate for `AH=09` print string.

*Stage 7 – Shell.* `src/kernel/shell64.asm` REPL after the self-test suite: prompt loop over PS/2 + COM1 RX, `cmd_parse_line64` → builtins against the mounted volume + `*.COM` EXEC. QEMU `-serial stdio` drives it from a pipe.

## 8. Bochs Config (AGENTS.md template)

```
megs: 256
romimage: file=$BXSHARE/BIOS-bochs-latest
vgaromimage: file=$BXSHARE/VGABIOS-lgpl-latest.bin
ata0-master: type=disk, path="build/dos64.img", mode=flat, cylinders=20, heads=16, spt=63
boot: disk
log: bochs.log
cpu: model=ryzen, count=1, ips=50000000, reset_on_triple_fault=1, ignore_bad_msrs=1
panic: action=report
magic_break: enabled=1
com1: enabled=1, mode=file, dev=serial.log
display_library: nogui
```

(QEMU `qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none` is the primary proof path.)

Build scripts (see `Makefile`):

```bash
nasm -f bin src/boot/mbr.asm -o build/mbr.bin
nasm -f bin src/boot/stage2.asm -o build/stage2.bin
nasm -f elf64 src/kernel/*.asm src/drivers/*.asm src/lib/*.asm -o build/src/.../*.o
ld -T linker.ld -o build/kernel.elf build/src/kernel/main.o ... -nostdlib  # linker places .text.start (_start) at 0x100000
objcopy -O binary build/kernel.elf build/kernel.bin  # must fit KERNEL_SECTORS 176
dd if=/dev/zero of=build/dos64.img bs=1M count=10
dd if=build/mbr.bin of=build/dos64.img conv=notrunc
dd if=build/stage2.bin of=build/dos64.img bs=512 seek=1 conv=notrunc
dd if=build/kernel.bin of=build/dos64.img bs=512 seek=16 conv=notrunc  # or via stage2 LBA loader
python3 tools/mkfat12.py build/dos64.img  # stamps FAT12 volume at LBA 512+
make run-qemu   # or: bochs -f bochsrc.txt -q
```

## 9. Debugging Tools

* Bochs internal debugger: `b 0x7C00`, `c`, `r`, `x /10xb 0x7C00`, `s`, `creg`.
* Serial port logging: `mov dx,0x3F8; out dx,al` fallback.
* VGA dump: `mov rax,0xB8000; mov word [rax],0x0F44` (white-on-black 'D').
* Triple-fault: `ips` and `reset_on_triple_fault=1` will reset; check `bochs.log` for `exception` lines.

## 10. Success Criteria (Phase 1 → Phase 12)

Refer to Validation section. Phase 1 success is **documentation + scaffold** complete and reviewed, no code crashes because no boot yet.

## 11. Next Steps (Phase 2 Kickoff)

1. Implement `src/boot/mbr.asm` + `stage2.asm` + `gdt.asm`
2. Create `linker.ld` and `Makefile`
3. Smoke-test mode switch in Bochs with debugger.

*Memory map follows AGENTS.md §Memory Layout Recommendations; all addresses verified against IO.ASM:0F0h ports and MSDOS.ASM mem arithmetic.*
