# AGENTS.md: Converting MS-DOS v1.25 ASM to 64-bit BIOS Bootable System

> **Status (2026-09-07): implementation complete — smoke 87 + 4 SKIP
> (`make`, default, non-destructive) and full 91/91 PASS (`make full`,
> destructive 71/83 in the reserved SCRATCH/RENAMED/CRASH namespace with
> mount-time recovery) on QEMU, then the interactive `COMMAND64`
> shell (`src/kernel/shell64.asm`).
> N2a (PLAN.md slice 4) landed: `proc_enter64` cooperative enter/return
> (tests 84–86, PURE) — EXEC still spawn-only from the shell/trap (N2d).
> N2b (slice 5) landed: handle `3Dh` OPEN (read-only) + `3Eh` CLOSE over
> a per-context fd table (`PSP64.fd_table`, test 87 READ-ONLY); kernel slot
> grew `176→184` sectors (extent `[16,200)`, test 82 locks it).
> N2c (slice 6) landed: `3Ch` CREATE + file `3Fh`/`40h` (byte-exact via
> `fs_fcb_io64` `recsiz=1`, FAT-first commit) + `42h` LSEEK (0..size, no
> sparse); tests 88 (cycle) + 89 (truncate/delete) DESTRUCTIVE in the
> `SCRATCH.TXT` namespace; descs now embed the FCB (13 qwords).
> N2d (slice 7) landed: shell ENTERS programs (`Exit <code>`, `sh_last_exit`
> for batch `%ERRORLEVEL%`, test 90) + `WRITE.COM` acceptance sample (args
> + `3Ch`/`40h`/`3Eh` + exit code); full kernel 183/184 sectors.
> N3-pre (PLAN.md item 8) landed: kernel slot `184→224` sectors (extent
> `[16,240)`); ATA scratch moved `200→400` (`ATA_SCRATCH_LBA`, test 82
> locks the new values).
> The phase plan below is kept as the build record; every checklist item is done.
> Current entry points: `README.md` (what works / memory / disk / shell),
> `docs/18-truth-gap-analysis.md` + `docs/19-closure-g1-g6.md` (audit trail for
> the G1–G6 correctness pass: 77-entry `INT 21h`, real FAT12 volume at LBA 512+,
> REPL, PIC master `0x28`/slave `0x30`) plus the cross-layer suite 77–82
> (malformed-BPB table + sentinels, pure ATA table, FAT-chain bounds,
> allocator arithmetic, queue interleave, layout invariants) and test 83
> (FAT12 crash-ordering: FAT-first commit, mirror heal, scrub/reclaim).

## Mission
You are tasked with converting the MIT-licensed MS-DOS v1.25 assembly code to create a fully 64-bit compatible operating system that boots via BIOS on x86-64 hardware. The target platform is QEMU emulator for testing, with the end goal being a working 64-bit OS that preserves the fundamental architecture and behavior of DOS while operating in long mode.

## Context and Constraints

### Source Material
- **Base Code**: MS-DOS v1.25 assembly source (8086/8088 16-bit real mode)
- **License**: MIT (permissive, allows modification and redistribution)
- **Original Architecture**: 16-bit real mode, segmented memory model, BIOS interrupt-driven I/O
- **Target Architecture**: x86-64 long mode (64-bit), flat memory model, with BIOS boot compatibility

### Technical Requirements
- **Boot Method**: Legacy BIOS (not UEFI) - must use MBR boot sector
- **Processor Mode Progression**: Real Mode → Protected Mode → Long Mode (64-bit)
- **Memory Model**: Flat 64-bit addressing (no segmentation)
- **Assembler**: NASM ≥ 2.15 (`nasm -f bin` for boot, `nasm -f elf64` + `ld -T linker.ld` + `objcopy -O binary` for the kernel, per `Makefile`)
- **Testing Platform**: QEMU `qemu-system-x86_64` (`-serial stdio` proof path, BIOS firmware)

## Conversion Strategy

### Phase 1: Architecture Analysis
Before touching any code, analyze the original DOS 1.25 structure:

1. **Identify all modules and their responsibilities**:
   - Boot sector (IO.SYS loading)
   - IO.SYS (device drivers, BIOS interface layer)
   - MSDOS.SYS (kernel: file system, process management, memory management)
   - COMMAND.COM (command interpreter)

2. **Map all BIOS interrupt dependencies** (INT 10h, 13h, 16h, etc.)

3. **Document the memory layout**:
   - Interrupt Vector Table (IVT) at 0000:0000
   - BIOS Data Area (BDA)
   - DOS kernel memory regions
   - Program loading area (PSP structure)

4. **Catalog all 16-bit specific constructs**:
   - Segment:offset addressing
   - 16-bit registers (AX, BX, CX, DX, SI, DI, BP, SP)
   - Real mode interrupts
   - Far pointers and segment registers (CS, DS, ES, SS)

### Phase 2: Boot Sector Redesign

Create a modern 64-bit boot sequence:

```nasm
; Boot sector must:
; 1. Start in 16-bit real mode (BIOS requirement)
; 2. Enable A20 line
; 3. Load GDT for protected mode
; 4. Switch to protected mode
; 5. Enable PAE (Physical Address Extension)
; 6. Set up page tables for identity mapping
; 7. Enable long mode via EFER MSR
; 8. Load 64-bit GDT
; 9. Jump to 64-bit kernel entry point
```

**Key Steps**:
- **Sector 1 (512 bytes)**: Initial bootloader that loads the secondary bootloader
- **Secondary Bootloader**: Performs mode transitions and loads the 64-bit kernel (chunked `INT 13h` LBA ≤16 sectors/packet with CHS fallback that advances ES across 64 KiB boundaries; stages at `0x70000`, copies to `0x100000` in long mode)
- **A20 Enabling**: Use Fast A20 method or keyboard controller
- **Page Table Setup**: Identity map 0–8 MiB via PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000` with 4×2 MiB pages (covers stage2, staging `0x70000`, stack `0x90000`, kernel `0x100000`)
- **GDT**: Create 64-bit code/data segments (base=0, limit=0xFFFFF, flags for long mode)
- **Kernel load**: `KERNEL_SECTORS 224` (LBA 16+, extent [16,240), clear of scratch `400`/`500–511` and the FAT12 volume at LBA 512+ stamped by `tools/mkfat12.py`)

### Phase 3: Register and Instruction Conversion

Transform all 16-bit code to 64-bit equivalents:

**Register Mapping**:
```
16-bit → 64-bit
AX/AH/AL → RAX (use appropriate sizes: AL, AX, EAX, RAX)
BX → RBX
CX → RCX
DX → RDX
SI → RSI
DI → RDI
BP → RBP
SP → RSP
```

**Additional 64-bit Registers Available**:
- R8 through R15 (use these for additional temporary storage)

**Instruction Adjustments**:
- Replace `PUSH segment` / `POP segment` with manual segment handling or eliminate
- Convert `LES`, `LDS` (load far pointer) to flat pointer loads
- Replace `LOOP` with explicit `DEC RCX / JNZ` if needed
- Update all memory operand sizes (`BYTE`, `WORD`, `DWORD`, `QWORD`)
- Change immediate operands to 32-bit or 64-bit where appropriate

### Phase 4: Addressing Mode Transformation

**From Segmented to Flat**:

Original DOS addressing:
```nasm
mov ax, 0x1000
mov ds, ax
mov si, 0x0050
mov al, [ds:si]  ; Accesses 0x10000 + 0x0050 = 0x10050
```

64-bit flat conversion:
```nasm
mov rsi, 0x10050
mov al, [rsi]    ; Direct linear address
```

**Guidelines**:
- Eliminate all segment override prefixes where possible
- Convert segment:offset calculations to linear addresses: `(segment << 4) + offset`
- Use RIP-relative addressing for position-independent code: `mov rax, [rel variable]`
- Replace far calls/jumps with near equivalents

### Phase 5: BIOS Interrupt Replacement

Since long mode doesn't support BIOS interrupts (must be called from real/protected mode):

**Option A: V86 Monitor** (Complex but complete)
- Create a Virtual 8086 mode handler
- Trap to real mode for BIOS calls
- Requires switching back to protected mode with VM86 flag

**Option B: Real Mode Stub** (Simpler)
- Keep a minimal real mode stub below 1MB
- Use far returns and mode switching to call BIOS
- Requires careful state preservation

**Option C: Native 64-bit Drivers** (Recommended for clean design)
- Replace BIOS INT 10h with direct VGA/VESA framebuffer driver
- Replace BIOS INT 13h with ATA/AHCI disk driver
- Replace BIOS INT 16h with keyboard controller (port 0x60/0x64) driver

**Implementation Priority**:
1. **INT 10h** (Video): VGA text mode driver (0xB8000 buffer, direct port I/O)
2. **INT 13h** (Disk): CHS or LBA disk I/O via ATA PIO mode
3. **INT 16h** (Keyboard): PS/2 keyboard driver via port 0x60

### Phase 6: Memory Management Overhaul

**DOS 1.25 Memory Manager**:
- No MCB chain (only `SETMEM` + `MEMSCAN` paragraph scan, `MSDOS.ASM:3363,3900`)
- 16-bit paragraph-based addressing (16-byte chunks)

**64-bit Conversion**:
```c
// Old MCB structure (DOS):
struct MCB {
    uint8_t type;      // 'M' = more blocks, 'Z' = last
    uint16_t owner;    // PSP segment of owner
    uint16_t size;     // Size in paragraphs (16-byte units)
    uint8_t reserved[3];
    uint8_t name[8];
};

// New 64-bit MCB (40 bytes on disk/in memory, see include/mcb.inc):
struct MCB64 {
    uint8_t type;      // 'M' or 'Z'
    uint8_t reserved[7];
    uint64_t owner;    // Process ID or linear address
    uint64_t size;     // Size in bytes
    uint8_t name[8];
    uint8_t pad1[8];   // reserved / future (checksum, flags)
};
```

**Changes Required**:
- Convert paragraph-based sizing to byte-based
- Expand pointers from 16-bit segments to 64-bit linear addresses
- Update allocation algorithms to handle 64-bit address space
- Implement proper memory protection using page table permissions

### Phase 7: File System Adaptation

**DOS 1.25 FAT12 File System**:
- Works with FAT12 on floppies
- Uses BIOS INT 13h for disk access
- CHS (Cylinder-Head-Sector) addressing

**64-bit Preservation Strategy**:
1. **Keep FAT12 Format**: Maintain compatibility with original disk images
2. **Replace Disk Access Layer**: 
   - Remove BIOS INT 13h calls
   - Implement direct ATA PIO or AHCI driver
   - Convert CHS to LBA if needed: `LBA = (C × HPC + H) × SPT + S - 1`
3. **Update Data Structures**:
   - File handles: 16-bit → 64-bit indices
   - File positions: 16-bit → 64-bit offsets
   - Buffer pointers: segment:offset → 64-bit linear

### Phase 8: Process Management (PSP Structure)

**Original PSP (Program Segment Prefix)** at offset 0x0000 of program segment:
```nasm
; 256-byte structure containing:
; +0x00: INT 20h instruction (program terminate)
; +0x02: Top of memory segment
; +0x2C: Environment segment
; +0x5C: FCB 1
; +0x6C: FCB 2
; +0x80: Command line length
; +0x81: Command line (127 bytes)
```

**64-bit PSP Redesign**:
- 664 bytes actual (`include/psp.inc`, `PSP64_size`; 512-byte DOS-compatible prefix + 64-bit extensions)
- Convert segment pointers to 64-bit linear addresses
- Add fields for 64-bit process state:
  - R8-R15 register storage
  - CR3 (page table base) for process isolation
  - 64-bit stack pointer
  - Extended file handle table (64-bit file descriptors)

### Phase 9: System Call Interface

**DOS 1.25 Used INT 21h** for system calls (AH = function number):
```nasm
mov ah, 0x09      ; Print string function
mov dx, offset msg
int 0x21
```

**64-bit Alternatives**:

**Option A: SYSCALL Instruction** (Modern, fast)
```nasm
; System V AMD64 ABI calling convention
mov rax, syscall_number
mov rdi, arg1
mov rsi, arg2
syscall
```

**Option B: Software Interrupt** (DOS-compatible)
- Keep INT 0x21 but implement as interrupt gate in IDT
- Handler runs in ring 0
- Convert 16-bit AH function codes to 64-bit equivalents

**Recommended**: Use Option B for DOS compatibility, allow Option A as extension

> Implemented as Option B: `src/kernel/idt64.asm` + `src/kernel/syscall64.asm`
> provide a 256-entry IDT with a DPL3 `INT 0x21` gate and a 77-entry
> `DISPATCH64` (`AH=00h–4Ch`); only DOS-reserved slots stay stubbed, as in DOS
> 1.25 itself (see `docs/19-closure-g1-g6.md` G1 table).

### Phase 10: Command Interpreter (COMMAND.COM → COMMAND64.SYS)

Convert the command interpreter (implemented as `src/kernel/cmd64.asm`
parser/builtins/exec/batch + `src/kernel/shell64.asm` interactive REPL, backed
by the mounted FAT12 volume; batch `%1`–`%9`, `*.COM` via `proc_spawn64`):

1. **Built-in Commands**: DIR, COPY, DEL, TYPE, REN, etc.
   - Update all file path parsing to handle 64-bit pointers
   - Maintain 8.3 filename restrictions or extend to LFN
   
2. **External Command Execution**:
   - Load .COM/.EXE programs (create 64-bit .EXE loader)
   - Set up 64-bit PSP for child process
   - Transfer control and wait for termination
   - As built: raw `.COM` + `MZ64` loaders via `proc_spawn64` (no MZ/PE loader; EXEC spawns but does not context-switch — see `docs/19-closure-g1-g6.md`)

3. **Batch File Processing**:
   - Preserve .BAT execution
   - Update variable substitution routines

### Phase 11: Interrupt Descriptor Table (IDT)

**Replace Real Mode IVT with Protected/Long Mode IDT**:

```nasm
; IDT entry structure for long mode (16 bytes):
struc IDT_ENTRY
    .offset_low:  resw 1    ; Offset bits 0-15
    .selector:    resw 1    ; Code segment selector
    .ist:         resb 1    ; Interrupt Stack Table offset
    .type_attr:   resb 1    ; Type and attributes
    .offset_mid:  resw 1    ; Offset bits 16-31
    .offset_high: resd 1    ; Offset bits 32-63
    .reserved:    resd 1    ; Reserved
endstruc
```

**Required Handlers**:
- Exception handlers: #DE, #GP, #PF, etc. (interrupts 0-31)
- DOS INT 0x21 (system call handler, DPL3)
- Timer interrupt (IRQ0 @ `0x28`, PIC master `0x28`)
- Keyboard interrupt (IRQ1 @ `0x29` installed, shares the polling queue)
- Disk interrupt (IRQ14 @ `0x36`, PIC slave `0x30`; note: CPU `#PF` is also
  vector `0x0E` — do not conflate it with the PIC IRQ14 vector)

### Phase 12: Stack and Calling Conventions

**DOS 1.25 Stack Usage**:
- 16-bit stack operations (PUSH/POP of 16-bit values)
- Near calls within segments
- Far calls between segments

**64-bit Conversion**:
- Use 64-bit stack (RSP register)
- All PUSH/POP operations are 64-bit by default (can use 16/32-bit with prefixes)
- Align stack to 16-byte boundaries (required by x86-64 ABI)

**Calling Convention**:
```nasm
; DOS style (preserve for internal DOS code):
; Parameters on stack or in registers (varies by function)

; Modern x86-64 System V ABI (for new code):
; RDI, RSI, RDX, RCX, R8, R9 for first 6 integer args
; Stack for additional args (16-byte aligned)
; RAX for return value
; RBX, RBP, R12-R15 are callee-saved
```

## Implementation Checklist

### Pre-Conversion Setup
- [x] Clone MS-DOS v1.25 source from official Microsoft repository
- [x] Install NASM 2.15+ (`nasm`, `ld`, `objcopy`, `python3` for `tools/mkfat12.py`)
- [x] Set up QEMU x86-64 BIOS support for testing
- [x] Create project structure for 64-bit rewrite (`src/boot|kernel|drivers|lib`, `include/`, `tools/`, `build/`)
- [x] Set up version control for tracking changes

### Boot and Mode Switching
- [x] Write 512-byte MBR boot sector (stage 1)
- [x] Implement A20 line enablement
- [x] Create GDT for protected mode transition
- [x] Implement protected mode entry code
- [x] Set up PAE paging structures
- [x] Create identity-mapped page tables (0–8 MiB via PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000`, 4×2 MiB pages)
- [x] Enable long mode via CR4 and EFER MSR
- [x] Load 64-bit GDT with proper code/data segments
- [x] Jump to 64-bit kernel entry point (`0x100000`, staged via `0x70000`, `KERNEL_SECTORS 224`)

### Core Kernel Conversion
- [x] Convert IO.SYS initialization routines to 64-bit
- [x] Convert MSDOS.SYS kernel to 64-bit
- [x] Update all register usage (AX→RAX, etc.)
- [x] Convert all segment:offset to linear addressing
- [x] Rewrite memory allocation routines for 64-bit
- [x] Implement 64-bit MCB chain management
- [x] Update file handle tables for 64-bit pointers
- [x] Convert FCB (File Control Block) structures

### BIOS Replacement Drivers
- [x] Implement VGA text mode driver (INT 10h replacement)
  - Character output to 0xB8000
  - Cursor positioning
  - Scrolling
  - Color attributes
- [x] Implement ATA PIO disk driver (INT 13h replacement)
  - Read sectors
  - Write sectors
  - Drive detection
  - LBA addressing
- [x] Implement PS/2 keyboard driver (INT 16h replacement)
  - Scan code reading
  - Key buffer management
  - Status checking

### File System Layer
- [x] Convert FAT12 parsing code to 64-bit
- [x] Update directory entry handling
- [x] Rewrite file open/close/read/write functions
- [x] Convert FCB-based operations (DOS 1.x style)
- [x] Ensure proper buffer pointer handling (64-bit)

### System Call Interface
- [x] Set up IDT with INT 0x21 gate
- [x] Implement INT 0x21 dispatcher in 64-bit
- [x] Convert each AH function handler:
  - [x] 0x01: Character input with echo
  - [x] 0x02: Character output
  - [x] 0x09: Print string (DS:DX → RSI)
  - [x] 0x0A: Buffered input
  - [x] 0x0D: Reset disk
  - [x] 0x0E: Select drive
  - [x] 0x19: Get current drive
  - [x] 0x25: Set interrupt vector
  - [x] 0x35: Get interrupt vector
  - [x] 0x3F: Read from file
  - [x] 0x40: Write to file
  - [x] 0x4C: Exit process
  - (Add others as needed)

### Process Management
- [x] Design 64-bit PSP structure
- [x] Implement program loader for 64-bit executables
- [x] Create process termination handler
- [x] Implement memory allocation for processes (INT 21h/48h)
- [x] Implement memory deallocation (INT 21h/49h)
- [x] Set up process environment blocks (64-bit)

### Command Interpreter
- [x] Convert COMMAND.COM to 64-bit (rename to COMMAND64)
- [x] Implement command line parser (64-bit string handling)
- [x] Convert built-in commands:
  - [x] DIR
  - [x] COPY
  - [x] DEL/ERASE
  - [x] REN/RENAME
  - [x] TYPE
  - [x] CLS
  - [x] DATE/TIME
  - [x] VER
  - [x] PROMPT
  - [x] PATH
- [x] Implement external command execution
- [x] Implement batch file processor

### Testing and Debugging
- [x] Create QEMU run configuration (`make run-qemu`, `-serial stdio`):
  ```
  qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
  ```
- [x] Create bootable disk image with boot sector
- [x] Test boot sequence in QEMU
- [x] Verify mode transitions (real → protected → long)
- [x] Test video output
- [x] Test keyboard input
- [x] Test disk I/O
- [x] Test file operations (create, read, write, delete)
- [x] Test command interpreter
- [x] Test program execution
- [x] Debug any crashes or hangs

## Technical Details and Gotchas

### Long Mode Requirements
1. **CPU Feature Detection**: Check CPUID for long mode support before attempting transition
   ```nasm
   mov eax, 0x80000001
   cpuid
   test edx, 1 << 29    ; LM bit
   jz no_long_mode
   ```

2. **Page Tables Must Be Set Up**: Long mode requires paging to be enabled
   - Implemented: PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000` with 4×2 MiB PS pages (identity 0–8 MiB)
   - Each table is 4KB aligned
   - Identity map at least where kernel code resides

3. **EFER MSR**: Extended Feature Enable Register (MSR 0xC0000080)
   ```nasm
   mov ecx, 0xC0000080
   rdmsr
   or eax, 1 << 8       ; Set LME (Long Mode Enable)
   wrmsr
   ```

### Memory Layout Recommendations
```
0x00000000 - 0x000003FF : Real Mode IVT (preserved for compatibility)
0x00000400 - 0x000004FF : BIOS Data Area
0x00000500 - 0x00007BFF : Free conventional memory
0x00007C00 - 0x00007DFF : Boot sector loaded here
0x00007E00 - 0x0007FFFF : Free (can use for stage 2 bootloader)
0x00080000 - 0x0009FFFF : Extended BIOS Data Area (EBDA)
0x000A0000 - 0x000BFFFF : Video RAM
0x000C0000 - 0x000FFFFF : BIOS ROM area
0x00100000 - ...        : Extended memory (load 64-bit kernel here)

Recommended Kernel Load Address: 0x00100000 (1MB mark)
```

> As built (see `README.md` Memory map): page tables PML4 @`0x1000` → PDPT
> @`0x2000` → PD @`0x3000` (0–8 MiB, 4×2 MiB); kernel staging `0x70000` →
> final `0x100000` (`KERNEL_SECTORS 224`); initial `RSP` `0x90000`;
> `IOSTACK`/`DSKSTACK` 4 KiB BSS stacks; heap `0x200000+` (`MCB64` 40 B);
> disk: kernel LBA 16+, scratch `400`/`500–511`, FAT12 volume LBA 512–3391.

### Critical Assembly Directives

For NASM:
```nasm
BITS 16          ; Start in 16-bit real mode
BITS 32          ; Switch to 32-bit protected mode
BITS 64          ; Switch to 64-bit long mode

ORG 0x7C00       ; Boot sector loaded at this address

; Use appropriate size specifiers:
mov al, [rsi]             ; 8-bit
mov ax, [rsi]             ; 16-bit
mov eax, [rsi]            ; 32-bit
mov rax, [rsi]            ; 64-bit
mov byte [rsi], 0x42      ; Explicit byte size
mov qword [rsi], 0x1000   ; Explicit qword size
```

### Common Pitfalls

1. **Default Operand Size**: In 64-bit mode, default operand size is 32-bit (not 64-bit)
   - Need explicit REX prefix or full register name for 64-bit ops
   - `mov eax, 0` zero-extends to RAX automatically

2. **No Segment Arithmetic**: CS, DS, ES, SS have no effect in 64-bit (except FS, GS)
   - FS and GS can still be used for thread-local storage

3. **RIP-Relative Addressing**: Default addressing mode in 64-bit
   - `mov rax, [variable]` may assemble to `mov rax, [rel variable]`
   - Useful for position-independent code

4. **Stack Alignment**: Must maintain 16-byte alignment before CALL instructions
   - Modern x86-64 ABI requirement
   - Failure can cause crashes in some operations

5. **High-Half Canonical Addresses**: In 64-bit, only 48 bits are typically used
   - Addresses must be canonical: bits 48-63 = bit 47
   - Non-canonical addresses cause #GP fault

## Testing Procedure

### Incremental Testing Strategy

**Stage 1: Boot and Mode Switch**
```bash
# Build everything (MBR + stage2 + kernel + image + FAT12 volume)
make

# Create disk image (done by make):
# dd if=/dev/zero of=build/dos64.img bs=1M count=10
# dd if=build/mbr.bin of=build/dos64.img conv=notrunc
# dd if=build/stage2.bin of=build/dos64.img bs=512 seek=1 conv=notrunc
# dd if=build/kernel.bin of=build/dos64.img bs=512 seek=16 conv=notrunc
# python3 tools/mkfat12.py --vol-lba 512 --vol-totsec 2880 --sector-size 512 --kernel-lba 16 --kernel-sectors 224 build/dos64.img   # stamps FAT12 volume (canonical values: Makefile disk-layout block)

# Test in QEMU
make run-qemu
```
Expected (smoke `make`): 85 PASS + 4 SKIP on serial, then the `COMMAND64` shell prompt; (full `make full`): 89 PASS, then the shell prompt

**Stage 2: Video Output**
- Test character output to screen using VGA driver
- Expected: "Hello from 64-bit DOS!" on screen

**Stage 3: Keyboard Input**
- Test reading a keypress
- Expected: Echo typed characters

**Stage 4: Disk I/O**
- Read boot sector back from disk
- Expected: Verify boot signature 0xAA55

**Stage 5: File System**
- Real FAT12 volume stamped at build time (`tools/mkfat12.py`, LBA 512–3391)
- Mount and read root directory via `fs_mount_volume64`
- Expected: List directory contents

**Stage 6: Command Interpreter**
- Load and execute command interpreter
- Expected: Command prompt appears, can accept commands

**Stage 7: External Programs**
- Create simple 64-bit test program
- Load and execute via command interpreter
- Expected: Program runs and returns to prompt

### Debugging Tools

1. **QEMU monitor / GDB stub**: `qemu-system-x86_64 -s -S ...` then
   `target remote :1234`; `info registers`, `x/10xb 0x7c00`, `stepi`.

2. **Serial Port Logging**: Add serial output for debugging messages
   ```nasm
   ; Output byte in AL to COM1
   mov dx, 0x3F8
   out dx, al
   ```

3. **VGA Text Buffer**: Write debug info directly to screen
   ```nasm
   mov rax, 0xB8000
   mov byte [rax], 'D'
   mov byte [rax+1], 0x0F     ; White on black
   ```

## Validation Criteria

The conversion is successful when:

- [x] System boots via BIOS on QEMU x86-64 emulator
- [x] Enters 64-bit long mode successfully
- [x] Can output text to screen without BIOS calls
- [x] Can read keyboard input without BIOS calls
- [x] Can read/write disk sectors without BIOS calls
- [x] Can mount and navigate FAT12 filesystem
- [x] Can create, read, write, and delete files
- [x] Command prompt appears and accepts input
- [x] Built-in commands function correctly
- [x] Can load and execute 64-bit programs
- [x] Memory allocation/deallocation works
- [x] System calls (INT 21h equivalent) function properly
- [x] No crashes or hangs during normal operation

## Additional Recommendations

1. **Start Small**: Begin with a minimal 64-bit bootloader that just prints "Hello World" before tackling the full conversion

2. **Module-by-Module**: Convert one subsystem at a time, testing thoroughly before moving on

3. **Keep Original DOS as Reference**: Have the original 16-bit code side-by-side for comparison

4. **Document Everything**: Comment extensively, especially the mode transitions and memory layouts

5. **Consider Hybrid Approach**: For early testing, you could keep some 16-bit real mode code and switch modes as needed

6. **Use Existing Resources**: Study other 64-bit OS projects (MINIX 3, SerenityOS) for driver implementation patterns

7. **Performance**: While not critical for DOS, be aware that 64-bit operations on small data can be less efficient

## Expected Challenges

1. **Mode Switching Complexity**: The real→protected→long mode transition is intricate and error-prone

2. **BIOS Dependency**: DOS heavily relies on BIOS; replacing all functionality requires substantial driver development

3. **Memory Model Mismatch**: DOS's segmented model is fundamentally different from 64-bit flat model

4. **Limited Documentation**: MS-DOS 1.25 is old and sparsely documented compared to modern systems

5. **Debugging Difficulty**: 64-bit assembly debugging in emulators can be challenging without good tooling

6. **Size Growth**: 64-bit code is typically larger than 16-bit equivalent, may not fit in same space constraints

## Deliverables

Upon completion, you should have:

1. **Source Code**: Complete 64-bit assembly source files
2. **Build Scripts**: Makefile or build.sh to compile all components
3. **Disk Image**: Bootable dos64.img with file system and programs
4. **Documentation**: 
   - Architecture overview
   - Memory map
   - System call reference
   - Build and testing instructions
5. **Test Programs**: Simple 64-bit .EXE programs demonstrating functionality

## Appendix: README detail backup (trimmed 2026-09-07)

This section preserves the implementation details that used to live in
`README.md` but were too low-level for a README. Kept here so they are not
lost; most overlap the phase plan above but these exact values/quirks are
authoritative.

### Self-test modes and write behavior
- `RUN_SELFTEST` (even smoke) performs bounded device writes: scratch-LBA
  patterns at LBA 400 / 500–511 (zeroed after) and an optional FAT2 heal on
  a diverged mount. Only `SKIP_SELFTEST` (`make lean`) performs zero device
  writes.
- Smoke (default `make`): PURE + SCRATCH-DEVICE + volume READ-ONLY; tests
  71/83 print SKIP, volume files untouched. Full (`make full`,
  `-DSELFTEST_DESTRUCTIVE`): all 83 including 71 (`SCRATCH.TXT` /
  `RENAMED.TXT`) and 83 (`CRASH.TXT`) in the reserved test namespace with
  pre-clean recovery + post-run preservation checks.
- References: `include/fs.inc` (reserved `SCRATCH`/`RENAMED`/`CRASH`
  namespace), `src/kernel/selftest64.asm` (PURE / SCRATCH-DEVICE /
  READ-ONLY / DESTRUCTIVE classification header, `msg_skip`, `Skipped
  (destructive)` summary, `R14` skip count, `>=3 ifdef
  SELFTEST_DESTRUCTIVE` gates for 69/71/83), `tools/check_volume_clean.py`
  (pre/post cleanliness proof: same contents before/after, no test files
  left).
- Build flags: default `NASM_DEFS ?= -DRUN_SELFTEST`; `FULL_DEFS :=
  -DRUN_SELFTEST -DSELFTEST_DESTRUCTIVE`; lean `-DSKIP_SELFTEST` skips suite,
  minimal init, shell direct.

### Serial: bounded best-effort (VGA authoritative)
- Every TX path uses a bounded helper that drops the char on timeout instead
  of hanging: `serial_try_putc` in MBR/stage2, `serial_try_putc64` in the
  kernel (`main.asm`, `SERIAL_TIMEOUT` polls, `ECX`/`CX` counter + `dec`,
  `stc`/CF=1 drop + `clc`/CF=0 success). `serial_print64` calls it (CF
  ignored). `shell64`/`cmd64`/`selftest64`/`stack64` call the shared helper
  and do no direct `mov dx, 0x3FD` UART poll; AUX backend
  (`syscall64.asm com1_write_char`) has its own `dec rcx` budget + `stc`
  timeout, `com1_read_char` is single-shot non-blocking.
- Boot/stage2 KBC waits are likewise bounded (`kbc_wait_timeout`, `CX`
  counter from `KBC_TIMEOUT*`, `stc` failure branch, 3 checked sites per
  stage, fallback: skip remaining KBC outs, re-assert fast A20, continue).
- Effect: boot/suite/shell keep working when the UART is absent or never
  reports THRE; a stuck UART only loses diagnostics. Normal QEMU
  output unchanged; missing UART reads LSR=0xFF (THRE set) so first poll
  succeeds.
- Limits: serial RX 1 byte deep (typing fine, paste bursts can overrun);
  printer output goes to the COM1 capture.

### Driver/ABI specifics
- Console: VGA text `0xB8000`, 80×25, cursor/scroll/color; COM1 `0x3F8` for
  logging + shell I/O. No `INT 10h` in long mode.
- Disk: ATA PIO LBA28 (`0x1F0`, polling, CHS→LBA conversion). No `INT 13h`
  in long mode. Disk IRQ only counts + EOIs; no DMA.
- Keyboard: PS/2 `0x60`/`0x64`, 128-byte queue, US shift/caps tables; polled
  in tests, IRQ-driven once the shell starts (IRQ1 shares the polling
  queue). No `INT 16h` in long mode.
- Memory: byte-based first-fit over `0x200000+` with split, prev+next
  coalesce, in-place resize, aligned/page allocation, validation, page-table
  `RW/NX` protection. `MCB64` 40 B (`include/mcb.inc`). `INT 21h
  AH=48h/49h/4Ah`.
- ABI: System V AMD64 throughout — 16-byte `RSP` alignment, `RDI RSI RDX
  RCX R8 R9` args, callee-saved `RBX RBP R12–R15`, near `CALL/RET` only,
  stack canaries; IST stacks reserved, IDT `IST==0` (no TSS yet).

### Filesystem / process specifics
- FAT12 engine: BPB→DPB, 12-bit chain walk, root-dir search, multi-cluster
  read, alloc-on-write with FAT+root write-through; mounted on the real
  on-image volume (LBA 512–3391, see below). Full FCB record I/O core
  (sequential + random + block, `RR`-addressed); sequential position mirrors
  `extent*128+nr` exactly for `recsiz=128`, other sizes address by `RR`.
  DMA defaults to unset and fails honestly — set with `AH=1Ah` before FCB
  transfers. Writes are record-granular (`COPY` truncates to exact length).
- Processes: 664-byte PSP64 (`include/psp.inc`, 512-byte DOS-compatible
  prefix + 64-bit extensions: R8–R15 storage, CR3, 64-bit RSP, extended
  handle table) + environment blocks; raw-`.COM` and `MZ64` loaders via
  `proc_spawn64` (no MZ/PE loader; EXEC spawns but does not
  context-switch). `INT 21h AH=4Bh/4Ch`, `INT 20h` terminate.
- Crash-ordering (test 83): FAT-first commit, mirror heal, scrub/reclaim
  (`CRASH.TXT`).

### Interrupts
- Full 256-entry IDT (`src/kernel/idt64.asm`); CPU vectors 0–31 with
  diagnostics (vector/error/`RIP` counters); PIC remapped master `0x28` /
  slave `0x30` so IRQ1 no longer collides with DOS `0x21`; timer IRQ0@`0x28`,
  keyboard IRQ1@`0x29` installed, disk IRQ14@`0x36`. Note CPU `#PF` is also
  vector `0x0E` — do not conflate with PIC IRQ14.

### INT 21h coverage (77-entry DISPATCH64, AH=00h–4Ch)
- Consoles `01/02/06–0C`, READER/PUNCH/LIST `03/04/05`, disk reset/select
  `0D/0E`, drive `19`, FCB files `0F–17/21–24/27–29`, pointers `1B/1C/1F`,
  attrs `1D/1E`, NEWBASE `26`, date/time `2A–2D` (CMOS RTC), VERIFY `2E`,
  vectors `25/35`, DMA `1A`, handles `3F/40`, alloc `48/49/4A`, EXEC/EXIT
  `4B/4C`, plus `INT 20h` terminate. Only DOS-reserved slots stay stubbed,
  as in DOS 1.25 itself (see `docs/19-closure-g1-g6.md` G1 table).

### Memory map (as built)
| Range | Use |
|---|---|
| `0x0000–0x0FFF` | IVT/BDA preserved |
| `0x1000/0x2000/0x3000` | PML4 / PDPT / PD (identity 0–8 MiB, 4×2 MiB pages) |
| `0x7C00–0x7DFF` | MBR load address |
| `0x7E00+` | Stage2 load address |
| `0x70000` | Kernel staging buffer (copied to `0x100000`; must avoid `0x90000` — BIOS `INT 13h` clobbers transfers ending there) |
| `0x90000` | Initial `RSP` top (16-aligned); `IOSTACK`/`DSKSTACK` separate 4 KiB BSS stacks (16-aligned tops) |
| `0xB8000` | VGA text buffer |
| `0x100000+` | Kernel (linked flat at 1 MiB, ~92 KiB / ~184 sectors, ≤224) |
| `0x200000+` | Heap (`MCB64` chain, first-fit) |

### Disk layout (`build/dos64.img`, 10 MiB)
- Canonical values live only in the Makefile disk-layout block
  (`IMG_MB=10`, `IMG_SECTOR_SIZE=512`, `VOL_LBA=512`, `VOL_SECTORS=2880`,
  `KERNEL_LBA=16`, `KERNEL_SECTORS=224`), which generates
  `build/include/layout.inc` for bootloader/kernel and passes the same
  numbers explicitly to `tools/mkfat12.py`. `make check-layout` (prerequisite
  of every image build) enforces this; layout overrides on the make
  command line are rejected.
| LBA | Contents |
|---|---|
| 0 | MBR + boot signature `55 AA` |
| 1–15 | Stage2 |
| 16+ | Kernel binary (up to 224 sectors) |
| 400, 500–511 | ATA/filesystem scratch (kept clear of kernel and volume) |
| 512–3391 | Real FAT12 volume (1.44 M geometry, stamped at build by `tools/mkfat12.py`) |
- Volume files: `HELLO.TXT` (1 cluster), `README.TXT` (2-cluster chain),
  `TEST.COM` (single `RET`, EXEC target), `DATA.BIN` (512 B pattern).

### Shell reference (removed from README)
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
- `COMMAND64` REPL (`src/kernel/shell64.asm` interactive + `src/kernel/cmd64.asm`
  parser/builtins/exec/batch): prompt expansion, line editing over PS/2 and
  serial, volume-backed builtins, batch `%1`–`%9` + `%%` escapes, `*.COM`
  via `proc_spawn64`. Drivable from a pipe under QEMU.
- `TYPE` shows the first 4 KiB. PIT runs at the BIOS rate.

### Source map (removed from README)
```
src/boot/      mbr.asm (A20, INT13 LBA/CHS) + stage2.asm (mode switch, chunked loads) + gdt.asm
src/kernel/    main.asm (entry @0x100000, boot glue) + selftest64.asm (83-test harness) + shell64.asm (REPL)
               cmd64.asm (COMMAND64 parser/builtins/exec/batch) + fat64.asm (UNPACK/PACK)
               fs64.asm (FAT12 mount/read/flush/alloc + FCB record-I/O core)
               mem64.asm (MCB64 manager) + proc64.asm (PSP64/env/loader/spawn)
               syscall64.asm (INT 21h dispatcher, 77 entries)
               time64.asm (timekeeping leaf: software clock + CMOS RTC + FAT pack)
               idt64.asm (IDT, PIC master 0x28/slave 0x30) + stack64.asm (ABI/canary)
src/drivers/   vga.asm (0xB8000 text) + ata.asm (0x1F0 PIO LBA28) + kbd.asm (PS/2 0x60/0x64)
src/lib/       string64.asm + bcd64.asm (AAM/AAD->DIV, CBW equiv.) + addr64.asm (seg:off->linear)
include/       fcb.inc/dpb.inc/psp.inc/mcb.inc/regs.inc/fs.inc/stack.inc (64-bit structures)
tools/         mkfat12.py (stamps FAT12 volume) + check_volume_clean.py (pre/post cleanliness proof)
MSDOS.ASM / IO.ASM / COMMAND.ASM   original v1.25 reference (STDDOS.ASM legacy wrapper; build uses src/ via Makefile)
linker.ld      flat link at 0x100000 (.text.start first)
```
#### Layering: timekeeping (`time64.asm`)
- `time64.asm` is a leaf module owning the software clock
  (`time_year/month/day/hour/min/sec`, defaults 1983-04-01 12:00:00 via
  `time_init64`), the validators/formatters/parsers
  (`time_date_set64/time_time_set64`, `time_date_get64/time_time_get64`,
  `time_date_parse64/time_time_parse64`), and all CMOS RTC access
  (`rtc_get_date64/rtc_get_time64/rtc_set_date64/rtc_set_time64`,
  `rtc_pack_fat_datetime`; ports `0x70/0x71`). It depends only on the
  `bcd64` lib (`rtc_bcd_to_bin_v2`/`rtc_bin_to_bcd`).
- Dependents: `syscall64.asm` (`INT 21h AH=2Ah–2Dh` + FAT timestamps) and
  `cmd64.asm`/`shell64.asm` (DATE/TIME builtins + REPL RTC sync) call the
  `time_*`/`rtc_*` APIs. The kernel ABI layer (`INT 21h`) must never extern
  command-interpreter state; `syscall64.asm` carries no `cmd64` clock
  externs. The `cmd_year`/`cmd_date_set64`/… symbols in `time64.asm` are
  backward-compat aliases to the canonical `time_*` storage/entry points.

### Verify commands (removed from README)
```bash
timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# tail: Summary: 87 passed, 0 failed ... Skipped (destructive): 4 ... MS-DOS64 shell (COMMAND64). Type HELP for commands.
timeout 25 qemu-system-x86_64 -drive file=build/dos64-full.img,format=raw -serial stdio -display none
# tail: Summary: 91 passed, 0 failed ... MS-DOS64 shell (COMMAND64).
python3 tools/check_volume_clean.py --vol-lba 512 --vol-totsec 2880 --sector-size 512 --kernel-lba 16 --kernel-sectors 224 build/dos64.img
python3 tools/check_volume_clean.py --vol-lba 512 --vol-totsec 2880 --sector-size 512 --kernel-lba 16 --kernel-sectors 224 build/dos64-full.img
printf '\rDIR\rTYPE HELLO.TXT\rHELP\rEXIT\r' | timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
```
- Make targets: `make` (smoke img), `make full` (destructive full img),
  `make lean` (no self-test img), `make run-qemu` / `run-qemu-full` /
  `run-qemu-lean`, `make clean`, `make check-layout` / `check-layout-neg` /
  `check-kbc` / `check-serial` / `check-selftest-modes` / `check-debug-symbols`.
