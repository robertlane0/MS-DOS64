; MS-DOS64 src/kernel/idt64.asm — Phase 9: System Call Interface (INT 21h IDT gate)
; Converts MSDOS.ASM SETVECT (MSDOS.ASM:3342, INTBASE+AL*4) + DISPATCH (MSDOS.ASM:349)
; + COMMAND entry (INT 21h/INT 33/CALL5) to flat 64-bit long-mode IDT.
;
; Original: real-mode IVT at 0000:0000, 256 far ptrs (4B each), DOS vectors
;           INT 20h (ABORT), INT 21h (DOS), INT 22/23/24 (exit/Ctrl-C/error),
;           SETVECT writes DS:[INTBASE+AL*4]=DX/DS.
; 64-bit:   256-entry IDT (16B each, 4096B), interrupt gates (type 0x8E kernel,
;           0xEE user for INT 0x21 DPL=3), selector 0x08 (GDT64 code), IST=0.
;           Exceptions 0-31 point to default stubs (error-code aware) that IRETQ.
;           Vector 0x21 points to int21_entry (Option B, DOS-compatible).
;           SETVECT (AH=25h) / GETVECT (AH=35h DOS2 ext) read/write IDT entries.
;
; int21_entry preserves DOS AH-function convention: user RAX holds AH=func,
; RBX/RCX/RDX/RSI/RDI hold args (BX/CX/DX/SI/DI 16-bit zero-extended).
; Handler results return via trap frame (STKPTRS64) + RAX/RBX + CF in RFLAGS
; (CF propagated to IRETQ frame, like DOS AL=0/FF + AH error).
;
bits 64
default rel

%include "include/regs.inc"

section .text
global idt_init64
global idt_load64
global idt_set_vector64
global idt_get_vector64
global idt_get_base64
global int21_entry
global idt_default_handler
global idt_default_handler_err
global idt_test_vectors

extern syscall_dispatch64
extern handler_conout

%define IDT_ENTRIES 256
%define IDT_CODE_SEL 0x08
%define IDT_TYPE_KERNEL 0x8E   ; P=1 DPL=0 64-bit interrupt gate
%define IDT_TYPE_USER 0xEE     ; P=1 DPL=3 64-bit interrupt gate (INT 21h)

section .bss
align 16
global idt_table
idt_table: resb 4096          ; 256 * 16
global idt_ptr
idt_ptr: resb 10              ; limit(2) + base(8) for LIDT

section .data
align 8
int21_cf_save: dq 0

section .text

; ------------------------------------------------------------
; idt_set_entry_raw — internal: write one IDT entry
;   In: RDI=vector 0..255, RSI=handler RIP, RDX=type_attr (0x8E/0xEE)
;   Out: RAX 0 ok, 1 bad vector
; ------------------------------------------------------------
idt_set_entry_raw:
    cmp rdi, 255
    ja .bad_raw
    push rbx
    push rcx
    mov rax, rdi
    shl rax, 4                ; *16
    lea rbx, [rel idt_table]
    add rbx, rax              ; entry ptr
    mov rax, rsi              ; handler
    mov word [rbx+0], ax      ; offset_low
    mov word [rbx+2], IDT_CODE_SEL
    mov byte [rbx+4], 0       ; IST
    mov al, dl
    mov byte [rbx+5], al      ; type_attr
    mov rax, rsi
    shr rax, 16
    mov word [rbx+6], ax      ; offset_mid
    mov rax, rsi
    shr rax, 32
    mov dword [rbx+8], eax    ; offset_high
    mov dword [rbx+12], 0     ; reserved
    pop rcx
    pop rbx
    xor eax, eax
    ret
.bad_raw:
    mov rax, 1
    ret

; ------------------------------------------------------------
; idt_init64 — fill IDT: 0-31 exceptions (error-aware), 0x21 INT21 (DPL3),
;              rest default. Builds IDTR. Does NOT LIDT (call idt_load64).
;   Out: RAX 0
; ------------------------------------------------------------
idt_init64:
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx
    push r8
    ; default = no-error stub, kernel gate
    lea r8, [rel idt_default_handler]
    xor ecx, ecx
.fill_loop:
    cmp ecx, IDT_ENTRIES
    jae .fill_done
    cmp ecx, 0x21
    je .skip_fill            ; set below with USER gate
    mov rdi, rcx
    mov rsi, r8
    ; error-code vectors need err stub (pop before IRETQ)
    cmp rdi, 8
    je .use_err
    cmp rdi, 10
    je .use_err
    cmp rdi, 11
    je .use_err
    cmp rdi, 12
    je .use_err
    cmp rdi, 13
    je .use_err
    cmp rdi, 14
    je .use_err
    cmp rdi, 17
    je .use_err
    cmp rdi, 21
    je .use_err
    mov rdx, IDT_TYPE_KERNEL
    jmp .do_set
.use_err:
    lea rax, [rel idt_default_handler_err]
    mov rsi, rax
    mov rdx, IDT_TYPE_KERNEL
.do_set:
    push rcx
    push r8
    call idt_set_entry_raw
    pop r8
    pop rcx
.skip_fill:
    inc ecx
    jmp .fill_loop
.fill_done:
    ; vector 0x21 -> int21_entry, USER gate (DPL3, DOS-compatible)
    mov rdi, 0x21
    lea rsi, [rel int21_entry]
    mov rdx, IDT_TYPE_USER
    call idt_set_entry_raw
    ; build IDTR: limit=4095, base=idt_table
    mov word [rel idt_ptr], 4095
    lea rax, [rel idt_table]
    mov [rel idt_ptr+2], rax
    pop r8
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    xor eax, eax
    ret

; ------------------------------------------------------------
; idt_load64 — mask PIC (polling drivers, no IRQs), LIDT, STI.
;   Phase9: native VGA/ATA/KBD use polling (no IRQ), timer IRQ0 would
;   fire as INT 8 (PIC overlap, no remap yet — Phase11). INT 8 expects
;   #DF error code, but IRQ pushes none, so err stub would corrupt stack
;   (Bochs check_cs loop). Mask master/slave PIC (0x21/0xA1=0xFF) to
;   prevent IRQs; STI then safe (software INT 0x21 works with IF=0/1).
; ------------------------------------------------------------
idt_load64:
    push rax
    mov al, 0xFF
    out 0x21, al              ; mask master PIC (IRQ0-7, incl timer IRQ0->INT8)
    out 0xA1, al              ; mask slave PIC (IRQ8-15)
    pop rax
    lidt [rel idt_ptr]
    sti
    xor eax, eax
    ret

; ------------------------------------------------------------
; idt_set_vector64 — 64-bit SETVECT backend (AH=25h)
;   In: RDI=vector 0..255, RSI=handler RIP
;   Out: RAX 0 ok, 1 bad
;   Gate type: 0xEE (user) so DOS programs can INT n.
; ------------------------------------------------------------
idt_set_vector64:
    cmp rdi, 255
    ja .bad_sv
    mov rdx, IDT_TYPE_USER
    jmp idt_set_entry_raw
.bad_sv:
    mov rax, 1
    ret

; ------------------------------------------------------------
; idt_get_vector64 — 64-bit GETVECT backend (AH=35h DOS2 ext)
;   In: RDI=vector 0..255
;   Out: RAX=handler RIP (0 if bad vector)
; ------------------------------------------------------------
idt_get_vector64:
    cmp rdi, 255
    ja .bad_gv
    push rbx
    mov rax, rdi
    shl rax, 4
    lea rbx, [rel idt_table]
    add rbx, rax
    movzx eax, word [rbx+0]       ; low
    movzx ecx, word [rbx+6]       ; mid
    shl ecx, 16
    or eax, ecx
    mov ecx, [rbx+8]              ; high
    shl rcx, 32
    ; RAX low 32 + RCX high 32: combine (mov edx,eax zero-extends)
    mov edx, eax
    or rdx, rcx
    mov rax, rdx
    pop rbx
    ret
.bad_gv:
    xor eax, eax
    ret

idt_get_base64:
    lea rax, [rel idt_table]
    ret

; ------------------------------------------------------------
; Default handlers — do nothing, IRETQ. Err version pops error code.
; ------------------------------------------------------------
idt_default_handler:
    iretq

idt_default_handler_err:
    add rsp, 8                ; drop CPU error code
    iretq

; ------------------------------------------------------------
; int21_entry — CPU interrupt gate for vector 0x21 (Option B).
;   Stack on entry (CPL0->CPL0): [RIP][CS][RFLAGS] (3 qwords).
;   We push 15 GPRs (same order as syscall_dispatch64/savregs64),
;   set SPSAVE64, dispatch via DISPATCH64[AH], propagate CF to IRETQ
;   frame, restore GPRs, IRETQ.
;
;   SPSAVE64/SSSAVE64 live in syscall64.asm (extern).
; ------------------------------------------------------------
extern SPSAVE64
extern SSSAVE64
extern DISPATCH64

int21_entry:
    ; save GPRs (order matches savregs64/STKPTRS64: r15..rax)
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
    push rax                  ; [rsp] = user RAX (AH=func)
    mov [rel SPSAVE64], rsp
    mov r11, ss
    mov [rel SSSAVE64], r11
    ; extract AH into R10 (preserve user RAX/RBX/R8 for handlers)
    ; (Was mov rax,ss which clobbered user RAX/AL.)
    mov r10, [rsp]
    shr r10, 8
    and r10d, 0xFF
    cmp r10d, 0x4C            ; MAXCOM (matches syscall64)
    ja .int_bad
    ; switch to handler stack (IOSTACK<=12 else DSKSTACK)
    cmp r10d, 12
    jle .int_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .int_call
.int_io:
    lea rsp, [rel IOSTACK_TOP64]
.int_call:
    and rsp, ~15
    sti
    ; R10=AH (func), use R11 temp for index, R10 for handler; user regs intact.
    mov r11, r10
    shl r11, 3
    lea r10, [rel DISPATCH64]
    add r10, r11
    mov r10, [r10]
    call r10
    ; save CF (handler success/fail) to memory before restoring GPRs
    ; (pops don't affect flags, but IRETQ pops user RFLAGS, losing CF)
    pushfq
    pop rax
    and rax, 1
    mov [rel int21_cf_save], rax
    jmp .int_restore
.int_bad:
    ; bad function: set saved RAX AL=0 (like dispatch_bad)
    mov rax, [rel SPSAVE64]
    mov byte [rax], 0
    pushfq
    pop rax
    and rax, 1
    mov [rel int21_cf_save], rax
    ; CF for bad? Keep current (usually 0). Clear for determinism:
    ; leave CF=0 -> clear bit in save
    mov qword [rel int21_cf_save], 0
.int_restore:
    cli
    mov rsp, [rel SPSAVE64]
    ; restore GPRs (reverse of push)
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
    ; propagate saved CF into CPU IRETQ frame RFLAGS (at [rsp+16])
    push rax
    push rbx
    mov rax, [rel int21_cf_save]
    mov rbx, [rsp+16+16]      ; rsp+16 (2 pushes) +16 = RFLAGS offset? [rsp]=savedRAX,[+8]=savedRBX,[+16]=RIP,[+24]=CS,[+32]=RFLAGS
    and rbx, ~1
    or rbx, rax
    mov [rsp+16+16], rbx
    pop rbx
    pop rax
    iretq

; IOSTACK/DSKSTACK live in syscall64.asm — extern for LEA above
extern IOSTACK_TOP64
extern DSKSTACK_TOP64

; ------------------------------------------------------------
; idt_test_vectors — self-check helper (called by Phase9 tests)
;   Out: RAX 0 ok (0x21==int21_entry, 0x00==default, DPL bits correct)
; ------------------------------------------------------------
idt_test_vectors:
    push rbx
    push rcx
    push rdi
    mov rdi, 0x21
    call idt_get_vector64
    lea rbx, [rel int21_entry]
    cmp rax, rbx
    jne .fail_tv
    ; check type_attr DPL3 for 0x21 (0xEE)
    mov rax, 0x21
    shl rax, 4
    lea rbx, [rel idt_table]
    add rbx, rax
    cmp byte [rbx+5], IDT_TYPE_USER
    jne .fail_tv
    ; vector 0 default type kernel
    xor edi, edi
    call idt_get_vector64
    test rax, rax
    jz .fail_tv
    mov rax, 0
    shl rax, 4
    lea rbx, [rel idt_table]
    add rbx, rax
    cmp byte [rbx+5], IDT_TYPE_KERNEL
    jne .fail_tv
    ; selector check
    cmp word [rbx+2], IDT_CODE_SEL
    jne .fail_tv
    xor eax, eax
    jmp .done_tv
.fail_tv:
    mov rax, 1
.done_tv:
    pop rdi
    pop rcx
    pop rbx
    ret
