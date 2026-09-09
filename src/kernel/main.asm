; MS-DOS64 64-bit kernel entry — boot glue only (long-mode entry at 0x100000)
; _start: stack + serial/VGA init, banner print, self-test dispatch, shell.
; All self-test logic lives in src/kernel/selftest64.asm (selftest_run64).
; Lean build (-DSKIP_SELFTEST): minimal init, straight to shell.
bits 64
default rel

%ifdef SKIP_SELFTEST
%undef RUN_SELFTEST
%undef SELFTEST_DESTRUCTIVE
%else
%ifndef RUN_SELFTEST
%define RUN_SELFTEST
%endif
%endif

section .text.start
global _start
global init_serial64
global serial_print64
global serial_try_putc64

extern vga_init
extern vga_print
extern handler_prtbuf
extern shell_repl64
extern mem_init64
extern proc_init64
extern syscall_init
extern kbd_init
extern idt_init64
extern idt_load64
extern pic_remap64
extern fs_mount_volume64
%ifdef RUN_SELFTEST
extern selftest_run64
%endif

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
    mov rsi, hello_phase4
    call vga_print
    call serial_print64
    mov rsi, hello_phase5
    call vga_print
    call serial_print64
    mov rsi, hello_phase6
    call vga_print
    call serial_print64
    mov rsi, hello_phase7
    call vga_print
    call serial_print64
    mov rsi, hello_phase8
    call vga_print
    call serial_print64
    mov rsi, hello_phase9
    call vga_print
    call serial_print64
    mov rsi, hello_phase10
    call vga_print
    call serial_print64
    mov rsi, hello_phase11
    call vga_print
    call serial_print64
    mov rsi, hello_phase12
    call vga_print
    call serial_print64

    ; Run Phase 3+4+5+6+7+8+9+10+11+12 tests, count passes
    ; Full build only: lean (SKIP_SELFTEST) jumps over the suite to .lean_boot.
%ifdef RUN_SELFTEST
    call selftest_run64
    test rax, rax
    jnz .hlt

    ; Also demonstrate handler_prtbuf (DOS 09h: print $-string)
    mov rdx, demo_dollar_str
    call handler_prtbuf

    ; G3: enter the interactive COMMAND64 shell (returns only on EXIT).
    call shell_repl64
    jmp .hlt

%else
    ; ---- Lean boot (SKIP_SELFTEST): no suite, minimal init, straight to shell.
    ; Replicates the essential init the suite would have performed so the
    ; shell alone still works in isolation (see docs/05 §7).
.lean_boot:
    call mem_init64
    call proc_init64
    call syscall_init
    call kbd_init
    call idt_init64
    call idt_load64
    call pic_remap64
    call fs_mount_volume64
    mov rsi, msg_lean
    call vga_print
    call serial_print64
    call shell_repl64
%endif

.hlt:
    cli
    hlt
    jmp .hlt

; ------------------------------------------------------------
; Serial helpers — early boot glue (COM1 38400 8N1)
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
    push rax
    push rdx
.loop:
    lodsb
    test al, al
    jz .done
    ; Serial is best-effort diagnostic I/O: drop on timeout, never hang.
    ; CF from serial_try_putc64 is intentionally ignored so a stuck UART
    ; cannot stall boot, the self-test suite, or the shell.
    call serial_try_putc64
    jmp .loop
.done:
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------
; serial_try_putc64 — reusable bounded COM1 TX helper (best-effort).
; Serial is optional diagnostic I/O: VGA remains authoritative, and all
; console/shell/test paths must keep working when the UART is absent or
; never reports THRE. A short timeout with character drop is preferable
; to a machine-wide hang.
; In: AL=char. Out: CF=0 sent, CF=1 dropped (timeout).
; Preserves RAX/RBX/RCX/RDX/RSI/RDI (only flags/CF clobbered).
; Timeout: SERIAL_TIMEOUT polls — ample for 16550 baud delay
; (per-byte THRE clear ~1000s of polls) yet bounded (<1ms) when LSR is
; stuck. QEMU (instant THRE) and missing UART (LSR=0xFF, THRE set) send
; on the first poll, so normal output is unchanged.
; ------------------------------------------------------------
SERIAL_TIMEOUT equ 0xFFFF
serial_try_putc64:
    push rax
    push rbx
    push rcx
    push rdx
    mov bl, al                  ; stash char (AL clobbered by status IN)
    mov ecx, SERIAL_TIMEOUT
.wait_txb:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20               ; THR empty?
    jnz .ready_txb
    dec ecx
    jnz .wait_txb
    pop rdx                     ; timeout: drop char, report CF=1
    pop rcx
    pop rbx
    pop rax
    stc
    ret
.ready_txb:
    mov al, bl
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rcx
    pop rbx
    pop rax
    clc
    ret


section .rodata
hello_phase2 db "Hello from 64-bit DOS64 kernel: Phase2 long mode OK!",13,10,0
hello_phase3 db "Phase3: Register & Instruction Conversion Test Suite",13,10,0
hello_phase4 db "Phase4: Addressing Mode Transformation (segmented->flat) Test Suite",13,10,0
hello_phase5 db "Phase5: BIOS Interrupt Replacement — Native Drivers (Option C)",13,10,0
hello_phase6 db "Phase6: Memory Management Overhaul — MCB64, para/page, coalesce, protection",13,10,0
hello_phase7 db "Phase7: File System Adaptation — FAT12 on LBA, DPB/DIR/FCB64",13,10,0
hello_phase8 db "Phase8: Process Management — PSP64, ENV, Loader, EXEC/EXIT",13,10,0
hello_phase9 db "Phase9: System Call Interface — INT 21h IDT gate + AH handlers",13,10,0
hello_phase10 db "Phase10: Command Interpreter — COMMAND64 parser/builtins/exec/batch",13,10,0
hello_phase11 db "Phase11: Interrupt Descriptor Table — full IDT, PIC remap, IRQ handlers",13,10,0
hello_phase12 db "Phase12: Stack & Calling Conventions — System V ABI, 16B, callee-saved",13,10,0
msg_lean db "Lean boot (SKIP_SELFTEST): suite skipped, entering COMMAND64...",13,10,0
msg_nl db 13,10,0
demo_dollar_str db "DOS dollar handler via PRTBUF (INT21 AH=09) test$",0

section .bss
resb 8192
kstack_top:
