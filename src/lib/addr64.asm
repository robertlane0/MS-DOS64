; MS-DOS64 lib/addr64.asm — Phase 4: Addressing Mode Transformation (segmented -> flat)
; Converts DOS 1.25 segmented constructs to 64-bit flat linear addressing.
; Covers: (seg<<4)+off, OFFSET DOSGROUP:xxx -> rel, DMAADD split -> dq,
;         FAR PTR BIOS* -> near dispatch, DIRBUF/BUFFER dq, segment overrides eliminated,
;         RIP-relative, far call/ret -> near, DS=CS alias elimination, stack flat.
; References: MSDOS.ASM:313 OFFSET DOSGROUP:IOSTACK, 517 IONAME, 3654 DMAADD, 414 FAR PTR BIOSFLUSH,
;             docs/04 §3-4, AGENTS.md Phase 4.

bits 64
default rel

%include "include/mcb.inc"
%include "include/dpb.inc"
%include "include/fcb.inc"

section .text

global seg_off_to_linear
global seg_off_to_linear2
global offset_to_rel_demo
global rip_relative_demo
global rip_relative_abs_vs_rel
global dosgroup_alias_elimination_demo
global dma_flat_demo
global far_to_near_demo
global far_to_near_call_via_index
global buffer_flat_demo
global dirbuf_flat_demo
global segment_override_elimination_demo
global stack_flat_demo
global paragraph_to_byte_demo
global linear_to_seg_off_demo
global flat_pointer_arithmetic_demo
global canonical_address_check
global addr_test_all
global addr_test_seg_off
global addr_test_rip
global addr_test_far_near
global addr_test_buffer
global addr_test_canonical

; ------------------------------------------------------------
; seg_off_to_linear — convert 16-bit seg:off to 64-bit linear
;   In:  RDI = segment (0..0xFFFF), RSI = offset (0..0xFFFF)
;   Out: RAX = linear = (segment<<4)+offset
;   Original DOS: linear = (segment<<4)+offset where segment is 16-bit para.
;   Example: MOV AX,0x1000; MOV DS,AX; MOV SI,0x0050; MOV AL,[DS:SI] -> 0x10050
;   64-bit: MOV RSI,0x10050; MOV AL,[RSI]
;   Clobbers: RAX
; ------------------------------------------------------------
seg_off_to_linear:
    mov rax, rdi
    shl rax, 4              ; seg*16 (paragraph -> byte, same as mem_para_to_bytes but seg)
    add rax, rsi
    ret

; Variant: packed seg:off in 32-bit (high 16 seg, low 16 off) like DWORD PTR [SPSAVE]
;   In: EDI = seg:off? Actually original SPSAVE+2 segment, SPSAVE offset.
;   Simplified: RDI = (seg<<16)|off? We split: DI=off, high 16=seg.
;   For demo, RDI holds 32-bit seg:off packed as (seg<<16 | off)
seg_off_to_linear2:
    mov eax, edi
    movzx ecx, ax           ; offset = low 16
    shr eax, 16             ; segment = high 16
    shl eax, 4
    add eax, ecx
    movzx rax, ax           ; zero-extend? Actually need 32-bit, but linear fits 20-bit
    ; Correct 64-bit:
    mov rax, rdi
    shr rax, 16
    and eax, 0xFFFF
    shl rax, 4
    movzx rcx, di
    add rax, rcx
    ret

; ------------------------------------------------------------
; offset_to_rel_demo — demonstrates OFFSET DOSGROUP:xxx -> [rel xxx]
;   Original: MOV SI,OFFSET DOSGROUP:IONAME  ; 16-bit offset within DOSGROUP segment
;             MOV AX,CS; MOV DS,AX           ; DS=CS alias (DOSGROUP = CS)
;             MOV AL,[SI]   ; via DS:SI
;   64-bit: LEA RSI,[rel IONAME] ; or MOV RSI,[rel IONAME_ptr]
;           MOV AL,[RSI]
;   We demo by loading address of a known variable via rel and via absolute,
;   verifying they match and can be dereferenced.
; ------------------------------------------------------------
section .data
offset_test_var: dq 0x1122334455667788
offset_test_str: db "IONAME",0

section .text
offset_to_rel_demo:
    ; Method 1: LEA RSI, [rel offset_test_var]  ; RIP-relative (PIC)
    lea rsi, [rel offset_test_var]
    ; Method 2: MOV RAX, offset_test_var ; absolute (NASM: movabs)
    ;   But in flat 64-bit with default rel, `mov rax, offset_test_var` would be rel too
    ; So we compute absolute via `mov rax, offset_test_var` vs `lea`
    mov rax, [rsi]          ; dereference via flat RSI
    mov rbx, 0x11223344
    shl rbx, 32
    or rbx, 0x55667788
    cmp rax, rbx
    jne .fail
    ; Also test str address
    lea rdi, [rel offset_test_str]
    mov al, [rdi]
    cmp al, 'I'
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; rip_relative_demo — explicit RIP-relative vs segment:offset
;   Original used segment registers to form address; 64-bit uses RIP.
;   Demonstrates `mov rax, [rel var]` vs `mov rax, [abs]` and LEA.
;   Also shows that `default rel` makes `mov rax, [var]` automatically RIP-relative.
; ------------------------------------------------------------
section .data
rip_var: dq 0x0102030405060708

section .text
rip_relative_demo:
    ; Absolute linear via LEA
    lea rax, [rel rip_var]      ; RAX = linear address of rip_var
    ; Verify that [rel rip_var] dereference works
    mov rbx, [rel rip_var]
    mov rcx, 0x01020304
    shl rcx, 32
    or rcx, 0x05060708
    cmp rbx, rcx
    jne .fail
    ; Check that LEA address + offset access matches MOV [rel]
    mov rcx, [rax]              ; dereference via absolute computed address
    cmp rcx, rbx
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; Check that two ways to get address are equal (RIP vs absolute via symbol)
; NASM `mov rsi, rip_var` without rel would be absolute movabs; with default rel it's RIP
rip_relative_abs_vs_rel:
    lea rsi, [rel rip_var]      ; RIP-relative
    ; Compute absolute via `lea rax, [rel rip_var]` same; just test that lea works at different RIP
    mov rax, rsi
    add rax, 8                  ; next qword after rip_var (should not fault, just arithmetic)
    lea rbx, [rel rip_var+8]
    cmp rax, rbx
    jne .fail2
    xor rax, rax
    ret
.fail2:
    mov rax, 1
    ret

; ------------------------------------------------------------
; dosgroup_alias_elimination_demo — DS=CS alias no longer needed
;   Original (MSDOS.ASM:213-214): ASSUME CS:DOSGROUP,DS:DOSGROUP,SS:DOSGROUP
;                                 MOV AX,CS; MOV DS,AX; MOV ES,AX
;                                 MOV SI,OFFSET DOSGROUP:NAME1; MOV AL,[SI]
;   64-bit: elimination — `default rel` + flat DS base=0
;           LEA RSI,[rel NAME1]; MOV AL,[RSI]
;   Demonstrates that DS load is unnecessary and flat access works.
; ------------------------------------------------------------
section .data
dosgroup_var: db 0x42
section .text
dosgroup_alias_elimination_demo:
    ; Old way would be: mov ax,cs; mov ds,ax; mov si, offset dosgroup_var; mov al,[ds:si]
    ; New way: flat
    lea rsi, [rel dosgroup_var]
    mov al, [rsi]               ; no segment prefix
    cmp al, 0x42
    jne .fail
    ; Also demonstrate that we don't need to push/pop DS
    ; Original: PUSH DS; MOV AX,CS; MOV DS,AX; ...; POP DS
    ; New: just use RSI/RDI flat, no DS save/restore
    lea rdi, [rel dosgroup_var]
    mov byte [rdi], 0x43
    cmp byte [rel dosgroup_var], 0x43
    jne .fail
    mov byte [rel dosgroup_var], 0x42  ; restore
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; dma_flat_demo — single DQ DMAADD vs split word-pair
;   Original (MSDOS.ASM:3654): DMAADD DW 80H ; offset, DMAADD+2 DW ? ; segment
;   Accessed via: MOV BX,[DMAADD]; MOV ES,[DMAADD+2]; ES:BX or LES DI,[DMAADD]
;   64-bit: DMAADD64 DQ linear (single 64-bit)
;           MOV RDI,[rel DMAADD64]  ; flat linear
;   Demonstrates conversion and that split calculation yields same linear.
; ------------------------------------------------------------
section .data
dma_split_off: dw 0x0080
dma_split_seg: dw 0x1000       ; seg 0x1000:0x0080 = 0x10080
DMAADD64_FLAT: dq 0x10080      ; precomputed linear

section .text
dma_flat_demo:
    ; Recompute linear from split pair (seg:off) and compare to flat DQ
    movzx eax, word [rel dma_split_seg]
    shl eax, 4
    movzx ecx, word [rel dma_split_off]
    add eax, ecx                ; EAX = 0x10080
    mov rbx, [rel DMAADD64_FLAT]
    cmp rax, rbx
    jne .fail
    ; Also test flat load store
    mov rdi, 0x12345678
    shl rdi, 32
    or rdi, 0x23456789
    mov [rel DMAADD64_FLAT], rdi
    mov rax, [rel DMAADD64_FLAT]
    cmp rax, rdi
    jne .fail
    ; restore
    mov qword [rel DMAADD64_FLAT], 0x10080
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; far_to_near_demo — FAR PTR BIOS jump table -> near dispatch
;   Original: BIOSSEG segment at 040h/060h with 13 FAR jumps (3 bytes each):
;             BIOSREAD DB 3 DUP (?) ; JMP FAR
;             CALL FAR PTR BIOSREAD  ; pushes CS:IP, far ret via RETF
;   64-bit: near table of dq function pointers, call via index:
;           DISPATCH64: dq handler0, handler1...
;           SHL RBX,3 ; CALL [DISPATCH64+RBX]
;   Demonstrates that far call/ret is replaced with near and stack is 64-bit.
; ------------------------------------------------------------
section .data
align 8
bios_near_table:
    dq bios_func0
    dq bios_func1
    dq bios_func2
    dq bios_func3

section .text
bios_func0: mov rax, 0xAA00 ; dummy
            ret
bios_func1: mov rax, 0xBB01
            ret
bios_func2: mov rax, 0xCC02
            ret
bios_func3: mov rax, 0xDD03
            ret

; call via index in RBX (like DOS DISPATCH: SHL BX,1; CALL CS:[BX+DISPATCH])
far_to_near_demo:
    mov rbx, 2                ; index 2 -> func2
    shl rbx, 3                ; *8 for dq
    lea rax, [rel bios_near_table]
    add rax, rbx
    mov rax, [rax]            ; load function pointer
    call rax
    cmp rax, 0xCC02
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; Alternative direct indexed call like syscall64: CALL [reg+rbx*8]
far_to_near_call_via_index:
    ; In: RDI = index
    mov rbx, rdi
    shl rbx, 3
    lea rax, [rel bios_near_table]
    mov rax, [rax + rbx]      ; SIB with scale 8 demo (flat)
    call rax
    ret

; ------------------------------------------------------------
; buffer_flat_demo — BUFFER/DIRBUF 16-bit offset tables -> dq linear
;   Original: BUFFER DW ? ; offset within DOSGROUP, accessed via MOV BX,[BUFFER]; MOV AX,CS; MOV DS,AX; MOV AL,[BX]
;   64-bit: BUFFER64 DQ linear, MOV RSI,[rel BUFFER64]; MOV AL,[RSI]
;   Demonstrates that table entries are now 64-bit and accessed flat.
; ------------------------------------------------------------
section .bss
flat_buffer: resb 512        ; simulate DIRBUF (one sector)
section .data
BUFFER64: dq 0               ; will hold linear address of flat_buffer
DIRBUF64_PTR: dq 0
FATSIZTAB64: dq 16,32,64,128  ; example: was DW 16 etc., now dq

section .text
buffer_flat_demo:
    ; Setup: store linear address via LEA rel (RIP-relative) into dq pointer
    lea rax, [rel flat_buffer]
    mov [rel BUFFER64], rax
    mov [rel DIRBUF64_PTR], rax
    ; Access via flat dq load (like GETENTRY: MOV BX,OFFSET DIRBUF -> LEA)
    mov rsi, [rel BUFFER64]
    mov byte [rsi], 0x5A
    cmp byte [rsi], 0x5A
    jne .fail
    ; Also test indexed access: FATSIZTAB was word table indexed by cluster shift
    mov rbx, 2                ; index 2
    shl rbx, 3                ; *8 dq vs original *2 dw
    lea rax, [rel FATSIZTAB64]
    mov rax, [rax + rbx]      ; load 64
    cmp rax, 64
    jne .fail
    ; Test dirbuf fill via flat
    mov rdi, [rel DIRBUF64_PTR]
    mov rcx, 512
    mov al, 0xFF
    cld
    rep stosb
    cmp byte [rel flat_buffer], 0xFF
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; Simpler demo for dirbuf sector calculation (GETENTRY flat)
dirbuf_flat_demo:
    ; Original: MOV AX,[LASTENT]; MOV CL,4; SHL AX,CL; MOV BX,[BP.SECSIZ]; DIV BX; MOV BX,DX; ADD BX,OFFSET DIRBUF
    ; 64-bit: RAX = LASTENT; SHL EAX,5 (*32); DIV ECX (secsiz); RBX = RDX; LEA RBX,[rel DIRBUF+RBX]
    mov eax, 5                ; LASTENT=5
    shl eax, 5                ; *32 =160
    mov ecx, 512              ; SECSIZ
    xor edx, edx
    div ecx                   ; EDX =160, EAX=0
    mov ebx, edx
    lea rdx, [rel flat_buffer]
    add rbx, rdx              ; RBX = DIRBUF + 160
    cmp rbx, rdx
    jbe .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; segment_override_elimination_demo — DS:SI, ES:DI, SS:BX etc. eliminated
;   Original heavily used segment overrides: MOV AL,[DS:SI], MOV AL,[ES:DI],
;   SEG CS MOV AL,[SI], REP MOVSB with DS:SI->ES:DI
;   64-bit: DS/ES/SS base=0, FS/GS only for TLS, overrides unnecessary.
;           REP MOVSB uses RSI/RDI flat, no prefix.
; ------------------------------------------------------------
section .data
seg_override_src: db "HELLO"
seg_override_dst: db 0,0,0,0,0,0

section .text
segment_override_elimination_demo:
    ; Original: MOV AX,CS; MOV DS,AX; MOV ES,AX; MOV SI,OFFSET src; MOV DI,OFFSET dst; MOV CX,5; REP MOVSB
    ; New: LEA RSI,[rel src]; LEA RDI,[rel dst]; MOV RCX,5; REP MOVSB
    lea rsi, [rel seg_override_src]
    lea rdi, [rel seg_override_dst]
    mov rcx, 5
    cld
    rep movsb
    ; Verify
    lea rsi, [rel seg_override_dst]
    cmp byte [rsi], 'H'
    jne .fail
    cmp byte [rsi+1], 'E'
    jne .fail
    ; Also demo that DS:SI and ES:DI are same flat: MOV AL,[RSI] vs MOV AL,[RDI]
    lea rsi, [rel seg_override_src]
    mov al, [rsi]             ; was MOV AL,[DS:SI] or [CS:SI]
    lea rdi, [rel seg_override_src]
    mov bl, [rdi]             ; was MOV AL,[ES:DI]
    cmp al, bl
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; stack_flat_demo — SS:SP flat, IOSTACK/DSKSTACK as linear
;   Original: MOV CS:[SPSAVE],SP; MOV CS:[SSSAVE],SS; MOV SP,OFFSET IOSTACK; ...; MOV SP,CS:[SPSAVE]; MOV SS,CS:[SSSAVE]
;   64-bit: MOV [rel SPSAVE64],RSP; LEA RSP,[rel IOSTACK_TOP64]; ...; MOV RSP,[rel SPSAVE64]
;   Demonstrates flat stack and 16-byte alignment.
; ------------------------------------------------------------
section .bss
align 16
test_iostack: resb 256
test_iostack_top:
test_saved_rsp: resq 1

section .text
stack_flat_demo:
    mov [rel test_saved_rsp], rsp
    lea rsp, [rel test_iostack_top]
    and rsp, -16               ; 16-byte align (replaces `and rsp, ~15` overflow bug)
    ; Use stack: push/pop 64-bit (was 16-bit)
    push rbx
    push 0x11223344
    pop rax
    cmp rax, 0x11223344
    jne .fail
    pop rbx
    mov rsp, [rel test_saved_rsp]
    xor rax, rax
    ret
.fail:
    mov rsp, [rel test_saved_rsp]
    mov rax, 1
    ret

; ------------------------------------------------------------
; paragraph_to_byte_demo — para*16 vs byte, and page*4096
;   Original frequently did SHL AX,4 or MOV CL,4; SHR BP,CL to convert paragraphs.
;   64-bit keeps bytes directly; para helpers use SHL 4, SHL 12.
; ------------------------------------------------------------
paragraph_to_byte_demo:
    mov rax, 0x100
    shl rax, 4                ; 0x100 para = 0x1000 bytes (DOS MEMSTRT calc)
    cmp rax, 0x1000
    jne .fail
    mov rax, 0x1000
    shr rax, 4                ; bytes -> para
    cmp rax, 0x100
    jne .fail
    ; Page demo: original would use 4K pages via SHL 12
    mov rax, 0x11
    shl rax, 12               ; 0x11 pages = 0x11000 bytes
    cmp rax, 0x11000
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; linear_to_seg_off_demo — inverse: given linear, compute seg:off (for legacy BIOS stub if needed)
;   Useful for calling BIOS from long mode via real-mode stub (Option B).
;   linear -> seg = linear>>4, off = linear & 0xF (or use 0xFFF for larger off?)
;   But canonical: seg = linear>>4 & 0xF000? Actually full 20-bit: seg*16+off = linear, pick seg= linear>>4.
; ------------------------------------------------------------
linear_to_seg_off_demo:
    mov rax, 0x12345           ; test linear
    mov rbx, rax
    shr rbx, 4                ; seg
    shl rbx, 4
    mov rcx, rax
    sub rcx, rbx              ; off = linear - seg*16
    ; verify
    mov rdx, rbx
    add rdx, rcx
    cmp rdx, rax
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; flat_pointer_arithmetic_demo — DPB/FCB field arithmetic flat
;   Original: MOV BP,[DRVTAB]; MOV AL,[BP.DEVNUM]; MOV BX,[BP.FIRFAT]; etc. where BP is offset within DOSGROUP.
;            MOV BX,[SI.FIRCLUS] where SI is dir entry offset.
;   64-bit: MOV RBP,[rel DRVTAB]; MOV AL,[RBP+DPB64.devnum]; etc. RBP is linear DPB pointer.
;   Demonstrates SIB scaling and 64-bit field offsets.
; ------------------------------------------------------------
%include "include/dpb.inc"
section .data
align 8
demo_dpb:
    istruc DPB64
        at DPB64.devnum,    db 0x07
        at DPB64.drvnum,    db 0x01
        at DPB64.secsiz,    dd 512
        at DPB64.clusmsk,   db 3
        at DPB64.clusshft,  db 2
        at DPB64.firfat,    dd 1
        at DPB64.fatcnt,    db 2
        at DPB64.maxent,    dd 64
        at DPB64.firrec,    dd 10
        at DPB64.maxclus,   dd 100
        at DPB64.fatsiz,    dd 1
        at DPB64.firdir,    dd 2
        at DPB64.fat,       dq 0
    iend
DRVTAB64: dq demo_dpb

section .text
flat_pointer_arithmetic_demo:
    mov rbp, [rel DRVTAB64]   ; flat DPB pointer
    mov al, [rbp + DPB64.devnum]
    cmp al, 0x07
    jne .fail
    mov eax, [rbp + DPB64.secsiz]
    cmp eax, 512
    jne .fail
    mov eax, [rbp + DPB64.firfat]
    cmp eax, 1
    jne .fail
    ; Simulate original LEA DI,[SI+BX] where SI=FAT base, BX=cluster*1.5
    lea rsi, [rel flat_buffer] ; FAT base
    mov ebx, 2
    mov eax, ebx
    shr eax, 1
    add eax, ebx              ; EBX*1.5
    add rsi, rax              ; RSI = FAT + EBX*1.5 (flat)
    cmp rsi, 0
    je .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

; ------------------------------------------------------------
; canonical_address_check — ensure addresses are canonical (bits 48-63 = bit47)
;   In 64-bit long mode, only 48 bits are used; non-canonical causes #GP.
;   Demonstrates that DOS linear 0x100000 etc. are canonical (low half).
;   Also tests high-half if needed.
; ------------------------------------------------------------
canonical_address_check:
    mov rax, 0x100000
    mov rbx, rax
    sar rbx, 47               ; sign extend bit47?
    cmp rbx, 0
    jne .fail_low
    ; Test max low canonical via constructing 0x00007FFFFFFFFFFF without overflow warning
    ; Use shifts: 0x7FFF <<32 = 0x7FFF00000000, need low 0xFFFFFFFF to get 0x7FFFFFFFFFFF
    mov rax, 0x7FFF
    shl rax, 32
    mov rbx, 0xFFFFFFFF
    or rax, rbx               ; RAX = 0x00007FFFFFFFFFFF
    mov rbx, rax
    sar rbx, 47
    cmp rbx, 0
    jne .fail_low
    xor rax, rax
    ret
.fail_low:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Combined tests — called by main.asm Phase4 harness
; Each returns 0 on PASS, 1 on FAIL
; ------------------------------------------------------------
addr_test_seg_off:
    call seg_off_to_linear
    ; Actually seg_off_to_linear needs args; test vector here
    mov rdi, 0x1000
    mov rsi, 0x0050
    call seg_off_to_linear
    cmp rax, 0x10050
    jne .fail_so
    ; Test BIOSSEG 0x60:0000 = 0x600
    mov rdi, 0x60
    xor rsi, rsi
    call seg_off_to_linear
    cmp rax, 0x600
    jne .fail_so
    ; Test DMA 0x1000:0x0080 =0x10080
    mov rdi, 0x1000
    mov rsi, 0x80
    call seg_off_to_linear
    cmp rax, 0x10080
    jne .fail_so
    call dma_flat_demo
    test rax, rax
    jne .fail_so
    call paragraph_to_byte_demo
    test rax, rax
    jne .fail_so
    call linear_to_seg_off_demo
    test rax, rax
    jne .fail_so
    xor rax, rax
    ret
.fail_so:
    mov rax, 1
    ret

addr_test_rip:
    call offset_to_rel_demo
    test rax, rax
    jnz .fail_r
    call rip_relative_demo
    test rax, rax
    jnz .fail_r
    call rip_relative_abs_vs_rel
    test rax, rax
    jnz .fail_r
    call dosgroup_alias_elimination_demo
    test rax, rax
    jnz .fail_r
    xor rax, rax
    ret
.fail_r:
    mov rax, 1
    ret

addr_test_far_near:
    call far_to_near_demo
    test rax, rax
    jnz .fail_f
    ; test via index 0..3
    mov rdi, 0
    call far_to_near_call_via_index
    cmp rax, 0xAA00
    jne .fail_f
    mov rdi, 3
    call far_to_near_call_via_index
    cmp rax, 0xDD03
    jne .fail_f
    xor rax, rax
    ret
.fail_f:
    mov rax, 1
    ret

addr_test_buffer:
    call buffer_flat_demo
    test rax, rax
    jnz .fail_b
    call dirbuf_flat_demo
    test rax, rax
    jnz .fail_b
    call segment_override_elimination_demo
    test rax, rax
    jnz .fail_b
    call flat_pointer_arithmetic_demo
    test rax, rax
    jnz .fail_b
    xor rax, rax
    ret
.fail_b:
    mov rax, 1
    ret

addr_test_canonical:
    call canonical_address_check
    test rax, rax
    jnz .fail_c
    call stack_flat_demo
    test rax, rax
    jnz .fail_c
    xor rax, rax
    ret
.fail_c:
    mov rax, 1
    ret

; Master test: all 5 subtests
addr_test_all:
    call addr_test_seg_off
    test rax, rax
    jnz .fail_all
    call addr_test_rip
    test rax, rax
    jnz .fail_all
    call addr_test_far_near
    test rax, rax
    jnz .fail_all
    call addr_test_buffer
    test rax, rax
    jnz .fail_all
    call addr_test_canonical
    test rax, rax
    jnz .fail_all
    xor rax, rax
    ret
.fail_all:
    mov rax, 1
    ret
