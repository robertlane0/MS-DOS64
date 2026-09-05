# AGENTS.md: Converting MS-DOS v1.25 ASM to 64-bit BIOS Bootable System

> **Status (2026-09-05): implementation complete — 72/72 self-tests PASS on QEMU
> and Bochs, then the interactive `COMMAND64` shell (`src/kernel/shell64.asm`).
> The phase plan below is kept as the build record; every checklist item is done.
> Current entry points: `README.md` (what works / memory / disk / shell),
> `docs/18-truth-gap-analysis.md` + `docs/19-closure-g1-g6.md` (audit trail for
> the G1–G6 correctness pass: 77-entry `INT 21h`, real FAT12 volume at LBA 512+,
> REPL, PIC master `0x28`/slave `0x30`).

## Mission
You are tasked with converting the MIT-licensed MS-DOS v1.25 assembly code to create a fully 64-bit compatible operating system that boots via BIOS on x86-64 hardware. The target platform is Bochs emulator for testing, with the end goal being a working 64-bit OS that preserves the fundamental architecture and behavior of DOS while operating in long mode.

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
- **Testing Platform**: QEMU `qemu-system-x86_64` (primary proof path, `-serial stdio`) and Bochs x86-64 emulator (`bochsrc.txt`: 256 MiB, `cpu: model=ryzen`, BIOS firmware)

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
- **Kernel load**: `KERNEL_SECTORS 176` (LBA 16+, clear of scratch `200`/`500–511` and the FAT12 volume at LBA 512+ stamped by `tools/mkfat12.py`)

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
- Used a simple first-fit allocation scheme
- MCB (Memory Control Block) chain starting at segment 0x0600
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
- [x] Set up QEMU (primary) + Bochs x86-64 BIOS support (`bochsrc.txt`: 256 MiB, `model=ryzen`)
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
- [x] Jump to 64-bit kernel entry point (`0x100000`, staged via `0x70000`, `KERNEL_SECTORS 176`)

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
- [x] Create Bochs configuration file:
  ```
  megs: 256
  romimage: file=$BXSHARE/BIOS-bochs-latest
  vgaromimage: file=$BXSHARE/VGABIOS-lgpl-latest.bin
  ata0-master: type=disk, path="build/dos64.img", mode=flat, cylinders=20, heads=16, spt=63
  boot: disk
  log: bochs.log
  com1: enabled=1, mode=file, dev=serial.log
  display_library: nogui
  cpu: model=ryzen, count=1, ips=50000000, reset_on_triple_fault=1, ignore_bad_msrs=1
  ```
- [x] Create bootable disk image with boot sector
- [x] Test boot sequence in Bochs
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
> final `0x100000` (`KERNEL_SECTORS 176`); initial `RSP` `0x90000`;
> `IOSTACK`/`DSKSTACK` 4 KiB BSS stacks; heap `0x200000+` (`MCB64` 40 B);
> disk: kernel LBA 16+, scratch `200`/`500–511`, FAT12 volume LBA 512–3391.

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
# python3 tools/mkfat12.py build/dos64.img   # stamps FAT12 volume at LBA 512+

# Test in QEMU (primary) or Bochs
make run-qemu
make run-bochs
```
Expected: 72/72 self-tests PASS on serial, then the `COMMAND64` shell prompt

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

1. **Bochs Internal Debugger**:
   ```
   bochs -f bochsrc.txt -q
   <bochs:1> b 0x7c00          # Breakpoint at boot sector
   <bochs:2> c                  # Continue
   <bochs:3> r                  # Show registers
   <bochs:4> x /10xb 0x7c00    # Examine memory
   <bochs:5> s                  # Step instruction
   ```

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

- [x] System boots via BIOS on Bochs x86-64 emulator
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
6. **Bochs Configuration**: Ready-to-use bochsrc.txt for testing
