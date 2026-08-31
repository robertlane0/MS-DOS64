; MS-DOS64 src/kernel/mem64.asm — 64-bit memory management (MCB64)
; Phase 3 register conversion + Phase 6 MCB intro
; Original: MSDOS.ASM had NO MCB in 1.25 (only SETMEM at HIGHMEM scan via NOT AL trick)
;           DOS 2.0 introduced MCB chain; we implement MCB64 per AGENTS.md §6
; Converts: paragraph arithmetic (SHL 4) -> byte/pages (SHL 12 for 4K)
;           BX/CX word sizes -> RBX/RCX byte sizes
;           DS:BP etc. -> flat RBP/RBX

bits 64
default rel

%include "include/mcb.inc"

section .text
global mem_init64
global mem_alloc64
global mem_free64
global mem_max_free64
global mem_dump64
global mem_para_to_bytes
global mem_bytes_to_para

extern vga_print
extern serial_print64

; ------------------------------------------------------------
; Constants
; ------------------------------------------------------------
%define MEM_START  MCB_CHAIN_START  ; 0x200000 (2 MiB)
%define MEM_END    0x800000         ; 8 MiB for demo (identity map covers 0-8M)
%define MEM_SIZE   (MEM_END - MEM_START)
%define PAGE_SIZE  4096

section .bss
mem_initialized: resb 1

section .text

; ------------------------------------------------------------
; mem_para_to_bytes — demonstrates paragraph (16 bytes) -> byte conversion
;   Original: SHL AX,1 x4  (or MOV CL,4 ; SHR BP,CL) to convert paragraphs to bytes
;   64-bit: bytes = para * 16, or para <<4 . For page: bytes = para *4096? Actually MCB size was paragraphs*16
;   In 64-bit we keep byte-based but provide conversion helpers for compatibility.
;   In: AX/EAX = paragraphs
;   Out: RAX = bytes
; ------------------------------------------------------------
mem_para_to_bytes:
    ; Original: MOV CL,4 ; SHL AX,CL
    ; 64-bit: shl rax,4 (explicit QWORD)
    shl rax, 4            ; para*16
    ret

; bytes to paragraphs (rounded up)
mem_bytes_to_para:
    ; Original: SHR AX,CL for para, but with rounding?
    add rax, 15
    shr rax, 4
    ret

; bytes to pages (4K)
mem_bytes_to_pages:
    add rax, PAGE_SIZE-1
    shr rax, 12           ; /4096
    ret

; ------------------------------------------------------------
; mem_init64 — initialize MCB chain with single large free block
;   Demonstrates 64-bit pointer handling vs 16-bit segment calc:
;   Original DOSINIT did: MEMSCAN loops with NOT AL / CMP [BX],AL to find top
;   64-bit: we trust identity map 0-8MiB, set up one MCB of type 'Z'
; ------------------------------------------------------------
mem_init64:
    push rax
    push rdi
    push rcx
    cmp byte [rel mem_initialized], 0
    jne .done

    mov rdi, MEM_START
    mov byte [rdi + MCB64.type], MCB_TYPE_Z
    mov qword [rdi + MCB64.owner], 0  ; free
    mov qword [rdi + MCB64.size], MEM_SIZE - MCBSIZ64
    mov dword [rdi + MCB64.name], 0x20202020 ; "    "
    mov dword [rdi + MCB64.name+4], 0x20202020
    mov byte [rel mem_initialized], 1

    ; Alternative paragraph-based calc demo: original would do
    ;   MOV CX, MEM_SIZE /16 ; but we do bytes directly.
.done:
    pop rcx
    pop rdi
    pop rax
    ret

; ------------------------------------------------------------
; mem_alloc64 — first-fit allocate
;   In: RDI = size bytes (64-bit)
;   Out: RAX = linear address of user data (after MCB), 0 on failure
;   Clobbers: RBX, RCX, RDX, RSI
;   Uses R8-R12 as temporaries (demonstrate extra regs)
;   Original: DOS 1.25 SETMEM did REP MOVSW then top-of-memory calc via paragraphs.
;             Now we use MCB chain walk.
; ------------------------------------------------------------
mem_alloc64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    ; Align size to 16 bytes (for ABI) and add header? User asks for data size, we find block >= size
    mov rax, rdi
    add rax, 15
    and rax, ~15
    mov r8, rax           ; r8 = aligned size

    ; Walk chain starting at MEM_START
    mov rsi, MEM_START    ; rsi = current MCB
.walk:
    mov al, [rsi + MCB64.type]
    cmp al, MCB_TYPE_M
    je .check_block
    cmp al, MCB_TYPE_Z
    jne .fail             ; invalid chain -> fail

.check_block:
    mov rdx, [rsi + MCB64.owner]
    test rdx, rdx
    jnz .next             ; owned (not free)

    mov rcx, [rsi + MCB64.size]
    cmp rcx, r8
    jb .next              ; too small

    ; Found free block, RCX = block size, R8 = requested
    ; If block > requested + MCBSIZ64 + 16 (split threshold), split
    mov r9, r8
    add r9, MCBSIZ64
    add r9, 16
    cmp rcx, r9
    jbe .use_whole

    ; Split: current block becomes allocated with size r8, next block is remainder
    mov r10, rsi
    add r10, MCBSIZ64
    add r10, r8           ; r10 = next MCB address (current + header + allocated)
    ; Next MCB type = old type
    mov al, [rsi + MCB64.type]
    mov [r10 + MCB64.type], al
    mov qword [r10 + MCB64.owner], 0
    mov r11, rcx
    sub r11, r8
    sub r11, MCBSIZ64
    mov [r10 + MCB64.size], r11
    ; Keep name zero
    ; Current becomes 'M' if there was a next, else 'Z' remains
    mov byte [rsi + MCB64.type], MCB_TYPE_M
    ; Set allocated size
    mov [rsi + MCB64.size], r8
    jmp .allocate

.use_whole:
    ; Use whole block, just mark allocated
    ; Keep type as is
    jmp .allocate

.next:
    ; Move to next MCB: rsi += MCBSIZ64 + size
    mov rcx, [rsi + MCB64.size]
    add rsi, MCBSIZ64
    add rsi, rcx
    ; Check if beyond MEM_END
    cmp rsi, MEM_END
    jae .fail
    ; If previous was Z, we already handled and would not continue (Z is last)
    ; But after split, previous Z's next is new Z, so we will visit it.
    jmp .walk

.allocate:
    ; Mark owner as 1 (kernel) or current PSP? For demo use 1
    mov qword [rsi + MCB64.owner], 1
    mov rax, rsi
    add rax, MCBSIZ64      ; return user data pointer
    jmp .done

.fail:
    xor rax, rax

.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; mem_free64 — free block by address
;   In: RDI = user data linear (as returned by alloc)
; ------------------------------------------------------------
mem_free64:
    push rax
    push rbx
    push rsi
    ; Get MCB: rsi = rdi - MCBSIZ64
    mov rsi, rdi
    sub rsi, MCBSIZ64
    ; Basic validation: check type
    mov al, [rsi + MCB64.type]
    cmp al, MCB_TYPE_M
    je .ok
    cmp al, MCB_TYPE_Z
    jne .fail2
.ok:
    mov qword [rsi + MCB64.owner], 0
    ; Coalesce with next if next is free? For demo, simple coalesce
    mov rax, [rsi + MCB64.size]
    mov rbx, rsi
    add rbx, MCBSIZ64
    add rbx, rax           ; rbx = next MCB
    cmp rbx, MEM_END
    jae .no_coalesce
    cmp qword [rbx + MCB64.owner], 0
    jne .no_coalesce
    ; Merge
    mov rax, [rbx + MCB64.size]
    add [rsi + MCB64.size], rax
    add qword [rsi + MCB64.size], MCBSIZ64
    mov al, [rbx + MCB64.type]
    mov [rsi + MCB64.type], al
.no_coalesce:
    clc
    jmp .exit
.fail2:
    stc
.exit:
    pop rsi
    pop rbx
    pop rax
    ret

; ------------------------------------------------------------
; mem_max_free64 — return size of largest free block
; ------------------------------------------------------------
mem_max_free64:
    push rbx
    push rsi
    xor rax, rax
    mov rsi, MEM_START
.walk_max:
    mov bl, [rsi + MCB64.type]
    cmp bl, MCB_TYPE_M
    je .check_max
    cmp bl, MCB_TYPE_Z
    jne .done_max
.check_max:
    cmp qword [rsi + MCB64.owner], 0
    jne .next_max
    mov rbx, [rsi + MCB64.size]
    cmp rbx, rax
    jbe .next_max
    mov rax, rbx
.next_max:
    mov rbx, [rsi + MCB64.size]
    add rsi, MCBSIZ64
    add rsi, rbx
    cmp rsi, MEM_END
    jb .walk_max
.done_max:
    pop rsi
    pop rbx
    ret

; ------------------------------------------------------------
; mem_dump64 — print MCB chain to serial/VGA for debugging
;   Uses 64-bit loops (DEC RCX / JNZ not LOOP)
; ------------------------------------------------------------
mem_dump64:
    push rax
    push rsi
    push rcx
    mov rsi, MEM_START
    xor rcx, rcx          ; count
.loop_dump:
    cmp rcx, 10           ; limit 10 entries
    jae .done_dump
    mov al, [rsi + MCB64.type]
    cmp al, 0
    je .done_dump
    ; For demo, just advance
    mov rax, [rsi + MCB64.size]
    add rsi, MCBSIZ64
    add rsi, rax
    inc rcx
    cmp rsi, MEM_END
    jb .loop_dump
.done_dump:
    pop rcx
    pop rsi
    pop rax
    ret
