; ASM64 core root (N4B.2): pure two-pass assemble-buffer function.
; %includes tables/parse/encode (single TU for both -f bin via main and
; -f elf64 for kernel/host-test builds — no ifdefs: section .bss + resb
; is bin-clean (dropped) and the tables self-zero per call anyway).
; Assemble with: nasm -f elf64 src/tools/asm64_core.asm (test/kernel) or
; via %%include from src/tools/asm64_main.asm (nasm -f bin, tool).
; Design: re-scan lines every pass (no AST storage); lengths monotonic
; non-decreasing (optimistic-short jumps/disp/imm, exact growth on
; resolve) so total-length + defined-count stability = convergence
; (bounded 16 passes). Unknowns assume shortest; emit re-evaluates
; fresh and errors honestly. Single-shot per call (globals reset).

; Layout constants FIRST (%define is single-pass: must precede use in
; the included parts below).
%define AC_MAXSYM 256
%define AC_SYM_ENT 48
%define AC_SYM_ADDR 32
%define AC_SYM_FLAGS 40
%define AC_SF_DEFINED 1
%define AC_SF_CONST 2
%define AC_SF_TOUCHED 4
%define AC_MAXDEF 32
%define AC_DEF_ENT 128
%define AC_MAXPASS 16
%define AC_LINEBUF 512
%define AC_ERRBUF 256

%include "src/tools/ac_tables.asm"
%include "src/tools/ac_parse.asm"
%include "src/tools/ac_enc.asm"

default rel

global asm64_assemble

section .bss
ac_symtab:  resb 256*48
ac_symcount: resq 1
ac_deftab:  resb 32*128
ac_defcount: resq 1
ac_linebuf: resb 512
ac_errbuf:  resb 256
ac_scratch: resb 512                  ; LENGTH-mode sink (lines fit: ≤255B)
ac_op1:     resb 32
ac_op2:     resb 32
ac_op1unk:  resq 2
ac_op2unk:  resq 2
ac_unkname: resq 1
ac_unklen:  resq 1
ac_outp:    resq 1
ac_outleft: resq 1
ac_listp:   resq 1
ac_listleft: resq 1
ac_offset:  resq 1
ac_lineoff: resq 1
ac_lineno:  resq 1
ac_emit:    resd 1
ac_opcount: resd 1
ac_errflag: resd 1
ac_errmsg:  resq 1
ac_errname: resq 1
ac_errnamelen: resq 1
ac_expr_label: resd 1
ac_src:     resq 1
ac_srclen:  resq 1
ac_out:     resq 1
ac_outcap:  resq 1
ac_list:    resq 1
ac_listcap: resq 1
ac_err:     resq 1
ac_errcap:  resq 1
ac_prevlen: resq 1
ac_prevdef: resq 1
ac_prep_after: resq 1             ; prep: after-line cursor (expansion clobbers
ac_sublvl:  resd 1               ; >0 inside times bodies (no listing)
ac_liston:  resd 1                    ; listing enabled (list+cap given)

section .text

; ac_error_msg(RDI=msg): first-error-wins; ends STC. Preserves all but RAX.
ac_error_msg:
    push rax
    cmp dword [rel ac_errflag], 0
    jne .em_set
    mov [rel ac_errmsg], rdi
    mov qword [rel ac_errname], 0
    mov dword [rel ac_errflag], 1
.em_set:
    pop rax
    stc
    ret

; ac_error_sym(RDI=msg, RSI=name, RDX=len): same + name. Preserves all.
ac_error_sym:
    push rax
    cmp dword [rel ac_errflag], 0
    jne .es_set
    mov [rel ac_errmsg], rdi
    mov [rel ac_errname], rsi
    mov [rel ac_errnamelen], rdx
    mov dword [rel ac_errflag], 1
.es_set:
    pop rax
    stc
    ret

; ac_error_finalize: compose "LINE: msg ['name']\0" into errbuf (capped).
ac_error_finalize:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, [rel ac_err]         ; dst cursor
    mov r12, [rel ac_errcap]      ; cap
    test rbx, rbx
    jz .eff_done
    test r12, r12
    jz .eff_done
    dec r12                       ; reserve the NUL
    jz .eff_nul                   ; cap was 1: NUL only
    sub rsp, 24                   ; itoa scratch
    mov rax, [rel ac_lineno]
    lea r14, [rsp+24]             ; digits end (exclusive)
    test rax, rax
    jnz .eff_dloop
    dec r14
    mov byte [r14], '0'
    jmp .eff_numdone
.eff_dloop:
    test rax, rax
    jz .eff_numdone
    xor edx, edx
    mov ecx, 10
    div rcx                       ; RAX=quot, RDX=rem
    add dl, '0'
    dec r14
    mov [r14], dl
    jmp .eff_dloop
.eff_numdone:
    lea r15, [rsp+24]
    sub r15, r14                  ; numlen
    mov rsi, r14
    mov rcx, r15
    call .eff_puts
    mov al, ':'
    call .eff_putc
    mov al, ' '
    call .eff_putc
    mov rsi, [rel ac_errmsg]
    call .eff_putz
    cmp qword [rel ac_errname], 0
    je .eff_noname
    mov al, ' '
    call .eff_putc
    mov al, "'"
    call .eff_putc
    mov rsi, [rel ac_errname]
    mov rcx, [rel ac_errnamelen]
    call .eff_puts
    mov al, "'"
    call .eff_putc
.eff_noname:
    add rsp, 24
.eff_nul:
    mov byte [rbx], 0
.eff_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.eff_putc:                        ; AL=char (drops past cap; preserves RAX)
    push rax
    test r12, r12
    jz .eff_pc_full
    mov [rbx], al
    inc rbx
    dec r12
.eff_pc_full:
    pop rax
    ret
.eff_puts:                        ; RSI=str, RCX=len
    test rcx, rcx
    jz .eff_ps_done
.eff_ps_loop:
    mov al, [rsi]                 ; (no pushes: putc preserves RAX/RCX/RSI,
    call .eff_putc                ; frame-only outstanding stays aligned)
    inc rsi
    dec rcx
    jnz .eff_ps_loop
.eff_ps_done:
    ret
.eff_putz:                        ; RSI=NUL string
    push rax
    push rsi
.pz_loop:
    mov al, [rsi]
    test al, al
    jz .pz_done
    call .eff_putc
    inc rsi
    jmp .pz_loop
.pz_done:
    pop rsi
    pop rax
    ret

; ac_process_line: parse+encode one expanded line (linebuf, NUL-term).
; Uses ac_lineno (for errors), ac_offset in/out, sink globals, ac_emit.
; CF=1 error (recorded). Callee-saved preserved.
; RBX = cursor in/out, RAX = bytes this line, listing at sublevel 0 only.
ac_process_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, [rel ac_outp]            ; sink snapshot (listing + len)
.pl_top:
    mov rdi, rbx
    call ac_skip_ws
    mov rbx, rax
    mov cl, [rbx]
    test cl, cl
    jz .pl_eol_len0                   ; EOL (label-only lines land here)
    cmp cl, ';'
    je .pl_eol_len0                   ; (pre-stripped; paranoia)
    cmp cl, '%'
    je .pl_percent
    mov rdi, rbx
    call ac_parse_ident               ; RAX=start RCX=len RDI=after / CF
    jc .pl_syntax
    mov r12, rax                      ; ident start
    mov r13, rcx                      ; ident len
    mov r14, rdi                      ; after-ident
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    cmp byte [rdi], ':'
    je .pl_label
    jmp .pl_after_label
.pl_eol_len0:
    xor eax, eax                      ; len 0 (sink untouched: delta 0 anyway)
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.pl_label:
    mov rbx, rdi
    inc rbx                           ; after ':'
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rel ac_offset]
    xor ecx, ecx                      ; non-const (address label)
    call ac_sym_def
    jc .pl_defmap
    jmp .pl_top                       ; loop (labels add 0)
.pl_defmap:
    mov eax, [rel ac_symcount]
    cmp eax, AC_MAXSYM
    jae .pl_symfull
    lea rdi, [rel ac_e_dupe]
    mov rsi, r12
    mov rdx, r13
    call ac_error_sym
    jmp .pl_err
.pl_symfull:
    lea rdi, [rel ac_e_symfull]
    call ac_error_msg
    jmp .pl_err
.pl_after_label:
    ; equ probe: side-effect-free ident scan for =="equ" (R12-14 live:
    ; probe preserves callee-saved; RDI/RAX/RCX scratch only).
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_ident               ; RAX=start2 RCX=len2 RDI=after2 / CF
    jc .pl_stmt                        ; single ident: statement (R14 live)
    cmp rcx, 3
    jne .pl_dbcheck
    push rax
    push rcx
    push rdi
    mov rdi, rax
    lea rsi, [rel ac_kw_equ]
    mov rdx, 3
    call ac_streicn
    pop rdi                           ; after-ident2
    pop rcx
    pop rax
    jnz .pl_dbcheck2                  ; not equ: maybe db-next
    jmp .pl_equ                       ; RDI = after "equ"
.pl_dbcheck:
    ; (probe found no ident2, or len != 3 and not equ-shaped: re-derive
    ; bounds? The probe consumed nothing committed; for db-check we need
    ; a FRESH ident2 parse. Redo it here uniformly:)
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_ident
    jc .pl_stmt
.pl_dbcheck2:
    ; RAX=start2 RCX=len2 RDI=after2: db/dw/dd/dq with label?
    cmp rcx, 2
    jne .pl_stmt
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov rsi, rcx
    lea rdx, [rel ac_kw_db]
    mov rcx, 2
    call ac_match_kw
    pop rdi
    pop rcx
    pop rax
    jz .pl_data_db
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov rsi, rcx
    lea rdx, [rel ac_kw_dw]
    mov rcx, 2
    call ac_match_kw
    pop rdi
    pop rcx
    pop rax
    jz .pl_data_dw
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov rsi, rcx
    lea rdx, [rel ac_kw_dd]
    mov rcx, 2
    call ac_match_kw
    pop rdi
    pop rcx
    pop rax
    jz .pl_data_dd
    push rax
    push rcx
    push rdi
    mov rdi, rax
    mov rsi, rcx
    lea rdx, [rel ac_kw_dq]
    mov rcx, 2
    call ac_match_kw
    pop rdi
    pop rcx
    pop rax
    jz .pl_data_dq
    jmp .pl_stmt
.pl_data_db:
    mov r10b, 1
    jmp .pl_data
.pl_data_dw:
    mov r10b, 2
    jmp .pl_data
.pl_data_dd:
    mov r10b, 4
    jmp .pl_data
.pl_data_dq:
    mov r10b, 8
.pl_data:
    ; label (R12/R13) + data (RDI=after-directive, size R10B)
    mov r14, rdi                  ; after-directive (R14 free: token bounds
    mov rdi, r12                  ; dead; sym_def preserves R14)
    mov rsi, r13
    mov rdx, [rel ac_offset]
    xor ecx, ecx
    call ac_sym_def
    jc .pl_defmap
    mov rdi, r14
    call ac_enc_data                  ; (RDI=cursor, R10B=size)
    jc .pl_err
    mov rbx, rdi
    jmp .pl_eol
.pl_equ:
    call ac_expr                      ; RAX=val RDX=unk RDI=after
    jc .pl_exprmap
    mov rbx, rdi                      ; cursor (EOL-verify later)
    test edx, edx
    jnz .pl_eol                       ; unknown: skip define (retry/use errs)
    mov rdx, rax                      ; value
    mov rdi, r12
    mov rsi, r13
    mov ecx, 1                        ; const
    call ac_sym_def
    jc .pl_defmap
    jmp .pl_eol
.pl_exprmap:
    cmp eax, 1
    je .pl_div0
    lea rdi, [rel ac_e_expr]
    call ac_error_msg
    jmp .pl_err
.pl_div0:
    lea rdi, [rel ac_e_div0]
    call ac_error_msg
    jmp .pl_err
.pl_stmt:
    ; R14 = after-token1. Exact mnemonics, then jcc, then bad-mnemonic.
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_mov]
    mov rcx, 3
    call ac_match_kw
    jz .do_mov
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_movzx]
    mov rcx, 5
    call ac_match_kw
    jz .do_movzx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_lea]
    mov rcx, 3
    call ac_match_kw
    jz .do_lea
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_add]
    mov rcx, 3
    call ac_match_kw
    jz .do_add
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_sub]
    mov rcx, 3
    call ac_match_kw
    jz .do_sub
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_cmp]
    mov rcx, 3
    call ac_match_kw
    jz .do_cmp
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_test]
    mov rcx, 4
    call ac_match_kw
    jz .do_test
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_inc]
    mov rcx, 3
    call ac_match_kw
    jz .do_inc
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_dec]
    mov rcx, 3
    call ac_match_kw
    jz .do_dec
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_jmp]
    mov rcx, 3
    call ac_match_kw
    jz .do_jmp
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_call]
    mov rcx, 4
    call ac_match_kw
    jz .do_call
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_ret]
    mov rcx, 3
    call ac_match_kw
    jz .do_ret
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_int]
    mov rcx, 3
    call ac_match_kw
    jz .do_int
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_syscall]
    mov rcx, 7
    call ac_match_kw
    jz .do_syscall
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_nop]
    mov rcx, 3
    call ac_match_kw
    jz .do_nop
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_db]
    mov rcx, 2
    call ac_match_kw
    jz .do_db
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_dw]
    mov rcx, 2
    call ac_match_kw
    jz .do_dw
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_dd]
    mov rcx, 2
    call ac_match_kw
    jz .do_dd
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_dq]
    mov rcx, 2
    call ac_match_kw
    jz .do_dq
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_bits]
    mov rcx, 4
    call ac_match_kw
    jz .do_bits
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_default]
    mov rcx, 7
    call ac_match_kw
    jz .do_default
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel ac_kw_times]
    mov rcx, 5
    call ac_match_kw
    jz .do_times
    mov al, [r12]                     ; jcc? (jmp handled above)
    or al, 0x20
    cmp al, 'j'
    je .do_jcc
    lea rdi, [rel ac_e_mnem]          ; bad mnemonic
    call ac_error_msg
    jmp .pl_err
.do_mov:
    mov rdi, r14
    call ac_split_operands            ; RAX=count RDI=after
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_mov
    jc .pl_err
    jmp .pl_eol
.do_movzx:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_movzx
    jc .pl_err
    jmp .pl_eol
.do_lea:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_lea
    jc .pl_err
    jmp .pl_eol
.do_add:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_add
    jc .pl_err
    jmp .pl_eol
.do_sub:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_sub
    jc .pl_err
    jmp .pl_eol
.do_cmp:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_cmp
    jc .pl_err
    jmp .pl_eol
.do_test:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_test
    jc .pl_err
    jmp .pl_eol
.do_inc:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_inc
    jc .pl_err
    jmp .pl_eol
.do_dec:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_dec
    jc .pl_err
    jmp .pl_eol
.do_jmp:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_jmp
    jc .pl_err
    jmp .pl_eol
.do_call:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_call
    jc .pl_err
    jmp .pl_eol
.do_ret:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_ret
    jc .pl_err
    jmp .pl_eol
.do_int:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_int
    jc .pl_err
    jmp .pl_eol
.do_syscall:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_syscall
    jc .pl_err
    jmp .pl_eol
.do_nop:
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_nop
    jc .pl_err
    jmp .pl_eol
.do_jcc:
    mov rdi, r12
    mov rsi, r13
    call ac_cc_lookup                ; RAX=cc / CF=miss
    jc .pl_badmnem
    mov r10b, al
    mov rdi, r14
    call ac_split_operands
    jc .pl_err
    mov [rel ac_opcount], eax
    mov rbx, rdi
    call ac_enc_jcc                  ; (R10B=cc)
    jc .pl_err
    jmp .pl_eol
.pl_badmnem:
    lea rdi, [rel ac_e_mnem]
    call ac_error_msg
    jmp .pl_err
.do_db:
    mov r10b, 1
    jmp .do_data
.do_dw:
    mov r10b, 2
    jmp .do_data
.do_dd:
    mov r10b, 4
    jmp .do_data
.do_dq:
    mov r10b, 8
.do_data:
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    call ac_enc_data                  ; (RDI=cursor, R10B=size)
    jc .pl_err
    mov rbx, rdi
    jmp .pl_eol
.do_bits:
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_number              ; must be exactly 64
    jc .pl_syntax
    cmp rax, 64
    jne .pl_bitsbad
    mov rbx, rdi
    jmp .pl_eol
.pl_bitsbad:
    lea rdi, [rel ac_e_bits]
    call ac_error_msg
    jmp .pl_err
.do_default:
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_ident
    jc .pl_syntax
    cmp rcx, 3
    jne .pl_baddir2
    push rax
    push rcx
    push rdi
    mov rdi, rax
    lea rsi, [rel ac_kw_rel2]
    mov rdx, 3
    call ac_streicn
    pop rdi
    pop rcx
    pop rax
    jnz .pl_baddir2
    mov rbx, rdi
    jmp .pl_eol
.pl_baddir2:
    lea rdi, [rel ac_e_direct]
    call ac_error_msg
    jmp .pl_err
.do_times:
    mov rdi, r14
    call ac_skip_ws
    mov rdi, rax
    call ac_expr                      ; RAX=count RDX=unk RDI=after
    jc .pl_exprmap2
    test edx, edx
    jnz .pl_times_unk
    test rax, rax
    js .pl_range2                     ; negative count
    jz .pl_times_skip                 ; zero: skip body (len 0)
    mov r12, rax                      ; N (token bounds dead here)
    mov r13, rdi                      ; body cursor
    cmp dword [rel ac_emit], 0
    je .pl_times_len
    inc dword [rel ac_sublvl]         ; EMIT: loop N (listing suppressed)
.tm_eloop:
    test r12, r12
    jz .tm_edone
    mov rbx, r13
    call ac_process_line              ; recursive (RBX=after, RAX=len1)
    jc .tm_efail
    dec r12
    jmp .tm_eloop
.tm_efail:
    dec dword [rel ac_sublvl]
    jmp .pl_err                       ; (CF=1 from recursion)
.tm_edone:
    dec dword [rel ac_sublvl]
    jmp .pl_eol                       ; len via sink delta (N×len1 emitted)
.pl_times_len:
    inc dword [rel ac_sublvl]
    mov rbx, r13
    call ac_process_line              ; body once (RBX=after, RAX=len1)
    dec dword [rel ac_sublvl]
    jc .pl_err
    mov r14, rax                      ; len1 (R14 free: token bounds dead)
    mov rax, r12                      ; N
    mul r14                           ; RDX:RAX = N*len1 (CF/OF on overflow)
    jc .pl_tm_ovf
    jmp .pl_eol_explicit              ; (RBX=after ✓, RAX=total ✓)
.pl_tm_ovf:
    lea rdi, [rel ac_e_outbig]
    call ac_error_msg
    jmp .pl_err
.pl_times_unk:
    cmp dword [rel ac_emit], 0
    je .pl_times_skip                 ; LENGTH: skip body (retry later)
    lea rdi, [rel ac_e_timeunk]       ; EMIT: still unknown -> error
    call ac_error_msg
    jmp .pl_err
.pl_times_skip:
    mov rbx, rdi                      ; body cursor (RDI intact from expr)
.ts_scan:
    cmp byte [rbx], 0                 ; run to EOL (linebuf NUL-term: safe)
    je .ts_eol
    inc rbx
    jmp .ts_scan
.ts_eol:
    xor eax, eax                      ; len 0
    jmp .pl_eol_explicit
.pl_range2:
    lea rdi, [rel ac_e_range]
    call ac_error_msg
    jmp .pl_err
.pl_exprmap2:
    cmp eax, 1
    je .pl_exprdiv2
    lea rdi, [rel ac_e_expr]
    call ac_error_msg
    jmp .pl_err
.pl_exprdiv2:
    lea rdi, [rel ac_e_div0]
    call ac_error_msg
    jmp .pl_err
.pl_eol:
    mov rax, [rel ac_outp]
    sub rax, r15                      ; len = sink delta (non-times paths)
.pl_eol_explicit:
    ; (RBX=cursor, RAX=len.) EOL-verify, then listing, then return.
    push rax                          ; len (skip_ws clobbers RAX)
    mov rdi, rbx
    call ac_skip_ws
    mov rbx, rax
    cmp byte [rbx], 0
    jne .pl_eol_garbage
    pop rax                           ; len
    cmp dword [rel ac_emit], 0
    je .pl_eol_ret                    ; LENGTH: no listing
    cmp dword [rel ac_sublvl], 0
    jne .pl_eol_ret                   ; recursion: no listing
    cmp dword [rel ac_liston], 0
    je .pl_eol_ret
    push rax                          ; len across list_emit (preserves? it
    push rbx                          ; must: define contract below)
    mov rdi, rax                      ; ( Planner: list_emit takes len in RDI?
    call ac_list_emit                 ; defined below: (RDI=len) uses globals)
    pop rbx
    pop rax
    jc .pl_err                         ; (list_emit preserves RBX/RAX? NO:
                                      ; reload after. Fixed in final below.)
.pl_eol_ret:
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.pl_eol_garbage:
    pop rax                           ; drop len
    lea rdi, [rel ac_e_syntax]        ; trailing garbage
    call ac_error_msg
    jmp .pl_err
.pl_syntax:
    lea rdi, [rel ac_e_syntax]
    call ac_error_msg
    jmp .pl_err
.pl_percent:
    ; %define NAME value... (RBX = after '%'.) Redefine replaces.
    inc rbx
    mov rdi, rbx
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_ident               ; "define"? (len 6 check + match)
    jc .pl_baddir
    cmp rcx, 6
    jne .pl_baddir
    push rax
    push rcx
    push rdi
    mov rdi, rax
    lea rsi, [rel ac_kw_define]
    mov rdx, 6
    call ac_streicn
    pop rdi
    pop rcx
    pop rax
    jnz .pl_baddir
    call ac_skip_ws
    mov rdi, rax
    call ac_parse_ident               ; defined name
    jc .pl_baddir
    push rax                          ; name start
    push rcx                          ; name len
    push rdi                          ; after name
    call ac_skip_ws
    mov rdi, rax                      ; value start
    mov rbx, rdi
.pc_vscan:
    mov cl, [rbx]                     ; value runs to NUL
    test cl, cl
    jz .pc_vdone
    inc rbx
    jmp .pc_vscan
.pc_vdone:
    cmp rbx, rdi
    je .pc_store                      ; empty value: allowed
    mov cl, [rbx-1]                   ; trim trailing ws
    cmp cl, ' '
    je .pc_trim
    cmp cl, 9
    jne .pc_store
.pc_trim:
    dec rbx
    jmp .pc_vdone
.pc_store:
    mov rcx, rbx
    sub rcx, rdi                      ; vallen
    mov rdx, rdi                      ; value
    add rsp, 8                        ; drop after-name
    pop rsi                           ; namelen
    pop rdi                           ; namestart
    call ac_def_add
    jc .pl_deffull
    xor eax, eax                      ; len 0 (nothing emitted)
    jmp .pl_eol_explicit              ; (RBX at EOL ✓ verify passes)
.pl_deffull:
    lea rdi, [rel ac_e_deffull]
    call ac_error_msg
    jmp .pl_err
.pl_baddir:
    lea rdi, [rel ac_e_direct]
    call ac_error_msg
    jmp .pl_err
.pl_err:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
ac_kw_define: db "define",0

; ac_prep_line(RSI=srcptr, RDX=srclen) -> RSI=after-line, CF=1 line-too-long.
; Copies to linebuf[0] (≤255 + NUL, strips trailing \r), strips ;-comments
; (string-aware, ''-escape-aware), expands %defines into linebuf+256
; (cap 256 → "expanded line too long"). Parsed from +256 afterwards.
ac_prep_line:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    mov rbx, rsi                  ; src cursor
    mov r12, rdx                  ; remaining
    lea r13, [rel ac_linebuf]     ; dst
    xor r14d, r14d                ; count
.pp_copy:
    test r12, r12
    jz .pp_copied                 ; src exhausted: end line here
    cmp r14, 255
    jae .pp_check_nl              ; 255 copied: need \n or end next
    mov al, [rbx]
    cmp al, 10
    je .pp_nl
    mov [r13], al
    inc rbx
    inc r13
    inc r14
    dec r12
    jmp .pp_copy
.pp_nl:
    inc rbx                       ; consume \n (not copied)
    dec r12
    jmp .pp_copied
.pp_check_nl:
    test r12, r12
    jz .pp_copied                 ; exactly 255 at EOF: ok
    cmp byte [rbx], 10
    je .pp_nl2
    lea rdi, [rel ac_e_line]      ; longer without newline: too long
    call ac_error_msg
    jmp .pp_out
.pp_nl2:
    inc rbx
    dec r12
.pp_copied:
    mov [rel ac_prep_after], rbx  ; after-line (expansion reuses all regs)
    lea r13, [rel ac_linebuf]     ; R12 free in prep otherwise)
    add r13, r14
    cmp r14, 0
    je .pp_term
    cmp byte [r13-1], 13          ; strip trailing \r (CRLF sources)
    jne .pp_term
    dec r13
    dec r14
.pp_term:
    mov byte [r13], 0
    ; strip ;-comments (string-aware: '...'/\"...\" with '' doubling)
    lea rbx, [rel ac_linebuf]
.pp_strip:
    mov al, [rbx]
    test al, al
    jz .pp_expand
    cmp al, ';'
    je .pp_cut
    cmp al, "'"
    je .pp_sq
    cmp al, '"'
    je .pp_dq
    inc rbx
    jmp .pp_strip
.pp_sq:
.pp_dq:
    mov ah, al                    ; quote char
    inc rbx
.pp_qloop:
    mov al, [rbx]
    test al, al
    jz .pp_expand                 ; unterminated: db errors later
    cmp al, ah
    jne .pp_qnext
    cmp byte [rbx+1], ah
    jne .pp_qend
    add rbx, 2                    ; doubled quote: literal, stay in string
    jmp .pp_qloop
.pp_qend:
    inc rbx
    jmp .pp_strip
.pp_qnext:
    inc rbx
    jmp .pp_qloop
.pp_cut:
    mov byte [rbx], 0
.pp_expand:
    ; expand whole-word defines into linebuf+256 (cap linebuf+511). No
    ; expansion inside '...'/\"...\" strings. RSI=src, RBX=dst, R14=cap,
    ; R12/R13/R15 scratch (all pushed/callee-saved across helpers).
    lea rsi, [rel ac_linebuf]     ; src
    lea rbx, [rel ac_linebuf+256] ; dst
    lea r14, [rel ac_linebuf+511] ; cap (last writable)
.pp_exp:
    mov al, [rsi]
    test al, al
    jz .pp_exp_end
    cmp al, "'"
    je .pp_exp_str
    cmp al, '"'
    je .pp_exp_str
    push rax
    push rsi
    mov al, [rsi]
    call ac_is_ident0             ; (preserves RSI; clobbers RDX)
    pop rsi
    pop rax
    jnz .pp_exp_byte              ; not ident-start: verbatim byte
    mov rdi, rsi
    call ac_parse_ident           ; RAX=start RCX=len RDI=after
    mov r12, rax                  ; start (survives lookup)
    mov r13, rcx                  ; len
    mov r15, rdi                  ; after
    mov rdi, rax
    mov rsi, rcx
    call ac_def_find              ; RAX=entry/0 (preserves R12/13/15)
    test rax, rax
    jz .pp_exp_word               ; miss: copy word verbatim
    lea rsi, [rax+32]             ; value (NUL-term)
.pp_exp_valcopy:
    mov al, [rsi]
    test al, al
    jz .pp_exp_valdone
    cmp rbx, r14
    jae .pp_exp_full
    mov [rbx], al
    inc rsi
    inc rbx
    jmp .pp_exp_valcopy
.pp_exp_valdone:
    mov rsi, r15                  ; src = after word
    jmp .pp_exp
.pp_exp_word:
    mov rcx, rsi                  ; word len (def_find preserved RSI)
    mov rsi, r12                  ; word start (saved pre-lookup)
.pp_exp_wordcopy:
    test rcx, rcx
    jz .pp_exp_worddone
    cmp rbx, r14
    jae .pp_exp_full
    mov al, [rsi]
    mov [rbx], al
    inc rsi
    inc rbx
    dec rcx
    jmp .pp_exp_wordcopy
.pp_exp_worddone:
    mov rsi, r15
    jmp .pp_exp
.pp_exp_byte:
    cmp rbx, r14
    jae .pp_exp_full
    mov [rbx], al
    inc rsi
    inc rbx
    jmp .pp_exp
.pp_exp_str:
    mov ah, al                    ; quote char
    jmp .pp_exp_strcopy
.pp_exp_strcopy:
    cmp rbx, r14
    jae .pp_exp_full
    mov [rbx], al                 ; copy verbatim (quotes + contents)
    inc rsi
    inc rbx
    mov al, [rsi]
    test al, al
    jz .pp_exp                   ; NUL: end (db errors if unterminated)
    cmp al, ah
    jne .pp_exp_strcopy
    cmp byte [rsi+1], ah
    je .pp_exp_strcopy            ; doubled: both bytes land verbatim
    cmp rbx, r14                  ; true close: copy it, exit string mode
    jae .pp_exp_full
    mov [rbx], al
    inc rsi
    inc rbx
    jmp .pp_exp
.pp_exp_end:
    cmp rbx, r14
    jae .pp_exp_full
    mov byte [rbx], 0
    mov rsi, [rel ac_prep_after]  ; after-line for the driver
    clc
.pp_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.pp_exp_full:
    lea rdi, [rel ac_e_expand]
    call ac_error_msg
    jmp .pp_out

; ac_scan_pass: iterate source lines (ac_src/srclen). Per line: lineno++,
; prep (copy/strip/expand), lineoff=offset, sink reset (LENGTH only),
; RBX=expanded, process_line, offset+=len. CF=1 aborts (recorded).
ac_scan_pass:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    lea rdi, [rel ac_symtab]      ; clear touched (every scan, incl EMIT —
    mov ecx, [rel ac_symcount]    ; the fixpoint loop must not be the only
.ac_untouch:                      ; place: emit redefines too. RDI scratch.)
    test ecx, ecx
    jz .ac_untdone
    and byte [rdi + AC_SYM_FLAGS], ~AC_SF_TOUCHED
    add rdi, AC_SYM_ENT
    dec ecx
    jmp .ac_untouch
.ac_untdone:
    mov rbx, [rel ac_src]         ; cursor (RDI was scratch throughout)
    mov r12, [rel ac_src]
    add r12, [rel ac_srclen]      ; end (exclusive)
    mov qword [rel ac_lineno], 0
.sp_loop:
    cmp rbx, r12
    jae .sp_done                  ; source exhausted
    inc qword [rel ac_lineno]
    mov rsi, rbx
    mov rdx, r12
    sub rdx, rbx                  ; remaining
    call ac_prep_line             ; RSI=after-line, CF=line-too-long
    jc .sp_out
    mov rbx, rsi                  ; advance
    mov rax, [rel ac_offset]
    mov [rel ac_lineoff], rax     ; line starts here
    cmp dword [rel ac_emit], 0
    jne .sp_emit_sink
    lea rax, [rel ac_scratch]     ; LENGTH: fresh 512B scratch per line
    mov [rel ac_outp], rax        ; (single lines fit: ≤255B content)
    mov qword [rel ac_outleft], 512
.sp_emit_sink:
    mov r13, rbx                  ; save src cursor (process_line takes RBX)
    lea rbx, [rel ac_linebuf+256] ; expanded line
    call ac_process_line          ; RBX=after, RAX=len, CF=err
    jc .sp_out
    mov rbx, r13                  ; restore src cursor
    add [rel ac_offset], rax
    jmp .sp_loop
.sp_done:
    clc
.sp_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; asm64_assemble(RDI=src, RSI=srclen, RDX=out, RCX=outcap, R8=list,
;   R9=listcap, [RSP+8]=err, [RSP+16]=errcap) -> RAX=outlen, or -1 with
;   errbuf "LINE: msg ['name']" (first error only). Single-shot per call
;   (all state reset here; tables rebuilt). Fixpoint ≤16 passes, then one
;   emit pass (length-verified against the fixpoint).
asm64_assemble:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    mov [rel ac_src], rdi
    mov [rel ac_srclen], rsi
    mov [rel ac_out], rdx
    mov [rel ac_outcap], rcx
    mov [rel ac_list], r8
    mov [rel ac_listcap], r9
    mov rax, [rsp+48]             ; err (5 pushes + retaddr = 48)
    mov [rel ac_err], rax
    mov rax, [rsp+56]             ; errcap
    mov [rel ac_errcap], rax
    ; reset state (tables logically empty; counts zero)
    lea rdi, [rel ac_symtab]
    mov ecx, 256*48/8
    xor eax, eax
    cld
    rep stosq
    mov qword [rel ac_symcount], 0
    lea rdi, [rel ac_deftab]
    mov ecx, 32*128/8
    rep stosq
    mov qword [rel ac_defcount], 0
    mov dword [rel ac_errflag], 0
    mov dword [rel ac_sublvl], 0
    cmp r8, 0
    je .as_nolist
    test r9, r9
    jz .as_nolist
    mov dword [rel ac_liston], 1
    jmp .as_listdone
.as_nolist:
    mov dword [rel ac_liston], 0
.as_listdone:
    mov dword [rel ac_emit], 0    ; LENGTH passes
    mov r15d, 1                   ; pass number
.as_ploop:
    cmp r15d, 16+1
    ja .as_unstable               ; >16 passes: give up honestly
    lea rdi, [rel ac_symtab]      ; clear touched flags (keep def/const)
    mov ecx, [rel ac_symcount]
.as_tclear:
    test ecx, ecx
    jz .as_tdone
    and byte [rdi + AC_SYM_FLAGS], ~AC_SF_TOUCHED
    add rdi, AC_SYM_ENT
    dec ecx
    jmp .as_tclear
.as_tdone:
    mov qword [rel ac_offset], 0
    call ac_scan_pass
    jc .as_fail
    mov rbx, [rel ac_offset]      ; totlen
    xor r12d, r12d                ; defined count
    lea rdi, [rel ac_symtab]
    mov ecx, [rel ac_symcount]
.as_dcount:
    test ecx, ecx
    jz .as_ddone
    test byte [rdi + AC_SYM_FLAGS], AC_SF_DEFINED
    jz .as_dnext
    inc r12d
.as_dnext:
    add rdi, AC_SYM_ENT
    dec ecx
    jmp .as_dcount
.as_ddone:
    cmp r15d, 1
    je .as_next                   ; pass 1 always continues (baseline)
    cmp rbx, [rel ac_prevlen]
    jne .as_next
    cmp r12, [rel ac_prevdef]
    je .as_converged              ; length + defined-set stable: done
.as_next:
    mov [rel ac_prevlen], rbx
    mov [rel ac_prevdef], r12
    inc r15d
    jmp .as_ploop
.as_converged:
    mov dword [rel ac_emit], 1    ; EMIT pass (fresh re-evaluation)
    mov qword [rel ac_offset], 0
    mov rax, [rel ac_out]
    mov [rel ac_outp], rax
    mov rax, [rel ac_outcap]
    mov [rel ac_outleft], rax
    mov rax, [rel ac_list]
    mov [rel ac_listp], rax
    mov rax, [rel ac_listcap]
    mov [rel ac_listleft], rax
    call ac_scan_pass
    jc .as_fail
    mov rax, [rel ac_offset]
    cmp rax, [rel ac_prevlen]     ; LENGTH/EMIT divergence tripwire
    jne .as_unstable
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret                           ; RAX = outlen
.as_unstable:
    lea rdi, [rel ac_e_unstab]
    call ac_error_msg
    jmp .as_fail
.as_fail:
    cmp dword [rel ac_errflag], 0
    jne .as_have_err
    lea rdi, [rel ac_e_internal]  ; contract breach (shouldn't happen)
    call ac_error_msg
.as_have_err:
    call ac_error_finalize
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ac_match_kw(RDI=start, RSI=len, RDX=kw, RCX=kwlen) -> ZF=1 exact match
; (length + case-insensitive content). Consumes inputs; preserves RBX/R12+.
ac_match_kw:
    cmp rsi, rcx
    jne .mk_no
    xchg rsi, rdx                 ; RSI=kw, RDX=len
    jmp ac_streicn                ; tail call (ZF passes through)
.mk_no:
    ret                           ; ZF=0 from the cmp above

; Keyword strings for dispatch.
ac_kw_mov: db "mov",0
ac_kw_movzx: db "movzx",0
ac_kw_lea: db "lea",0
ac_kw_add: db "add",0
ac_kw_sub: db "sub",0
ac_kw_cmp: db "cmp",0
ac_kw_test: db "test",0
ac_kw_inc: db "inc",0
ac_kw_dec: db "dec",0
ac_kw_jmp: db "jmp",0
ac_kw_call: db "call",0
ac_kw_ret: db "ret",0
ac_kw_int: db "int",0
ac_kw_syscall: db "syscall",0
ac_kw_nop: db "nop",0
ac_kw_db: db "db",0
ac_kw_dw: db "dw",0
ac_kw_dd: db "dd",0
ac_kw_dq: db "dq",0
ac_kw_bits: db "bits",0
ac_kw_default: db "default",0
ac_kw_times: db "times",0
ac_kw_equ: db "equ",0
ac_kw_rel2: db "rel",0

; ac_list_emit(RDI=len): append one listing entry (offset + bytes + src).
; Format: "XXXXXXXX  BB BB ...  srctext\n" (up to 8 bytes shown).
; Uses ac_lineoff, bytes [[outp]-len, [outp]), text linebuf+256 (≤64).
; CF=1 "listing too large". Preserves RBX/R12-R15/RSI/RDI.
ac_list_emit:
    push rbx
    push r12
    push r13
    push r14
    push r15                      ; 5 pushes: aligned
    mov r12, rdi                  ; len
    mov r13, [rel ac_outp]
    sub r13, r12                  ; first byte
    mov r14, [rel ac_listp]       ; dst cursor
    mov r15, [rel ac_listleft]    ; remaining
    mov rax, [rel ac_lineoff]
    mov ebx, 8                    ; 8 hex digits, high first
.le_h8:
    rol rax, 4                    ; top nibble -> low (wraps around)
    push rax
    push rbx
    and al, 0x0F
    call .le_hexnyb
    pop rbx
    pop rax
    jc .le_out
    dec ebx
    jnz .le_h8
    mov al, ' '
    call .le_putc
    jc .le_out
    call .le_putc                 ; (AL still space; putc preserves RAX)
    jc .le_out
    mov rax, r12                  ; n = min(len, 8)
    cmp rax, 8
    jbe .le_nok
    mov rax, 8
.le_nok:
    mov rbx, rax                  ; byte loop count
    mov rcx, 8
    sub rcx, rax                  ; pad slots
    push rcx                      ; pad count (balanced below)
    test rbx, rbx
    jz .le_pad
.le_bloop:
    mov al, [r13]
    call .le_hexbyte              ; (preserves RBX/RCX; frame+pad outstanding
    jc .le_bfail                  ; = 6 pushes: aligned)
    mov al, ' '
    call .le_putc
    jc .le_bfail
    inc r13
    dec rbx
    jnz .le_bloop
.le_pad:
    pop rcx                       ; pad slots
    test rcx, rcx
    jz .le_text
.le_padloop:
    push rcx
    mov al, ' '
    call .le_putc
    pop rcx
    jc .le_out
    call .le_putc
    jc .le_out
    call .le_putc
    jc .le_out
    dec rcx
    jnz .le_padloop
.le_text:
    mov al, ' '
    call .le_putc
    jc .le_out
    call .le_putc
    jc .le_out
    lea rsi, [rel ac_linebuf+256] ; expanded source text
    mov ebx, 64                   ; cap
.le_tloop:
    mov al, [rsi]
    test al, al
    jz .le_nl
    test ebx, ebx
    jz .le_nl
    call .le_putc
    jc .le_out
    inc rsi
    dec ebx
    jmp .le_tloop
.le_nl:
    mov al, 10
    call .le_putc
    jc .le_out
    mov [rel ac_listp], r14       ; commit cursor + remaining
    mov [rel ac_listleft], r15
    clc
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.le_bfail:
    add rsp, 8                    ; drop pad count
    jmp .le_out
.le_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.le_hexbyte:                      ; AL=byte -> two hex chars. Preserves RBX.
    push rbx
    mov bl, al
    shr al, 4
    call .le_hexnyb
    jc .le_hb_out
    mov al, bl
    and al, 0x0F
    call .le_hexnyb
.le_hb_out:
    pop rbx
    ret                           ; (CF from last putc; pops preserve it)
.le_hexnyb:                       ; AL=nibble -> putc(table[AL]). Preserves RBX.
    push rdx
    push rax
    push rcx                      ; 3 pushes: aligned (dummy preserve)
    lea rdx, [rel ac_hexdig]
    movzx eax, al
    mov al, [rdx+rax]
    call .le_putc
    pop rcx
    pop rax
    pop rdx
    ret
.le_putc:                         ; AL=char (drops past cap→listbig err once).
    push rax                      ; (1 push: frame was 5 (aligned); 6 total
    test r15, r15                 ; at error_msg call: (8-48)≡0 ✓ aligned)
    jz .le_full
    mov [r14], al
    inc r14
    dec r15
    clc
    pop rax
    ret
.le_full:
    lea rdi, [rel ac_e_listbig]
    call ac_error_msg             ; (first-error-wins; ends STC)
    pop rax                       ; (CF survives pop)
    ret
ac_hexdig: db "0123456789ABCDEF"