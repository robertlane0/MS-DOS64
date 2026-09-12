; ASM64 operand parsing + instruction/data encoding (N4B.2).
; %included by asm64_core.asm. All emit goes through ac_outb (globals
; ac_outp/ac_outleft: real output in EMIT mode, 32B scratch in LENGTH
; mode — instructions never exceed 15 B; db lines count, never scratch).
; CF=1 on any error (message already recorded via ac_error*).

section .text

; ac_outb(AL=byte): store + advance, or "output too big" (CF=1).
ac_outb:
    push rbx
    mov rbx, [rel ac_outp]
    cmp qword [rel ac_outleft], 0
    je .ob_full
    mov [rbx], al
    inc qword [rel ac_outp]
    dec qword [rel ac_outleft]
    clc
    pop rbx
    ret
.ob_full:
    lea rdi, [rel ac_e_outbig]
    call ac_error_msg
    stc
    pop rbx
    ret

; ac_outw(AX) / ac_outd(EAX) / ac_outq(RAX): little-endian stores.
ac_outw:
    push rax
    call ac_outb                  ; AL first (little-endian)
    jc .ow_done
    pop rax
    push rax
    mov al, ah
    call ac_outb
.ow_done:
    pop rax
    ret
ac_outd:
    push rax
    call ac_outb
    jc .od_done
    shr rax, 8
    call ac_outb
    jc .od_done
    shr rax, 8
    call ac_outb
    jc .od_done
    shr rax, 8
    call ac_outb
.od_done:
    pop rax
    ret
ac_outq:
    push rax
    push rcx
    push rdx                      ; 3 pushes: aligned (dummy preserve)
    mov ecx, 8
.oq_loop:
    push rcx
    push rax
    call ac_outb
    pop rax
    pop rcx
    jc .oq_done
    shr rax, 8
    dec ecx
    jnz .oq_loop
.oq_done:
    pop rdx
    pop rcx
    pop rax
    ret

; ac_rex(BL=w, CL=r, DL=b, R10B=forced, R11B=legacy-high): emit REX unless
;   it would be bare 0x40 unforced; error if legacy-high meets any REX.
ac_rex:
    push rax
    test r11b, r11b
    jz .rx_ok
    test bl, bl
    jnz .rx_bad
    test cl, cl
    jnz .rx_bad
    test dl, dl
    jnz .rx_bad
    test r10b, r10b
    jnz .rx_bad
    jmp .rx_ok
.rx_bad:
    lea rdi, [rel ac_e_rexhigh]
    call ac_error_msg
    stc
    pop rax
    ret
.rx_ok:
    mov al, 0x40
    test bl, bl
    jz .rx_nw
    or al, 0x08
.rx_nw:
    test cl, cl
    jz .rx_nr
    or al, 0x04
.rx_nr:
    test dl, dl
    jz .rx_nb
    or al, 0x01
.rx_nb:
    cmp al, 0x40
    je .rx_bare
    test r10b, r10b
    jnz .rx_emit
    cmp al, 0x40
    jne .rx_emit
.rx_bare:
    test r10b, r10b
    jz .rx_done                   ; bare 0x40, unforced: omit (byte-identity)
.rx_emit:
    call ac_outb
    jc .rx_done2
.rx_done:
    clc
.rx_done2:
    pop rax
    ret

; ac_modrm(AL: mod(2):reg(3):rm(3) packed as mod<<6|reg<<3|rm) -> emit.
ac_modrm:
    jmp ac_outb                   ; tail call (CF passes through)

; ac_regop_check(R10B=legacy-high flags of op A, R11B=of op B, plus
;   W/R/B in BL/CL/DL) -> CF=1 "16-bit"? No — 16-bit is checked by SIZE.
;   (Legacy-high check lives in ac_rex via R11B: caller ORs both flags.)

; ac_parse_operand(RDI=cursor, RSI=slot32) -> RDI=after, CF=1 syntax error.
;   Slot layout (32 B): +0 kind(0 none,1 reg,2 imm,3 mem,4 sym),
;   +1 reg_code, +2 reg_size, +3 reg_flags, +8 imm_val qword,
;   +16 imm_unk/name_len, +17 mem_base(-1 none,0-15,16 rip)/sym_namelen hi?,
;   +18 mem_rel, +19 mem_sizekw(0,1,2,4,8), +20 disp_val qword, +28 disp_unk.
;   For kind=4 (jump target): +8=nameptr, +16=namelen.
ac_parse_operand:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                  ; slot
    mov qword [r12], 0            ; clear kind..flags+pad
    mov qword [r12+8], 0
    mov qword [r12+16], 0
    mov qword [r12+24], 0
    call ac_skip_ws
    mov rdi, rax
    mov al, [rdi]
    cmp al, '['
    je .op_mem_go
    ; size keyword? (byte/word/dword/qword directly before '[')
    mov rbx, rdi                  ; save cursor (RBX is pushed-free)
    call ac_parse_ident
    jc .op_no_kw                  ; not an ident: fall through to normal
    push rax
    push rcx
    push rdi                      ; after-ident
    mov rdi, rax
    mov rsi, rcx                  ; (len)
    call ac_sizekw_lookup         ; RAX=1/2/4/8, CF=0 / CF=1 miss
    pop rdi
    pop rcx
    pop rax
    jc .op_no_kw2                 ; ident, not a size keyword
    mov [r12+19], al              ; mem_sizekw
    call ac_skip_ws
    mov rdi, rax
    cmp byte [rdi], '['
    jne .op_kw_nobracket          ; keyword not followed by '[': reparse
    jmp .op_mem_go                ; RDI at '['; slot sizekw set
.op_kw_nobracket:
.op_no_kw2:
    mov rdi, rbx                  ; restore cursor
.op_no_kw:
    mov al, [rdi]
    cmp al, '['
    je .op_mem_go
    ; fallthrough into ident path below
    call ac_parse_ident
    jc .op_expr_or_bad            ; not an ident: number/expr or garbage
    ; ident: register? (registers win, NASM-like). Bounds to callee-saved:
    ; reg_lookup destroys RAX (miss) and RDI/RSI (scratch).
    mov r13, rax                  ; start
    mov r14, rcx                  ; len
    mov r15, rdi                  ; after-ident
    mov rdi, rax
    mov rsi, rcx
    call ac_reg_lookup
    jc .op_ident_notreg
    mov byte [r12], 1             ; kind = reg
    mov [r12+1], al               ; code
    mov [r12+2], cl               ; size
    mov [r12+3], dl               ; flags
    mov rdi, r15
    clc
    jmp .op_done
.op_ident_notreg:
    ; bare ident where an operand goes: SYMBOL (jump targets use this;
    ; mov-family rejects kind=4 at encode with "bad operands")
    mov byte [r12], 4
    mov [r12+8], r13              ; name ptr
    mov [r12+16], r14             ; name len
    mov rdi, r15
    clc
    jmp .op_done
.op_expr_or_bad:
    ; number or '(' or unary: full expression = IMM (unknown ok)
    mov dword [rel ac_expr_label], 0
    call ac_expr
    jc .op_bad
    mov byte [r12], 2
    mov [r12+8], rax
    mov [r12+16], rdx             ; unknown flag
    mov rax, [rel ac_expr_label]
    mov [r12+17], al              ; label-ref flag (absolute check at encode)
    test edx, edx
    jz .op_expr_known
    push rsi
    mov rsi, r12
    call ac_unk_save              ; remember whose name it was
    pop rsi
.op_expr_known:
    clc
    jmp .op_done
.op_mem_go:
    inc rdi                       ; past '['
    call ac_parse_mem             ; (below; fills slot, RDI=after `]`)
    jmp .op_done2                 ; CF passes through
.op_bad:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
    stc
.op_done2:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.op_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ac_parse_mem(RDI=after '[', RSI=slot) -> RDI=after ']', CF=1 error.
;   Forms: [rel expr] | [reg] | [reg +/- expr] | [bare-expr] (= [rel],
;   default-rel rule). Pure-number [0x1234] (no symbols, no rel) is
;   absolute -> error. SIB shapes ([r+r], [r*s], [r+r*s]) -> error.
;   Base must come first ([8+rax] misparses — documented cut).
;   Uses global ac_expr_label (factor sets it on known-nonconst refs;
;   caller clears before each mem expression).
ac_parse_mem:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rsi                  ; slot
    mov byte [r15+17], -1         ; base = none
    mov byte [r15+18], 0          ; rel = 0
    mov byte [r15], 3             ; kind = mem (tentative)
    call ac_skip_ws
    mov rdi, rax
    ; try `rel` keyword, register base, or symbol expression
    mov r12, rdi                  ; stanza start (EXPR backtrack)
    call ac_parse_ident           ; RAX=start RCX=len RDI=after / CF=no-ident
    jc .pm_expr_at
    mov r13, rax                  ; ident start (callee-saved)
    mov r14, rcx                  ; ident len
    mov rbx, rdi                  ; after-ident
    mov rdi, rax
    lea rsi, [rel ac_kw_rel]
    mov edx, 3
    call ac_streicn
    jz .pm_got_rel
    mov rdi, r13                  ; register base?
    mov rsi, r14
    call ac_reg_lookup            ; RAX=code RCX=size RDX=flags / CF=miss
    jc .pm_symexpr
    mov [r15+1], al               ; stash base code/size/flags
    mov [r15+2], cl
    mov [r15+3], dl
    mov [r15+17], al              ; mem_base
    mov rdi, rbx                  ; after base ident
    jmp .pm_base
.pm_got_rel:
    mov byte [r15+18], 1          ; explicit [rel ...]
    mov rdi, rbx                  ; after `rel`
    jmp .pm_expr_at2
.pm_symexpr:
    mov rdi, r13                  ; re-parse whole thing as expression
    jmp .pm_expr_at2
.pm_expr_at:
    mov rdi, r12                  ; backtrack to stanza start
.pm_expr_at2:
.pm_expr:
    ; expression form (RDI = cursor at expr start)
    mov dword [rel ac_expr_label], 0
    call ac_expr                  ; RAX=val RDX=unk RDI=after
    jc .pm_bad
    mov [r15+20], rax             ; disp_val
    mov [r15+28], dl              ; disp_unk
    test edx, edx
    jz .pm_expr_known
    mov rsi, r15
    call ac_unk_save              ; remember whose name (RDI survives)
.pm_expr_known:
    test edx, edx
    jnz .pm_close                 ; unknown: assume rel (resolved at emit)
    cmp byte [r15+18], 1
    je .pm_close                  ; explicit [rel]: always fine
    cmp dword [rel ac_expr_label], 0
    jne .pm_close                 ; has label refs: default-rel applies
    lea rdi, [rel ac_e_abs]       ; pure number: absolute -> honest error
    call ac_error_msg
    stc
    jmp .pm_out
.pm_base:
    ; RDI = after base ident. Expect ']' | +/- expr | SIB junk.
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    cmp cl, ']'
    je .pm_bare
    cmp cl, '+'
    je .pm_off
    cmp cl, '-'
    je .pm_off
    cmp cl, '*'
    je .pm_sib
    lea rdi, [rel ac_e_opds]      ; e.g. `[rax rax]`: bad syntax
    call ac_error_msg
    stc
    jmp .pm_out
.pm_bare:
    inc rdi
    mov qword [r15+20], 0         ; disp = 0
    mov byte [r15+28], 0
    jmp .pm_close
.pm_off:
    ; SIB peek: an ident right after the op that IS a register (with a
    ; SIB boundary after it) means [r+r] / [r+r*..] -> honest SIB error.
    ; Otherwise the op stays: ac_expr parses the sign as unary.
    push rdi                      ; op cursor
    inc rdi
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_ident
    jc .pm_off_expr               ; not an ident: plain disp expression
    push rax
    push rcx
    push rdi                      ; after-index-ident
    mov rdi, rax
    mov rsi, rcx
    call ac_reg_lookup
    jc .pm_off_notreg
    mov rdi, [rsp]                ; after-index-ident
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    cmp cl, ']'
    je .pm_off_sib
    cmp cl, '*'
    je .pm_off_sib
    cmp cl, '+'
    je .pm_off_sib
    cmp cl, '-'
    je .pm_off_sib
.pm_off_notreg:
    add rsp, 24                   ; drop ident bounds + after-cursor
.pm_off_expr:
    pop rdi                       ; op cursor (or pushed ident state fixed)
    mov dword [rel ac_expr_label], 0
    call ac_expr                  ; handles the +/- sign as unary
    jc .pm_bad
    mov [r15+20], rax
    mov [r15+28], dl
    test edx, edx
    jz .pm_off_known
    mov rsi, r15
    call ac_unk_save
.pm_off_known:
    jmp .pm_close
.pm_off_sib:
    add rsp, 24                   ; drop ident bounds + after-cursor
    pop rdi                       ; op cursor (drop; error path ignores)
.pm_sib:
    lea rdi, [rel ac_e_sib]
    call ac_error_msg
    stc
    jmp .pm_out
.pm_close:
    call ac_skip_ws               ; disp exprs stop AT `]`: consume it here
    mov rdi, rax
    cmp byte [rdi], ']'
    jne .pm_bad
    inc rdi
.pm_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.pm_bad:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
    stc
    jmp .pm_out
ac_kw_rel: db "rel",0

; ------------------------------------------------------------
; Operand slots (32 B each) + splitter. Slot layout: +0 kind (0 none,
; 1 reg, 2 imm, 3 mem, 4 sym), +1 reg_code, +2 reg_size, +3 reg_flags,
; +8 imm_val/name_ptr, +16 imm_unk/name_len, +17 mem_base, +18 mem_rel,
; +19 mem_sizekw, +20 disp_val, +28 disp_unk. (kind=4 sym reuses +8/+16.)

; ac_split_operands(RDI=cursor) -> RAX=count(0-2), RDI=after, CF=1 error.
;   Fills ac_op1/ac_op2. Top-level commas only (quote-aware: ',' is a
;   legal char literal). Empty operand (trailing comma) falls out at
;   encode as count mismatch... actually parse_operand on "" errors
;   "bad operands" naturally. Good.
ac_split_operands:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    xor r14d, r14d                ; count
    lea r12, [rel ac_op1]
    mov qword [r12], 0            ; clear both slots (kind=0)
    mov qword [r12+8], 0
    mov qword [r12+16], 0
    mov qword [r12+24], 0
    lea r13, [rel ac_op2]
    mov qword [r13], 0
    mov qword [r13+8], 0
    mov qword [r13+16], 0
    mov qword [r13+24], 0
.so_loop:
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    test cl, cl                   ; NUL end
    jz .so_done
    cmp cl, ';'
    je .so_done                   ; comment ends operands
    cmp r14d, 2
    jae .so_many                  ; third operand
    cmp r14d, 1
    je .so_second
    mov rsi, r12
    jmp .so_parse
.so_second:
    mov rsi, r13
.so_parse:
    call ac_parse_operand         ; RDI=after, CF=err
    jc .so_bad
    inc r14d
    call ac_skip_ws
    mov rdi, rax
    cmp byte [rdi], ','
    jne .so_done                  ; (caller checks trailing garbage)
    inc rdi
    jmp .so_loop
.so_done:
    mov rax, r14
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.so_many:
    lea rdi, [rel ac_e_opds]      ; 3+ operands: bad operands
    call ac_error_msg
    stc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.so_bad:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret                           ; CF already set (message recorded)

; ac_fit8(RAX=v) -> CF=0 iff -128..127.
ac_fit8:
    cmp rax, 127
    ja .f8_no                     ; (unsigned >127: could still be -128..-1?)
    clc
    ret
.f8_no:
    cmp rax, -128
    jb .f8_out
    clc
    ret
.f8_out:
    stc
    ret

; ac_fit32s(RAX=v) -> CF=0 iff -2^31..2^31-1 (signed int32). Preserves RCX.
ac_fit32s:
    push rcx
    mov rcx, rax
    movsxd rcx, ecx
    cmp rax, rcx
    pop rcx
    je .f32_ok
    stc
    ret
.f32_ok:
    clc
    ret

; ac_fit_u32(RAX=v) -> CF=0 iff -2^31..2^32-1 (nasm imm32 rule). Preserves RCX.
ac_fit_u32:
    push rcx
    mov rcx, rax
    shr rcx, 32
    jz .fu_ok_pop                  ; high 32 clear: 0..2^32-1
    cmp rcx, -1                    ; high all ones?
    jne .fu_bad_pop
    cmp rax, -0x80000000           ; -2^32..-1: only -2^31..-1 valid
    jae .fu_ok_pop
.fu_bad_pop:
    stc
    pop rcx
    ret
.fu_ok_pop:
    clc
    pop rcx
    ret

; ac_unk_save(RSI=slot) — copy the current miss-name globals to this
; operand's pair (ac_op1unk/ac_op2unk). Preserves everything but RAX.
; Called when an operand's expression came back unknown.
ac_unk_save:
    push rax
    push rdx
    lea rax, [rel ac_op1]
    cmp rsi, rax
    mov rax, [rel ac_unkname]
    mov rdx, [rel ac_unklen]
    jne .us2
    mov [rel ac_op1unk], rax
    mov [rel ac_op1unk+8], rdx
    pop rdx
    pop rax
    ret
.us2:
    mov [rel ac_op2unk], rax
    mov [rel ac_op2unk+8], rdx
    pop rdx
    pop rax
    ret

; ac_sizekw_lookup(RDI=name, RSI=len) -> RAX=1/2/4/8, CF=0; CF=1 miss.
ac_sizekw_lookup:
    cmp rsi, 4
    je .sk_4
    cmp rsi, 5
    jne .sk_miss
    push rbx
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rel ac_kw_dword]
    mov rdx, 5
    call ac_streicn
    jz .sk_dword
    mov rdi, rbx
    lea rsi, [rel ac_kw_qword]
    mov rdx, 5
    call ac_streicn
    pop rbx
    jz .sk_qword
    jmp .sk_miss
.sk_dword:
    pop rbx
    mov eax, 4
    clc
    ret
.sk_qword:
    mov eax, 8
    clc
    ret
.sk_4:
    push rbx
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rel ac_kw_byte]
    mov rdx, 4
    call ac_streicn
    jz .sk_byte
    mov rdi, rbx
    lea rsi, [rel ac_kw_word]
    mov rdx, 4
    call ac_streicn
    pop rbx
    jz .sk_word
    jmp .sk_miss
.sk_byte:
    pop rbx
    mov eax, 1
    clc
    ret
.sk_word:
    mov eax, 2
    clc
    ret
.sk_miss:
    stc
    xor eax, eax
    ret
ac_kw_byte: db "byte",0
ac_kw_word: db "word",0
ac_kw_dword: db "dword",0
ac_kw_qword: db "qword",0

; ac range for r8 immediates (RAX=v) -> CF=0 iff -128..255. Leaf.
ac_fit_i8u:
    cmp rax, 255
    ja .fi8_hi
    clc
    ret
.fi8_hi:
    cmp rax, -128
    jb .fi8_bad
    clc
    ret
.fi8_bad:
    stc
    ret

; ---- per-mnemonic encoders (ac_op1/ac_op2 + ac_opcount + ac_lineoff) ----
; All: CF=1 error (message recorded). Callee-saved preserved.

; ac_rex_for(BL=W, CL=dcode(0-15), DL=scode(0-15), R10B=dflags,
;   R11B=sflags) -> ac_rex with R/B/force/legacy combined from both sides.
; Inputs consumed; clobbers RAX. RBX/R12-R15 preserved.
ac_rex_for:
    sub rsp, 8                    ; align (no regs needed: pure scratch use)
    and cl, 8                     ; R = dst>=8
    and dl, 8                     ; B = src>=8
    or r10b, r11b                 ; combined flags
    mov al, r10b
    and al, 1
    mov r11b, al                  ; legacy = combined&1
    mov al, r10b
    and al, 2
    mov r10b, al                  ; forced = combined&2 (0/2)
    call ac_rex
    add rsp, 8
    ret

; ac_out_opcode_r(AL=base, DL=code) -> emit base+(code&7). Clobbers RAX,RDX.
ac_out_opcode_r:
    and dl, 7
    or al, dl
    jmp ac_outb

; ac_need_known(RDI=unkpair, RSI=slot) -> CF=1 "undefined symbol" at EMIT.
;   CF=0 when known, or unknown-at-LENGTH (assume longest). Uses [rsi+16].
ac_need_known:
    push rax
    push rbx                      ; 3 pushes (2nd is dummy): aligned
    push rdx
    cmp byte [rsi+16], 0
    je .nk_ok
    cmp dword [rel ac_emit], 0
    je .nk_ok                     ; LENGTH: assume (longest forms chosen)
    mov rdx, [rdi+8]              ; namelen
    mov rsi, [rdi]                ; name
    lea rdi, [rel ac_e_undef]
    call ac_error_sym
    stc
    pop rdx
    pop rbx
    pop rax
    ret
.nk_ok:
    clc
    pop rdx
    pop rbx
    pop rax
    ret

; ac_sym_target(RSI=slot kind=4) -> RAX=addr, RDX=unk(0/1).
;   CF=1 undefined-at-EMIT (with the slot's own name). At LENGTH with a
;   missing symbol: optimistic (RAX=0, RDX=1, CF=0). Equ aliases are not
;   addresses -> "bad operands".
ac_sym_target:
    push rbx
    push r12
    push r13
    mov r12, [rsi+8]              ; name (survives: callee-saved)
    mov r13, [rsi+16]             ; len
    mov rdi, r12
    mov rsi, r13
    call ac_sym_find
    test rax, rax
    jz .st_unk
    test byte [rax + AC_SYM_FLAGS], AC_SF_DEFINED
    jz .st_unk
    test byte [rax + AC_SYM_FLAGS], AC_SF_CONST
    jnz .st_const
    mov rax, [rax + AC_SYM_ADDR]
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    clc
    ret
.st_unk:
    cmp dword [rel ac_emit], 0
    je .st_ok
    mov rdx, r13
    mov rsi, r12
    lea rdi, [rel ac_e_undef]
    call ac_error_sym
    stc
    pop r13
    pop r12
    pop rbx
    ret
.st_ok:
    xor eax, eax
    mov edx, 1
    clc
    pop r13
    pop r12
    pop rbx
    ret
.st_const:
    lea rdi, [rel ac_e_opds]      ; equ is a value, not an address
    call ac_error_msg
    stc
    pop r13
    pop r12
    pop rbx
    ret

; ac_mem_emit(RSI=mem slot, R10B=reg-field code, BL=W-bit,
;   R11B=bit0 dst-legacy-high, bit1 dst-force-REX, R14B=lead count (0/2),
;   R15W=lead bytes low-first) -> CF=1 error.
;   Emits REX + lead[] + ModRM + disp (wire order — the lead mechanism
;   exists because 0F-prefixed opcodes sit between REX and ModRM).
;   Base legacy/force read from the slot and merged. Rejects rsp/r12
;   bases (SIB) and non-64 bases (address-size cut). Unknown disp -> optimistic-short placeholder (mod01 ib=0);
;   known disp: 0 (non-rbp/r13) -> mod00, fits-int8 -> mod01, else mod10
;   (fit32s-checked); rel form always mod00+disp32 (fit32s-checked).
ac_mem_emit:
    push rax
    push rbx
    push rcx
    push rdx
    push r10
    push r11
    push r13
    push r14
    sub rsp, 24                   ; locals: [rsp]=dispval, [rsp+8]=modrm,
                                  ; [rsp+9]=W (total frame 64+24=88: aligned)
    mov rax, [rel ac_outp]
    mov [rsp+16], rax             ; save outp at start of instruction
    mov r13b, r11b                ; dst legacy(bit0)/force(bit1)
    mov [rsp+9], bl               ; W bit (R14B is the lead-count input!)
    mov cl, [rsi+17]              ; base (-1 none, 0-15)
    cmp cl, -1
    je .mm_rel
    cmp cl, 4                     ; rsp needs SIB
    je .mm_sib
    cmp cl, 12                    ; r12 needs SIB
    je .mm_sib
    cmp byte [rsi+2], 64          ; base size (address-size cut otherwise)
    jne .mm_basecut
    mov al, [rsi+3]               ; base flags -> merge legacy/force
    and al, 3
    or r13b, al
    mov dl, cl
    and dl, 8                     ; B = base>=8 (0/8)
    mov [rsp+10], dl
    cmp byte [rsi+28], 0          ; disp unknown?
    jne .mm_ph                     ; optimistic-short placeholder
    mov rax, [rsi+20]             ; disp value
    test rax, rax
    jnz .mm_vnz
    cmp cl, 5                     ; rbp disp0 still needs mod01
    je .mm_m01z
    cmp cl, 13                    ; r13 disp0 still needs mod01
    je .mm_m01z
    mov byte [rsp+8], 0x00        ; mod=00, no disp bytes
    mov qword [rsp], 0
    jmp .mm_go
.mm_vnz:
    mov [rsp], rax                ; stash disp value
    push rax
    call ac_fit8
    pop rax
    jc .mm_m10                    ; doesn't fit int8: disp32
    mov byte [rsp+8], 0x40        ; mod=01
    jmp .mm_go
.mm_m01z:
    mov qword [rsp], 0
    mov byte [rsp+8], 0x40        ; mod=01, disp8 = 0
    jmp .mm_go
.mm_ph:
    mov qword [rsp], 0
    mov byte [rsp+8], 0x40        ; mod=01 placeholder
    jmp .mm_go
.mm_m10:
    mov rax, [rsp]
    push rax
    call ac_fit32s
    pop rax
    jc .mm_range
    mov byte [rsp+8], 0x80        ; mod=10, disp32 (value already stashed)
    jmp .mm_go
.mm_rel:
    mov byte [rsp+10], 0          ; B = 0
    mov byte [rsp+8], 0x00        ; mod=00
    mov cl, 5                     ; rm = 101 (RIP)
    jmp .mm_go_rm
.mm_go:
    mov cl, [rsi+17]
    and cl, 7                     ; rm = base&7
.mm_go_rm:
    mov al, [rsp+8]               ; mod bits
    mov dl, r10b
    and dl, 7
    shl dl, 3
    or al, dl
    or al, cl                     ; full ModRM
    mov [rsp+8], al
    mov dl, [rsp+10]              ; restore B in DL for ac_rex
    mov bl, [rsp+9]               ; W (lead count lives in R14B now)
    mov cl, r10b
    and cl, 8                     ; R = reg>=8
    mov r10b, r13b
    and r10b, 2                   ; force (0/2)
    mov r11b, r13b
    and r11b, 1                   ; legacy (0/1)
    call ac_rex
    jc .mm_out
    movzx ecx, r14b               ; lead bytes (0 for 1-byte opcodes,
    jrcxz .mm_lead_done           ; 2 for 0F-prefixed)
    push rax
    mov rax, r15                  ; low byte first
.mm_lead:
    call ac_outb
    jc .mm_lead_fail
    shr rax, 8
    dec ecx
    jnz .mm_lead
    pop rax
    jmp .mm_lead_done
.mm_lead_fail:
    pop rax
    jmp .mm_out
.mm_lead_done:
    mov al, [rsp+8]
    call ac_modrm
    jc .mm_out
    mov al, [rsp+8]               ; re-read mod bits for disp size
    shr al, 6
    cmp al, 1
    je .mm_d8
    cmp al, 2
    je .mm_d32
    mov al, [rsp+8]               ; mod=00: disp32 iff rm==101 (rel form)
    and al, 7
    cmp al, 5
    je .mm_d32_rel
    jmp .mm_ok
.mm_d8:
    mov rax, [rsp]
    call ac_outb                  ; low byte
    jc .mm_out
    jmp .mm_ok
.mm_d32:
    mov rax, [rsp]
    call ac_outd
    jc .mm_out
    jmp .mm_ok
.mm_d32_rel:
    cmp byte [rsi+28], 0          ; disp unknown?
    jne .mm_d32_rel_unk
    mov rax, [rel ac_outp]
    sub rax, [rsp+16]             ; bytes emitted so far
    add rax, 4                    ; next RIP offset from start of line
    add rax, [rel ac_lineoff]     ; absolute next RIP
    mov rcx, [rsi+20]             ; target address
    sub rcx, rax                  ; target - next_rip
    mov rax, rcx
    push rax
    call ac_fit32s
    pop rax
    jc .mm_range
    call ac_outd
    jc .mm_out
    jmp .mm_ok
.mm_d32_rel_unk:
    xor eax, eax
    call ac_outd
    jc .mm_out
    jmp .mm_ok
.mm_ok:
    clc
.mm_out:
    add rsp, 24
    pop r14
    pop r13
    pop r11
    pop r10
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.mm_sib:
    lea rdi, [rel ac_e_sib]
    call ac_error_msg
    stc
    jmp .mm_out
.mm_range:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
    stc
    jmp .mm_out
.mm_basecut:
    lea rdi, [rel ac_e_opds]      ; 16/32-bit base: address-size cut
    call ac_error_msg
    stc
    jmp .mm_out

; ---- mov ----
; ac_enc_mov. Forms: r8/r32/r64<-imm, r<-r, r8<-m8.
; Regs: R12D=dst size, R13=imm value, R14B=dst code, R15B=dst flags.
ac_enc_mov:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [rel ac_opcount], 2
    jne .mv_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 1             ; dst must be reg
    jne .mv_opds
    movzx r12d, byte [rsi+2]      ; dst size
    cmp r12d, 16
    je .mv_r16
    movzx eax, byte [rsi+1]
    mov r14b, al                  ; dst code
    movzx eax, byte [rsi+3]
    mov r15b, al                  ; dst flags
    lea rsi, [rel ac_op2]
    mov cl, [rsi]
    cmp cl, 2
    je .mv_imm
    cmp cl, 1
    je .mv_reg
    cmp cl, 3
    je .mv_mem
    jmp .mv_opds
.mv_imm:
    lea rsi, [rel ac_op2]
    cmp byte [rsi+17], 0          ; label ref in imm = absolute address
    jne .mv_abs
    lea rdi, [rel ac_op2unk]
    call ac_need_known            ; undefined-at-EMIT errors here (RSI=slot)
    jc .mv_out
    mov rax, [rsi+8]              ; value
    mov r13, rax                  ; stash (callee-saved across emits)
    cmp r12d, 8
    je .mv_i8
    cmp r12d, 32
    je .mv_i32
    mov rax, r13                  ; r64: fits-int32? C7 (7B, optimistic)
    call ac_fit32s                ; else B8 (10B, growth on resolve)
    jc .mv_i64full                ; doesn't fit int32: B8 imm64
    mov bl, 1                     ; W
    mov cl, r14b                  ; dcode
    xor dl, dl                    ; scode 0
    mov r10b, r15b                ; dflags
    xor r11b, r11b                ; sflags 0
    call ac_rex_for
    jc .mv_out
    mov al, 0xC7                  ; REX.W + C7 /0 id
    call ac_outb
    jc .mv_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    or al, dl                     ; mod=11 reg=000 rm=dst&7
    call ac_outb
    jc .mv_out
    mov rax, r13
    call ac_outd
    jc .mv_out
    jmp .mv_ok
.mv_i64full:
    mov bl, 1
    mov cl, r14b
    xor dl, dl
    mov r10b, r15b
    xor r11b, r11b
    call ac_rex_for
    jc .mv_out
    mov al, 0xB8
    mov dl, r14b
    call ac_out_opcode_r          ; B8+rd
    jc .mv_out
    mov rax, r13
    call ac_outq
    jc .mv_out
    jmp .mv_ok
.mv_i8:
    mov rax, r13
    call ac_fit_i8u
    jc .mv_range
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    mov r10b, r15b
    xor r11b, r11b
    call ac_rex_for
    jc .mv_out
    mov al, 0xB0
    mov dl, r14b
    call ac_out_opcode_r          ; B0+rb
    jc .mv_out
    mov rax, r13
    call ac_outb                  ; ib
    jc .mv_out
    jmp .mv_ok
.mv_i32:
    mov rax, r13
    call ac_fit_u32
    jc .mv_range
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    mov r10b, r15b
    xor r11b, r11b
    call ac_rex_for
    jc .mv_out
    mov al, 0xB8
    mov dl, r14b
    call ac_out_opcode_r          ; B8+rd
    jc .mv_out
    mov rax, r13
    call ac_outd
    jc .mv_out
    jmp .mv_ok
.mv_reg:
    lea rsi, [rel ac_op2]
    movzx eax, byte [rsi+2]       ; src size
    cmp eax, r12d
    jne .mv_opds                  ; size mismatch
    cmp r12d, 16
    je .mv_r16
    mov r13b, [rsi+1]             ; src code (R13 value-half dead here)
    mov bl, 0
    cmp r12d, 64
    jne .mv_reg_nw
    mov bl, 1                     ; W
.mv_reg_nw:
    mov cl, r14b                  ; dcode
    mov dl, r13b                  ; scode
    mov r10b, r15b                ; dflags
    mov r11b, [rsi+3]             ; sflags (RSI still op2: movzx spared it)
    call ac_rex_for
    jc .mv_out
    mov al, 0x8B
    cmp r12d, 8
    jne .mv_reg_op
    mov al, 0x8A
.mv_reg_op:
    call ac_outb
    jc .mv_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    shl dl, 3
    or al, dl
    mov dl, r13b
    and dl, 7
    or al, dl                     ; mod=11 reg=dst rm=src
    call ac_outb
    jc .mv_out
    jmp .mv_ok
.mv_mem:
    cmp r12d, 8                   ; mov r32,m32 cut (loads: r8/movzx only)
    jne .mv_opds
    lea rsi, [rel ac_op2]
    mov al, [rsi+19]              ; mem_sizekw
    cmp al, 1
    je .mv_mem_ok
    test al, al
    jnz .mv_opds                  ; explicit non-byte size: bad operands
.mv_mem_ok:
    mov bl, 0                     ; W=0
    mov r10b, r14b                ; regcode = dst
    mov r11b, r15b                ; dst legacy/force (base merged inside)
    mov r14b, 1                   ; lead carries the opcode byte
    mov r15w, 0x8A                ; (mov r8,m8)
    call ac_mem_emit
    jc .mv_out
    jmp .mv_ok
.mv_abs:
    lea rdi, [rel ac_e_abs]
    call ac_error_msg
    jmp .mv_out
.mv_range:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
    jmp .mv_out
.mv_r16:
    lea rdi, [rel ac_e_r16]
    call ac_error_msg
    jmp .mv_out
.mv_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.mv_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.mv_ok:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- movzx ----
; ac_enc_movzx. Forms: r32<-m8 (size keyword required), r32<-r8.
ac_enc_movzx:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [rel ac_opcount], 2
    jne .mz_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 1
    jne .mz_opds
    cmp byte [rsi+2], 32          ; dst must be 32-bit (r16/r64 cut)
    jne .mz_opds
    movzx r14d, byte [rsi+1]      ; dst code
    lea rbx, [rel ac_op2]
    cmp byte [rbx], 3
    je .mz_mem
    cmp byte [rbx], 1
    jne .mz_opds
    cmp byte [rbx+2], 8           ; src must be 8-bit
    jne .mz_opds
    mov bl, 0                     ; W=0
    mov cl, r14b                  ; dcode
    mov dl, [rbx+1]               ; scode
    mov r10b, 0                   ; dflags (32-bit: none possible)
    mov r11b, [rbx+3]             ; sflags
    call ac_rex_for
    jc .mz_out
    mov al, 0x0F                  ; 0F B6 /r
    call ac_outb
    jc .mz_out
    mov al, 0xB6
    call ac_outb
    jc .mz_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    shl dl, 3
    or al, dl
    mov dl, [rbx+1]
    and dl, 7
    or al, dl
    call ac_outb
    jc .mz_out
    jmp .mz_ok
.mz_mem:
    cmp byte [rbx+19], 1          ; size keyword must be `byte`
    jne .mz_opds
    mov bl, 0                     ; W=0
    mov r10b, r14b                ; regcode = dst (REX.R via mem_emit)
    xor r11b, r11b                ; dst 32-bit: no legacy/force possible
    mov r14b, 2                   ; lead = 0F B6 (low-first)
    mov r15w, 0xB60F
    mov rsi, rbx
    call ac_mem_emit
    jc .mz_out
    jmp .mz_ok
.mz_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.mz_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.mz_ok:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- lea ----
; ac_enc_lea. Form: r64<-mem (size keyword ignored).
ac_enc_lea:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [rel ac_opcount], 2
    jne .lea_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 1
    jne .lea_opds
    cmp byte [rsi+2], 64
    jne .lea_opds                  ; r32/r16 lea cut (documented)
    lea rsi, [rel ac_op2]
    cmp byte [rsi], 3
    jne .lea_opds
    mov bl, 1                     ; W
    mov r10b, [rel ac_op1+1]       ; regcode = dst (direct BSS read)
    mov r11b, [rel ac_op1+3]       ; dst flags
    mov r14b, 1
    mov r15w, 0x8D                ; lead = 8D
    call ac_mem_emit
    jc .lea_out
    jmp .lea_ok
.lea_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.lea_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.lea_ok:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- add/sub/cmp (shared core, R10B=/digit: add 0, sub 5, cmp 7) ----
; Regs: R15B=digit (saved first), R12D=dst size, R14B=dst code,
; R13=imm value (imm paths) / src code low (reg path, R13B).
; R10B/R11B/BL/CL/DL rebuilt per emission for ac_rex_for.
ac_enc_add:
    mov r10b, 0
    jmp ac_alu_core
ac_enc_sub:
    mov r10b, 5
    jmp ac_alu_core
ac_enc_cmp:
    mov r10b, 7
    jmp ac_alu_core
ac_alu_core:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15b, r10b                ; digit (safe: nothing else uses R15B yet)
    cmp dword [rel ac_opcount], 2
    jne .al_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 1
    jne .al_opds
    movzx r12d, byte [rsi+2]      ; dst size
    cmp r12d, 16
    je .al_r16
    movzx eax, byte [rsi+1]
    mov r14b, al                  ; dst code
    lea rbx, [rel ac_op2]
    cmp byte [rbx], 1
    je .al_reg
    cmp byte [rbx], 2
    je .al_imm
    jmp .al_opds
.al_reg:
    movzx eax, byte [rbx+2]       ; src size
    cmp eax, r12d
    jne .al_opds
    mov r13b, [rbx+1]             ; src code (value-half dead here)
    mov al, r15b
    shl al, 3                     ; base = 8*digit (00/28/38)
    cmp r12d, 8
    je .al_rr8
    inc al                        ; 01/29/39
.al_rr8:
    push rax                      ; stash opcode
    mov bl, 0
    cmp r12d, 64
    jne .al_rr_nw
    mov bl, 1
.al_rr_nw:
    mov cl, r14b                  ; dcode
    mov dl, r13b                  ; scode
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]             ; dflags
    lea rsi, [rel ac_op2]
    mov r11b, [rsi+3]             ; sflags
    call ac_rex_for
    jc .al_out_pop
    pop rax                       ; opcode
    push rax
    call ac_outb
    pop rax
    jc .al_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    shl dl, 3
    or al, dl
    mov dl, r13b
    and dl, 7
    or al, dl
    call ac_outb
    jc .al_out
    jmp .al_ok
.al_out_pop:
    add rsp, 8
    jmp .al_out
.al_imm:
    cmp byte [rbx+17], 0          ; label ref in imm = absolute address
    jne .al_abs
    lea rdi, [rel ac_op2unk]
    mov rsi, rbx
    call ac_need_known            ; undefined-at-EMIT errors here
    jc .al_out
    mov rax, [rbx+8]              ; value
    mov r13, rax                  ; stash (callee-saved across emits)
    cmp r12d, 8
    je .al_i8
    cmp r12d, 32
    je .al_i32
    cmp byte [rbx+16], 0          ; unknown at LENGTH: optimistic-small
    jne .al_i64small              ; (growth on resolve; corpus all-known)
    mov rax, r13                  ; r64: range u32 (id sign-extends)
    call ac_fit_u32
    jc .al_range
    mov rax, r13
    call ac_fit8
    jc .al_i64bigdecide           ; imm8 doesn't fit: acc iff rax else 81
    jmp .al_i64small              ; fits: 83 is always shortest for r64
.al_i64bigdecide:
    cmp r14b, 0                   ; acc? rax (code 0, flags 0)
    jne .al_i64big
    lea rsi, [rel ac_op1]
    cmp byte [rsi+3], 0
    jne .al_i64big
.al_i64acc:
    mov bl, 1                     ; REX.W + acc32 group (05+8*digit)
    xor cl, cl
    xor dl, dl
    xor r10b, r10b
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x05
    mov dl, r15b
    shl dl, 3
    or al, dl
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outd
    jc .al_out
    jmp .al_ok
.al_i64small:
    mov bl, 1
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x83                  ; REX.W + 83 /d ib
    call ac_outb
    jc .al_out
    mov al, 0xC0
    mov dl, r15b
    shl dl, 3
    or al, dl
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outb
    jc .al_out
    jmp .al_ok
.al_i64big:
    mov bl, 1
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x81                  ; REX.W + 81 /d id
    call ac_outb
    jc .al_out
    mov al, 0xC0
    mov dl, r15b
    shl dl, 3
    or al, dl
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outd
    jc .al_out
    jmp .al_ok
.al_i32:
    mov rax, r13
    call ac_fit_u32
    jc .al_range
    cmp byte [rbx+16], 0          ; unknown at LENGTH: optimistic-small
    jne .al_i32small
    mov rax, r13
    call ac_fit8
    jc .al_i32bigdecide           ; imm8 doesn't fit: acc iff eax else 81
    jmp .al_i32small              ; fits: 83 always shortest
.al_i32bigdecide:
    cmp r14b, 0                   ; acc? eax (code 0, flags 0)
    jne .al_i32big
    lea rsi, [rel ac_op1]
    cmp byte [rsi+3], 0
    jne .al_i32big
    mov bl, 0
    xor cl, cl
    xor dl, dl
    xor r10b, r10b
    xor r11b, r11b
    call ac_rex_for               ; (no-op rex, keeps pattern uniform)
    jc .al_out
    mov al, 0x05
    mov dl, r15b
    shl dl, 3
    or al, dl                     ; acc32 group (eax only: 5 bytes)
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outd
    jc .al_out
    jmp .al_ok
.al_i32small:
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x83
    call ac_outb
    jc .al_out
    mov al, 0xC0
    mov dl, r15b
    shl dl, 3
    or al, dl
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outb
    jc .al_out
    jmp .al_ok
.al_i32big:
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x81
    call ac_outb
    jc .al_out
    mov al, 0xC0
    mov dl, r15b
    shl dl, 3
    or al, dl
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outd
    jc .al_out
    jmp .al_ok
.al_i8:
    mov rax, r13
    call ac_fit_i8u
    jc .al_range
    cmp r14b, 0                   ; acc? al
    jne .al_i8gen
    lea rsi, [rel ac_op1]
    cmp byte [rsi+3], 0
    jne .al_i8gen
    mov bl, 0
    xor cl, cl
    xor dl, dl
    xor r10b, r10b
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x04
    mov dl, r15b
    shl dl, 3
    or al, dl                     ; acc8 group
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outb
    jc .al_out
    jmp .al_ok
.al_i8gen:
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .al_out
    mov al, 0x80                  ; 80 /d ib
    call ac_outb
    jc .al_out
    mov al, 0xC0
    mov dl, r15b
    shl dl, 3
    or al, dl
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .al_out
    mov rax, r13
    call ac_outb
    jc .al_out
    jmp .al_ok
.al_abs:
    lea rdi, [rel ac_e_abs]
    call ac_error_msg
    jmp .al_out
.al_range:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
    jmp .al_out
.al_r16:
    lea rdi, [rel ac_e_r16]
    call ac_error_msg
    jmp .al_out
.al_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.al_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.al_ok:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- test ----
; ac_enc_test. Forms: r,r (84/85) and r,imm (A8/A9/F6/F7, no imm8 form
; for 32/64: F7-id always, even for small values — x86 has no test r,i8).
ac_enc_test:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [rel ac_opcount], 2
    jne .tt_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 1
    jne .tt_opds
    movzx r12d, byte [rsi+2]
    cmp r12d, 16
    je .tt_r16
    movzx eax, byte [rsi+1]
    mov r14b, al
    movzx eax, byte [rsi+3]
    mov r15b, al
    lea rbx, [rel ac_op2]
    cmp byte [rbx], 1
    je .tt_reg
    cmp byte [rbx], 2
    je .tt_imm
    jmp .tt_opds
.tt_reg:
    movzx eax, byte [rbx+2]
    cmp eax, r12d
    jne .tt_opds
    cmp r12d, 16
    je .tt_r16
    mov r13b, [rbx+1]
    mov bl, 0
    cmp r12d, 64
    jne .tt_reg_nw
    mov bl, 1
.tt_reg_nw:
    mov cl, r14b
    mov dl, r13b
    mov r10b, r15b
    mov r11b, [rbx+3]
    call ac_rex_for
    jc .tt_out
    mov al, 0x85
    cmp r12d, 8
    jne .tt_reg_op
    mov al, 0x84
.tt_reg_op:
    call ac_outb
    jc .tt_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    shl dl, 3
    or al, dl
    mov dl, r13b
    and dl, 7
    or al, dl
    call ac_outb
    jc .tt_out
    jmp .tt_ok
.tt_imm:
    cmp byte [rbx+17], 0
    jne .tt_abs
    lea rdi, [rel ac_op2unk]
    mov rsi, rbx
    call ac_need_known
    jc .tt_out
    mov rax, [rbx+8]
    mov r13, rax
    cmp r12d, 8
    je .tt_i8
    cmp r12d, 32
    je .tt_i32
    mov rax, r13                  ; r64: u32 rule (id sign-extends)
    call ac_fit_u32
    jc .tt_range
    mov bl, 1                     ; REX.W + F7 /0 id (only form)
    mov cl, r14b
    xor dl, dl
    mov r10b, r15b
    xor r11b, r11b
    call ac_rex_for
    jc .tt_out
    mov al, 0xF7
    call ac_outb
    jc .tt_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    or al, dl                     ; mod=11 reg=000 rm=dst
    call ac_outb
    jc .tt_out
    mov rax, r13
    call ac_outd
    jc .tt_out
    jmp .tt_ok
.tt_i32:
    mov rax, r13
    call ac_fit_u32
    jc .tt_range
    cmp r14b, 0                   ; acc? eax (code 0, flags 0)
    jne .tt_i32gen
    lea rsi, [rel ac_op1]
    cmp byte [rsi+3], 0
    jne .tt_i32gen
    xor bl, bl
    xor cl, cl
    xor dl, dl
    xor r10b, r10b
    xor r11b, r11b
    call ac_rex_for
    jc .tt_out
    mov al, 0xA9                  ; A9 id (5B beats F7 6B)
    call ac_outb
    jc .tt_out
    mov rax, r13
    call ac_outd
    jc .tt_out
    jmp .tt_ok
.tt_i32gen:
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .tt_out
    mov al, 0xF7                  ; F7 /0 id (only form for r32-imm)
    call ac_outb
    jc .tt_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .tt_out
    mov rax, r13
    call ac_outd
    jc .tt_out
    jmp .tt_ok
.tt_i8:
    mov rax, r13
    call ac_fit_i8u
    jc .tt_range
    cmp r14b, 0                   ; acc? al
    jne .tt_i8gen
    lea rsi, [rel ac_op1]
    cmp byte [rsi+3], 0
    jne .tt_i8gen
    xor bl, bl
    xor cl, cl
    xor dl, dl
    xor r10b, r10b
    xor r11b, r11b
    call ac_rex_for
    jc .tt_out
    mov al, 0xA8                  ; A8 ib
    call ac_outb
    jc .tt_out
    mov rax, r13
    call ac_outb
    jc .tt_out
    jmp .tt_ok
.tt_i8gen:
    mov bl, 0
    mov cl, r14b
    xor dl, dl
    lea rsi, [rel ac_op1]
    mov r10b, [rsi+3]
    xor r11b, r11b
    call ac_rex_for
    jc .tt_out
    mov al, 0xF6                  ; F6 /0 ib
    call ac_outb
    jc .tt_out
    mov al, 0xC0
    mov dl, r14b
    and dl, 7
    or al, dl
    call ac_outb
    jc .tt_out
    mov rax, r13
    call ac_outb
    jc .tt_out
    jmp .tt_ok
.tt_abs:
    lea rdi, [rel ac_e_abs]
    call ac_error_msg
    jmp .tt_out
.tt_range:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
    jmp .tt_out
.tt_r16:
    lea rdi, [rel ac_e_r16]
    call ac_error_msg
    jmp .tt_out
.tt_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.tt_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.tt_ok:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- inc/dec (shared, R10B=/digit: inc 0, dec 1) ----
ac_enc_inc:
    mov r10b, 0
    jmp ac_incdec_core
ac_enc_dec:
    mov r10b, 1
    jmp ac_incdec_core
ac_incdec_core:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15b, r10b                ; digit
    cmp dword [rel ac_opcount], 1
    jne .id_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 1
    jne .id_opds
    movzx r12d, byte [rsi+2]
    cmp r12d, 16
    je .id_r16
    cmp r12d, 8
    je .id_ok_sz
    cmp r12d, 32
    je .id_ok_sz
    cmp r12d, 64
    jne .id_opds
.id_ok_sz:
    mov bl, 0
    cmp r12d, 64
    jne .id_nw
    mov bl, 1
.id_nw:
    movzx eax, byte [rsi+1]
    mov cl, al                    ; B via rex_for (scode unused: 0)
    xor dl, dl
    movzx eax, byte [rsi+3]
    mov r10b, al                  ; flags (legacy/force)
    xor r11b, r11b
    call ac_rex_for               ; (5-push frame: aligned, no pad needed)
    jc .id_out
    mov al, 0xFF                  ; FF /d
    call ac_outb
    jc .id_out
    mov al, 0xC0
    mov dl, r15b
    shl dl, 3
    or al, dl
    mov dl, [rsi+1]
    and dl, 7
    or al, dl                     ; mod=11 reg=digit rm=code
    call ac_outb
    jc .id_out
    jmp .id_ok
.id_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
    jmp .id_out
.id_r16:
    lea rdi, [rel ac_e_r16]
    call ac_error_msg
.id_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.id_ok:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- jmp/jcc/call ----
; ac_enc_jmp. Form: SYM (bare label only). Optimistic-short fixpoint.
ac_enc_jmp:
    push rbx
    push r12
    push r13
    cmp dword [rel ac_opcount], 1
    jne .jm_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 4
    jne .jm_opds                  ; number/whatever: bad operands
    call ac_sym_target            ; RAX=addr RDX=unk (name from slot)
    jc .jm_out
    test edx, edx
    jnz .jm_short_ph              ; unknown: short placeholder (growth later)
    mov rbx, [rel ac_lineoff]
    mov rcx, rax
    sub rcx, rbx
    sub rcx, 2                     ; rel assuming short
    mov rax, rcx
    call ac_fit8                  ; (preserves RCX)
    jc .jm_near
    mov al, 0xEB                  ; short: EB ib
    call ac_outb
    jc .jm_out
    mov rax, rcx
    call ac_outb
    jc .jm_out
    jmp .jm_ok
.jm_short_ph:
    mov al, 0xEB
    call ac_outb
    jc .jm_out
    xor eax, eax
    call ac_outb
    jc .jm_out
    jmp .jm_ok
.jm_near:
    mov rax, rcx                  ; (rel for len-2 basis; recompute for 5)
    add rax, 2
    sub rax, 5                    ; rel = target-(off+5)
    push rax
    mov al, 0xE9                  ; near: E9 id
    call ac_outb
    pop rax
    jc .jm_out
    call ac_outd
    jc .jm_out
    jmp .jm_ok
.jm_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.jm_out:
    pop r13
    pop r12
    pop rbx
    ret
.jm_ok:
    clc
    pop r13
    pop r12
    pop rbx
    ret

; ---- jcc (R10B=condition 0-15) ----
ac_enc_jcc:
    push rbx
    push r12
    push r13                      ; 3 pushes: aligned (cc lives in R13B)
    mov r13b, r10b                ; cc (R10B is scratch below)
    cmp dword [rel ac_opcount], 1
    jne .jc_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 4
    jne .jc_opds
    call ac_sym_target
    jc .jc_out
    test edx, edx
    jnz .jc_short_ph
    mov rbx, [rel ac_lineoff]
    mov rcx, rax
    sub rcx, rbx
    sub rcx, 2
    mov rax, rcx
    call ac_fit8                  ; (preserves RCX)
    jc .jc_near
    mov al, 0x70
    or al, r13b                   ; short: 70+cc ib
    call ac_outb
    jc .jc_out
    mov rax, rcx
    call ac_outb
    jc .jc_out
    jmp .jc_ok
.jc_short_ph:
    mov al, 0x70
    or al, r13b
    call ac_outb
    jc .jc_out
    xor eax, eax
    call ac_outb
    jc .jc_out
    jmp .jc_ok
.jc_near:
    mov rax, rcx
    add rax, 2
    sub rax, 6                    ; rel = target-(off+6)
    push rax
    mov al, 0x0F                  ; near: 0F 80+cc id
    call ac_outb
    pop rax
    jc .jc_out
    push rax
    mov al, 0x80
    or al, r13b
    call ac_outb
    pop rax
    jc .jc_out
    call ac_outd
    jc .jc_out
    jmp .jc_ok
.jc_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.jc_out:
    pop r13
    pop r12
    pop rbx
    ret
.jc_ok:
    clc
    pop r13
    pop r12
    pop rbx
    ret

; ---- call (rel32 always) ----
ac_enc_call:
    push rbx
    push r12
    push r13
    cmp dword [rel ac_opcount], 1
    jne .ca_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 4
    jne .ca_opds
    call ac_sym_target
    jc .ca_out
    test edx, edx
    jnz .ca_ph                    ; unknown: disp 0
    sub rax, [rel ac_lineoff]
    sub rax, 5                    ; rel = target-(off+5)
    jmp .ca_emit
.ca_ph:
    xor eax, eax
.ca_emit:
    push rax
    mov al, 0xE8
    call ac_outb
    pop rax
    jc .ca_out
    call ac_outd
    jc .ca_out
    jmp .ca_ok
.ca_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.ca_out:
    pop r13
    pop r12
    pop rbx
    ret
.ca_ok:
    clc
    pop r13
    pop r12
    pop rbx
    ret

; ---- ret/int/syscall/nop ----
ac_enc_ret:
    cmp dword [rel ac_opcount], 0
    jne .rt_opds
    mov al, 0xC3
    jmp ac_outb                   ; tail call (CF passes)
.rt_opds:
    lea rdi, [rel ac_e_opds]
    jmp ac_error_msg              ; tail call (ends STC per contract)
ac_enc_syscall:
    cmp dword [rel ac_opcount], 0
    jne .sc_opds
    mov al, 0x0F
    call ac_outb
    jc .sc_out
    mov al, 0x05
    jmp ac_outb
.sc_opds:
    lea rdi, [rel ac_e_opds]
    jmp ac_error_msg
.sc_out:
    ret                           ; CF already set
ac_enc_nop:
    cmp dword [rel ac_opcount], 0
    jne .np_opds
    mov al, 0x90
    jmp ac_outb
.np_opds:
    lea rdi, [rel ac_e_opds]
    jmp ac_error_msg
ac_enc_int:
    push rbx
    cmp dword [rel ac_opcount], 1
    jne .in_opds
    lea rsi, [rel ac_op1]
    cmp byte [rsi], 2             ; must be a number
    jne .in_opds
    cmp byte [rsi+17], 0          ; label in `int x`? absolute-ish: bad
    jne .in_abs
    cmp byte [rsi+16], 0          ; unknown?
    jne .in_unk
    mov rax, [rsi+8]
    cmp rax, 255
    ja .in_range
    push rax
    mov al, 0xCD
    call ac_outb
    pop rax
    jc .in_out
    call ac_outb                  ; ib = value low byte (range-checked ≤255)
    jc .in_out
    jmp .in_ok
.in_unk:
    lea rdi, [rel ac_op1unk]      ; LENGTH: placeholder; EMIT: undefined err
    call ac_need_known
    jc .in_out
    xor eax, eax
    push rax
    mov al, 0xCD
    call ac_outb
    pop rax
    jc .in_out
    call ac_outb
    jc .in_out
    jmp .in_ok
.in_abs:
    lea rdi, [rel ac_e_abs]
    call ac_error_msg
    jmp .in_out
.in_range:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
    jmp .in_out
.in_opds:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
.in_out:
    pop rbx
    ret
.in_ok:
    clc
    pop rbx
    ret

; ---- db/dw/dd/dq (R10B=size 1/2/4/8) ----
; ac_enc_data(RDI=cursor) -> RDI=after (EOL/comment), CF=1 err. Length via
; sink-delta (driver): ALWAYS emits size-correct bytes (real values, or 0
; for unknowns in LENGTH mode) — no count-only path. Range checks run in
; both modes (deterministic for known values); unknown at EMIT errors.
; Strings pack LE per unit with zero-pad (documented subset).
ac_enc_data:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    mov r15b, r10b                ; unit size
    xor r13d, r13d                ; items done (empty list -> error)
.dd_loop:
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    test cl, cl
    jz .dd_end
    cmp cl, ';'
    je .dd_end
    inc r13d
    cmp cl, "'"
    je .dd_str
    cmp cl, '"'
    je .dd_str
    ; expression item
    mov dword [rel ac_expr_label], 0
    call ac_expr                  ; RAX=val RDX=unk RDI=after
    jc .dd_exprerr
    cmp dword [rel ac_emit], 0
    je .dd_len_val                ; LENGTH: value-or-0, no undef error
    test edx, edx
    jz .dd_valknown
    mov rdx, [rel ac_unklen]      ; unknown at EMIT: undefined (inline:
    mov rsi, [rel ac_unkname]     ; pair still current — checked now)
    lea rdi, [rel ac_e_undef]
    call ac_error_sym
    jc .dd_out
.dd_valknown:
.dd_len_val:
    mov rbx, rax                  ; value (0 for unknowns in LENGTH)
    cmp r15b, 1
    je .dd_ck8
    cmp r15b, 2
    je .dd_ck16
    cmp r15b, 4
    je .dd_ck32
    jmp .dd_em64                  ; dq: any value
.dd_ck8:
    cmp rbx, 255
    ja .dd_ck8neg
    jmp .dd_em8
.dd_ck8neg:
    cmp rbx, -128
    jb .dd_range
    jmp .dd_em8
.dd_ck16:
    cmp rbx, 65535
    ja .dd_ck16neg
    jmp .dd_em16
.dd_ck16neg:
    cmp rbx, -32768
    jb .dd_range
    jmp .dd_em16
.dd_ck32:
    mov rax, rbx
    call ac_fit_u32
    jc .dd_range
    jmp .dd_em32
.dd_em8:
    mov rax, rbx
    call ac_outb
    jc .dd_out
    jmp .dd_after
.dd_em16:
    mov rax, rbx
    call ac_outw
    jc .dd_out
    jmp .dd_after
.dd_em32:
    mov rax, rbx
    call ac_outd
    jc .dd_out
    jmp .dd_after
.dd_em64:
    mov rax, rbx
    call ac_outq
    jc .dd_out
    jmp .dd_after
.dd_str:
    mov bl, cl                    ; quote char
    inc rdi
    xor r14d, r14d                ; unit accumulator
    xor ecx, ecx                  ; pos in unit
.dd_sloop:
    mov al, [rdi]
    test al, al
    jz .dd_strend                 ; NUL/EOL inside: unterminated -> error
    cmp al, 10
    je .dd_strend
    cmp al, bl
    jne .dd_schar
    cmp byte [rdi+1], bl
    je .dd_sesc
    inc rdi                       ; closing quote
    jmp .dd_sflush
.dd_sesc:
    mov al, bl                    ; doubled quote = literal quote char
    add rdi, 2
    jmp .dd_sacc
.dd_schar:
    inc rdi
.dd_sacc:
    push rax                      ; accumulate AL into unit (LE)
    push rcx
    push rdx
    movzx eax, al
    mov edx, ecx
    shl edx, 3
    mov ecx, edx
    shl rax, cl
    or r14, rax
    pop rdx
    pop rcx
    pop rax
    inc ecx
    cmp cl, r15b
    jb .dd_sloop
    call .dd_flush_unit           ; unit full
    jc .dd_out
    xor r14d, r14d
    xor ecx, ecx
    jmp .dd_sloop
.dd_strend:
    lea rdi, [rel ac_e_syntax]    ; unterminated string
    call ac_error_msg
    jmp .dd_out
.dd_sflush:
    test ecx, ecx                 ; partial unit? pad (acc has zeros above)
    jz .dd_after
    call .dd_flush_unit
    jc .dd_out
    jmp .dd_after
.dd_flush_unit:
    ; emit R14 as one R15B-sized unit, LE. (Both modes: LENGTH emits too —
    ; sink is 512B scratch there, lines fit.)
    push rdx                      ; 1 push: aligned (dummy preserve)
    movzx ecx, r15b
    mov rax, r14
.dd_fu_loop:
    call ac_outb
    jc .dd_fu_out
    shr rax, 8
    dec ecx
    jnz .dd_fu_loop
    clc
.dd_fu_out:
    pop rdx
    ret
.dd_after:
    call ac_skip_ws
    mov rdi, rax
    cmp byte [rdi], ','
    jne .dd_end
    inc rdi
    jmp .dd_loop
.dd_end:
    test r13d, r13d               ; empty list (`db` alone)?
    jz .dd_empty
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.dd_empty:
    lea rdi, [rel ac_e_opds]
    call ac_error_msg
    jmp .dd_out
.dd_exprerr:
    cmp eax, 1
    je .dd_div0
    lea rdi, [rel ac_e_expr]
    call ac_error_msg
    jmp .dd_out
.dd_div0:
    lea rdi, [rel ac_e_div0]
    call ac_error_msg
    jmp .dd_out
.dd_range:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
.dd_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret