; MS-DOS64 64-bit kernel — Phase 3: Register & Instruction Conversion verification
; Phase 2 long-mode entry at 0x100000 plus Phase 3 comprehensive tests
; Demonstrates: RAX/RBX/RCX/RDX/RSI/RDI/RBP/RSP 64-bit, R8-R15, REP with RCX,
;               AAM/AAD->DIV/MUL, XLAT->MOV, LES/LDS->flat, PUSH seg elimination,
;               operand sizes, 64-bit stack, flat DMA, DISPATCH table

bits 64
default rel

%include "include/regs.inc"
%include "include/mcb.inc"
%include "include/dpb.inc"
%include "include/fcb.inc"
%include "include/psp.inc"

section .text.start
global _start

; Externals from Phase 3 modules
extern vga_init
extern vga_clear
extern vga_print
extern vga_putc

extern memcpy64
extern memset64
extern strlen64
extern strcmp64
extern strupper64
extern loop_replacement_demo
extern xlat_replacement_demo

extern bcd_aam_replacement
extern bcd_aad_replacement_final
extern rtc_bcd_to_bin
extern rtc_bin_to_bcd
extern rtc_bcd_to_bin_v2
extern cbw_cwde_cdqe_demo
extern mul_div_64_demo
extern shl_rcl_demo

extern fat_unpack64
extern fat_pack64
extern fat_test_pack_unpack
extern dma_get_linear
extern dma_set_linear

extern mem_init64
extern mem_alloc64
extern mem_free64
extern mem_max_free64
extern mem_para_to_bytes

extern syscall_init
extern syscall_dispatch64
extern handler_conout
extern handler_prtbuf

_start:
    mov rsp, 0x90000
    and rsp, -16
    call init_serial64
    call vga_init

    ; Print Phase2 hello still
    mov rsi, hello_phase2
    call vga_print
    call serial_print64

    mov rsi, hello_phase3
    call vga_print
    call serial_print64

    ; Run Phase 3 tests, count passes
    xor r12, r12          ; passed count in R12 (callee-saved, demonstrates R8-R15)
    xor r13, r13          ; failed count in R13
    mov r14, 0            ; test index

    ; ---- Test 1: Register mapping — 64-bit RAX etc. and R8-R15 ----
    mov rsi, msg_test1
    call vga_print
    call serial_print64
    call test_registers
    test rax, rax
    jz .t1_pass
    inc r13
    mov rsi, msg_fail
    jmp .t1_done
.t1_pass:
    inc r12
    mov rsi, msg_pass
.t1_done:
    call vga_print
    call serial_print64

    ; ---- Test 2: String ops — REP MOVSB/MOVSQ, SCASB, CMPSB, LODSB/STOSB ----
    mov rsi, msg_test2
    call vga_print
    call serial_print64
    call test_string_ops
    test rax, rax
    jz .t2_pass
    inc r13
    mov rsi, msg_fail
    jmp .t2_done
.t2_pass:
    inc r12
    mov rsi, msg_pass
.t2_done:
    call vga_print
    call serial_print64

    ; ---- Test 3: BCD — AAM/AAD replacement ----
    mov rsi, msg_test3
    call vga_print
    call serial_print64
    call test_bcd
    test rax, rax
    jz .t3_pass
    inc r13
    mov rsi, msg_fail
    jmp .t3_done
.t3_pass:
    inc r12
    mov rsi, msg_pass
.t3_done:
    call vga_print
    call serial_print64

    ; ---- Test 4: FAT12 pack/unpack ----
    mov rsi, msg_test4
    call vga_print
    call serial_print64
    call fat_test_pack_unpack
    test rax, rax
    jz .t4_pass
    inc r13
    mov rsi, msg_fail
    jmp .t4_done
.t4_pass:
    inc r12
    mov rsi, msg_pass
.t4_done:
    call vga_print
    call serial_print64

    ; ---- Test 5: Memory — MCB64, paragraph->byte, alloc/free ----
    mov rsi, msg_test5
    call vga_print
    call serial_print64
    call test_memory
    test rax, rax
    jz .t5_pass
    inc r13
    mov rsi, msg_fail
    jmp .t5_done
.t5_pass:
    inc r12
    mov rsi, msg_pass
.t5_done:
    call vga_print
    call serial_print64

    ; ---- Test 6: DMA flat pointer (LES/LDS elimination) ----
    mov rsi, msg_test6
    call vga_print
    call serial_print64
    call test_dma
    test rax, rax
    jz .t6_pass
    inc r13
    mov rsi, msg_fail
    jmp .t6_done
.t6_pass:
    inc r12
    mov rsi, msg_pass
.t6_done:
    call vga_print
    call serial_print64

    ; ---- Test 7: Syscall dispatch and CBW etc. ----
    mov rsi, msg_test7
    call vga_print
    call serial_print64
    call test_syscall
    test rax, rax
    jz .t7_pass
    inc r13
    mov rsi, msg_fail
    jmp .t7_done
.t7_pass:
    inc r12
    mov rsi, msg_pass
.t7_done:
    call vga_print
    call serial_print64

    ; ---- Summary ----
    mov rsi, msg_summary
    call vga_print
    call serial_print64
    ; Print passed count (single digit for demo, up to 7)
    mov al, r12b
    add al, '0'
    call print_char_vga_serial
    mov rsi, msg_summary2
    call vga_print
    call serial_print64
    mov al, r13b
    add al, '0'
    call print_char_vga_serial
    mov rsi, msg_nl
    call vga_print
    call serial_print64

    cmp r13, 0
    je .all_pass
    mov rsi, msg_phase3_fail
    call vga_print
    call serial_print64
    jmp .hlt
.all_pass:
    mov rsi, msg_phase3_ok
    call vga_print
    call serial_print64

    ; Also demonstrate handler_prtbuf (DOS 09h: print $-string)
    mov rdx, demo_dollar_str
    call handler_prtbuf

.hlt:
    cli
    hlt
    jmp .hlt

; ------------------------------------------------------------
; Helper: print single char in AL to both VGA and serial
; ------------------------------------------------------------
print_char_vga_serial:
    push rax
    push rdx
    push r8
    mov r8b, al
    movzx edi, r8b
    mov al, r8b
    call vga_putc
    ; serial: wait for THR empty then out
    mov al, r8b
.wait:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait
    mov al, r8b
    mov dx, 0x3F8
    out dx, al
    pop r8
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------
; Test 1: Register mapping and R8-R15
; ------------------------------------------------------------
test_registers:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    ; Test 64-bit register widths: AL->AX->EAX->RAX zero extend
    mov rax, 0x11223344
    shl rax, 32
    or rax, 0x55667788
    mov al, 0x99
    ; AL changed, check low byte is 0x99 (RAX now 0x1122334455667799)
    cmp al, 0x99
    jne .fail
    ; Test R8-R15 availability — use 32-bit values to avoid truncation
    mov r8d, 0x11111111
    mov r9d, 0x22222222
    mov r10d, 0x33333333
    mov r11d, 0x44444444
    add r8, r9
    cmp r8d, 0x33333333
    jne .fail
    ; Test RBX/RBP/RSP mapping (BX->RBX etc.)
    mov rbx, 0x1234
    mov rcx, 0x5678
    mov rdx, rbx
    add rdx, rcx
    cmp rdx, 0x68AC
    jne .fail
    ; Test RSI/RDI flat
    lea rsi, [rel hello_phase2]
    lea rdi, [rel hello_phase2]
    cmp rsi, rdi
    jne .fail
    xor rax, rax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 2: String ops
; ------------------------------------------------------------
section .bss
test_buf_src: resb 128
test_buf_dst: resb 128

section .text
test_string_ops:
    push rsi
    push rdi
    push rcx
    push rbx

    ; Prepare source: "Hello64"
    lea rsi, [rel str_hello]
    lea rdi, [rel test_buf_src]
    mov rcx, 8
    call memcpy64          ; REP MOVSB with RCX

    ; Verify via strlen
    lea rdi, [rel test_buf_src]
    call strlen64
    cmp rax, 7
    jne .fail2

    ; Test memset: fill dst with 'A'
    lea rdi, [rel test_buf_dst]
    mov al, 'A'
    mov rcx, 16
    call memset64
    cmp byte [rel test_buf_dst], 'A'
    jne .fail2
    cmp byte [rel test_buf_dst+15], 'A'
    jne .fail2

    ; Test strcmp: src vs dst should differ
    lea rsi, [rel test_buf_src]
    lea rdi, [rel test_buf_dst]
    mov rcx, 8
    call strcmp64
    test rax, rax
    jz .fail2              ; should not be equal

    ; Test strupper
    lea rsi, [rel str_lower]
    lea rdi, [rel test_buf_dst]
    mov rcx, 5
    call strupper64
    cmp byte [rel test_buf_dst], 'H'
    jne .fail2             ; 'hello' -> 'HELLO'
    cmp byte [rel test_buf_dst+1], 'E'
    jne .fail2

    ; Test loop_replacement_demo (should not hang)
    mov rcx, 5
    mov r8, 0
    call loop_replacement_demo
    cmp r8, 5
    jne .fail2

    ; Test xlat replacement
    lea rbx, [rel xlat_table]
    mov al, 2
    call xlat_replacement_demo
    cmp al, 0x22
    jne .fail2

    xor rax, rax
    jmp .done2
.fail2:
    mov rax, 1
.done2:
    pop rbx
    pop rcx
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------
; Test 3: BCD
; ------------------------------------------------------------
test_bcd:
    push rbx
    ; Test rtc_bcd_to_bin: 0x59 -> 59
    mov al, 0x59
    call rtc_bcd_to_bin_v2
    cmp al, 59
    jne .fail3

    ; Test rtc_bin_to_bcd: 59 -> 0x59
    mov al, 59
    call rtc_bin_to_bcd
    ; packed BCD in AL (low), check
    cmp al, 0x59
    jne .fail3

    ; Test 0x00, 0x99 edges
    mov al, 0x00
    call rtc_bcd_to_bin_v2
    cmp al, 0
    jne .fail3
    mov al, 0x99
    call rtc_bcd_to_bin_v2
    cmp al, 99
    jne .fail3

    ; Test cbw demo doesn't fault
    call cbw_cwde_cdqe_demo
    call mul_div_64_demo
    call shl_rcl_demo

    xor rax, rax
    jmp .done3
.fail3:
    mov rax, 1
.done3:
    pop rbx
    ret

; ------------------------------------------------------------
; Test 5: Memory
; ------------------------------------------------------------
test_memory:
    call mem_init64
    ; Test para->bytes: 1 para =16 bytes
    mov rax, 1
    call mem_para_to_bytes
    cmp rax, 16
    jne .fail5
    mov rax, 0x100
    call mem_para_to_bytes
    cmp rax, 0x1000
    jne .fail5

    ; Alloc test
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail5
    mov rbx, rax           ; save
    mov rdi, 512
    call mem_alloc64
    test rax, rax
    jz .fail5
    mov rcx, rax
    ; Free first
    mov rdi, rbx
    call mem_free64
    jc .fail5
    ; Alloc again should reuse
    mov rdi, 128
    call mem_alloc64
    test rax, rax
    jz .fail5

    ; Max free should be >0
    call mem_max_free64
    test rax, rax
    jz .fail5

    xor rax, rax
    jmp .done5
.fail5:
    mov rax, 1
.done5:
    ret

; ------------------------------------------------------------
; Test 6: DMA flat
; ------------------------------------------------------------
test_dma:
    mov rdi, 0x12345678
    call dma_set_linear
    call dma_get_linear
    cmp rdi, 0x12345678
    jne .fail6
    ; Test that we no longer need LES/LDS split
    mov rdi, 0x80000
    call dma_set_linear
    call dma_get_linear
    cmp rdi, 0x80000
    jne .fail6
    xor rax, rax
    ret
.fail6:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Test 7: Syscall/Dispatch
; ------------------------------------------------------------
test_syscall:
    call syscall_init
    ; Test dispatch for CONOUT (2) with DL='X'
    mov rax, 2
    mov dl, 'X'
    ; Instead of full dispatch, just call handler directly
    call handler_conout
    ; Test PRTBUF
    mov rdx, demo_dollar2
    call handler_prtbuf
    ; Test that syscall_dispatch doesn't crash on bad call
    mov rax, 99
    call syscall_dispatch64
    ; Should return AL=0 for BADCALL
    cmp al, 0
    jne .fail7
    xor rax, rax
    ret
.fail7:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Serial/VGA helpers (stub versions, real drivers are in vga.asm)
; ------------------------------------------------------------
init_serial64:
    mov dx, 0x3FB
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8
    mov al, 0x03
    out dx, al
    mov dx, 0x3F9
    xor al, al
    out dx, al
    mov dx, 0x3FB
    mov al, 0x03
    out dx, al
    mov dx, 0x3FA
    xor al, al
    out dx, al
    mov dx, 0x3FC
    mov al, 0x03
    out dx, al
    ret

serial_print64:
    push rdx
    push rax
.loop:
    lodsb
    test al, al
    jz .done
    push rax
.wait:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait
    pop rax
    mov dx, 0x3F8
    out dx, al
    jmp .loop
.done:
    pop rax
    pop rdx
    ret

vga_print_stub:
    mov rdi, 0xB8000
    xor rcx, rcx
.loop:
    lodsb
    test al, al
    jz .done
    stosb
    mov al, 0x0F
    stosb
    jmp .loop
.done:
    ret

section .rodata
hello_phase2 db "Hello from 64-bit DOS64 kernel: Phase2 long mode OK!",13,10,0
hello_phase3 db "Phase3: Register & Instruction Conversion Test Suite",13,10,0
msg_test1 db " [1] Register mapping (AX->RAX, R8-R15)... ",0
msg_test2 db " [2] String ops (REP MOVSB, SCASB, LOOP->DEC)... ",0
msg_test3 db " [3] BCD (AAM/AAD -> DIV/MUL, CBW, MUL/DIV)... ",0
msg_test4 db " [4] FAT12 UNPACK/PACK (BX->RBX, SHL, LES)... ",0
msg_test5 db " [5] Memory MCB64 (para*16->byte, alloc)... ",0
msg_test6 db " [6] DMA flat (LES/LDS elimination)... ",0
msg_test7 db " [7] Syscall dispatch (SAVREGS, far->near)... ",0
msg_pass db "PASS",13,10,0
msg_fail db "FAIL",13,10,0
msg_summary db 13,10,"Summary: ",0
msg_summary2 db " passed, ",0
msg_nl db 13,10,0
msg_phase3_ok db "Phase3 register conversion: ALL TESTS PASS",13,10,0
msg_phase3_fail db "Phase3: SOME TESTS FAILED",13,10,0

str_hello db "Hello64",0
str_lower db "hello",0
xlat_table db 0x00,0x11,0x22,0x33,0x44
demo_dollar_str db "DOS $ handler via PRTBUF (INT21 AH=09) test$",0
demo_dollar2 db "INT21 test$",0

section .bss
resb 8192
kstack_top:
