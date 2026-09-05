; MS-DOS64 include/stack.inc — Phase 12: Stack & Calling Conventions (64-bit)
; Converts DOS 1.25 16-bit stack (SS:SP, near/far CALL, PUSH segment) to
; flat 64-bit System V AMD64 ABI (RSP, 16-byte alignment, near CALL only).
; See AGENTS.md Phase 12 and docs/17-phase12-stack.md.
;
; Original (MSDOS.ASM): 16-bit SS:SP, PUSH/POP 16-bit, near CALL within
;   segment, far CALL/JMP between segments, parameters on stack or in
;   AX/BX/CX/DX/SI/DI (varies per function), no alignment requirement.
; 64-bit: RSP flat, PUSH/POP 64-bit, near CALL/RET only, System V ABI:
;   RDI,RSI,RDX,RCX,R8,R9 first 6 integer args, stack for 7th+ (16B-aligned),
;   RAX return, RBX/RBP/R12-R15 callee-saved, RAX/RCX/RDX/RSI/RDI/R8-R11
;   caller-saved, DF=0 (CLD), RSP%16==0 before CALL (==8 inside function).

%ifndef STACK64_INC
%define STACK64_INC

; --- Fixed stack addresses (see docs/03-memory-layout.md) ---
%define STACK_TOP64       0x90000   ; initial RSP (_start, long_entry STACK_PM)
%define STACK_ALIGN       16        ; x86-64 ABI requirement before CALL
%define IOSTACK_SIZE64    4096      ; syscall I/O stack (func<=12)
%define DSKSTACK_SIZE64   4096      ; syscall disk stack (func>12)
%define IST_STACK_SIZE64  4096      ; future IST1/IST2 (TSS) stacks
%define KSTACK_RESV64     8192      ; main.asm kstack_top reserve

; --- Canary magic for overflow detection ---
%define STACK_CANARY_MAGIC 0x535441434B313200  ; "STAK12" + 00

; --- Callee-saved / caller-saved sets (System V) ---
; Callee-saved: RBX RBP R12 R13 R14 R15 (+RSP). Caller must preserve across calls.
; Caller-saved: RAX RCX RDX RSI RDI R8 R9 R10 R11 (clobber allowed).

; Align RSP down to 16 bytes (for private stack switch, like syscall dispatch).
; Clobbers RSP only. Use only when switching to a private stack top.
%macro ALIGN_RSP16 0
    and rsp, ~15
%endmacro

; Standard 7-push prologue that leaves RSP aligned for nested calls.
; Entry RSP%16==8; 7 pushes (56B, 56%16==8) -> RSP%16==0, safe to CALL.
; Preserves RBX/RBP/R12-R15 + R10 dummy for alignment (R10 caller-saved,
; so RAX stays free for return values).
%macro ABI_PUSH_CALLEE 0
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push r10                ; dummy alignment (R10 restored, RAX free)
%endmacro

%macro ABI_POP_CALLEE 0
    pop r10
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
%endmacro

; Single-push align: entry 8 -> 0, safe for one nested CALL.
; Pair with ABI_SINGLE_POP.
%macro ABI_SINGLE_PUSH 1
    push %1
%endmacro

%macro ABI_SINGLE_POP 1
    pop %1
%endmacro

%endif
