; ASM64 register + condition tables (N4B.2, %included by asm64_core.asm).
; Register entry (10 B): name (NUL-terminated, padded to 6 by macro),
; code, size (8/16/32/64), flags (bit0 = legacy-high ah/bh/ch/dh: REX
; forbidden; bit1 = low8 spl/bpl/sil/dil: REX required), pad. Matched
; case-insensitively; symbols are NOT consulted first (registers win).
; Condition entry (6 B): name padded to 5 + cc. Common aliases included.

section .rodata

%macro REG 4
%%n: db %1, 0
    times 6 - ($ - %%n) db 0
    db %2, %3, %4, 0
%endmacro

%define AC_REG_ENT 10
ac_regtab:
    REG "rax", 0,64,0
    REG "rcx", 1,64,0
    REG "rdx", 2,64,0
    REG "rbx", 3,64,0
    REG "rsp", 4,64,0
    REG "rbp", 5,64,0
    REG "rsi", 6,64,0
    REG "rdi", 7,64,0
    REG "r8",  8,64,0
    REG "r9",  9,64,0
    REG "r10", 10,64,0
    REG "r11", 11,64,0
    REG "r12", 12,64,0
    REG "r13", 13,64,0
    REG "r14", 14,64,0
    REG "r15", 15,64,0
    REG "eax", 0,32,0
    REG "ecx", 1,32,0
    REG "edx", 2,32,0
    REG "ebx", 3,32,0
    REG "esp", 4,32,0
    REG "ebp", 5,32,0
    REG "esi", 6,32,0
    REG "edi", 7,32,0
    REG "r8d", 8,32,0
    REG "r9d", 9,32,0
    REG "r10d", 10,32,0
    REG "r11d", 11,32,0
    REG "r12d", 12,32,0
    REG "r13d", 13,32,0
    REG "r14d", 14,32,0
    REG "r15d", 15,32,0
    REG "ax", 0,16,0
    REG "cx", 1,16,0
    REG "dx", 2,16,0
    REG "bx", 3,16,0
    REG "sp", 4,16,0
    REG "bp", 5,16,0
    REG "si", 6,16,0
    REG "di", 7,16,0
    REG "r8w", 8,16,0
    REG "r9w", 9,16,0
    REG "r10w", 10,16,0
    REG "r11w", 11,16,0
    REG "r12w", 12,16,0
    REG "r13w", 13,16,0
    REG "r14w", 14,16,0
    REG "r15w", 15,16,0
    REG "al", 0,8,0
    REG "cl", 1,8,0
    REG "dl", 2,8,0
    REG "bl", 3,8,0
    REG "spl", 4,8,2
    REG "bpl", 5,8,2
    REG "sil", 6,8,2
    REG "dil", 7,8,2
    REG "ah", 4,8,1
    REG "bh", 7,8,1
    REG "ch", 5,8,1
    REG "dh", 6,8,1
    REG "r8b", 8,8,0
    REG "r9b", 9,8,0
    REG "r10b", 10,8,0
    REG "r11b", 11,8,0
    REG "r12b", 12,8,0
    REG "r13b", 13,8,0
    REG "r14b", 14,8,0
    REG "r15b", 15,8,0
ac_regtab_end:
%define AC_NREG ((ac_regtab_end - ac_regtab) / AC_REG_ENT)

%macro CC 2
%%n: db %1, 0
    times 5 - ($ - %%n) db 0
    db %2
%endmacro

%define AC_CC_ENT 6
ac_cctab:
    CC "jo", 0
    CC "jno", 1
    CC "jb", 2
    CC "jc", 2
    CC "jnae", 2
    CC "jae", 3
    CC "jnc", 3
    CC "jnb", 3
    CC "je", 4
    CC "jz", 4
    CC "jne", 5
    CC "jnz", 5
    CC "jbe", 6
    CC "jna", 6
    CC "ja", 7
    CC "jnbe", 7
    CC "js", 8
    CC "jns", 9
    CC "jp", 10
    CC "jpe", 10
    CC "jnp", 11
    CC "jpo", 11
    CC "jl", 12
    CC "jnge", 12
    CC "jge", 13
    CC "jnl", 13
    CC "jle", 14
    CC "jng", 14
    CC "jg", 15
    CC "jnle", 15
ac_cctab_end:
%define AC_NCC ((ac_cctab_end - ac_cctab) / AC_CC_ENT)

; Error message texts (core reports "LINE: msg"; main prepends "FILE:").
ac_e_mnem:      db "bad mnemonic",0
ac_e_opds:      db "bad operands",0
ac_e_reg:       db "bad register",0
ac_e_num:       db "bad number",0
ac_e_expr:      db "bad expression",0
ac_e_undef:     db "undefined symbol",0
ac_e_dupe:      db "duplicate symbol",0
ac_e_range:     db "value out of range",0
ac_e_div0:      db "division by zero",0
ac_e_line:      db "line too long",0
ac_e_expand:    db "expanded line too long",0
ac_e_symfull:   db "too many symbols",0
ac_e_deffull:   db "too many defines",0
ac_e_outbig:    db "output too big",0
ac_e_listbig:   db "listing too large",0
ac_e_unstab:    db "jumps unstable",0
ac_e_timeunk:   db "times count unresolved",0
ac_e_r16:       db "16-bit operands unsupported",0
ac_e_abs:       db "absolute addresses unsupported",0
ac_e_sib:       db "indexed addressing unsupported",0
ac_e_store:     db "memory stores unsupported",0
ac_e_direct:    db "unsupported directive",0
ac_e_syntax:    db "bad syntax",0
ac_e_rexhigh:   db "invalid high-byte register combination",0
ac_e_bits:      db "bits must be 64",0
ac_e_internal:  db "internal error",0
