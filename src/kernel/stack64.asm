; MS-DOS64 src/kernel/stack64.asm — Phase 12: Stack & Calling Conventions
; Converts DOS 1.25 16-bit stack (SS:SP, near/far CALL, PUSH segment,
; params on stack or AX/BX/CX/DX/SI/DI) to flat 64-bit System V AMD64 ABI.
;
; Original: 16-bit SS:SP grows down, PUSH/POP 16-bit, near CALL in-segment,
;   far CALL/JMP cross-segment, LES/LDS far loads, no alignment rule.
; 64-bit: RSP flat (STACK_TOP 0x90000), PUSH/POP 64-bit, near CALL/RET only,
;   RDI,RSI,RDX,RCX,R8,R9 first 6 args, stack for 7th+ (16B-aligned),
;   RAX return, RBX/RBP/R12-R15 callee-saved, DF=0, RSP%16==0 before CALL.
;
; Stacks: boot RSP 0x90000 (stage2 STACK_PM, _start), syscall IOSTACK/DSKSTACK
;   4K each (syscall64.asm, and rsp,~15 on switch), IST1/IST2 4K reserved here
;   (future TSS; IDT IST stays 0, verified by test). Canary guards overflow.
;
; Exports: 15 ABI helpers + 8 stack_test_* (harness [59]-[66]).
; All globals preserve RBX/RBP/R12-R15 (callee-saved) and use only near CALL.

bits 64
default rel

%include "include/stack.inc"
%include "include/regs.inc"

section .text
global stack_init64
global stack_get_rsp64
global stack_align_offset64
global stack_caller_aligned64
global abi_sum6_64
global abi_sum8_64
global abi_callee_demo64
global abi_caller_clobber64
global stack_recurse64
global stack_canary_init64
global stack_canary_check64
global stack_irq_align64
global stack_push_balance64
global stack_df_check64
global stack_near_call_demo64
global stack_test_align
global stack_test_callee
global stack_test_args
global stack_test_depth
global stack_test_irq
global stack_test_push
global stack_test_canary
global stack_test_stress
global ist1_top
global ist2_top
global stack_canary

extern IOSTACK_TOP64
extern DSKSTACK_TOP64
extern idt_get_tick64
extern idt_get_fault_count64
extern idt_get_vector64
extern idt_get_base64
extern idt_reset_stats64
extern mem_validate64
extern int21_entry
extern irq0_timer_handler
extern irq14_disk_handler

section .bss
alignb 16
stack_canary: resq 1
alignb 16
ist1_stack: resb IST_STACK_SIZE64
ist1_top:
alignb 16
ist2_stack: resb IST_STACK_SIZE64
ist2_top:

section .rodata
align 8
stack_dollar: db "STK$",0

section .text

; ------------------------------------------------------------
; stack_init64 — verify boot stack + init canary + IST tops aligned.
;   Out: RAX 0 ok, 1 fail (RSP top, I/O stacks, IST tops, canary).
; ------------------------------------------------------------
stack_init64:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10                ; 7 pushes -> aligned for calls
    ; canary init
    call stack_canary_init64
    test rax, rax
    jnz .fail_si
    ; I/O + IST stacks aligned?
    call stack_irq_align64
    test rax, rax
    jnz .fail_si
    ; boot stack top 0x90000 is 16-aligned (constant check)
    mov eax, STACK_TOP64
    test al, 15
    jnz .fail_si
    ; caller (harness) was aligned before CALL?
    call stack_caller_aligned64
    test rax, rax
    jnz .fail_si
    xor eax, eax
    jmp .done_si
.fail_si:
    mov eax, 1
.done_si:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ------------------------------------------------------------
; stack_get_rsp64 — Out: RAX=RSP (leaf, no pushes).
; ------------------------------------------------------------
stack_get_rsp64:
    mov rax, rsp
    ret

; ------------------------------------------------------------
; stack_align_offset64 — Out: RAX=RSP&15 (8 inside func after CALL).
; ------------------------------------------------------------
stack_align_offset64:
    mov rax, rsp
    and rax, 15
    ret

; ------------------------------------------------------------
; stack_caller_aligned64 — Out: RAX 0 if caller was aligned before CALL.
;   Inside func RSP%16==8; caller RSP was RSP+8, so (RSP+8)%16==0 expected.
; ------------------------------------------------------------
stack_caller_aligned64:
    mov rax, rsp
    add rax, 8
    and rax, 15
    test rax, rax
    jz .ok_ca
    mov eax, 1
    ret
.ok_ca:
    xor eax, eax
    ret

; ------------------------------------------------------------
; abi_sum6_64 — System V 6-reg sum.
;   In: RDI,RSI,RDX,RCX,R8,R9. Out: RAX=sum. Leaf, RAX/R10 only.
; ------------------------------------------------------------
abi_sum6_64:
    mov rax, rdi
    add rax, rsi
    add rax, rdx
    add rax, rcx
    add rax, r8
    add rax, r9
    ret

; ------------------------------------------------------------
; abi_sum8_64 — System V 6-reg + 2 stack args (7th/8th).
;   In: RDI,RSI,RDX,RCX,R8,R9 + [RSP+8]=7th + [RSP+16]=8th.
;   Caller: sub rsp,16; mov [rsp],7th; mov [rsp+8],8th; call; add rsp,16.
;   Out: RAX=sum of 8. Leaf.
; ------------------------------------------------------------
abi_sum8_64:
    mov rax, rdi
    add rax, rsi
    add rax, rdx
    add rax, rcx
    add rax, r8
    add rax, r9
    mov r10, [rsp+8]
    add rax, r10
    mov r10, [rsp+16]
    add rax, r10
    ret

; ------------------------------------------------------------
; abi_callee_demo64 — preserves RBX/RBP/R12-R15, clobbers caller-saved.
;   Out: RAX=0x1122334455667788, RCX/RDX/RSI/RDI/R8-R11=patterns.
;   6 pushes (no nested calls, so alignment not needed inside).
; ------------------------------------------------------------
abi_callee_demo64:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    ; scribble callee-saved (discarded by pops -> proves save/restore)
    mov rbx, 0x0B0B0B0B0B0B0B0B
    mov rbp, 0x0C0C0C0C0C0C0C0C
    mov r12, 0x0E0E0E0E0E0E0E0E
    mov r13, 0x0F0F0F0F0F0F0F0F
    mov r14, 0x1414141414141414
    mov r15, 0x1515151515151515
    ; intentional caller-saved clobber (survives return by ABI design)
    mov rax, 0x1122334455667788
    mov rcx, 0x0C0C0C0C0C0C0C0C
    mov rdx, 0x0D0D0D0D0D0D0D0D
    mov rsi, 0x5151515151515151
    mov rdi, 0xD1D1D1D1D1D1D1D1
    mov r8, 0x0808080808080808
    mov r9, 0x0909090909090909
    mov r10, 0x1010101010101010
    mov r11, 0x1111111111111111
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ------------------------------------------------------------
; abi_caller_clobber64 — documents caller-saved set (same clobber, RAX=0).
; ------------------------------------------------------------
abi_caller_clobber64:
    mov rax, 0x0A0A0A0A0A0A0A0A
    mov rcx, 0x0C0C0C0C0C0C0C0C
    mov rdx, 0x0D0D0D0D0D0D0D0D
    mov rsi, 0x5151515151515151
    mov rdi, 0xD1D1D1D1D1D1D1D1
    mov r8, 0x0808080808080808
    mov r9, 0x0909090909090909
    mov r10, 0x1010101010101010
    mov r11, 0x1111111111111111
    xor eax, eax
    ret

; ------------------------------------------------------------
; stack_recurse64 — depth sum: sum(n)=n+sum(n-1), sum(0)=0.
;   In: RDI=depth. Out: RAX=sum. 1 push (entry 8->0, call aligned).
; ------------------------------------------------------------
stack_recurse64:
    push rbx
    mov rbx, rdi
    test rbx, rbx
    jz .base_sr
    mov rdi, rbx
    dec rdi
    call stack_recurse64
    add rax, rbx
    pop rbx
    ret
.base_sr:
    xor eax, eax
    pop rbx
    ret

; ------------------------------------------------------------
; stack_canary_init64 — write magic. Out: RAX 0.
; ------------------------------------------------------------
stack_canary_init64:
    mov rax, STACK_CANARY_MAGIC
    mov [rel stack_canary], rax
    xor eax, eax
    ret

; ------------------------------------------------------------
; stack_canary_check64 — Out: RAX 0 intact, 1 corrupted.
; ------------------------------------------------------------
stack_canary_check64:
    mov rax, [rel stack_canary]
    mov rcx, STACK_CANARY_MAGIC
    cmp rax, rcx
    je .ok_cc
    mov eax, 1
    ret
.ok_cc:
    xor eax, eax
    ret

; ------------------------------------------------------------
; stack_irq_align64 — I/O + IST tops 16-aligned and ISTs distinct.
;   Out: RAX 0 ok, 1 fail. Leaf (RAX/RCX caller-saved only).
; ------------------------------------------------------------
stack_irq_align64:
    lea rax, [rel IOSTACK_TOP64]
    test al, 15
    jnz .fail_ia
    lea rax, [rel DSKSTACK_TOP64]
    test al, 15
    jnz .fail_ia
    lea rax, [rel ist1_top]
    test al, 15
    jnz .fail_ia
    lea rax, [rel ist2_top]
    test al, 15
    jnz .fail_ia
    lea rax, [rel ist1_top]
    lea rcx, [rel ist2_top]
    cmp rax, rcx
    je .fail_ia
    xor eax, eax
    ret
.fail_ia:
    mov eax, 1
    ret

; ------------------------------------------------------------
; stack_push_balance64 — odd-push realign + near CALL balance check.
;   Entry 8, push->0, call->8/0, pop->8. Out: RAX 0 balanced.
; ------------------------------------------------------------
stack_push_balance64:
    mov rax, rsp
    push rbx
    call .dummy_pb
    pop rbx
    cmp rax, rsp
    je .ok_pb
    mov eax, 1
    ret
.ok_pb:
    xor eax, eax
    ret
.dummy_pb:
    ret

; ------------------------------------------------------------
; stack_df_check64 — CLD then verify DF==0 (RFLAGS bit 10).
;   Out: RAX 0 DF clear, 1 DF set.
; ------------------------------------------------------------
stack_df_check64:
    cld
    pushfq
    pop rax
    test rax, 0x400
    jz .ok_df
    mov eax, 1
    ret
.ok_df:
    xor eax, eax
    ret

; ------------------------------------------------------------
; stack_near_call_demo64 — near CALL/RET RIP capture.
;   Out: RAX 0 if captured RIP == .retpt (near, canonical).
; ------------------------------------------------------------
stack_near_call_demo64:
    call .inner_nc
.retpt_nc:
    jmp .check_nc
.inner_nc:
    mov rax, [rsp]
    ret
.check_nc:
    lea rcx, [rel .retpt_nc]
    cmp rax, rcx
    je .ok_nc
    mov eax, 1
    ret
.ok_nc:
    xor eax, eax
    ret

; ============================================================
; Phase 12 harness tests [59]-[66] — each preserves callee-saved,
; returns RAX 0 pass / 1 fail, uses only near CALL, aligned stacks.
; ============================================================

; Test 59: RSP alignment (caller aligned, inside offset 8, stacks aligned)
stack_test_align:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    call stack_caller_aligned64
    test rax, rax
    jnz .fail59
    call stack_align_offset64
    cmp rax, 8
    jne .fail59
    call stack_irq_align64
    test rax, rax
    jnz .fail59
    mov eax, STACK_TOP64
    test al, 15
    jnz .fail59
    call stack_init64
    test rax, rax
    jnz .fail59
    xor eax, eax
    jmp .done59
.fail59:
    mov eax, 1
.done59:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Test 60: callee-saved RBX/RBP/R12-R15 preserved, caller-saved clobbered
stack_test_callee:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    ; sentinels in callee-saved (originals already saved above)
    mov rbx, 0x1111111111111111
    mov rbp, 0x2222222222222222
    mov r12, 0x3333333333333333
    mov r13, 0x4444444444444444
    mov r14, 0x5555555555555555
    mov r15, 0x6666666666666666
    mov r10, 0
    mov r11, 0
    call abi_callee_demo64
    ; return magic?
    mov rcx, 0x1122334455667788
    cmp rax, rcx
    jne .fail60
    ; callee-saved intact?
    mov rax, 0x1111111111111111
    cmp rbx, rax
    jne .fail60
    mov rax, 0x2222222222222222
    cmp rbp, rax
    jne .fail60
    mov rax, 0x3333333333333333
    cmp r12, rax
    jne .fail60
    mov rax, 0x4444444444444444
    cmp r13, rax
    jne .fail60
    mov rax, 0x5555555555555555
    cmp r14, rax
    jne .fail60
    mov rax, 0x6666666666666666
    cmp r15, rax
    jne .fail60
    ; caller-saved were clobbered (R10/R11 == patterns, not 0)?
    mov rax, 0x1010101010101010
    cmp r10, rax
    jne .fail60
    mov rax, 0x1111111111111111
    cmp r11, rax
    jne .fail60
    xor eax, eax
    jmp .done60
.fail60:
    mov eax, 1
.done60:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Test 61: System V args (6-reg + 2 stack) + odd-push realign
stack_test_args:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    ; sum6: 1+2+3+4+5+6 = 21
    mov rdi, 1
    mov rsi, 2
    mov rdx, 3
    mov rcx, 4
    mov r8, 5
    mov r9, 6
    call abi_sum6_64
    cmp rax, 21
    jne .fail61
    ; sum8: 1..8 = 36 (7th/8th on stack, 16B-aligned)
    mov rdi, 1
    mov rsi, 2
    mov rdx, 3
    mov rcx, 4
    mov r8, 5
    mov r9, 6
    sub rsp, 16
    mov qword [rsp], 7
    mov qword [rsp+8], 8
    call abi_sum8_64
    mov rbx, rax
    add rsp, 16
    cmp rbx, 36
    jne .fail61
    ; zeros still work (all 0 -> 0)
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call abi_sum6_64
    test rax, rax
    jnz .fail61
    ; odd-push balance helper
    call stack_push_balance64
    test rax, rax
    jnz .fail61
    xor eax, eax
    jmp .done61
.fail61:
    mov eax, 1
.done61:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Test 62: nested-call depth (recurse 32 -> 528, RSP restored)
stack_test_depth:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    mov rbx, rsp             ; save RSP
    xor edi, edi
    call stack_recurse64
    test rax, rax
    jnz .fail62
    mov rdi, 1
    call stack_recurse64
    cmp rax, 1
    jne .fail62
    mov rdi, 32
    call stack_recurse64
    cmp rax, 528             ; 32*33/2
    jne .fail62
    cmp rbx, rsp
    jne .fail62
    xor eax, eax
    jmp .done62
.fail62:
    mov eax, 1
.done62:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; stack_dbg_char — emit AL to COM1 (debug markers). Preserves all but RAX/RDX.
stack_dbg_char:
    push rbx
    push rcx
    push rdx
    mov bl, al
.wait_dbg:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait_dbg
    mov al, bl
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 63: IRQ/exc stacks — IST==0 reserved, tops aligned, timer preserves
stack_test_irq:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    call idt_reset_stats64
    call stack_irq_align64
    test rax, rax
    jnz .fail63
    ; IDT IST bytes must be 0 (no TSS wired yet; stacks reserved for Phase 13)
    call idt_get_base64
    mov rbx, rax
    cmp byte [rbx+0*16+4], 0
    jne .fail63
    cmp byte [rbx+0x20*16+4], 0
    jne .fail63
    cmp byte [rbx+0x21*16+4], 0
    jne .fail63
    cmp byte [rbx+0x2E*16+4], 0
    jne .fail63
    ; gate types: DOS 0x21 must stay 0xEE (DPL3); IRQ 0x20/0x2E accept 0x8E
    ; or 0xEE — Phase11 [57] restores 0x20 via SETVECT (USER gate), so a
    ; strict 0x8E check would fail after [57] although the handler works.
    cmp byte [rbx+0x21*16+5], 0xEE
    jne .fail63
    mov al, [rbx+0x20*16+5]
    cmp al, 0x8E
    je .ok63_t20
    cmp al, 0xEE
    jne .fail63
.ok63_t20:
    mov al, [rbx+0x2E*16+5]
    cmp al, 0x8E
    je .ok63_t2e
    cmp al, 0xEE
    jne .fail63
.ok63_t2e:
    ; vectors still point at handlers (no stack switch corruption)
    mov rdi, 0x20
    call idt_get_vector64
    lea rcx, [rel irq0_timer_handler]
    cmp rax, rcx
    jne .fail63
    mov rdi, 0x21
    call idt_get_vector64
    lea rcx, [rel int21_entry]
    cmp rax, rcx
    jne .fail63
    mov rdi, 0x2E
    call idt_get_vector64
    lea rcx, [rel irq14_disk_handler]
    cmp rax, rcx
    jne .fail63
    ; timer IRQ preserves regs + RSP, tick 0->1, no fault
    mov rbx, rsp
    mov rcx, 0x1357
    int 0x20
    cmp rcx, 0x1357
    jne .fail63
    cmp rbx, rsp
    jne .fail63
    call idt_get_tick64
    cmp rax, 1
    jne .fail63
    call idt_get_fault_count64
    test rax, rax
    jnz .fail63
    xor eax, eax
    jmp .done63
.fail63:
    mov eax, 1
.done63:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Test 64: 64-bit PUSH/POP + near CALL/RET + DF=0 (no far/segment ops)
stack_test_push:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    call stack_push_balance64
    test rax, rax
    jnz .fail64
    call stack_df_check64
    test rax, rax
    jnz .fail64
    call stack_near_call_demo64
    test rax, rax
    jnz .fail64
    ; 15-push/15-pop balance like syscall dispatch (order r15..rax)
    mov rbx, rsp
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
    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
    cmp rbx, rsp
    jne .fail64
    xor eax, eax
    jmp .done64
.fail64:
    mov eax, 1
.done64:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Test 65: canary init/intact/detect + survives depth stress
stack_test_canary:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    call stack_canary_init64
    test rax, rax
    jnz .fail65
    call stack_canary_check64
    test rax, rax
    jnz .fail65
    ; depth stress must not corrupt canary
    mov rdi, 16
    call stack_recurse64
    cmp rax, 136              ; 16*17/2
    jne .fail65
    call stack_canary_check64
    test rax, rax
    jnz .fail65
    ; detection: corrupt -> check==1, restore -> check==0
    mov rax, [rel stack_canary]
    mov rbx, rax              ; save magic (RBX saved above, safe temp)
    mov rax, 0xDEADBEEFDEADBEEF
    mov [rel stack_canary], rax
    call stack_canary_check64
    cmp rax, 1
    jne .fail65b
    mov [rel stack_canary], rbx
    call stack_canary_check64
    test rax, rax
    jnz .fail65b
    xor eax, eax
    jmp .done65
.fail65b:
    ; try restore before failing
    push rax
    mov rax, STACK_CANARY_MAGIC
    mov [rel stack_canary], rax
    pop rax
.fail65:
    mov eax, 1
.done65:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; Test 66: stress — mixed ABI + timer + DOS INT 21h + mem validate
stack_test_stress:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10
    call idt_reset_stats64
    call stack_canary_init64
    ; ABI mix
    mov rdi, 10
    mov rsi, 20
    mov rdx, 30
    mov rcx, 40
    mov r8, 50
    mov r9, 60
    call abi_sum6_64
    cmp rax, 210
    jne .fail66
    mov rdi, 32
    call stack_recurse64
    cmp rax, 528
    jne .fail66
    ; timer tick (IRQ stack path)
    int 0x20
    call idt_get_tick64
    cmp rax, 1
    jne .fail66
    ; DOS round-trip still fine after ABI hardening (AH=02/09/19)
    mov rax, 0x0200
    mov dl, 'X'
    int 0x21
    mov rax, 0x0900
    lea rdx, [rel stack_dollar]
    int 0x21
    mov rax, 0x1900
    int 0x21
    cmp al, 0
    jne .fail66
    ; no faults from IRQ/DOS, canary intact, heap valid
    call idt_get_fault_count64
    test rax, rax
    jnz .fail66
    call stack_canary_check64
    test rax, rax
    jnz .fail66
    call mem_validate64
    test rax, rax
    jnz .fail66
    xor eax, eax
    jmp .done66
.fail66:
    mov eax, 1
.done66:
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
