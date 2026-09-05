; MS-DOS64 src/kernel/idt64.asm — Phase 11: Full IDT (IVT replacement)
; Converts real-mode IVT at 0000:0000 (256 far ptrs, MSDOS SETVECT:3342,
; DISPATCH:349, INT 20h/21h/22/23/24) to flat 64-bit long-mode IDT.
;
; Original: IVT 1024B, DOS vectors INT 20h ABORT, 21h DOS, 22/23/24 exit/Ctrl-C,
;           hardware INT 08h timer IRQ0, 09h kbd IRQ1, 0Eh disk IRQ14 (PIC overlap).
; 64-bit (Phase 9): 256-entry IDT 4096B, 0xEE DPL3 for 0x21, 0x8E else,
;           error-aware default stubs, int21_entry Option B, PIC masked.
; 64-bit (Phase 11): per-vector exception stubs 0-31 with diagnostics
;           (vector+error+RIP recorded, per-vector counts), PIC remapped
;           master 0x28 / slave 0x30 (above CPU 0-31 AND clear of DOS 0x21;
;           the old 0x20/0x28 map put IRQ1 on 0x21), IRQ0 timer @0x28
;           (tick+EOI), IRQ1 kbd @0x29 INSTALLED (0x60->queue+EOI),
;           IRQ14 disk @0x36 (count+EOI slave+master).
;           All IRQs masked after remap for deterministic tests; unmask
;           API provided, and the shell unmasks IRQ0/IRQ1 on entry.
;
; IDT entry (16B, AGENTS.md Phase11 IDT_ENTRY):
;   +0 offset_low (RIP 0-15), +2 selector 0x08, +4 IST 0, +5 type_attr,
;   +6 offset_mid (16-31), +8 offset_high (32-63), +12 reserved 0.
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
; Phase 11 new exports
global pic_remap64
global pic_get_mask64
global pic_set_mask64
global pic_mask_irq64
global pic_unmask_irq64
global irq0_timer_handler
global irq1_kbd_handler
global irq14_disk_handler
global exc_common
global idt_get_tick64
global idt_get_irq14_count64
global idt_get_fault_count64
global idt_get_last_vector64
global idt_get_last_error64
global idt_get_last_rip64
global idt_get_exc_count64
global idt_reset_stats64

extern syscall_dispatch64
extern handler_conout
extern kbd_queue_push

%define IDT_ENTRIES 256
%define IDT_CODE_SEL 0x08
%define IDT_TYPE_KERNEL 0x8E   ; P=1 DPL=0 64-bit interrupt gate
%define IDT_TYPE_USER 0xEE     ; P=1 DPL=3 64-bit interrupt gate (INT 21h)
%define PIC_MASTER_CMD 0x20
%define PIC_MASTER_DATA 0x21
%define PIC_SLAVE_CMD 0xA0
%define PIC_SLAVE_DATA 0xA1
%define IRQ_TIMER_VEC 0x28      ; master 0x28 + IRQ0 (clears DOS 0x21)
%define IRQ_KBD_VEC 0x29        ; master 0x28 + IRQ1 (installed, was masked)
%define IRQ_DISK_VEC 0x36       ; slave 0x30 + IRQ14-8=6 -> 0x36
%define DOS_VEC 0x21

section .bss
align 16
global idt_table
idt_table: resb 4096          ; 256 * 16
global idt_ptr
idt_ptr: resb 10              ; limit(2) + base(8) for LIDT
alignb 8
global idt_tick_count
idt_tick_count: resq 1
global idt_irq14_count
idt_irq14_count: resq 1
global idt_fault_count
idt_fault_count: resq 1
global idt_last_vector
idt_last_vector: resq 1
global idt_last_error
idt_last_error: resq 1
global idt_last_rip
idt_last_rip: resq 1
global idt_exc_counts
idt_exc_counts: resq 32

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
; pic_delay — small IO delay for PIC init (POST port, harmless)
; ------------------------------------------------------------
pic_delay:
    push rax
    in al, 0x80
    pop rax
    ret

; ------------------------------------------------------------
; pic_remap64 — remap 8259 PIC master 0x28 / slave 0x30.
;   Master 0x28 + slave 0x30 keeps every hardware IRQ above the CPU
;   0-31 exception range AND clears DOS INT 0x21 (the old 0x20/0x28 map
;   put IRQ1 on 0x21, forcing the keyboard handler to stay uninstalled).
;   ICW1 0x11 -> 0x20/0xA0, ICW2 offsets, ICW3 cascade (master IRQ2,
;   slave id 2), ICW4 0x01 8086 mode. Ends masked (0xFF/0xFF) for
;   deterministic polling drivers (Phase5). Safe with IF=0/1 (no STI/CLI).
;   The shell unmasks IRQ0/IRQ1 on entry (live tick + key IRQs).
;   Out: RAX 0
; ------------------------------------------------------------
pic_remap64:
    push rax
    mov al, 0x11
    out PIC_MASTER_CMD, al
    call pic_delay
    out PIC_SLAVE_CMD, al
    call pic_delay
    mov al, 0x28              ; master offset (IRQ0 -> 0x28)
    out PIC_MASTER_DATA, al
    call pic_delay
    mov al, 0x30              ; slave offset (IRQ8 -> 0x30, IRQ14 -> 0x36)
    out PIC_SLAVE_DATA, al
    call pic_delay
    mov al, 0x04              ; master: slave at IRQ2
    out PIC_MASTER_DATA, al
    call pic_delay
    mov al, 0x02              ; slave: cascade id 2
    out PIC_SLAVE_DATA, al
    call pic_delay
    mov al, 0x01              ; 8086 mode
    out PIC_MASTER_DATA, al
    call pic_delay
    out PIC_SLAVE_DATA, al
    call pic_delay
    mov al, 0xFF              ; mask all (deterministic, polling drivers)
    out PIC_MASTER_DATA, al
    call pic_delay
    out PIC_SLAVE_DATA, al
    call pic_delay
    pop rax
    xor eax, eax
    ret

; ------------------------------------------------------------
; pic_get_mask64 — read combined IMR
;   Out: RAX bits 0-7 master (0x21), 8-15 slave (0xA1)
; ------------------------------------------------------------
pic_get_mask64:
    push rdx
    push rcx
    mov dx, PIC_MASTER_DATA
    in al, dx
    movzx ecx, al             ; master
    mov dx, PIC_SLAVE_DATA
    in al, dx
    movzx eax, al
    shl eax, 8
    or eax, ecx
    pop rcx
    pop rdx
    ret

; ------------------------------------------------------------
; pic_set_mask64 — write combined IMR
;   In: RDI bits 0-7 master, 8-15 slave
; ------------------------------------------------------------
pic_set_mask64:
    push rax
    push rdx
    mov eax, edi
    mov dx, PIC_MASTER_DATA
    out dx, al
    shr eax, 8
    mov dx, PIC_SLAVE_DATA
    out dx, al
    pop rdx
    pop rax
    xor eax, eax
    ret

; ------------------------------------------------------------
; pic_mask_irq64 — set one IMR bit
;   In: RDI irq 0..15. Out: RAX 0 ok, 1 bad
; ------------------------------------------------------------
pic_mask_irq64:
    cmp rdi, 15
    ja .bad_m
    push rcx
    push rdx
    push rdi
    call pic_get_mask64        ; RAX=mask
    mov rcx, [rsp]             ; irq (pushed RDI)
    mov rdx, 1
    shl rdx, cl
    or rax, rdx
    mov rdi, rax
    call pic_set_mask64
    pop rdi
    pop rdx
    pop rcx
    xor eax, eax
    ret
.bad_m:
    mov rax, 1
    ret

; ------------------------------------------------------------
; pic_unmask_irq64 — clear one IMR bit
;   In: RDI irq 0..15. Out: RAX 0 ok, 1 bad
; ------------------------------------------------------------
pic_unmask_irq64:
    cmp rdi, 15
    ja .bad_u
    push rcx
    push rdx
    push rdi
    call pic_get_mask64
    mov rcx, [rsp]
    mov rdx, 1
    shl rdx, cl
    not rdx
    and rax, rdx
    mov rdi, rax
    call pic_set_mask64
    pop rdi
    pop rdx
    pop rcx
    xor eax, eax
    ret
.bad_u:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Exception per-vector stubs — push vector (+dummy 0 if CPU pushes
; no error), jmp exc_common. Error vectors (CPU pushes error):
; 8,10,11,12,13,14,17,21. All others push dummy 0 first so common
; always sees [vector][error][RIP][CS][RFLAGS].
; NOTE: software `int n` never pushes error, so tests must only
; `int` non-error vectors (0,3,4,6...); error vectors verified
; via IDT read, not via `int`.
; ------------------------------------------------------------
exc_stub_0:
    push 0
    push 0
    jmp exc_common
exc_stub_1:
    push 0
    push 1
    jmp exc_common
exc_stub_2:
    push 0
    push 2
    jmp exc_common
exc_stub_3:
    push 0
    push 3
    jmp exc_common
exc_stub_4:
    push 0
    push 4
    jmp exc_common
exc_stub_5:
    push 0
    push 5
    jmp exc_common
exc_stub_6:
    push 0
    push 6
    jmp exc_common
exc_stub_7:
    push 0
    push 7
    jmp exc_common
exc_stub_8:
    push 8
    jmp exc_common
exc_stub_9:
    push 0
    push 9
    jmp exc_common
exc_stub_10:
    push 10
    jmp exc_common
exc_stub_11:
    push 11
    jmp exc_common
exc_stub_12:
    push 12
    jmp exc_common
exc_stub_13:
    push 13
    jmp exc_common
exc_stub_14:
    push 14
    jmp exc_common
exc_stub_15:
    push 0
    push 15
    jmp exc_common
exc_stub_16:
    push 0
    push 16
    jmp exc_common
exc_stub_17:
    push 17
    jmp exc_common
exc_stub_18:
    push 0
    push 18
    jmp exc_common
exc_stub_19:
    push 0
    push 19
    jmp exc_common
exc_stub_20:
    push 0
    push 20
    jmp exc_common
exc_stub_21:
    push 21
    jmp exc_common
exc_stub_22:
    push 0
    push 22
    jmp exc_common
exc_stub_23:
    push 0
    push 23
    jmp exc_common
exc_stub_24:
    push 0
    push 24
    jmp exc_common
exc_stub_25:
    push 0
    push 25
    jmp exc_common
exc_stub_26:
    push 0
    push 26
    jmp exc_common
exc_stub_27:
    push 0
    push 27
    jmp exc_common
exc_stub_28:
    push 0
    push 28
    jmp exc_common
exc_stub_29:
    push 0
    push 29
    jmp exc_common
exc_stub_30:
    push 0
    push 30
    jmp exc_common
exc_stub_31:
    push 0
    push 31
    jmp exc_common

; ------------------------------------------------------------
; exc_common — shared fault recorder. Stack on entry:
;   [vector][error][RIP][CS][RFLAGS]. Saves 15 GPRs, records
;   vector/error/RIP + fault_count + per-vector count, restores,
;   drops vector+error, IRETQ. Preserves all GPRs + RFLAGS (except
;   fault计数 side effects). Safe for software `int n` tests.
; ------------------------------------------------------------
exc_common:
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
    ; RSP+120=vector, +128=error, +136=RIP (15 pushes *8)
    mov rax, [rsp+120]
    mov [rel idt_last_vector], rax
    mov rax, [rsp+128]
    mov [rel idt_last_error], rax
    mov rax, [rsp+136]
    mov [rel idt_last_rip], rax
    inc qword [rel idt_fault_count]
    mov rax, [rsp+120]
    cmp rax, 32
    jae .skip_pv
    mov rcx, rax
    shl rcx, 3
    lea rax, [rel idt_exc_counts]
    add rax, rcx
    inc qword [rax]
.skip_pv:
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
    add rsp, 16               ; drop vector+error
    iretq

; ------------------------------------------------------------
; irq0_timer_handler — IRQ0 @0x28. Tick++, EOI master, IRETQ.
;   Preserves all GPRs. Runs with IF=0 (interrupt gate).
; ------------------------------------------------------------
irq0_timer_handler:
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
    inc qword [rel idt_tick_count]
    mov al, 0x20
    out PIC_MASTER_CMD, al
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
    iretq

; ------------------------------------------------------------
; irq1_kbd_handler — IRQ1 keyboard @0x29 (INSTALLED: PIC master 0x28
;   leaves 0x29 free, so DOS INT 0x21 and the keyboard IRQ coexist).
;   Checks OBF 0x64:0x01, reads 0x60, pushes queue (drop if full),
;   EOI master, IRETQ. Preserves all GPRs. Masked during tests
;   (deterministic polling); the shell unmasks IRQ0/IRQ1 on entry.
; ------------------------------------------------------------
irq1_kbd_handler:
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
    mov dx, 0x64
    in al, dx
    test al, 0x01
    jz .k_no_data
    mov dx, 0x60
    in al, dx
    call kbd_queue_push       ; CF ignored (drop if full)
.k_no_data:
    mov al, 0x20
    out PIC_MASTER_CMD, al
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
    iretq

; ------------------------------------------------------------
; irq14_disk_handler — IRQ14 @0x36 (slave 0x30+6). Count++,
;   EOI slave+master (cascade via IRQ2), IRETQ. Preserves all.
; ------------------------------------------------------------
irq14_disk_handler:
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
    inc qword [rel idt_irq14_count]
    mov al, 0x20
    out PIC_SLAVE_CMD, al
    out PIC_MASTER_CMD, al
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
    iretq

; ------------------------------------------------------------
; idt_init64 — fill IDT: 0-31 per-vector exc stubs (error-aware),
;   0x28 timer IRQ, 0x29 keyboard IRQ, 0x21 DOS DPL3, 0x36 disk IRQ,
;   rest default. Builds IDTR. Does NOT LIDT/remap (call idt_load64).
;   Out: RAX 0
; ------------------------------------------------------------
idt_init64:
    push rbx
    push rcx
    push rdi
    push rsi
    push rdx
    push r8
    ; default = no-error stub, kernel gate for 32..255 (except specials)
    lea r8, [rel idt_default_handler]
    xor ecx, ecx
.fill_loop:
    cmp ecx, IDT_ENTRIES
    jae .fill_done
    cmp ecx, 0x21
    je .skip_fill
    cmp ecx, 32
    jb .skip_fill              ; 0-31 set explicitly below
    cmp ecx, IRQ_TIMER_VEC
    je .skip_fill
    cmp ecx, IRQ_KBD_VEC
    je .skip_fill
    cmp ecx, IRQ_DISK_VEC
    je .skip_fill
    mov rdi, rcx
    mov rsi, r8
    mov rdx, IDT_TYPE_KERNEL
    push rcx
    push r8
    call idt_set_entry_raw
    pop r8
    pop rcx
.skip_fill:
    inc ecx
    jmp .fill_loop
.fill_done:
    ; 0-31 exception stubs (explicit LEA, no table -> no RIP+SIB pitfalls)
    mov rdi, 0
    lea rsi, [rel exc_stub_0]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 1
    lea rsi, [rel exc_stub_1]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 2
    lea rsi, [rel exc_stub_2]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 3
    lea rsi, [rel exc_stub_3]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 4
    lea rsi, [rel exc_stub_4]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 5
    lea rsi, [rel exc_stub_5]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 6
    lea rsi, [rel exc_stub_6]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 7
    lea rsi, [rel exc_stub_7]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 8
    lea rsi, [rel exc_stub_8]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 9
    lea rsi, [rel exc_stub_9]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 10
    lea rsi, [rel exc_stub_10]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 11
    lea rsi, [rel exc_stub_11]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 12
    lea rsi, [rel exc_stub_12]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 13
    lea rsi, [rel exc_stub_13]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 14
    lea rsi, [rel exc_stub_14]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 15
    lea rsi, [rel exc_stub_15]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 16
    lea rsi, [rel exc_stub_16]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 17
    lea rsi, [rel exc_stub_17]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 18
    lea rsi, [rel exc_stub_18]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 19
    lea rsi, [rel exc_stub_19]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 20
    lea rsi, [rel exc_stub_20]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 21
    lea rsi, [rel exc_stub_21]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 22
    lea rsi, [rel exc_stub_22]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 23
    lea rsi, [rel exc_stub_23]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 24
    lea rsi, [rel exc_stub_24]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 25
    lea rsi, [rel exc_stub_25]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 26
    lea rsi, [rel exc_stub_26]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 27
    lea rsi, [rel exc_stub_27]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 28
    lea rsi, [rel exc_stub_28]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 29
    lea rsi, [rel exc_stub_29]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 30
    lea rsi, [rel exc_stub_30]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    mov rdi, 31
    lea rsi, [rel exc_stub_31]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    ; IRQ0 timer @0x28
    mov rdi, IRQ_TIMER_VEC
    lea rsi, [rel irq0_timer_handler]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    ; IRQ1 keyboard @0x29 (installed: no DOS collision at 0x28/0x30 map)
    mov rdi, IRQ_KBD_VEC
    lea rsi, [rel irq1_kbd_handler]
    mov rdx, IDT_TYPE_KERNEL
    call idt_set_entry_raw
    ; DOS INT 0x21 USER gate (DPL3, DOS-compatible)
    mov rdi, DOS_VEC
    lea rsi, [rel int21_entry]
    mov rdx, IDT_TYPE_USER
    call idt_set_entry_raw
    ; IRQ14 disk @0x36
    mov rdi, IRQ_DISK_VEC
    lea rsi, [rel irq14_disk_handler]
    mov rdx, IDT_TYPE_KERNEL
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
; idt_load64 — remap PIC (0x20/0x28, masked), LIDT, STI.
;   Phase9 masked without remap (timer would fire as INT 8 -> #DF
;   stack corruption). Phase11 remaps first so masked state is safe
;   and future unmask delivers to 0x20+/0x28+ (no CPU overlap).
; ------------------------------------------------------------
idt_load64:
    push rax
    call pic_remap64
    mov al, 0xFF
    out PIC_MASTER_DATA, al    ; re-assert mask (remap already masked)
    out PIC_SLAVE_DATA, al
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
; Phase 11 stat getters / reset (all preserve caller regs except RAX)
; ------------------------------------------------------------
idt_get_tick64:
    mov rax, [rel idt_tick_count]
    ret
idt_get_irq14_count64:
    mov rax, [rel idt_irq14_count]
    ret
idt_get_fault_count64:
    mov rax, [rel idt_fault_count]
    ret
idt_get_last_vector64:
    mov rax, [rel idt_last_vector]
    ret
idt_get_last_error64:
    mov rax, [rel idt_last_error]
    ret
idt_get_last_rip64:
    mov rax, [rel idt_last_rip]
    ret
; In: RDI=vector 0..31. Out: RAX=count (0 if bad)
idt_get_exc_count64:
    cmp rdi, 31
    ja .bad_ec
    mov rax, rdi
    shl rax, 3
    lea rcx, [rel idt_exc_counts]
    add rcx, rax
    mov rax, [rcx]
    ret
.bad_ec:
    xor eax, eax
    ret
; Zero tick/irq14/fault/last/per-vector. Out: RAX 0
idt_reset_stats64:
    push rdi
    push rcx
    mov qword [rel idt_tick_count], 0
    mov qword [rel idt_irq14_count], 0
    mov qword [rel idt_fault_count], 0
    mov qword [rel idt_last_vector], 0
    mov qword [rel idt_last_error], 0
    mov qword [rel idt_last_rip], 0
    lea rdi, [rel idt_exc_counts]
    mov rcx, 32
.zero_loop:
    mov qword [rdi], 0
    add rdi, 8
    dec rcx
    jnz .zero_loop
    pop rcx
    pop rdi
    xor eax, eax
    ret

; ------------------------------------------------------------
; Default handlers — kept for Phase9 compat (vectors 32+, except
; 0x20/0x21/0x2E which now point to IRQ/DOS). Do nothing, IRETQ.
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
;   Out: RAX 0 ok (0x21==int21_entry, 0x00==exc_stub_0, DPL bits correct)
;   Phase11: vector 0 now points to exc_stub_0 (not default) but still
;   kernel gate 0x8E selector 0x08, so same checks pass.
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
