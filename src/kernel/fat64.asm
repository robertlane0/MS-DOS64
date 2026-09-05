bits 64
default rel
%include "include/dpb.inc"
%include "include/fcb.inc"
section .text
global fat_unpack64
global fat_pack64
global fat_get_entry64
global fat_next_entry64
global fat_dir_read64
global fat_test_pack_unpack
global dma_get_linear
global dma_set_linear
extern fs_dir_read64

; fat_unpack64 — 64-bit UNPACK
fat_unpack64:
    mov r9, rbx
    mov r8d, dword [rbp + DPB64.maxclus]
    cmp ebx, r8d
    ja near .hurt
    mov eax, ebx
    shr eax, 1
    add eax, ebx
    movzx edi, word [rsi + rax]
    test bl, 1
    jz .even
    shr edi, 4
    stc
    jmp .mask
.even:
    clc
.mask:
    and edi, 0x0FFF
    test edi, edi
    mov rbx, r9
    ret
.hurt:
    mov edi, 0x0FFF
    mov rbx, r9
    clc
    ret

; fat_pack64
fat_pack64:
    push rax
    push rbx
    push rdi
    push rsi
    mov r8, rbx
    mov r9, rdx
    mov r10, rsi
    mov eax, r8d
    shr eax, 1
    add eax, r8d
    lea rbx, [r10 + rax]
    movzx edi, word [rbx]
    test r8b, 1
    jz .aligned
    shl r9d, 4
    and edi, 0x000F
    jmp .packin
.aligned:
    and edi, 0xF000
.packin:
    or edi, r9d
    mov [rbx], di
    pop rsi
    pop rdi
    pop rbx
    pop rax
    ret

; fat_get_entry64
fat_get_entry64:
    push rdx
    push rcx
    push rsi
    mov eax, [rel LASTENT64]
    inc eax
    mov r8d, [rbp + DPB64.maxent]
    cmp eax, r8d
    jae .none
    mov [rel LASTENT64], eax
    shl eax, 5
    mov ecx, [rbp + DPB64.secsiz]
    and ecx, 0xFFFFFFE0
    xor edx, edx
    div ecx
    mov ebx, edx
    clc
    pop rsi
    pop rcx
    pop rdx
    ret
.none:
    stc
    pop rsi
    pop rcx
    pop rdx
    ret

; fat_next_entry64
fat_next_entry64:
    push rax
    push rdx
    mov edi, [rel LASTENT64]
    inc edi
    cmp edi, [rbp + DPB64.maxent]
    jae .none2
    mov [rel LASTENT64], edi
    add ebx, 32
    cmp ebx, edx
    jb .have
    lea rbx, [rel DIRBUF64]
.have:
    clc
    pop rdx
    pop rax
    ret
.none2:
    stc
    pop rdx
    pop rax
    ret

; fat_dir_read64 — real directory-block read (DIRREAD analog).
;   ABI is identical to fs_dir_read64: RBP = DPB64 ptr, AL = dir block #
;   (0..dirsec-1), RDI = 512B buffer. Out: RAX 0 ok, 1 fail (ATA error).
;   Implemented as a tail-call so the Phase-3 symbol stays wired to the
;   ATA-backed path instead of shipping as a no-op stub (see G5).
fat_dir_read64:
    jmp fs_dir_read64

dma_get_linear:
    mov rdi, [rel DMAADD64]
    ret
dma_set_linear:
    mov [rel DMAADD64], rdi
    ret

fat_test_pack_unpack:
    lea rsi, [rel test_fat_buf]
    mov dword [rsi], 0
    mov dword [rsi+4], 0
    lea rbp, [rel dummy_dpb]
    mov rbx, 2
    mov rdx, 0x123
    call fat_pack64
    mov rbx, 3
    mov rdx, 0xABC
    call fat_pack64
    mov rbx, 2
    call fat_unpack64
    cmp edi, 0x123
    jne .fail
    mov rbx, 3
    call fat_unpack64
    cmp edi, 0xABC
    jne .fail
    xor rax, rax
    ret
.fail:
    mov rax, 1
    ret

section .data
dummy_dpb:
    istruc DPB64
        at DPB64.devnum,    db 0
        at DPB64.drvnum,    db 0
        at DPB64.secsiz,    dd 512
        at DPB64.clusmsk,   db 1
        at DPB64.clusshft,  db 1
        at DPB64.firfat,    dd 1
        at DPB64.fatcnt,    db 2
        at DPB64.maxent,    dd 64
        at DPB64.firrec,    dd 10
        at DPB64.maxclus,   dd 100
        at DPB64.fatsiz,    dd 1
        at DPB64.firdir,    dd 2
        at DPB64.fat,       dq 0
    iend

DIRBUF64: times 512 db 0
LASTENT64: dd -1
DIRBUFID64: dd -1
DMAADD64: dq 0x80
test_fat_buf: times 32 db 0

section .bss
fat_buffer: resb 4096
