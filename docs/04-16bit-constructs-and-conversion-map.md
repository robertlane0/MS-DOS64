# Phase 1 – 16-bit Constructs Catalog & 64-bit Conversion Map

## 1. Assembly Dialect & Directives (SCP ASM vs NASM)

Original uses SCP ASM 2.44 syntax, **not NASM**. All directives must be translated.

| Original (SCP) | NASM Equivalent | Occurrences | Conversion Action |
|----------------|-----------------|-------------|-------------------|
| `ORG 100H` + `PUT 100H` | `org 0x100` or `bits 16; org 0x7C00` for boot | All files | For boot: `org 0x7C00`. For kernel: `org 0x100000` (load at 1MiB) |
| `SEGMENT` / `ENDS` / `GROUP` / `ASSUME` | `section .text/.data/.bss` + `default rel` | `MSDOS.ASM:151-160,213` | Eliminate segments; use flat `section`. Preserve ordering only for documentation |
| `SEGMENT AT BIOSSEG` | N/A | `MSDOS.ASM:175` | Delete — replaced by driver structs |
| `INCLUDE MSDOS.ASM` (STDDOS) | ` %include "msdos.inc"` | `STDDOS.ASM:21` | Split into include files |
| `IF IBM` / `IF NOT IBM` / `IF HIGHMEM` etc. | `%ifdef` / NASM macros | `MSDOS.ASM:47-61,168` | Convert to `%define` build flags |
| `EQU`, `=` constants | `equ` | 60+ | Keep |
| `STRUC`/`ENDS` `FCBLOCK`/`DPBLOCK`/`STKPTRS` | `struc`/`endstruc` NASM | 3 strucs | Keep but expand to 64-bit (see §4) |
| `LABEL WORD/BYTE` | Label | `DATA:DIRBUF LABEL WORD` | Keep |
| `DB/DW/DS/DUP` `MOVW/MOVB/LODB/STOB/SCAB/RET L` (far ret) | `db/dw/resb` `movsw/lodsb/scasb/ret` `retf` | Throughout | Map: `RET L`→`retf`, `JMPS`→`jmp short` |
| `PUTCD`-style intermediate code | NASM `%rep`/`%assign` | `ASM.ASM` self-host | Not ported |

**Verified:** `grep -n "SEGMENT\|GROUP\|ASSUME\|PUT\|IF " MSDOS.ASM` → ~65 hits.

---

## 2. Register Usage Census (MSDOS.ASM)

Count via `grep -c "MOV.*AX"` sampling: ~615 data-move ops.

| 16-bit | 64-bit target | Preservation Notes |
|--------|---------------|-------------------|
| `AX/AH/AL` | `RAX/EAX/AX/AL` | `AH` holds DOS function (0-46); return code in `AL` (FF=err). `AX` often holds word ptr. |
| `BX` | `RBX` | Base for dispatch `SHL BX,1` + table index; also FCB ptr |
| `CX` | `RCX` | Loop counter (`LOOP`, `REP MOVSB`), record counts. `CL` holds 4/5 shift for dir entry calc |
| `DX` | `RDX` | FCB ptr (`DS:DX`), DMA high, sector rec no. |
| `SI` | `RSI` | Source for `REP MOVSB`, FCB fields, DPT |
| `DI` | `RDI` | Dest for store, directory buffer |
| `BP` | `RBP` | `BP` = DPB pointer (heavily used: `[BP.FIRFAT]`, `[BP.SECSIZ]`); also `BP` drives `TRKPT` index in IO.ASM |
| `SP` | `RSP` | Kernel stack pointer – switch between user/DOS |
| `DS,ES,SS,CS` | — | DOSGROUP alias (`MOV DS,CS`), user vs kernel segmentation. FS/GS only for TLS (new) |
| `R8-R15` | — | Free for new drivers |

**Port rules:**

* `AX/AH/AL` → `RAX` (use `AL` for byte, `AX` for word, `EAX` for 32-bit, `RAX` for 64-bit addr).
* `PUSH segment`/`POP segment` → `mov rax, seg; ...` or delete (flat).
* `LES`/`LDS` (`LDS SI,[SPSAVE]`) → `mov rsi, [rel SPSAVE]` + `mov rsi, [rsi]` pattern (split base/offset originally).
* `CBW` → `cbw`/`cwde`/`cdqe` depending on width.
* `MUL AH` / `DIV BX` → 64-bit `mul rbx` / `div rbx` but watch 128-bit dividend (`RDX:RAX`).

---

## 3. Segment:Offset → Flat Address Arithmetic

All original addresses are `seg:off` with `<<4`. Examples to eliminate:

```nasm
; Original
mov ax, 0x1000
mov ds, ax
mov si, 0x0050
mov al, [ds:si]          ; linear 0x10050

; Also BIOS far call setup:
mov bp, [DRVTAB]
mov al, [BP.DEVNUM]
mov bx, 2048
mov si, [BP.FAT]         ; pointer relative to DOSGROUP

; DMA split
mov ds, [DMAADD+2]
mov si, [DMAADD]         ; offset
rep movsb                ; DS:SI → ES:DI
```

**64-bit flat:**

```nasm
mov rsi, 0x10050
mov al, [rsi]

mov rbp, [rel DRVTAB]    ; now 64-bit ptr
mov al, [rbp + DPB.DEVNUM]
mov rsi, [rel DMAADD]    ; single 64-bit linear
```

**Specific patterns to replace (grep hits):**

* `LDS`/`LES` – 18 hits in MSDOS.ASM → manual `[rbx+8]`-style.
* `MOV DS,AX` / `MOV ES,AX` where AX=CS alias → delete; use `default rel`.
* `OFFSET DOSGROUP:*` – 70+ hits → `rel var`.
* `DMAADD` word-pair – 18 hits → single `dq`.
* `BUFFER`, `DIRBUF`, `FATSIZTAB` address tables holding 16-bit offsets → `dq`.
* `DRVTAB DW 0` plus `MOV BP,[DRVTAB]` → `mov rbp, [rel DRVTAB]`.
* `FAR PTR BIOS*` jump table (3-byte far jumps) → near calls.

---

## 4. Data Structure Width Expansion

| Structure | Field | 16-bit | 64-bit | File:Line |
|-----------|-------|--------|--------|-----------|
| FCB `FCBLOCK` | `EXTENT` | `DW` block | `DQ` or `DD` with 64-bit rec pos | `MSDOS.ASM:80` |
|  | `RECSIZ` | `DW` (0 default 128) | `DQ` or `DD` (up to 64K? keep 32) | `81` |
|  | `FILSIZ` | `DW` 2-word 32-bit | `DQ` 64-bit size | `82` |
|  | `DRVBP` | `DW` BP save | `DQ` | `83` |
|  | `FDATE`/`FTIME` | `DW` | unchanged (FAT) | `84-85` |
|  | `DEVID` | `DB` device id bits 0-5 + 7 device /6 dirty | expand to `DB` + 7 pad, or `DQ` dev ptr | `86` |
|  | `FIRCLUS` etc. | `DW` cluster <4080 | `DD` or `DQ` cluster (FAT32-ready) | `90-92` |
|  | `NR`/`RR` | `DB`+3 `DB` 4-byte RR | expand RR to `DQ` | `94-95` |
| DPB `DPBLOCK` | `SECSIZ` | `DW` 128-1024 | `DD` or `Q` (or keep 16, but LEA to 32) | `131` |
|  | `FIRFAT` etc. | `DW` sector numbers | `DD` LBA (32-bit) | `134-140` |
|  | `FAT` ptr | `DW` offset in DOSGROUP | `DQ` linear | `141` |
|  | `MAXCLUS` | `DW` 77*26≈2002 | `DD` | `138` |
| MCB (new) | — | absent | `MCB64` per AGENTS.md §6 | — |
| PSP | fields at 0,2,5,A,E | 16-bit segs | 64-bit `QWORD` seg/ptr | `MSDOS.ASM:3374` |
| `STKPTRS` | all `DW` | — | all `DQ` (`AXSAVE` → `RAXSAVE`) | `196-209` |
| `TRANS`/`NXTADD`/`SECPOS` etc. | all `DW` | word sector/cluster counters | `DQ` LBA counters | `DATA:3703` |

*Also paragraph-based sizing (`/16` divides/shifts) → byte-based. Example `DOSINIT` does `MOV CL,4; SHR BP,CL` to get paragraphs; in 64-bit divide by 4096 for pages.*

Naming clash: `NUMIO` vs `NUMDRV` counts. `FATSIZTAB DW 16` entries of fat sizes per allocation unit index – expand to 64-bit.

---

## 5. Instruction Idioms That Differ

| Idiom | Purpose | 64-bit Change |
|-------|---------|---------------|
| `REP MOVSB/MOVSW` + `CLD`/`STD` | Copy DOS (`MOVFAT`), copy FCB names, batch params | Keep, but `RCX` count; ensure `CLD`; use `movsq` for 64-bit |
| `SCASB/CMPSB` + `REPE` | Search IONAME, WILDCRD `?` | Keep |
| `OUT`/`IN` (8-bit) `INB` | Port I/O | Keep port I/O, but use `in al, dx` / `out dx, al` mnemonic. Bochs requires 0x1F0 ATA, 0xB8000 VGA not port |
| `CLI`/`STI` | Stack swap protection (`SAVREGS`/`LEAVE`, `HARDERR`) | Still valid in ring0; but `SS` loading is serializing in long mode |
| `PUSHF`/`POPF` / `IRET` | Syscall return, hard error IRET to user handler | `IRETQ` in 64-bit; stack frame 5 qwords (RIP,CS,RFLAGS,RSP,SS) not 3 words. Must build `IRETQ` frame |
| `HLT` | `BADINIT` halt | Keep, but after `STI`; triple-fault will reboot Bochs if not handled |
| `LOOP` | Retry counts (`BL=10` in READSECT) | Keep or `dec rcx/jnz` |
| `AAM`/`AAD` | BCD conversions for timer/date (`STCTIME`, `OUTBCD`) | `AAM` is invalid in 64-bit! Must replace with explicit `mov bl,10; div bl` or manual BCD. This is critical. |
| `XLAT` | Translate via DS:BX | Replace with `mov al, [rbx+rax]` |
| `LES`/`LDS` | Far pointer loads | Deprecated in 64-bit; illegal? `LDS`/`LES` are invalid in 64-bit mode. Must replace with two moves |
| `INT nn` / `IRET` | `INT 24h` hard error, `INT 23h` Ctrl-C | Replace with `call` or IDT gates; `int 24h` becomes `call hard_error_handler` |
| `RET L` (`retf`) | BIOS far returns | Near `ret` in flat |
| `CBW` / `CWD` | Sign-extend AL→AX, AX→DX:AX | `cbw`/`cwde`/`cdqe`/`cqo` |
| `MUL`/`DIV` with 16-bit | `FIGFATSIZ`, disk CHS `DIV AL,DL` | Use 64-bit dividends; watch #DE on divide error |
| `SHL AL,1` + `RCL` | 16-bit shift across registers (`FIGSHFT`) | Use `shl rax,1`/`rcl` 64-bit equivalents |
| `NOT AL` memory-scan trick | `MEMSCAN: NOT AL; CMP AL,[BX]` at `MSDOS.ASM:3909` | Keep, but use `xor byte [rbx],0xFF` etc. |

**Instruction census:** `IN`/`OUT` 22 hits in IO.ASM, `REP` 12, `AAM`/`AAD` 4 hits (critical), `LES`/`LDS` 14, `XLAT` 3, `INT` 25+ DOS-internal, `PUSHF` 2.

---

## 6. Mode-Transition Sensitive Code (for bootloader)

Original has no mode switch. Must insert:

```
real (BIOS) → protected (GDT 32-bit) → long (PAE + paging + EFER.LME → CR0.PG)
```

`DOSINIT` assumes CS=DS=ES=SS=DOSGROUP and that physical = segment<<4. In long mode DS/ES/SS ignored (base 0). So INIT relocation `MOV SW, DS:[DRVCNT]` must become flat `mov rax, [rel DRVCNT]`.

---

## 7. Converted File Layout (Target)

```
src/boot/mbr.asm        # 512B boot0: INT 13h LBA (chunked ≤64/packet) + CHS fallback (ES advances over 64K) → stage2 at 0x7E00, A20, GDT32
src/boot/stage2.asm     # PAE + PML4 @0x1000/PDPT @0x2000/PD @0x3000 identity 0-8MiB (4×2MiB PS), EFER.LME, GDT64, staging 0x80000 → 0x100000 copy, KERNEL_SECTORS 176
src/boot/gdt.asm        # GDT32 + GDT64 (code 0x9A, data 0x92, TSS if needed)
src/kernel/main.asm     # 64-bit entry _start @0x100000 (section .text.start first): 72-test harness → shell_repl64
src/kernel/shell64.asm  # interactive COMMAND64 REPL (prompt/line-edit/volume builtins/*.COM EXEC)
src/kernel/cmd64.asm    # COMMAND64 parser/COMTAB64/builtins/batch (%1-%9)
src/kernel/syscall64.asm # IDT INT 21h gate + DISPATCH64 (77 entries AH=00h-4Ch)
src/kernel/fat64.asm    # UNPACK/PACK/GETENTRY 64-bit cluster math (+ fat_dir_read64 tail-calls fs_dir_read64)
src/kernel/fs64.asm     # FAT12 mount/read/flush/alloc + FCB record-I/O core (volume LBA 512+)
src/kernel/mem64.asm    # MCB64 manager (40B headers, first-fit/coalesce/resize)
src/kernel/proc64.asm   # PSP64/env/loader(MZ64+COM)/spawn/terminate
src/kernel/idt64.asm    # IDT 256×16B + PIC master 0x28/slave 0x30 (timer 0x28/kbd 0x29/disk 0x36)
src/kernel/stack64.asm  # System V ABI/canary/IST reserve
src/drivers/vga.asm     # writes 0xB8000, cursor via 0x3D4
src/drivers/ata.asm     # PIO LBA28 (0x1F0-0x1F7), scratch LBA 200
src/drivers/kbd.asm     # port 0x60 scancode, queue
src/lib/string64.asm    # REP helpers for flat
src/lib/bcd64.asm       # DIV-based BCD (AAM/AAD invalid in 64-bit)
src/lib/addr64.asm      # seg:off→linear + RIP-rel demos
include/dpb.inc         # DPBLOCK64 struc
include/fcb.inc         # FCBLOCK64 struc
include/psp.inc         # PSP64 struc (664B actual, PSP64_size)
include/mcb.inc         # MCB64 struc (40B, MCBSIZ64)
include/regs.inc        # STKPTRS64 trap frame
include/fs.inc          # DIRENT/BPB + FS_VOL_LBA 512 scratch defines
include/stack.inc       # STACK_TOP64 0x90000 + ABI macros
tools/mkfat12.py        # stamps the real FAT12 volume at LBA 512+ during make
```

All new code `bits 64` `default rel`.

---

## 8. Validation Checklist (Phase 1 → Phase 2 hand-off)

* [x] All `SEGMENT`/`GROUP` sites identified (65 hits) → plan flat sections
* [x] All `FAR PTR BIOS*` sites (13) inventoried → replace with near driver calls
* [x] `AAM`/`LDS`/`LES` invalid-in-64 marked for rewrite (18 sites)
* [x] FCB/DPB/STKPTRS field widths cataloged for `.inc` expansion
* [x] I/O ports tabled (0xF0,0xE0,0x10,0xF4/0xF5 etc.) → new ports table (0x3F8,0xB8000,0x1F0,0x60,0x70)
* [x] Memory map with DOSSEG arithmetic documented → new map with 0x100000 kernel base
* [ ] Next phase will produce `boot/mbr.bin` + `stage2.bin` + `kernel.bin` and Bochs `bochsrc.txt`

*Catalog produced via `grep -n "AAM\\|LDS\\|LES\\|SEG\|DMAADD\\|FAR PTR" MSDOS.ASM` on 2026-08-30.*
