bits 64
default rel
%include "include/regs.inc"
%include "include/fcb.inc"
%include "include/dpb.inc"
extern vga_putc
extern vga_print
section .text
global syscall_init
global syscall_dispatch64
global savregs64
global leave64
global cmd_entry64
global dos_entry64
global iretq64
global get_dma64
global set_dma64
global handler_conout
global handler_prtbuf
global handler_in
global handler_abort

%define MAXCOM 46
%define MAXCALL 36
%define IOSTACK_SIZE 1024
%define DSKSTACK_SIZE 1024

section .bss
align 16
SPSAVE64:  resq 1
SSSAVE64:  resq 1
CONTSTK64: resq 1
IOSTACK64: resb IOSTACK_SIZE
IOSTACK_TOP64:
DSKSTACK64: resb DSKSTACK_SIZE
DSKSTACK_TOP64:
SAV_EXIT64: resq 1
EXITHOLD64: resq 2
DMAADD64_SC: resq 1
THISDRV64: resb 1
CURDRV64: resb 1

section .text
syscall_init:
    push rax
    xor rax, rax
    mov [rel SPSAVE64], rax
    mov [rel SSSAVE64], rax
    mov byte [rel THISDRV64], 0
    mov byte [rel CURDRV64], 0
    pop rax
    ret

; savregs64
savregs64:
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax
    mov [rel SPSAVE64], rsp
    mov rax, ss
    mov [rel SSSAVE64], rax
    mov rax, [rsp]
    shr rax, 8
    and eax, 0xFF
    cmp eax, 12
    jle .sav_use_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .sav_done
.sav_use_io:
    lea rsp, [rel IOSTACK_TOP64]
.sav_done:
    and rsp, ~15
    sti
    movzx ebx, byte [rel SPSAVE64]
    ret

syscall_dispatch64:
    cmp eax, MAXCOM
    ja .dispatch_bad
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov [rel SPSAVE64], rsp
    mov rax, ss
    mov [rel SSSAVE64], rax
    mov r8, rax
    cmp r8d, 12
    jle .dispatch_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .dispatch_after
.dispatch_io:
    lea rsp, [rel IOSTACK_TOP64]
.dispatch_after:
    and rsp, ~15
    mov rbx, r8
    shl rbx, 3
    lea rax, [rel DISPATCH64]
    add rax, rbx
    mov rax, [rax]
    call rax
    jmp leave64
.dispatch_bad:
    mov al, 0
    ret

leave64:
    cli
    mov rsp, [rel SPSAVE64]
    mov rax, [rel SSSAVE64]
    mov ss, ax
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

iretq64:
    iretq

get_dma64:
    mov rax, [rel DMAADD64_SC]
    ret

set_dma64:
    mov [rel DMAADD64_SC], rdi
    ret

set_dma_from_legacy:
    jmp set_dma64

cmd_entry64:
    cmp ah, MAXCOM
    jbe savregs64
    mov al, 0
    iretq

dos_entry64:
    mov ah, cl
    cmp cl, MAXCALL
    ja .dos_bad
    jmp savregs64
.dos_bad:
    mov al, 0
    iretq

section .data
align 8
DISPATCH64:
    dq handler_abort
    dq handler_conin
    dq handler_conout
    dq handler_reader
    dq handler_punch
    dq handler_list
    dq handler_rawio
    dq handler_rawinp
    dq handler_in
    dq handler_prtbuf
    dq handler_bufin
    dq handler_constat
    dq handler_flushkb
    dq handler_dskreset
    dq handler_seldsk
    dq handler_open
    dq handler_close
    dq handler_srchfrst
    dq handler_srchnxt
    dq handler_delete
    dq handler_seqrd
    dq handler_seqwrt
    dq handler_create
    dq handler_rename
    dq handler_inuse
    dq handler_getdrv
    dq handler_setdma
    dq handler_getfatpt
    dq handler_getfatptdl
    dq handler_getrdonly
    dq handler_setattrib
    dq handler_getdskpt
    dq handler_usercode
    dq handler_rndrd
    dq handler_rndwrt
    dq handler_filesize
    dq handler_setrndrec
    dq handler_setvect
    dq handler_newbase
    dq handler_blkrd
    dq handler_blkwrt
    dq handler_makefcb
    dq handler_getdate
    dq handler_setdate
    dq handler_gettime
    dq handler_settime
    dq handler_verify

section .text
handler_abort:
    mov rsi, [rel SPSAVE64]
    jmp qword [rel EXITHOLD64]

handler_conin:
    call handler_in
    mov dl, al
    call handler_conout
    ret

handler_conout:
    movzx rdi, dl
    call vga_putc
    ret

%macro STUB_HANDLER 1
%1:
    mov al, 0
    ret
%endmacro

STUB_HANDLER handler_reader
STUB_HANDLER handler_punch
STUB_HANDLER handler_list
STUB_HANDLER handler_rawio
STUB_HANDLER handler_rawinp
STUB_HANDLER handler_in
STUB_HANDLER handler_constat
STUB_HANDLER handler_flushkb
STUB_HANDLER handler_dskreset
STUB_HANDLER handler_seldsk
STUB_HANDLER handler_open
STUB_HANDLER handler_close
STUB_HANDLER handler_srchfrst
STUB_HANDLER handler_srchnxt
STUB_HANDLER handler_delete
STUB_HANDLER handler_seqrd
STUB_HANDLER handler_seqwrt
STUB_HANDLER handler_create
STUB_HANDLER handler_rename
STUB_HANDLER handler_inuse
STUB_HANDLER handler_getdrv
STUB_HANDLER handler_getfatpt
STUB_HANDLER handler_getfatptdl
STUB_HANDLER handler_getrdonly
STUB_HANDLER handler_setattrib
STUB_HANDLER handler_getdskpt
STUB_HANDLER handler_usercode
STUB_HANDLER handler_rndrd
STUB_HANDLER handler_rndwrt
STUB_HANDLER handler_filesize
STUB_HANDLER handler_setrndrec
STUB_HANDLER handler_setvect
STUB_HANDLER handler_newbase
STUB_HANDLER handler_blkrd
STUB_HANDLER handler_blkwrt
STUB_HANDLER handler_makefcb
STUB_HANDLER handler_getdate
STUB_HANDLER handler_setdate
STUB_HANDLER handler_gettime
STUB_HANDLER handler_settime
STUB_HANDLER handler_verify

handler_prtbuf:
    push rsi
    push rax
    mov rsi, rdx
.prt_next:
    lodsb
    cmp al, '$'
    je .prt_done
    mov dl, al
    call handler_conout
    jmp .prt_next
.prt_done:
    pop rax
    pop rsi
    ret

handler_bufin:
    mov al, 0
    ret

handler_setdma:
    mov [rel DMAADD64_SC], rdx
    ret

demo_les_lds:
    mov rdi, [rel DMAADD64_SC]
    mov rsi, [rel SPSAVE64]
    mov rax, [rsi + STKPTRS64.rax_save]
    ret
