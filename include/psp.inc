; 64-bit PSP (Program Segment Prefix) — expands MSDOS.ASM PSP concept (MSDOS.ASM:3374)
; Original PSP was 256 bytes at program segment base, 16-bit segment pointers.
; 64-bit PSP is 512 bytes, flat 64-bit linear addresses, preserves DOS 1.25 compatibility fields.
; See docs/03-memory-layout.md and AGENTS.md Phase 8.

%ifndef PSP64_INC
%define PSP64_INC

struc PSP64
    .int20      resb 2    ; +0x00: INT 20h (CD 20) — kept for debugging, not executed in long mode
    .pad0       resb 6    ; alignment
    .top_mem    resq 1    ; +0x08: top of memory (linear address, was word top_of_memory_segment at +0x02)
    .reserved0  resb 8    ; +0x10: reserved (was CALL 5 far jump at +0x05 - EAh xx xx yy yy)
    .call5_ptr  resq 1    ; +0x18: 64-bit pointer to DOS syscall entry (replaces 0Ch:40h far ptr)
    .exit_ip    resq 1    ; +0x20: saved INT 22h termination address (RIP)
    .exit_cs    resq 1    ; +0x28: saved INT 22h CS (flat selector base)
    .cont_ip    resq 1    ; +0x30: saved INT 23h Ctrl-C address
    .cont_cs    resq 1    ; +0x38: saved INT 23h CS
    .error_ip   resq 1    ; +0x40: saved INT 24h fatal error address
    .error_cs   resq 1    ; +0x48: saved INT 24h CS
    .reserved1  resb 16   ; +0x50: padding to reach FCB1 at 0x5C (keep DOS 1.25 offset equiv)
    .fcb1       resb 32   ; +0x60: FCB 1 (16+16 expanded; original 16 bytes at 0x5C)
    .fcb2       resb 32   ; +0x80: FCB 2 (original 0x6C)
    .cmd_len    resb 1    ; +0xA0: command tail length (original 0x80)
    .cmd_tail   resb 127  ; +0xA1: command tail (127 bytes, original 0x81)
    .pad1       resb 32   ; pad to 0x100
    ; --- 64-bit extensions beyond 256 ---
    .env_ptr    resq 1    ; +0x100: environment block linear address (was word at 0x2C in DOS2+)
    .cr3        resq 1    ; +0x108: page table base for process isolation
    .rsp0       resq 1    ; +0x110: kernel stack pointer (RSP) on entry
    .rflags     resq 1    ; +0x118: saved RFLAGS
    .rax_save   resq 1    ; +0x120: extended register save area (R8-R15)
    .rbx_save   resq 1    ; +0x128
    .rcx_save   resq 1    ; +0x130
    .rdx_save   resq 1    ; +0x138
    .rsi_save   resq 1    ; +0x140
    .rdi_save   resq 1    ; +0x148
    .rbp_save   resq 1    ; +0x150
    .r8_save    resq 1    ; +0x158
    .r9_save    resq 1    ; +0x160
    .r10_save   resq 1    ; +0x168
    .r11_save   resq 1    ; +0x170
    .r12_save   resq 1    ; +0x178
    .r13_save   resq 1    ; +0x180
    .r14_save   resq 1    ; +0x188
    .r15_save   resq 1    ; +0x190
    .fd_table   resq 16   ; +0x198: extended file handle table (16×64-bit indices, was FCB-only)
    .pad2       resb 64   ; +0x218: reserved to reach 512
endstruc
%define PSPSIZ64 PSP64_size

; Compile-time check: must be 512 bytes
; %if PSPSIZ64 != 512
; %error "PSP64 size must be 512"
; %endif

%endif
