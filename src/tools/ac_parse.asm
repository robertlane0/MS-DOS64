; ASM64 tokenizer, symbol/define tables, expression evaluator (N4B.2).
; %included by asm64_core.asm. Conventions: RDI=cursor-ish inputs,
; RAX=value/out, CF=1 hard error (syntax/range), RDX=unknown-flag where
; noted (unknown is NOT an error mid-pass). Callee-saved preserved by
; every function (push-all discipline); volatiles are scratch.

section .text

; ac_is_ident0(AL=c) -> ZF=1 if valid first char [A-Za-z_.?]. Leaf.
; Preserves RAX/RBX/RCX; clobbers RDX, flags.
ac_is_ident0:
    cmp al, 'A'
    jb .ii_dot
    cmp al, 'Z'
    jbe .ii_yes
    cmp al, 'a'
    jb .ii_no
    cmp al, 'z'
    jbe .ii_yes
    jmp .ii_no
.ii_dot:
    cmp al, '.'
    je .ii_yes
    cmp al, '_'
    je .ii_yes
    cmp al, '?'
    je .ii_yes
    jmp .ii_no
.ii_yes:
    xor edx, edx
    test edx, edx                 ; ZF=1, AL preserved
    ret
.ii_no:
    xor edx, edx
    inc edx
    test edx, edx                 ; ZF=0, AL preserved
    ret

; ac_is_ident(AL=c) -> ZF=1 if valid continuation [A-Za-z0-9_.?$#].
; Same preservation contract.
ac_is_ident:
    push rbx
    mov bl, al
    call ac_is_ident0
    jz .ii2_yes
    mov al, bl
    cmp al, '0'
    jb .ii2_no
    cmp al, '9'
    jbe .ii2_yes
    cmp al, '$'
    je .ii2_yes
    cmp al, '#'
    jne .ii2_no
.ii2_yes:
    pop rbx
    xor edx, edx
    test edx, edx
    ret
.ii2_no:
    pop rbx
    xor edx, edx
    inc edx
    test edx, edx
    ret

; ac_skip_ws(RDI=cursor) -> RAX=cursor past spaces/tabs.
ac_skip_ws:
    mov rax, rdi
.sw_loop:
    mov cl, [rax]
    cmp cl, ' '
    je .sw_adv
    cmp cl, 9
    jne .sw_done
.sw_adv:
    inc rax
    jmp .sw_loop
.sw_done:
    ret

; ac_lower(AL) -> AL lowercased (ASCII letters only).
ac_lower:
    cmp al, 'A'
    jb .lo_done
    cmp al, 'Z'
    ja .lo_done
    or al, 0x20
.lo_done:
    ret

; ac_streicn(RDI=a, RSI=b, RDX=len) -> ZF=1 if equal case-insensitively.
ac_streicn:
    push rbx
    push rcx
    push rdx
    mov rcx, rdx
    test rcx, rcx
    jz .se_yes                    ; zero length: equal
.se_loop:
    mov al, [rdi]
    mov bl, [rsi]
    call ac_lower                 ; AL lowered (BL untouched: lower uses AL)
    xchg al, bl                   ; lower BL too via swap trick
    call ac_lower
    xchg al, bl                   ; AL=a-lowered, BL=b-lowered
    cmp al, bl
    jne .se_no
    inc rdi
    inc rsi
    dec rcx
    jnz .se_loop
.se_yes:
    pop rdx
    pop rcx
    pop rbx
    xor eax, eax
    ret
.se_no:
    pop rdx
    pop rcx
    pop rbx
    mov eax, 1
    test eax, eax
    ret

; ac_streq(RDI=a, RSI=b, RDX=len) -> ZF=1 if exactly equal (case-SENSITIVE).
ac_streq:
    push rbx
    push rcx
    push rdx
    mov rcx, rdx
    test rcx, rcx
    jz .sq_yes
.sq_loop:
    mov al, [rdi]
    cmp al, [rsi]
    jne .sq_no
    inc rdi
    inc rsi
    dec rcx
    jnz .sq_loop
.sq_yes:
    pop rdx
    pop rcx
    pop rbx
    xor eax, eax
    ret
.sq_no:
    pop rdx
    pop rcx
    pop rbx
    mov eax, 1
    test eax, eax
    ret

; ac_reg_lookup(RDI=name, RSI=len) -> RAX=code, RCX=size, RDX=flags, CF=0;
;   CF=1 + RAX=0 on miss. (len must equal the table name incl NUL? table
;   names are NUL-padded to 6: compare len bytes + require table[len]==0.)
global ac_reg_lookup_TMPFORTEST
global ac_reg_lookup
ac_reg_lookup_TMPFORTEST:
ac_reg_lookup:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: (8-40)%16==0, call-safe
    lea r12, [rel ac_regtab]
    mov r13d, AC_NREG
    mov r14, rsi                  ; len (callee-saved across table walk)
    mov rbx, rdi
.rl_loop:
    test r13d, r13d
    jz .rl_miss
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call ac_streicn
    jnz .rl_next
    cmp byte [r12 + r14], 0       ; table name ends where input ends
    jne .rl_next
    movzx eax, byte [r12 + 6]
    movzx ecx, byte [r12 + 7]
    movzx edx, byte [r12 + 8]
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.rl_next:
    add r12, AC_REG_ENT
    dec r13d
    jmp .rl_loop
.rl_miss:
    stc
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ac_cc_lookup(RDI=name, RSI=len) -> RAX=cc, CF=0; CF=1 + RAX=0 on miss.
ac_cc_lookup:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    lea r12, [rel ac_cctab]
    mov r13d, AC_NCC
    mov r14, rsi
    mov rbx, rdi
.cl_loop:
    test r13d, r13d
    jz .cl_miss
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call ac_streicn
    jnz .cl_next
    cmp byte [r12 + r14], 0
    jne .cl_next
    movzx eax, byte [r12 + 5]
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.cl_next:
    add r12, AC_CC_ENT
    dec r13d
    jmp .cl_loop
.cl_miss:
    stc
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ac_sym_find(RDI=name, RSI=len) -> RAX=entry / 0. Entry: name[32] +
;   addr qword @32 + flags @40 (bit0 defined, bit1 const, bit2 touched).
;   Case-SENSITIVE (NASM default). Leaf-ish (calls streq only).
ac_sym_find:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    cmp rsi, 32
    ja .sf_miss                   ; overlong can never match (stored ≤32)
    mov r12, rdi                  ; name
    mov r13, rsi                  ; len
    lea rbx, [rel ac_symtab]
    mov ecx, [rel ac_symcount]
.sf_loop:
    test ecx, ecx
    jz .sf_miss
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call ac_streq
    jnz .sf_next
    cmp byte [rbx + r13], 0       ; stored name ends here too
    jne .sf_next
    mov rax, rbx
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.sf_next:
    add rbx, AC_SYM_ENT
    dec ecx
    jmp .sf_loop
.sf_miss:
    xor eax, eax
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ac_sym_get(RDI=name, RSI=len) -> RAX=entry (adds if absent), CF=1 if the
;   table is full or the name exceeds 31 chars. New entries start blank
;   (undefined, untouched).
ac_sym_get:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    sub rsp, 8                    ; 8 pushes + 8 = 72: aligned
    mov r12, rdi
    mov r13, rsi
    call ac_sym_find              ; (saves/restores our pushes: balanced)
    test rax, rax
    jnz .sg_hit
    cmp r13, 32
    jae .sg_full                  ; 31 chars + NUL max
    mov eax, [rel ac_symcount]
    cmp eax, AC_MAXSYM
    jae .sg_full
    lea rbx, [rel ac_symtab]
    imul rcx, rax, AC_SYM_ENT
    add rbx, rcx                  ; new entry
    mov rdi, rbx                  ; zero name+addr+flags (fresh slot may
    xor eax, eax                  ; hold garbage: flat image has no BSS!)
    mov ecx, AC_SYM_ENT / 8
.sg_zero:
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .sg_zero
    mov rdi, rbx                  ; dst = entry (NOT the name!)
    mov rsi, r12                  ; src = name
    mov rcx, r13                  ; len
    cld
    rep movsb
    mov rax, rbx
    inc dword [rel ac_symcount]
.sg_hit:
    clc
    mov r14, rax
    mov rax, r14
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.sg_full:
    stc
    xor eax, eax
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ac_sym_def(RDI=name, RSI=len, RDX=addr, ECX=is_const) -> CF=1 on
;   duplicate (already touched this pass) or table full. Sets defined +
;   touched + value. (Labels call with is_const=0; equ with 1.)
ac_sym_def:
    push rbx
    push r12
    push r14                      ; 3 pushes: aligned (r14 dummy)
    call ac_sym_get               ; RAX=entry (CF=full propagates below)
    jc .sd_full
    mov rbx, rax
    test byte [rbx + AC_SYM_FLAGS], AC_SF_TOUCHED
    jnz .sd_dupe
    mov [rbx + AC_SYM_ADDR], rdx
    mov al, AC_SF_DEFINED | AC_SF_TOUCHED
    test ecx, ecx
    jz .sd_noconst
    or al, AC_SF_CONST
.sd_noconst:
    mov [rbx + AC_SYM_FLAGS], al
    clc
    pop r14
    pop r12
    pop rbx
    ret
.sd_dupe:
    pop r14
    pop r12
    pop rbx
    stc                           ; caller maps to "duplicate symbol"
    ret
.sd_full:
    pop r14
    pop r12
    pop rbx
    stc                           ; caller maps to "too many symbols"
    ret

; ac_def_find(RDI=name, RSI=len) -> RAX=value-entry / 0. Entry: name[32]
;   + value[96] @32. Case-SENSITIVE.
ac_def_find:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    cmp rsi, 32
    ja .df_miss
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rel ac_deftab]
    mov ecx, [rel ac_defcount]
.df_loop:
    test ecx, ecx
    jz .df_miss
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call ac_streq
    jnz .df_next
    cmp byte [rbx + r13], 0
    jne .df_next
    mov rax, rbx
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.df_next:
    add rbx, AC_DEF_ENT
    dec ecx
    jmp .df_loop
.df_miss:
    xor eax, eax
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ac_def_add(RDI=name, RSI=name_len, RDX=value, RCX=value_len) -> CF=1 if
;   full (replace existing silently — NASM allows %define redefinition).
ac_def_add:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    call ac_def_find
    test rax, rax
    jnz .da_replace               ; redefine: overwrite value in place
    cmp r13, 32
    jae .da_full
    cmp r15, 96
    jae .da_full                  ; value must fit + NUL
    mov eax, [rel ac_defcount]
    cmp eax, AC_MAXDEF
    jae .da_full
    lea rbx, [rel ac_deftab]
    imul rcx, rax, AC_DEF_ENT
    add rbx, rcx
    inc dword [rel ac_defcount]
    jmp .da_store
.da_replace:
    mov rbx, rax
.da_store:
    push rbx                      ; zero the whole slot first (stale replace)
    mov rdi, rbx
    xor eax, eax
    mov ecx, AC_DEF_ENT / 8
.da_zero:
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .da_zero
    pop rbx
    mov rdi, rbx                  ; name
    mov rsi, r12
    mov rcx, r13
    cld
    rep movsb
    lea rdi, [rbx + 32]           ; value
    mov rsi, r14
    mov rcx, r15
    cld
    rep movsb
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.da_full:
    stc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ac_parse_number(RDI=cursor) -> RAX=value, RDI=after, CF=1 on garbage.
;   Forms: 0xHEX+, decimal digits, 'c' char literal. Trailing alnum fails.
ac_parse_number:
    push rbx
    push rcx
    push rdx                      ; 3 pushes: aligned (dummy preserve)
    mov al, [rdi]
    cmp al, "'"
    je .pn_char
    cmp al, '0'
    jne .pn_dec_chk
    cmp byte [rdi+1], 'x'
    je .pn_hex
    cmp byte [rdi+1], 'X'
    je .pn_hex
    jmp .pn_dec
.pn_dec_chk:
    cmp al, '0'
    jb .pn_bad
    cmp al, '9'
    ja .pn_bad
.pn_dec:
    xor eax, eax
    xor ecx, ecx                  ; digit count
.pn_dloop:
    mov cl, [rdi]
    cmp cl, '0'
    jb .pn_dend
    cmp cl, '9'
    ja .pn_dend
    imul rax, rax, 10             ; (wraps mod 2^64; jc ignored: lengths
    movzx ecx, cl                 ; of real programs never approach it)
    sub ecx, '0'
    add rax, rcx
    inc rdi
    jmp .pn_dloop
.pn_dend:
    push rax
    mov al, [rdi]                 ; trailing alnum (not x/X — hex handled)?
    call ac_is_ident              ; letters after digits = bad number... but
    pop rax
    jz .pn_bad                    ; careful: "10h"? h-suffix UNSUPPORTED, so
    clc                           ; "10h" IS an error here. Correct per spec.
    pop rdx
    pop rcx
    pop rbx
    ret
.pn_hex:
    add rdi, 2
    xor eax, eax
    xor ecx, ecx
    xor edx, edx                  ; digit count (RDX free here: factor sets it)
.pn_hloop:
    mov cl, [rdi]
    cmp cl, '0'
    jb .pn_hend
    cmp cl, '9'
    jbe .pn_hdig
    mov bl, cl
    call ac_lower_x               ; BL lowered (helper below: uses BL only)
    mov cl, bl
    cmp cl, 'a'
    jb .pn_hend
    cmp cl, 'f'
    ja .pn_hend
    sub cl, 'a' - 10
    jmp .pn_hacc
.pn_hdig:
    sub cl, '0'
.pn_hacc:
    shl rax, 4
    movzx ecx, cl
    add rax, rcx
    inc edx                       ; (does not touch CF? INC preserves CF ✓)
    inc rdi
    jmp .pn_hloop
.pn_hend:
    test edx, edx                 ; `0x` with no digits is garbage
    jz .pn_bad
    push rax
    mov al, [rdi]
    call ac_is_ident
    pop rax
    jz .pn_bad
    clc
    pop rdx
    pop rcx
    pop rbx
    ret
.pn_char:
    mov al, [rdi+1]
    test al, al
    jz .pn_bad
    cmp byte [rdi+2], "'"
    jne .pn_bad                   ; exactly one char between quotes
    movzx eax, al
    add rdi, 3
    clc
    pop rdx
    pop rcx
    pop rbx
    ret
.pn_bad:
    stc
    pop rdx
    pop rcx
    pop rbx
    ret

; ac_lower_x — ac_lower for BL (AL-preserving): BL=lower(BL).
ac_lower_x:
    cmp bl, 'A'
    jb .lx_done
    cmp bl, 'Z'
    ja .lx_done
    or bl, 0x20
.lx_done:
    ret

; ac_parse_ident(RDI=cursor) -> RAX=start, RCX=len, RDI=after, CF=1 if
;   no identifier here. First char [A-Za-z_.?], rest +[0-9$#].
ac_parse_ident:
    push rbx                      ; 1 push: (8-8)%16==0 (calls ident fns)
    mov al, [rdi]
    call ac_is_ident0
    jnz .pi_bad
    mov rbx, rdi                  ; start in RBX (AL writes below would
    inc rdi                       ; clobber RAX's low byte!)
.pi_loop:
    mov al, [rdi]                 ; (predicates preserve AL)
    call ac_is_ident
    jnz .pi_done
    inc rdi
    jmp .pi_loop
.pi_done:
    mov rax, rbx                  ; start
    mov rcx, rdi
    sub rcx, rax                  ; len
    clc
    pop rbx
    ret
.pi_bad:
    stc
    pop rbx
    ret

; ac_expr(RDI=cursor) -> RAX=value, RDX=unknown(0/1), RDI=after, CF=1 on
;   error (RAX=0 syntax, RAX=1 division by zero). Unknown symbols are NOT
;   errors: RDX=1, value 0. Trailing whitespace is consumed.
;   Grammar: expr := term ((+|-) term)*.
ac_expr:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call ac_expr_term
    jc .ex_bad
    mov r12, rax                  ; acc value
    mov r13, rdx                  ; acc unknown
.ex_loop:
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    cmp cl, '+'
    je .ex_add
    cmp cl, '-'
    jne .ex_done
    inc rdi
    call ac_expr_term
    jc .ex_bad
    or r13, rdx
    sub r12, rax
    jmp .ex_loop
.ex_add:
    inc rdi
    call ac_expr_term
    jc .ex_bad
    or r13, rdx
    add r12, rax
    jmp .ex_loop
.ex_done:
    mov rax, r12
    mov rdx, r13
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.ex_bad:                          ; RAX already = error class from term
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret                           ; CF=1 preserved (pops don't touch flags)

; ac_expr_term(RDI=cursor) -> same contract. term := factor ((*|/) factor)*.
ac_expr_term:
    push rbx
    push r12
    push r13
    call ac_expr_factor
    jc .et_bad
    mov r12, rax
    mov r13, rdx
.et_loop:
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    cmp cl, '*'
    je .et_mul
    cmp cl, '/'
    jne .et_done
    inc rdi
    call ac_expr_factor
    jc .et_bad
    test rdx, rdx                 ; rhs unknown: result unknown, skip div
    jnz .et_unkdiv
    test rax, rax                 ; rhs known zero: DIVISION BY ZERO
    jz .et_div0
    or r13, rdx
    mov rbx, rax
    mov rax, r12
    xor edx, edx                  ; 64/64: RDX must be 0 (negatives wrap)
    div rbx
    mov r12, rax
    jmp .et_loop
.et_unkdiv:
    or r13, rdx                   ; (rdx=1 here)
    mov r12, 0
    jmp .et_loop
.et_mul:
    inc rdi
    call ac_expr_factor
    jc .et_bad
    or r13, rdx
    imul r12, rax                 ; wraps mod 2^64
    jmp .et_loop
.et_done:
    mov rax, r12
    mov rdx, r13
    clc
    pop r13
    pop r12
    pop rbx
    ret
.et_div0:
    mov eax, 1                    ; class 1 = division by zero
    stc
    pop r13
    pop r12
    pop rbx
    ret
.et_bad:                          ; class already in RAX (0 syntax / 1 div0)
    pop r13
    pop r12
    pop rbx
    ret

; ac_expr_factor(RDI=cursor) -> same contract.
;   factor := number | ident | '(' expr ')' | '-' factor | '+' factor.
ac_expr_factor:
    push rbx
    push r12
    push r14                      ; 3 pushes: aligned (r14 dummy)
    call ac_skip_ws
    mov rdi, rax
    mov cl, [rdi]
    cmp cl, '('
    je .ef_paren
    cmp cl, '-'
    je .ef_neg
    cmp cl, '+'
    je .ef_pos
    cmp cl, "'"
    je .ef_num
    cmp cl, '0'
    jb .ef_ident_chk
    cmp cl, '9'
    jbe .ef_num
.ef_ident_chk:
    mov al, cl
    call ac_is_ident0
    jnz .ef_bad
    call ac_parse_ident           ; RAX=start, RCX=len, RDI=after
    mov r12, rax                  ; (callee-saved: survive sym_find)
    mov rbx, rcx
    mov rdi, rax
    mov rsi, rcx
    call ac_sym_find              ; preserves all but RAX
    test rax, rax
    jz .ef_miss                   ; never defined (forward or typo)
    test byte [rax + AC_SYM_FLAGS], AC_SF_DEFINED
    jz .ef_miss                   ; seen but value unknown yet
    test byte [rax + AC_SYM_FLAGS], AC_SF_CONST
    jnz .ef_value                  ; constants never set the label flag
    mov dword [rel ac_expr_label], 1  ; address label in value context
.ef_value:
    mov rdi, r12
    add rdi, rbx                  ; cursor past the name
    mov rax, [rax + AC_SYM_ADDR]  ; const and address are both just values
    xor edx, edx
    pop r14
    pop r12
    pop rbx
    clc
    ret
.ef_miss:
    mov [rel ac_unkname], r12     ; record for "undefined symbol 'X'"
    mov [rel ac_unklen], rbx
.ef_unknown:
    mov rdi, r12
    add rdi, rbx                  ; cursor past the name
    xor eax, eax
    mov edx, 1
    pop r14
    pop r12
    pop rbx
    clc
    ret
.ef_paren:
    inc rdi
    call ac_expr
    jc .ef_bad2                   ; class in RAX already
    mov rbx, rax
    mov r12, rdx
    call ac_skip_ws
    mov rdi, rax
    cmp byte [rdi], ')'
    jne .ef_bad
    inc rdi
    mov rax, rbx
    mov rdx, r12
    pop r14
    pop r12
    pop rbx
    clc
    ret
.ef_neg:
    inc rdi
    call ac_expr_factor
    jc .ef_bad2
    neg rax                       ; unknown-0 stays 0, flag preserved in RDX
    clc                           ; (NEG sets CF — contract needs CF=0 here)
    pop r14
    pop r12
    pop rbx
    ret
.ef_pos:
    inc rdi
    call ac_expr_factor           ; tail: result passes through
    pop r14
    pop r12
    pop rbx
    ret
.ef_num:
    call ac_parse_number          ; CF=1 bad number (class 0: RAX undefined)
    jc .ef_badnum
    xor edx, edx
    pop r14
    pop r12
    pop rbx
    clc
    ret
.ef_badnum:
    xor eax, eax                  ; class 0 = syntax
    stc
    pop r14
    pop r12
    pop rbx
    ret
.ef_bad:
    xor eax, eax
.ef_bad2:
    stc
    pop r14
    pop r12
    pop rbx
    ret
