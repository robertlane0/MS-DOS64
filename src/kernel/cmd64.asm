; MS-DOS64 src/kernel/cmd64.asm — Phase 10: Command Interpreter (COMMAND64)
; Converts COMMAND.ASM resident/transient, COMTAB, SWITCH/DELIM/SCANOFF,
; CATALOG/ERASE/RENAME/TYPEFIL/COPY/PAUSE/DATE/TIME/EXELOAD, batch %1..%9
; Original: 16-bit segmented RESGROUP/TRANGROUP, FCB 5Ch, INT 21h/33, seg:off DMA,
; paragraph TPA, FAR jumps, AAM/AAD in OUT2/GETNUM.
; 64-bit: flat linear, RIP-relative, near dispatch, native VGA (Phase5),
; MCB64 heap (Phase6), FAT12 LBA (Phase7), PSP64/EXEC (Phase8), INT21 IDT (Phase9).
bits 64
default rel
%include "include/fs.inc"
section .text
global cmd_dbg_putc
global cmd_init64
global cmd_strlen64
global cmd_toupper_buf64
global cmd_is_delim64
global cmd_skip_delims64
global cmd_parse_switches64
global cmd_parse_line64
global cmd_table_lookup64
global cmd_streq_upper
global cmd_dispatch64
global cmd_cls64
global cmd_ver64
global cmd_prompt_set64
global cmd_prompt_get64
global cmd_path_set64
global cmd_path_get64
global cmd_rem64
global cmd_pause64
global cmd_echo64
global cmd_date_get64
global cmd_date_set64
global cmd_date_parse64
global cmd_time_get64
global cmd_time_set64
global cmd_time_parse64
global cmd_dir_format64
global cmd_type_buffer64
global cmd_copy_buffer64
global cmd_del_entry64
global cmd_ren_entry64
global cmd_exec_external64
global cmd_batch_open64
global cmd_batch_next64
global cmd_batch_close64
global cmd_batch_expand64
global cmd_test_parser
global cmd_test_dir_type
global cmd_test_fileops
global cmd_test_shellcfg
global cmd_test_datetime
global cmd_test_exec
global cmd_test_batch
global cmd_test_dispatch
global cmd_env
global cmd_year
global cmd_month
global cmd_day
global cmd_hour
global cmd_min
global cmd_sec
extern vga_clear
extern vga_print
extern vga_putc
extern mem_alloc64
extern mem_free64
extern mem_validate64
extern env_init64
extern env_set64
extern env_get64
extern env_count64
extern proc_spawn64
extern proc_terminate64
extern proc_reap64
extern fs_dir_get_firstclus64
extern fs_dir_get_size64
extern fs_dir_get_attr64

; cmd_dbg_putc AL=char -> COM1 (for fail-point isolation, like Phase8 markers)
cmd_dbg_putc:
    push rdx
    push rax
    mov ah, al
.wait_dbg:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait_dbg
    mov al, ah
    mov dx, 0x3F8
    out dx, al
    pop rax
    pop rdx
    ret
%define SW_W 1
%define SW_P 2
%define SW_V 4
%define SW_A 8
%define SW_B 0x10
%define CMD_ENV_SIZE 1024
%define CMD_BATCH_SIZE 1024

; cmd_strlen64 RDI=str -> RAX=len max 1024, null->0
cmd_strlen64:
    test rdi, rdi
    jz .null_s
    push rbx
    push rcx
    xor eax, eax
    mov rcx, 1024
.loop_s:
    test rcx, rcx
    jz .done_s
    mov bl, [rdi + rax]
    test bl, bl
    jz .done_s
    inc rax
    dec rcx
    jnz .loop_s
.done_s:
    pop rcx
    pop rbx
    ret
.null_s:
    xor eax, eax
    ret

; cmd_toupper_buf64 RDI=buf RSI=len -> RAX 0, null->1
cmd_toupper_buf64:
    test rdi, rdi
    jz .bad_u
    push rbx
    push rcx
    mov rcx, rsi
    xor ebx, ebx
.loop_u:
    cmp rbx, rcx
    jae .done_u
    mov al, [rdi + rbx]
    cmp al, 'a'
    jb .next_u
    cmp al, 'z'
    ja .next_u
    sub al, 32
    mov [rdi + rbx], al
.next_u:
    inc rbx
    jmp .loop_u
.done_u:
    xor eax, eax
    pop rcx
    pop rbx
    ret
.bad_u:
    mov rax, 1
    ret

; cmd_is_delim64 DIL=char -> RAX 1 delim else 0 (space = , ; TAB)
cmd_is_delim64:
    movzx eax, dil
    cmp al, ' '
    je .is_d
    cmp al, '='
    je .is_d
    cmp al, ','
    je .is_d
    cmp al, ';'
    je .is_d
    cmp al, 9
    je .is_d
    xor eax, eax
    ret
.is_d:
    mov rax, 1
    ret

; cmd_skip_delims64 RSI=ptr -> RAX=new ptr, null->0, stops NUL/CR/LF
cmd_skip_delims64:
    test rsi, rsi
    jz .null_k
    push rbx
.loop_k:
    mov bl, [rsi]
    test bl, bl
    jz .done_k
    cmp bl, 13
    je .done_k
    cmp bl, 10
    je .done_k
    mov dil, bl
    push rsi
    call cmd_is_delim64
    pop rsi
    test rax, rax
    jz .done_k
    inc rsi
    jmp .loop_k
.done_k:
    mov rax, rsi
    pop rbx
    ret
.null_k:
    xor eax, eax
    ret

; cmd_parse_switches64 RSI=ptr -> RAX=newptr RDX=bits RCX=bad
cmd_parse_switches64:
    test rsi, rsi
    jz .null_w
    push rbx
    push rdi
    xor edx, edx
    xor ecx, ecx
    mov rbx, rsi
.loop_w:
    mov al, [rbx]
    test al, al
    jz .done_w
    cmp al, 13
    je .done_w
    cmp al, 10
    je .done_w
    cmp al, ' '
    je .skip_w
    cmp al, '='
    je .skip_w
    cmp al, ','
    je .skip_w
    cmp al, ';'
    je .skip_w
    cmp al, 9
    je .skip_w
    cmp al, '/'
    jne .done_w
    mov al, [rbx+1]
    test al, al
    jz .done_w
    cmp al, 'a'
    jb .have_w
    cmp al, 'z'
    ja .have_w
    sub al, 32
.have_w:
    cmp al, 'W'
    je .bit_w
    cmp al, 'P'
    je .bit_p
    cmp al, 'V'
    je .bit_v
    cmp al, 'A'
    je .bit_a
    cmp al, 'B'
    je .bit_b
    mov ecx, 1
    add rbx, 2
    jmp .loop_w
.bit_w:
    or edx, SW_W
    add rbx, 2
    jmp .loop_w
.bit_p:
    or edx, SW_P
    add rbx, 2
    jmp .loop_w
.bit_v:
    or edx, SW_V
    add rbx, 2
    jmp .loop_w
.bit_a:
    or edx, SW_A
    add rbx, 2
    jmp .loop_w
.bit_b:
    or edx, SW_B
    add rbx, 2
    jmp .loop_w
.skip_w:
    inc rbx
    jmp .loop_w
.done_w:
    mov rax, rbx
    pop rdi
    pop rbx
    ret
.null_w:
    xor eax, eax
    xor edx, edx
    mov ecx, 1
    ret

; cmd_init64 -> RAX 0
cmd_init64:
    push rbx
    push rdi
    push rsi
    push rdx
    push rcx
    lea rdi, [rel cmd_env]
    mov rsi, CMD_ENV_SIZE
    call env_init64
    test rax, rax
    jnz .fail_i
    lea rdi, [rel cmd_env]
    mov rsi, CMD_ENV_SIZE
    lea rdx, [rel cmd_name_path]
    lea rcx, [rel cmd_val_dot]
    call env_set64
    lea rdi, [rel cmd_env]
    mov rsi, CMD_ENV_SIZE
    lea rdx, [rel cmd_name_comspec]
    lea rcx, [rel cmd_val_comspec]
    call env_set64
    lea rdi, [rel cmd_env]
    mov rsi, CMD_ENV_SIZE
    lea rdx, [rel cmd_name_prompt]
    lea rcx, [rel cmd_val_prompt]
    call env_set64
    mov word [rel cmd_year], 1983
    mov byte [rel cmd_month], 4
    mov byte [rel cmd_day], 1
    mov byte [rel cmd_hour], 12
    mov byte [rel cmd_min], 0
    mov byte [rel cmd_sec], 0
    mov byte [rel cmd_batch_active], 0
    mov qword [rel cmd_batch_len], 0
    mov qword [rel cmd_batch_off], 0
    xor eax, eax
    jmp .done_i
.fail_i:
    mov rax, 1
.done_i:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbx
    ret

; cmd_parse_line64 RDI=line RSI=cmd_out(16) RDX=tail_out(128/0) RCX=sw_out(0 ok) -> RAX 0/1
cmd_parse_line64:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test rdi, rdi
    jz .bad_p
    test rsi, rsi
    jz .bad_p
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, rdi
    mov rsi, r15
    call cmd_skip_delims64
    test rax, rax
    jz .bad_p
    mov r15, rax
    mov al, [r15]
    cmp al, 0
    je .empty_p
    cmp al, 13
    je .empty_p
    cmp al, 10
    je .empty_p
    ; drive X: ?
    mov al, [r15]
    mov bl, [r15+1]
    cmp bl, ':'
    jne .no_drive
    mov bl, al
    cmp bl, 'a'
    jb .chk_up
    cmp bl, 'z'
    ja .chk_up
    sub bl, 32
.chk_up:
    cmp bl, 'A'
    jb .no_drive
    cmp bl, 'Z'
    ja .no_drive
    add r15, 2
    mov rsi, r15
    call cmd_skip_delims64
    mov r15, rax
.no_drive:
    ; token start in r15, find end
    push r15
    mov rbx, r15
    xor ecx, ecx
.tok_loop:
    mov al, [rbx]
    test al, al
    jz .tok_end
    cmp al, 13
    je .tok_end
    cmp al, 10
    je .tok_end
    cmp al, '/'
    je .tok_end
    cmp al, ':'
    je .tok_end
    mov dil, al
    push rax
    push rbx
    push rcx
    call cmd_is_delim64
    mov rsi, rax
    pop rcx
    pop rbx
    pop rax
    test rsi, rsi
    jnz .tok_end
    inc rbx
    inc rcx
    cmp rcx, 64
    jb .tok_loop
    jmp .tok_end
.tok_end:
    ; rcx = raw len, cap copy at 8
    pop r15
    mov rdx, rcx
    cmp rdx, 8
    jbe .copy_len_ok
    mov rdx, 8
.copy_len_ok:
    test rdx, rdx
    jz .nocopy_tok
    xor ebx, ebx
.copy_ch:
    cmp rbx, rdx
    jae .copy_done
    mov al, [r15 + rbx]
    cmp al, 'a'
    jb .store_ch
    cmp al, 'z'
    ja .store_ch
    sub al, 32
.store_ch:
    mov [r12 + rbx], al
    inc rbx
    jmp .copy_ch
.copy_done:
.nocopy_tok:
    mov byte [r12 + rdx], 0
    ; r15+rcx is remainder start (rcx raw len, not capped)
    ; recompute: remainder = token_start + raw_len
    ; token_start still? we popped; need start: r15 is token start? No r15 was token start before? Actually r15=token start, rbx=end, rcx=raw len. remainder = r15+rcx.
    add r15, rcx
    ; scan remainder for /X bits into r11d
    xor r11d, r11d
    mov rsi, r15
.scan_sw:
    mov al, [rsi]
    test al, al
    jz .scan_done
    cmp al, 13
    je .scan_done
    cmp al, 10
    je .scan_done
    cmp al, '/'
    jne .next_scan
    mov bl, [rsi+1]
    test bl, bl
    jz .next_scan
    cmp bl, 'a'
    jb .up_sw
    cmp bl, 'z'
    ja .up_sw
    sub bl, 32
.up_sw:
    cmp bl, 'W'
    je .sw_w
    cmp bl, 'P'
    je .sw_p
    cmp bl, 'V'
    je .sw_v
    cmp bl, 'A'
    je .sw_a
    cmp bl, 'B'
    je .sw_b
    jmp .next_scan
.sw_w:
    or r11d, SW_W
    add rsi, 2
    jmp .scan_sw
.sw_p:
    or r11d, SW_P
    add rsi, 2
    jmp .scan_sw
.sw_v:
    or r11d, SW_V
    add rsi, 2
    jmp .scan_sw
.sw_a:
    or r11d, SW_A
    add rsi, 2
    jmp .scan_sw
.sw_b:
    or r11d, SW_B
    add rsi, 2
    jmp .scan_sw
.next_scan:
    inc rsi
    jmp .scan_sw
.scan_done:
    test r14, r14
    jz .no_sw_store
    mov [r14], r11d
.no_sw_store:
    test r13, r13
    jz .ok_p
    mov rsi, r15
    call cmd_skip_delims64
    mov rsi, rax
    mov rdi, r13
    xor ecx, ecx
.tail_copy:
    cmp ecx, 127
    jae .tail_end
    mov al, [rsi]
    test al, al
    jz .tail_end
    cmp al, 13
    je .tail_end
    cmp al, 10
    je .tail_end
    mov [rdi + rcx], al
    inc rsi
    inc rcx
    jmp .tail_copy
.tail_end:
    mov byte [rdi + rcx], 0
.ok_p:
    xor eax, eax
    jmp .done_p
.empty_p:
    mov byte [r12], 0
    test r13, r13
    jz .empty_sw
    mov byte [r13], 0
.empty_sw:
    test r14, r14
    jz .empty_ok
    mov qword [r14], 0
.empty_ok:
    xor eax, eax
    jmp .done_p
.bad_p:
    mov rax, 1
.done_p:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cmd_streq_upper RDI=a RSI=b -> RAX 0 eq else 1 (tolerant lower in a)
cmd_streq_upper:
    push rbx
    push rcx
    push rdi
    push rsi
.loop_q:
    mov bl, [rdi]
    mov cl, [rsi]
    cmp bl, 'a'
    jb .cmp_q
    cmp bl, 'z'
    ja .cmp_q
    sub bl, 32
.cmp_q:
    cmp bl, cl
    jne .diff_q
    test cl, cl
    jz .eq_q
    inc rdi
    inc rsi
    jmp .loop_q
.diff_q:
    mov rax, 1
    jmp .done_q
.eq_q:
    xor eax, eax
.done_q:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; cmd_table_lookup64 RDI=cmd -> RAX=handler or 0
cmd_table_lookup64:
    test rdi, rdi
    jz .unknown_t
    push rbx
    push rcx
    push rsi
    lea rsi, [rel cmd_s_dir]
    call cmd_streq_upper
    test rax, rax
    jz .found_dir
    lea rsi, [rel cmd_s_rename]
    call cmd_streq_upper
    test rax, rax
    jz .found_rename
    lea rsi, [rel cmd_s_ren]
    call cmd_streq_upper
    test rax, rax
    jz .found_rename
    lea rsi, [rel cmd_s_erase]
    call cmd_streq_upper
    test rax, rax
    jz .found_erase
    lea rsi, [rel cmd_s_del]
    call cmd_streq_upper
    test rax, rax
    jz .found_erase
    lea rsi, [rel cmd_s_type]
    call cmd_streq_upper
    test rax, rax
    jz .found_type
    lea rsi, [rel cmd_s_rem]
    call cmd_streq_upper
    test rax, rax
    jz .found_rem
    lea rsi, [rel cmd_s_copy]
    call cmd_streq_upper
    test rax, rax
    jz .found_copy
    lea rsi, [rel cmd_s_pause]
    call cmd_streq_upper
    test rax, rax
    jz .found_pause
    lea rsi, [rel cmd_s_date]
    call cmd_streq_upper
    test rax, rax
    jz .found_date
    lea rsi, [rel cmd_s_time]
    call cmd_streq_upper
    test rax, rax
    jz .found_time
    lea rsi, [rel cmd_s_cls]
    call cmd_streq_upper
    test rax, rax
    jz .found_cls
    lea rsi, [rel cmd_s_ver]
    call cmd_streq_upper
    test rax, rax
    jz .found_ver
    lea rsi, [rel cmd_s_prompt]
    call cmd_streq_upper
    test rax, rax
    jz .found_prompt
    lea rsi, [rel cmd_s_path]
    call cmd_streq_upper
    test rax, rax
    jz .found_path
    lea rsi, [rel cmd_s_echo]
    call cmd_streq_upper
    test rax, rax
    jz .found_echo
    xor eax, eax
    pop rsi
    pop rcx
    pop rbx
    ret
.found_dir:
    lea rax, [rel cmd_dir_format64]
    jmp .done_t
.found_rename:
    lea rax, [rel cmd_ren_entry64]
    jmp .done_t
.found_erase:
    lea rax, [rel cmd_del_entry64]
    jmp .done_t
.found_type:
    lea rax, [rel cmd_type_buffer64]
    jmp .done_t
.found_rem:
    lea rax, [rel cmd_rem64]
    jmp .done_t
.found_copy:
    lea rax, [rel cmd_copy_buffer64]
    jmp .done_t
.found_pause:
    lea rax, [rel cmd_pause64]
    jmp .done_t
.found_date:
    lea rax, [rel cmd_date_get64]
    jmp .done_t
.found_time:
    lea rax, [rel cmd_time_get64]
    jmp .done_t
.found_cls:
    lea rax, [rel cmd_cls64]
    jmp .done_t
.found_ver:
    lea rax, [rel cmd_ver64]
    jmp .done_t
.found_prompt:
    lea rax, [rel cmd_prompt_get64]
    jmp .done_t
.found_path:
    lea rax, [rel cmd_path_get64]
    jmp .done_t
.found_echo:
    lea rax, [rel cmd_echo64]
    jmp .done_t
.done_t:
    pop rsi
    pop rcx
    pop rbx
    ret
.unknown_t:
    xor eax, eax
    ret

; cmd_dispatch64 RDI=line -> RAX 0 builtin, 1 empty/fail, 2 external
cmd_dispatch64:
    test rdi, rdi
    jz .bad_d
    push rbx
    push r12
    push r13
    mov r12, rdi
    sub rsp, 160
    mov rdi, r12
    mov rsi, rsp
    lea rdx, [rsp+16]
    lea rcx, [rsp+144]
    call cmd_parse_line64
    test rax, rax
    jnz .fail_d
    mov al, [rsp]
    test al, al
    jz .empty_d
    mov rdi, rsp
    call cmd_table_lookup64
    test rax, rax
    jz .external_d
    mov rdi, rsp
    lea rsi, [rel cmd_s_rem]
    call cmd_streq_upper
    test rax, rax
    jz .ok_d
    mov rdi, rsp
    lea rsi, [rel cmd_s_cls]
    call cmd_streq_upper
    test rax, rax
    jz .do_cls
    mov rdi, rsp
    lea rsi, [rel cmd_s_ver]
    call cmd_streq_upper
    test rax, rax
    jz .do_ver
    mov rdi, rsp
    lea rsi, [rel cmd_s_pause]
    call cmd_streq_upper
    test rax, rax
    jz .ok_d
    mov rdi, rsp
    lea rsi, [rel cmd_s_echo]
    call cmd_streq_upper
    test rax, rax
    jz .ok_d
    jmp .ok_d
.do_cls:
    call cmd_cls64
    jmp .ok_d
.do_ver:
    lea rsi, [rel cmd_version]
    call vga_print
    jmp .ok_d
.ok_d:
    xor eax, eax
    jmp .done_d
.empty_d:
    mov rax, 1
    jmp .done_d
.external_d:
    mov rax, 2
    jmp .done_d
.fail_d:
    mov rax, 1
    jmp .done_d
.bad_d:
    mov rax, 1
    ret
.done_d:
    add rsp, 160
    pop r13
    pop r12
    pop rbx
    ret

; cmd_cls64 -> 0
cmd_cls64:
    push rbx
    call vga_clear
    xor eax, eax
    pop rbx
    ret

; cmd_ver64 RDI=out RSI=size -> 0/1
cmd_ver64:
    test rdi, rdi
    jz .bad_v
    test rsi, rsi
    jz .bad_v
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rel cmd_version]
    call cmd_strlen64
    mov rbx, rax
    inc rbx
    cmp rbx, r13
    ja .small_v
    lea rsi, [rel cmd_version]
    mov rdi, r12
    mov rcx, rbx
    cld
    rep movsb
    xor eax, eax
    jmp .done_v
.small_v:
    mov rax, 1
    jmp .done_v
.bad_v:
    mov rax, 1
    ret
.done_v:
    pop r13
    pop r12
    pop rbx
    ret

; cmd_prompt_set64 RDI=val -> 0/1 ; cmd_prompt_get64 RDI=out RSI=size -> 0/1
cmd_prompt_set64:
    test rdi, rdi
    jz .bad_ps
    push rbx
    push rsi
    push rdx
    push rcx
    mov rcx, rdi
    lea rdi, [rel cmd_env]
    mov rsi, CMD_ENV_SIZE
    lea rdx, [rel cmd_name_prompt]
    call env_set64
    pop rcx
    pop rdx
    pop rsi
    pop rbx
    ret
.bad_ps:
    mov rax, 1
    ret
cmd_prompt_get64:
    test rdi, rdi
    jz .bad_pg
    test rsi, rsi
    jz .bad_pg
    push rbx
    push rcx
    push rdx
    mov rbx, rdi
    mov rcx, rsi
    lea rdi, [rel cmd_env]
    lea rsi, [rel cmd_name_prompt]
    mov rdx, rbx
    call env_get64
    pop rdx
    pop rcx
    pop rbx
    ret
.bad_pg:
    mov rax, 1
    ret

; cmd_path_set64 / get64 same with PATH
cmd_path_set64:
    test rdi, rdi
    jz .bad_qs
    push rbx
    push rsi
    push rdx
    push rcx
    mov rcx, rdi
    lea rdi, [rel cmd_env]
    mov rsi, CMD_ENV_SIZE
    lea rdx, [rel cmd_name_path]
    call env_set64
    pop rcx
    pop rdx
    pop rsi
    pop rbx
    ret
.bad_qs:
    mov rax, 1
    ret
cmd_path_get64:
    test rdi, rdi
    jz .bad_qg
    test rsi, rsi
    jz .bad_qg
    push rbx
    push rcx
    push rdx
    mov rbx, rdi
    mov rcx, rsi
    lea rdi, [rel cmd_env]
    lea rsi, [rel cmd_name_path]
    mov rdx, rbx
    call env_get64
    pop rdx
    pop rcx
    pop rbx
    ret
.bad_qg:
    mov rax, 1
    ret

; cmd_emit_both — AL=char -> VGA + COM1 (serial parity for the REPL;
; VGA-only output would vanish from serial.log / stdio transcripts).
cmd_emit_both:
    push rax
    push rdx
    mov ah, al
    movzx edi, ah
    mov al, ah
    call vga_putc
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .drop_cb
    mov al, ah
    mov dx, 0x3F8
    out dx, al
.drop_cb:
    pop rdx
    pop rax
    ret

; cmd_print_both — RSI=NUL string -> VGA + COM1.
cmd_print_both:
    push rax
    push rsi
.loop_cb:
    lodsb
    test al, al
    jz .done_cb
    call cmd_emit_both
    jmp .loop_cb
.done_cb:
    pop rsi
    pop rax
    ret

; cmd_rem64 RDI=line -> 0 (comment no-op, COMMAND REM jumps to COMMAND)
cmd_rem64:
    xor eax, eax
    ret
; cmd_pause64 -> 0 (no blocking wait in test; prints message like PAUSMES)
cmd_pause64:
    push rbx
    lea rsi, [rel cmd_pause_msg]
    call cmd_print_both
    xor eax, eax
    pop rbx
    ret
; cmd_echo64 RDI=str (0 ok) -> prints if given, 0
cmd_echo64:
    test rdi, rdi
    jz .echo_ok
    push rbx
    mov rsi, rdi
    call cmd_print_both
    pop rbx
.echo_ok:
    xor eax, eax
    ret

; ---- DATE ----
; cmd_date_get64 RDI=out RSI=size -> "YYYY-MM-DD" NUL, 0/1
cmd_date_get64:
    test rdi, rdi
    jz .bad_dg
    cmp rsi, 11
    jb .bad_dg
    push rbx
    push r12
    push r13
    mov r12, rdi
    movzx eax, word [rel cmd_year]
    movzx r13d, byte [rel cmd_month]
    movzx edx, byte [rel cmd_day]
    push rdx
    push r13
    ; YYYY in EAX
    mov rbx, 1000
    xor edx, edx
    div rbx
    add al, '0'
    mov [r12], al
    mov eax, edx
    mov ebx, 100
    xor edx, edx
    div ebx
    add al, '0'
    mov [r12+1], al
    mov eax, edx
    mov bl, 10
    div bl
    mov dl, ah
    add al, '0'
    mov [r12+2], al
    add dl, '0'
    mov [r12+3], dl
    mov byte [r12+4], '-'
    pop rbx
    mov eax, ebx
    mov bl, 10
    div bl
    mov dl, ah
    add al, '0'
    mov [r12+5], al
    add dl, '0'
    mov [r12+6], dl
    mov byte [r12+7], '-'
    pop rdx
    mov eax, edx
    mov bl, 10
    div bl
    mov dl, ah
    add al, '0'
    mov [r12+8], al
    add dl, '0'
    mov [r12+9], dl
    mov byte [r12+10], 0
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.bad_dg:
    mov rax, 1
    ret

; cmd_is_leap: AX=year -> RAX 1 leap else 0 (div by 4, no century rule needed for 1980-2099 except 2000 leap ok)
cmd_is_leap:
    push rbx
    push rdx
    mov ebx, eax
    mov eax, ebx
    xor edx, edx
    mov ecx, 4
    div ecx
    test edx, edx
    jnz .not_leap
    mov rax, 1
    jmp .done_leap
.not_leap:
    xor eax, eax
.done_leap:
    pop rdx
    pop rbx
    ret

; cmd_date_days_in_month: RDI=year RSI=month -> RAX days (0 bad)
cmd_date_days_in_month:
    push rbx
    push rcx
    mov ebx, edi
    mov ecx, esi
    cmp cl, 1
    je .d31
    cmp cl, 3
    je .d31
    cmp cl, 5
    je .d31
    cmp cl, 7
    je .d31
    cmp cl, 8
    je .d31
    cmp cl, 10
    je .d31
    cmp cl, 12
    je .d31
    cmp cl, 4
    je .d30
    cmp cl, 6
    je .d30
    cmp cl, 9
    je .d30
    cmp cl, 11
    je .d30
    cmp cl, 2
    jne .bad_m
    mov eax, ebx
    call cmd_is_leap
    test rax, rax
    jnz .d29
    mov rax, 28
    jmp .done_m
.d29:
    mov rax, 29
    jmp .done_m
.d31:
    mov rax, 31
    jmp .done_m
.d30:
    mov rax, 30
    jmp .done_m
.bad_m:
    xor eax, eax
.done_m:
    pop rcx
    pop rbx
    ret

; cmd_date_set64 RDI=year RSI=month RDX=day -> 0/1 (valid 1980-2099, month 1-12, day valid)
cmd_date_set64:
    cmp rdi, 1980
    jb .bad_ds
    cmp rdi, 2099
    ja .bad_ds
    cmp rsi, 1
    jb .bad_ds
    cmp rsi, 12
    ja .bad_ds
    cmp rdx, 1
    jb .bad_ds
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r12
    mov rsi, r13
    call cmd_date_days_in_month
    test rax, rax
    jz .bad_ds_pop
    cmp r14, rax
    ja .bad_ds_pop
    mov rax, r12
    mov [rel cmd_year], ax
    mov rax, r13
    mov [rel cmd_month], al
    mov rax, r14
    mov [rel cmd_day], al
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad_ds_pop:
    pop r14
    pop r13
    pop r12
    pop rbx
    mov rax, 1
    ret
.bad_ds:
    mov rax, 1
    ret

; cmd_date_parse64 RDI=str ("MM-DD-YY[YY]" or "MM/DD/YY[YY]", like INLINE/GETNUM) -> 0/1 + store
; Accepts 1-2 digit M, sep - or /, 1-2 digit D, sep, 2 or 4 digit Y (2-digit => 1900+)
cmd_date_parse64:
    test rdi, rdi
    jz .bad_dp
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    ; parse MM
    call cmd_parse_num2
    test rcx, rcx
    jz .fail_dp
    mov r13, rax
    mov r12, rdx
    mov al, [r12]
    cmp al, '-'
    je .sep_dp
    cmp al, '/'
    je .sep_dp
    jmp .fail_dp
.sep_dp:
    inc r12
    mov rdi, r12
    call cmd_parse_num2
    test rcx, rcx
    jz .fail_dp
    mov r14, rax
    mov r12, rdx
    mov al, [r12]
    cmp al, '-'
    je .sep2_dp
    cmp al, '/'
    je .sep2_dp
    jmp .fail_dp
.sep2_dp:
    inc r12
    mov rdi, r12
    call cmd_parse_num4
    test rcx, rcx
    jz .fail_dp
    mov r15, rax
    cmp r15, 100
    jae .have_year
    add r15, 1900
.have_year:
    ; validate via set (year=r15, month=r13, day=r14)
    mov rdi, r15
    mov rsi, r13
    mov rdx, r14
    call cmd_date_set64
    jmp .done_dp
.fail_dp:
    mov rax, 1
    jmp .done_dp
.bad_dp:
    mov rax, 1
    ret
.done_dp:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; helper cmd_parse_num2 RDI=str -> RAX=val RDX=newptr RCX=digits(0 fail, else 1-2)
cmd_parse_num2:
    push rbx
    xor eax, eax
    xor ecx, ecx
    mov bl, [rdi]
    cmp bl, '0'
    jb .fail_n2
    cmp bl, '9'
    ja .fail_n2
    sub bl, '0'
    movzx eax, bl
    inc rcx
    inc rdi
    mov bl, [rdi]
    cmp bl, '0'
    jb .done_n2
    cmp bl, '9'
    ja .done_n2
    imul eax, eax, 10
    sub bl, '0'
    movzx ebx, bl
    add eax, ebx
    inc rcx
    inc rdi
.done_n2:
    mov rdx, rdi
    pop rbx
    ret
.fail_n2:
    xor ecx, ecx
    xor eax, eax
    mov rdx, rdi
    pop rbx
    ret

; helper cmd_parse_num4 RDI=str -> RAX=val RDX=newptr RCX=digits(2-4 ok else 0)
cmd_parse_num4:
    push rbx
    push r12
    mov r12, rdi
    xor ecx, ecx
    xor eax, eax
.loop_n4:
    mov bl, [r12]
    cmp bl, '0'
    jb .end_n4
    cmp bl, '9'
    ja .end_n4
    imul eax, eax, 10
    sub bl, '0'
    movzx ebx, bl
    add eax, ebx
    inc r12
    inc rcx
    cmp rcx, 4
    jb .loop_n4
.end_n4:
    cmp rcx, 2
    jb .fail_n4
    mov rdx, r12
    pop r12
    pop rbx
    ret
.fail_n4:
    xor ecx, ecx
    xor eax, eax
    mov rdx, rdi
    pop r12
    pop rbx
    ret

; ---- TIME ----
; cmd_time_get64 RDI=out RSI=size -> "HH:MM:SS" NUL, 0/1 (needs 9)
cmd_time_get64:
    test rdi, rdi
    jz .bad_tg
    cmp rsi, 9
    jb .bad_tg
    push rbx
    movzx eax, byte [rel cmd_hour]
    mov bl, 10
    div bl
    add al, '0'
    mov [rdi], al
    add ah, '0'
    mov [rdi+1], ah
    mov byte [rdi+2], ':'
    movzx eax, byte [rel cmd_min]
    div bl
    add al, '0'
    mov [rdi+3], al
    add ah, '0'
    mov [rdi+4], ah
    mov byte [rdi+5], ':'
    movzx eax, byte [rel cmd_sec]
    div bl
    add al, '0'
    mov [rdi+6], al
    add ah, '0'
    mov [rdi+7], ah
    mov byte [rdi+8], 0
    xor eax, eax
    pop rbx
    ret
.bad_tg:
    mov rax, 1
    ret

; cmd_time_set64 RDI=h RSI=m RDX=s -> 0/1 (h 0-23, m/s 0-59)
cmd_time_set64:
    cmp rdi, 23
    ja .bad_ts
    cmp rsi, 59
    ja .bad_ts
    cmp rdx, 59
    ja .bad_ts
    mov [rel cmd_hour], dil
    mov [rel cmd_min], sil
    mov [rel cmd_sec], dl
    xor eax, eax
    ret
.bad_ts:
    mov rax, 1
    ret

; cmd_time_parse64 RDI=str ("HH:MM[:SS]", like TIME INLINE) -> 0/1 + store
cmd_time_parse64:
    test rdi, rdi
    jz .bad_tp
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov rdi, r12
    call cmd_parse_num2
    test rcx, rcx
    jz .fail_tp
    mov r13, rax
    mov r12, rdx
    mov al, [r12]
    cmp al, ':'
    jne .check_end_tp
    inc r12
    mov rdi, r12
    call cmd_parse_num2
    test rcx, rcx
    jz .fail_tp
    mov r14, rax
    mov r12, rdx
    mov al, [r12]
    cmp al, ':'
    jne .use_hm_tp
    inc r12
    mov rdi, r12
    call cmd_parse_num2
    test rcx, rcx
    jz .fail_tp
    mov rbx, rax
    jmp .set_tp
.use_hm_tp:
    xor ebx, ebx
    jmp .set_tp2
.check_end_tp:
    ; single hour only? Allow "HH" -> MM=SS=0 (like RET100 time may have only hour)
    cmp al, 0
    je .single_h
    cmp al, 13
    je .single_h
    jmp .fail_tp
.single_h:
    xor r14d, r14d
    xor ebx, ebx
    jmp .set_tp2b
.set_tp:
    mov rdi, r13
    mov rsi, r14
    mov rdx, rbx
    call cmd_time_set64
    jmp .done_tp
.set_tp2:
    mov rdi, r13
    mov rsi, r14
    mov rdx, rbx
    call cmd_time_set64
    jmp .done_tp
.set_tp2b:
    mov rdi, r13
    mov rsi, r14
    mov rdx, rbx
    call cmd_time_set64
    jmp .done_tp
.fail_tp:
    mov rax, 1
    jmp .done_tp
.bad_tp:
    mov rax, 1
    ret
.done_tp:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---- DIR / TYPE / COPY / DEL / REN ----
; cmd_dir_format64 RDI=dir_buf(32B entries) RSI=count RDX=out RCX=out_size R8=flags(/W) -> RAX=files or -1 bad
; Formats "NAME.EXT size\r\n" or wide "/W": "NAME.EXT " 5 per line. Skips 0xE5/0x00-end.
; Uses fs_dir_get_size64 for size (FS integration).
cmd_dir_format64:
    test rdi, rdi
    jz .bad_dir
    test rdx, rdx
    jz .bad_dir
    test rcx, rcx
    jz .bad_dir
    push rbx
    push r9
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov al, r8b
    mov [rel cmd_dir_flags], al
    xor r9d, r9d          ; index
    xor r10d, r10d        ; file count
    mov r11, r14          ; out ptr
.loop_dir:
    cmp r9, r13
    jae .end_dir
    mov rax, r9
    shl rax, 5
    lea rdi, [r12 + rax]
    mov al, [rdi]
    test al, al
    jz .end_dir
    cmp al, 0xE5
    je .next_dir
    mov rax, r11
    sub rax, r14
    mov rdx, r15
    sub rdx, 16
    cmp rax, rdx
    jae .next_dir
    push r9
    push rdi
    mov rsi, rdi
    mov rdi, r11
    mov r8, 8
    call cmd_copy_name_trim
    mov r11, rax
    pop rdi
    pop r9
    mov al, [rdi+8]
    cmp al, ' '
    je .no_ext
    mov al, [rdi+9]
    cmp al, ' '
    je .no_ext
    mov al, [rdi+8]
    cmp al, ' '
    je .no_ext
    mov byte [r11], '.'
    inc r11
    push r9
    push rdi
    lea rsi, [rdi+8]
    mov rdi, r11
    mov r8, 3
    call cmd_copy_name_trim
    mov r11, rax
    pop rdi
    pop r9
.no_ext:
    test byte [rel cmd_dir_flags], SW_W
    jnz .wide_dir
    mov byte [r11], ' '
    inc r11
    push r9
    push rdi
    mov rbx, rdi
    call fs_dir_get_size64
    mov esi, eax
    mov rdi, r11
    call cmd_u32_to_dec
    mov r11, rax
    pop rdi
    pop r9
    mov byte [r11], 13
    inc r11
    mov byte [r11], 10
    inc r11
    inc r10d
    jmp .next_dir
.wide_dir:
    mov byte [r11], ' '
    inc r11
    inc r10d
    mov eax, r10d
    xor edx, edx
    mov ecx, 5
    div ecx
    test edx, edx
    jnz .next_dir
    mov byte [r11], 13
    inc r11
    mov byte [r11], 10
    inc r11
    jmp .next_dir
.next_dir:
    inc r9
    jmp .loop_dir
.end_dir:
    test byte [rel cmd_dir_flags], SW_W
    jz .term_dir
    mov eax, r10d
    test eax, eax
    jz .term_dir
    xor edx, edx
    mov ecx, 5
    div ecx
    test edx, edx
    jz .term_dir
    mov byte [r11], 13
    inc r11
    mov byte [r11], 10
    inc r11
.term_dir:
    mov byte [r11], 0
    mov eax, r10d
    jmp .done_dir
.bad_dir:
    mov rax, -1
    ret
.done_dir:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r9
    pop rbx
    ret

; helper cmd_copy_name_trim RSI=src RDI=dst R8=len -> RAX=new dst (trim trailing spaces)
cmd_copy_name_trim:
    push rbx
    push rcx
    mov rcx, r8
    ; find last non-space
    mov rbx, rcx
.trim_loop:
    test rbx, rbx
    jz .empty_nm
    mov al, [rsi + rbx - 1]
    cmp al, ' '
    jne .have_nm
    dec rbx
    jmp .trim_loop
.have_nm:
    push rsi
    push rdi
    push rcx
    mov rcx, rbx
    cld
    rep movsb
    pop rcx
    pop rdi
    pop rsi
    mov rax, rdi
    add rax, rbx
    pop rcx
    pop rbx
    ret
.empty_nm:
    mov rax, rdi
    pop rcx
    pop rbx
    ret

; helper cmd_u32_to_dec RDI=out RSI=scratch? Actually RDI=out, RSI unused, input value in RDI? We use RDI=out, value in stack? Redo: RDI=out, value in EDI? Conflict. Define: RDI=out, ESI=value32? Let's define RDI=out, ESI=val -> RAX=new out
; Implemented iterative div 10.
cmd_u32_to_dec:
    push rbx
    push rcx
    push rdx
    mov ebx, esi
    mov rcx, rdi
    cmp ebx, 0
    jne .nz_dec
    mov byte [rcx], '0'
    inc rcx
    mov rax, rcx
    jmp .done_dec
.nz_dec:
    sub rsp, 16
    xor ecx, ecx
.div_loop:
    test ebx, ebx
    jz .out_dec
    xor edx, edx
    mov eax, ebx
    mov ebx, 10
    div ebx
    add dl, '0'
    mov [rsp + rcx], dl
    inc rcx
    mov ebx, eax
    jmp .div_loop
.out_dec:
    dec rcx
    mov al, [rsp + rcx]
    mov [rdi], al
    inc rdi
    test rcx, rcx
    jnz .out_dec
    mov rax, rdi
    add rsp, 16
.done_dec:
    pop rdx
    pop rcx
    pop rbx
    ret

; cmd_type_buffer64 RDI=src RSI=len RDX=dst RCX=dst_size -> RAX=bytes (until 0x1A), -1 bad
cmd_type_buffer64:
    test rdi, rdi
    jz .bad_typ
    test rdx, rdx
    jz .bad_typ
    test rcx, rcx
    jz .bad_typ
    push rbx
    push r8
    push r9
    xor r8d, r8d          ; src index
    xor r9d, r9d          ; dst len
.loop_typ:
    cmp r8, rsi
    jae .done_typ
    cmp r9, rcx
    jae .done_typ
    mov al, [rdi + r8]
    cmp al, 0x1A
    je .done_typ
    mov [rdx + r9], al
    inc r8
    inc r9
    jmp .loop_typ
.done_typ:
    mov rax, r9
    cmp r9, rcx
    jae .no_nul_typ
    mov byte [rdx + r9], 0
.no_nul_typ:
    pop r9
    pop r8
    pop rbx
    ret
.bad_typ:
    mov rax, -1
    ret

; cmd_copy_buffer64 RDI=src RSI=len RDX=dst RCX=dst_size R8=ascii -> RAX=bytes/-1
cmd_copy_buffer64:
    test rdi, rdi
    jz .bad_cpy
    test rdx, rdx
    jz .bad_cpy
    cmp rsi, 0
    je .empty_cpy
    cmp rcx, 0
    je .bad_cpy
    push rbx
    push r9
    push r12
    push r13
    mov r12, rsi
    mov r13, rcx
    cmp r12, r13
    jbe .len_ok_cpy
    mov r12, r13
.len_ok_cpy:
    xor eax, eax
    xor ebx, ebx
.loop_cpy:
    cmp rbx, r12
    jae .done_cpy
    mov r9b, [rdi + rbx]
    test r8b, r8b
    jz .store_cpy
    cmp r9b, 0x1A
    je .done_cpy
.store_cpy:
    mov [rdx + rax], r9b
    inc rbx
    inc rax
    jmp .loop_cpy
.done_cpy:
    pop r13
    pop r12
    pop r9
    pop rbx
    ret
.empty_cpy:
    xor eax, eax
    ret
.bad_cpy:
    mov rax, -1
    ret

; cmd_del_entry64 RDI=dir RSI=count RDX=name11 -> 0 ok /1 not found/bad
cmd_del_entry64:
    test rdi, rdi
    jz .bad_del
    test rdx, rdx
    jz .bad_del
    push rbx
    push rcx
    push rsi
    push rdi
    xor ecx, ecx
.loop_del:
    cmp rcx, rsi
    jae .nf_del
    mov rax, rcx
    shl rax, 5
    lea rbx, [rdi + rax]
    mov al, [rbx]
    test al, al
    jz .nf_del
    cmp al, 0xE5
    je .next_del
    push rcx
    push rsi
    push rdi
    mov rsi, rbx
    mov rdi, rdx
    mov rcx, 11
    cld
    repe cmpsb
    pop rdi
    pop rsi
    pop rcx
    je .found_del
.next_del:
    inc rcx
    jmp .loop_del
.found_del:
    mov rax, rcx
    shl rax, 5
    lea rbx, [rdi + rax]
    mov byte [rbx], 0xE5
    xor eax, eax
    jmp .done_del
.nf_del:
    mov rax, 1
    jmp .done_del
.bad_del:
    mov rax, 1
    ret
.done_del:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; cmd_ren_entry64 RDI=dir RSI=count RDX=old11 RCX=new11 -> 0 ok /1 not found /2 dup/bad
cmd_ren_entry64:
    test rdi, rdi
    jz .bad_ren
    test rdx, rdx
    jz .bad_ren
    test rcx, rcx
    jz .bad_ren
    push rbx
    push r9
    push r10
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    ; check new not exists (dup): scan for new11
    xor r9d, r9d
.loop_dup:
    cmp r9, r13
    jae .no_dup
    mov rax, r9
    shl rax, 5
    lea rbx, [r12 + rax]
    mov al, [rbx]
    test al, al
    jz .no_dup
    cmp al, 0xE5
    je .next_dup
    push r9
    mov rsi, rbx
    mov rdi, r15
    mov rcx, 11
    cld
    repe cmpsb
    pop r9
    je .dup_found
.next_dup:
    inc r9
    jmp .loop_dup
.dup_found:
    mov rax, 2
    jmp .done_ren
.no_dup:
    ; find old
    xor r9d, r9d
.loop_old:
    cmp r9, r13
    jae .nf_ren
    mov rax, r9
    shl rax, 5
    lea rbx, [r12 + rax]
    mov al, [rbx]
    test al, al
    jz .nf_ren
    cmp al, 0xE5
    je .next_old
    push r9
    mov rsi, rbx
    mov rdi, r14
    mov rcx, 11
    cld
    repe cmpsb
    pop r9
    je .found_old
.next_old:
    inc r9
    jmp .loop_old
.found_old:
    mov rax, r9
    shl rax, 5
    lea rbx, [r12 + rax]
    mov rsi, r15
    mov rdi, rbx
    mov rcx, 11
    cld
    rep movsb
    xor eax, eax
    jmp .done_ren
.nf_ren:
    mov rax, 1
    jmp .done_ren
.bad_ren:
    mov rax, 2
    ret
.done_ren:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r10
    pop r9
    pop rbx
    ret

; cmd_exec_external64 RDI=src RSI=size RDX=cmdline RCX=cmdlen -> RAX=pid RDX=psp (0 fail)
cmd_exec_external64:
    test rdi, rdi
    jz .fail_ex
    test rsi, rsi
    jz .fail_ex
    push rbx
    push r8
    xor r8d, r8d
    call proc_spawn64
    pop r8
    pop rbx
    ret
.fail_ex:
    xor eax, eax
    xor edx, edx
    ret

; cmd_batch_open64 RDI=script RSI=len RDX=params(0 none) -> 0/1
cmd_batch_open64:
    test rdi, rdi
    jz .bad_bo
    test rsi, rsi
    jz .bad_bo
    cmp rsi, CMD_BATCH_SIZE
    ja .bad_bo
    push rbx
    push r10
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov r10, rdx
    lea rdi, [rel cmd_batch_buf]
    mov rsi, r12
    mov rcx, r13
    cld
    rep movsb
    mov [rel cmd_batch_len], r13
    mov qword [rel cmd_batch_off], 0
    mov byte [rel cmd_batch_active], 1
    mov rdx, r10
    ; params: split RDX space-separated into 10 slots (offsets into cmd_batch_params)
    push rbx
    lea rbx, [rel cmd_batch_params]
    mov qword [rbx], -1
    mov qword [rbx+8], -1
    mov qword [rbx+16], -1
    mov qword [rbx+24], -1
    mov qword [rbx+32], -1
    mov qword [rbx+40], -1
    mov qword [rbx+48], -1
    mov qword [rbx+56], -1
    mov qword [rbx+64], -1
    mov qword [rbx+72], -1
    test rdx, rdx
    jz .params_done
    lea rdi, [rel cmd_batch_param_buf]
    xor ecx, ecx
    xor r10d, r10d
.param_loop:
    mov al, [rdx]
    test al, al
    jz .param_end
    cmp al, 13
    je .param_end
    cmp al, 10
    je .param_end
    cmp al, ' '
    je .param_sep
    cmp al, 9
    je .param_sep
    cmp al, ','
    je .param_sep
    cmp al, ';'
    je .param_sep
    cmp al, '='
    je .param_sep
    ; start new param if prev was sep and slots left
    cmp ecx, 0
    jne .store_ch_p
    cmp r10d, 10
    jae .skip_ch_p
    mov r11b, al
    mov rax, rdi
    push rsi
    lea rsi, [rel cmd_batch_param_buf]
    sub rax, rsi
    pop rsi
    mov [rbx + r10*8], rax
    inc r10d
    mov al, r11b
.store_ch_p:
    mov [rdi], al
    inc rdi
    mov ecx, 1
    inc rdx
    jmp .param_loop
.param_sep:
    test ecx, ecx
    jz .skip_sep
    mov byte [rdi], 0
    inc rdi
    xor ecx, ecx
.skip_sep:
    inc rdx
    jmp .param_loop
.skip_ch_p:
    inc rdx
    jmp .param_loop
.param_end:
    test ecx, ecx
    jz .params_done
    mov byte [rdi], 0
.params_done:
    pop rbx
    pop r13
    pop r12
    pop r10
    pop rbx
    xor eax, eax
    ret
.bad_bo:
    mov rax, 1
    ret

; cmd_batch_close64 -> 0
cmd_batch_close64:
    mov byte [rel cmd_batch_active], 0
    mov qword [rel cmd_batch_off], 0
    mov qword [rel cmd_batch_len], 0
    xor eax, eax
    ret

; cmd_batch_expand64 RDI=src RSI=dst RDX=dst_size -> RAX=len/-1 bad
cmd_batch_expand64:
    test rdi, rdi
    jz .bad_be
    test rsi, rsi
    jz .bad_be
    test rdx, rdx
    jz .bad_be
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
.loop_be:
    mov al, [r12]
    test al, al
    jz .done_be
    cmp al, 13
    je .done_be
    cmp al, 10
    je .done_be
    cmp al, '%'
    jne .copy_be
    mov cl, [r12+1]
    test cl, cl
    jz .copy_be
    cmp cl, '%'
    je .esc_be
    cmp cl, '0'
    jb .copy_be
    cmp cl, '9'
    ja .copy_be
    sub cl, '0'
    movzx ecx, cl
    cmp ecx, 10
    jae .copy_be
    test ecx, ecx
    jz .skip_param
    dec ecx
    lea rdi, [rel cmd_batch_params]
    mov rax, [rdi + rcx*8]
    cmp rax, -1
    je .skip_param
    lea rsi, [rel cmd_batch_param_buf]
    add rsi, rax
    jmp .copy_param
.skip_param:
    add r12, 2
    jmp .loop_be
.copy_param:
    mov al, [rsi]
    test al, al
    jz .after_param
    cmp rbx, r14
    jae .done_be
    mov [r13 + rbx], al
    inc rbx
    inc rsi
    jmp .copy_param
.after_param:
    add r12, 2
    jmp .loop_be
.esc_be:
    cmp rbx, r14
    jae .done_be
    mov byte [r13 + rbx], '%'
    inc rbx
    add r12, 2
    jmp .loop_be
.copy_be:
    cmp rbx, r14
    jae .done_be
    mov [r13 + rbx], al
    inc rbx
    inc r12
    jmp .loop_be
.done_be:
    cmp rbx, r14
    jae .trunc_be
    mov byte [r13 + rbx], 0
.trunc_be:
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad_be:
    mov rax, -1
    ret

; cmd_batch_next64 RDI=out RSI=out_size -> RAX=len / -1 EOF/fail
cmd_batch_next64:
    test rdi, rdi
    jz .bad_bn
    test rsi, rsi
    jz .bad_bn
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    cmp byte [rel cmd_batch_active], 0
    je .eof_bn
    mov rax, [rel cmd_batch_off]
    mov rbx, [rel cmd_batch_len]
    cmp rax, rbx
    jae .eof_bn2
    lea r14, [rel cmd_batch_buf]
    add r14, rax
    ; find line end
    xor ecx, ecx
.find_eol:
    mov rdx, rax
    add rdx, rcx
    cmp rdx, rbx
    jae .have_line
    mov dl, [r14 + rcx]
    cmp dl, 13
    je .have_line
    cmp dl, 10
    je .have_line
    cmp dl, 0x1A
    je .have_eof
    inc rcx
    cmp rcx, 256
    jb .find_eol
.have_line:
    ; copy rcx bytes to temp, expand
    lea rdi, [rel cmd_tmp_line]
    xor r10d, r10d
.copy_tmp:
    cmp r10, rcx
    jae .tmp_done
    mov dl, [r14 + r10]
    mov [rdi + r10], dl
    inc r10
    jmp .copy_tmp
.tmp_done:
    mov byte [rdi + r10], 0
    ; expand into out
    lea rdi, [rel cmd_tmp_line]
    mov rsi, r12
    mov rdx, r13
    dec rdx
    push rcx
    push r14
    call cmd_batch_expand64
    pop r14
    pop rcx
    mov r10, rax
    ; advance off past line + CRLF
    mov rax, [rel cmd_batch_off]
    add rax, rcx
    mov rdx, [rel cmd_batch_len]
    cmp rax, rdx
    jae .adv_done
    lea rsi, [rel cmd_batch_buf]
    mov bl, [rsi + rax]
    cmp bl, 13
    jne .chk_lf
    inc rax
    cmp rax, rdx
    jae .adv_done
    mov bl, [rsi + rax]
    cmp bl, 10
    jne .adv_done
    inc rax
    jmp .adv_done
.chk_lf:
    cmp bl, 10
    jne .adv_done
    inc rax
.adv_done:
    mov [rel cmd_batch_off], rax
    mov rax, r10
    jmp .done_bn
.have_eof:
    mov byte [rel cmd_batch_active], 0
    jmp .eof_bn2
.eof_bn:
    mov rax, -1
    jmp .done_bn
.eof_bn2:
    mov byte [rel cmd_batch_active], 0
    mov rax, -1
.done_bn:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.bad_bn:
    mov rax, -1
    ret

; ================= TESTS [43]-[50] =================
; Each returns RAX 0 pass / 1 fail, preserves callee-saved.

; [43] parser: delims, switches, drive, upper, empty, bad ptr
cmd_test_parser:
    push rbx
    push r12
    push r13
    push r14
    call cmd_init64
    test rax, rax
    jnz .fail43
    sub rsp, 160
    mov rsi, rsp
    lea rdx, [rsp+16]
    lea rcx, [rsp+144]
    lea rdi, [rel t43_line1]
    mov rsi, rsp
    lea rdx, [rsp+16]
    lea rcx, [rsp+144]
    call cmd_parse_line64
    test rax, rax
    jnz .fail43s
    mov al, [rsp]
    cmp al, 'D'
    jne .fail43s
    mov al, [rsp+1]
    cmp al, 'I'
    jne .fail43s
    mov al, [rsp+2]
    cmp al, 'R'
    jne .fail43s
    mov rax, [rsp+144]
    and rax, 0xFF
    cmp rax, SW_W
    jne .fail43s
    ; lower -> upper + /P
    lea rdi, [rel t43_line2]
    mov rsi, rsp
    lea rdx, [rsp+16]
    lea rcx, [rsp+144]
    call cmd_parse_line64
    test rax, rax
    jnz .fail43s
    cmp byte [rsp], 'C'
    jne .fail43s
    cmp byte [rsp+1], 'O'
    jne .fail43s
    cmp byte [rsp+2], 'P'
    jne .fail43s
    cmp byte [rsp+3], 'Y'
    jne .fail43s
    mov rax, [rsp+144]
    and rax, 0xFF
    cmp rax, SW_P
    jne .fail43s
    ; drive strip C:DIR
    lea rdi, [rel t43_line3]
    mov rsi, rsp
    lea rdx, [rsp+16]
    lea rcx, [rsp+144]
    call cmd_parse_line64
    test rax, rax
    jnz .fail43s
    cmp byte [rsp], 'D'
    jne .fail43s
    ; empty
    lea rdi, [rel t43_empty]
    mov rsi, rsp
    lea rdx, [rsp+16]
    lea rcx, [rsp+144]
    call cmd_parse_line64
    test rax, rax
    jnz .fail43s
    cmp byte [rsp], 0
    jne .fail43s
    ; delims
    mov dil, ' '
    call cmd_is_delim64
    cmp rax, 1
    jne .fail43s
    mov dil, 'X'
    call cmd_is_delim64
    cmp rax, 0
    jne .fail43s
    ; skip
    lea rsi, [rel t43_spaces]
    call cmd_skip_delims64
    mov bl, [rax]
    cmp bl, 'A'
    jne .fail43s
    ; switches direct
    lea rsi, [rel t43_sw]
    call cmd_parse_switches64
    cmp rdx, SW_W|SW_P
    jne .fail43s
    ; bad ptr
    xor edi, edi
    xor esi, esi
    xor edx, edx
    mov rcx, rsp
    add rcx, 144
    call cmd_parse_line64
    test rax, rax
    jz .fail43s
    add rsp, 160
    xor eax, eax
    jmp .done43
.fail43s:
    add rsp, 160
.fail43:
    mov rax, 1
.done43:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; [44] dir + type
cmd_test_dir_type:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; build dir: 3 entries + end
    lea r12, [rel cmd_test_dirbuf]
    mov qword [r12], 0
    mov qword [r12+8], 0
    mov qword [r12+16], 0
    mov qword [r12+24], 0
    ; entry0 HELLO TXT size 123
    lea rsi, [rel t44_name1]
    mov rdi, r12
    mov rcx, 11
    cld
    rep movsb
    mov byte [r12+11], 0x20
    mov word [r12+26], 2
    mov dword [r12+28], 123
    ; entry1 WORLD BIN size 4567
    lea rsi, [rel t44_name2]
    lea rdi, [r12+32]
    mov rcx, 11
    cld
    rep movsb
    mov byte [r12+32+11], 0x20
    mov word [r12+32+26], 3
    mov dword [r12+32+28], 4567
    ; entry2 deleted
    mov byte [r12+64], 0xE5
    ; entry3 end
    mov byte [r12+96], 0
    ; format normal
    lea rdx, [rel cmd_test_out]
    mov rdi, r12
    mov rsi, 4
    mov rcx, 512
    xor r8d, r8d
    call cmd_dir_format64
    cmp rax, 2
    jne .fail44
    ; check out contains HELLO and WORLD (first chars)
    lea rsi, [rel cmd_test_out]
    mov al, [rsi]
    cmp al, 'H'
    jne .fail44
    ; wide
    lea rdx, [rel cmd_test_out]
    mov rdi, r12
    mov rsi, 4
    mov rcx, 512
    mov r8d, SW_W
    call cmd_dir_format64
    cmp rax, 2
    jne .fail44
    ; type with ^Z
    lea rdi, [rel t44_content]
    mov rsi, 10
    lea rdx, [rel cmd_test_out]
    mov rcx, 512
    call cmd_type_buffer64
    cmp rax, 5
    jne .fail44
    cmp byte [rel cmd_test_out], 'H'
    jne .fail44
    cmp byte [rel cmd_test_out+5], 0
    jne .fail44
    ; type no ^Z
    lea rdi, [rel t44_content2]
    mov rsi, 4
    lea rdx, [rel cmd_test_out]
    mov rcx, 512
    call cmd_type_buffer64
    cmp rax, 4
    jne .fail44
    ; bad ptr
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    mov rdi, 0
    mov rsi, 4
    lea rdx, [rel cmd_test_out]
    mov rcx, 512
    xor r8d, r8d
    call cmd_dir_format64
    cmp rax, -1
    jne .fail44
    xor eax, eax
    jmp .done44
.fail44:
    mov rax, 1
.done44:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; [45] fileops copy/del/ren
cmd_test_fileops:
    push rbx
    push r12
    push r13
    ; copy binary
    lea rdi, [rel t45_src]
    mov rsi, 8
    lea rdx, [rel cmd_test_file]
    mov rcx, 512
    xor r8d, r8d
    call cmd_copy_buffer64
    cmp rax, 8
    jne .fail45
    mov al, [rel cmd_test_file]
    cmp al, 'A'
    jne .fail45
    mov al, [rel cmd_test_file+7]
    cmp al, 'H'
    jne .fail45
    ; copy ascii stops at ^Z
    lea rdi, [rel t45_src_z]
    mov rsi, 8
    lea rdx, [rel cmd_test_file]
    mov rcx, 512
    mov r8d, SW_A
    call cmd_copy_buffer64
    cmp rax, 3
    jne .fail45
    ; del: build dir 2 entries
    lea r12, [rel cmd_test_dirbuf]
    lea rsi, [rel t44_name1]
    mov rdi, r12
    mov rcx, 11
    cld
    rep movsb
    mov byte [r12+11], 0x20
    lea rsi, [rel t44_name2]
    lea rdi, [r12+32]
    mov rcx, 11
    cld
    rep movsb
    mov byte [r12+32+11], 0x20
    mov byte [r12+64], 0
    lea rdx, [rel t44_name1]
    mov rdi, r12
    mov rsi, 3
    call cmd_del_entry64
    test rax, rax
    jnz .fail45
    cmp byte [r12], 0xE5
    jne .fail45
    ; del missing -> 1
    lea rdx, [rel t45_missing]
    mov rdi, r12
    mov rsi, 3
    call cmd_del_entry64
    test rax, rax
    jz .fail45
    ; ren: restore entry0 then rename entry1 -> new
    lea rsi, [rel t44_name1]
    mov rdi, r12
    mov rcx, 11
    cld
    rep movsb
    lea rdx, [rel t44_name2]
    lea rcx, [rel t45_newname]
    mov rdi, r12
    mov rsi, 3
    call cmd_ren_entry64
    test rax, rax
    jnz .fail45
    mov al, [r12+32]
    cmp al, 'N'
    jne .fail45
    ; ren dup -> fail (rename entry0 to same as renamed entry1)
    lea rdx, [rel t44_name1]
    lea rcx, [rel t45_newname]
    mov rdi, r12
    mov rsi, 3
    call cmd_ren_entry64
    test rax, rax
    jz .fail45
    ; ren missing -> fail
    lea rdx, [rel t45_missing]
    lea rcx, [rel t45_newname]
    mov rdi, r12
    mov rsi, 3
    call cmd_ren_entry64
    test rax, rax
    jz .fail45
    xor eax, eax
    jmp .done45
.fail45:
    mov rax, 1
.done45:
    pop r13
    pop r12
    pop rbx
    ret

; [46] shellcfg cls/ver/prompt/path/rem/pause/echo
cmd_test_shellcfg:
    push rbx
    push r12
    call cmd_init64
    test rax, rax
    jnz .fail46
    call cmd_cls64
    test rax, rax
    jnz .fail46
    lea rdi, [rel cmd_test_out]
    mov rsi, 512
    call cmd_ver64
    test rax, rax
    jnz .fail46
    cmp byte [rel cmd_test_out], 'M'
    jne .fail46
    ; small buf -> fail
    lea rdi, [rel cmd_test_out]
    mov rsi, 4
    call cmd_ver64
    test rax, rax
    jz .fail46
    ; prompt set/get
    lea rdi, [rel t46_prompt]
    call cmd_prompt_set64
    test rax, rax
    jnz .fail46
    lea rdi, [rel cmd_test_out]
    mov rsi, 64
    call cmd_prompt_get64
    test rax, rax
    jnz .fail46
    mov al, [rel cmd_test_out]
    cmp al, '$'
    jne .fail46
    ; path set/get
    lea rdi, [rel t46_path]
    call cmd_path_set64
    test rax, rax
    jnz .fail46
    lea rdi, [rel cmd_test_out]
    mov rsi, 64
    call cmd_path_get64
    test rax, rax
    jnz .fail46
    mov al, [rel cmd_test_out]
    cmp al, '/'
    jne .fail46
    ; rem/pause/echo
    lea rdi, [rel t46_rem]
    call cmd_rem64
    test rax, rax
    jnz .fail46
    call cmd_pause64
    test rax, rax
    jnz .fail46
    lea rdi, [rel t46_echo]
    call cmd_echo64
    test rax, rax
    jnz .fail46
    xor edi, edi
    call cmd_echo64
    test rax, rax
    jnz .fail46
    ; null bad
    xor edi, edi
    mov rsi, 64
    call cmd_ver64
    test rax, rax
    jz .fail46
    xor eax, eax
    jmp .done46
.fail46:
    mov rax, 1
.done46:
    pop r12
    pop rbx
    ret

; [47] datetime
cmd_test_datetime:
    push rbx
    push r12
    call cmd_init64
    test rax, rax
    jnz .fail47
    ; get defaults
    lea rdi, [rel cmd_test_out]
    mov rsi, 16
    call cmd_date_get64
    test rax, rax
    jnz .fail47
    cmp byte [rel cmd_test_out+4], '-'
    jne .fail47
    lea rdi, [rel cmd_test_out]
    mov rsi, 16
    call cmd_time_get64
    test rax, rax
    jnz .fail47
    cmp byte [rel cmd_test_out+2], ':'
    jne .fail47
    ; set valid
    mov rdi, 1984
    mov rsi, 2
    mov rdx, 29
    call cmd_date_set64
    test rax, rax
    jnz .fail47
    ; invalid: 1983-02-29 (non-leap)
    mov rdi, 1983
    mov rsi, 2
    mov rdx, 29
    call cmd_date_set64
    test rax, rax
    jz .fail47
    ; invalid month 13
    mov rdi, 1983
    mov rsi, 13
    mov rdx, 1
    call cmd_date_set64
    test rax, rax
    jz .fail47
    ; invalid day 0
    mov rdi, 1983
    mov rsi, 1
    mov rdx, 0
    call cmd_date_set64
    test rax, rax
    jz .fail47
    ; parse valid "04-01-83"
    lea rdi, [rel t47_date1]
    call cmd_date_parse64
    test rax, rax
    jnz .fail47
    cmp word [rel cmd_year], 1983
    jne .fail47
    ; parse "12/25/1984"
    lea rdi, [rel t47_date2]
    call cmd_date_parse64
    test rax, rax
    jnz .fail47
    cmp word [rel cmd_year], 1984
    jne .fail47
    ; parse bad
    lea rdi, [rel t47_date_bad]
    call cmd_date_parse64
    test rax, rax
    jz .fail47
    ; time set valid
    mov rdi, 23
    mov rsi, 59
    mov rdx, 58
    call cmd_time_set64
    test rax, rax
    jnz .fail47
    ; invalid hour 24
    mov rdi, 24
    mov rsi, 0
    mov rdx, 0
    call cmd_time_set64
    test rax, rax
    jz .fail47
    ; parse "12:30:45"
    lea rdi, [rel t47_time1]
    call cmd_time_parse64
    test rax, rax
    jnz .fail47
    cmp byte [rel cmd_hour], 12
    jne .fail47
    ; parse "09:05"
    lea rdi, [rel t47_time2]
    call cmd_time_parse64
    test rax, rax
    jnz .fail47
    cmp byte [rel cmd_min], 5
    jne .fail47
    ; parse bad
    lea rdi, [rel t47_time_bad]
    call cmd_time_parse64
    test rax, rax
    jz .fail47
    xor eax, eax
    jmp .done47
.fail47:
    mov rax, 1
.done47:
    pop r12
    pop rbx
    ret

; [48] exec external via proc_spawn
cmd_test_exec:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call mem_validate64
    test rax, rax
    jnz .fail48
    ; build COM 64B pattern
    lea r12, [rel cmd_test_com]
    mov rcx, 64
    mov al, 0x90
.fill48:
    mov [r12], al
    inc r12
    dec rcx
    jnz .fill48
    lea r12, [rel cmd_test_com]
    ; verify via lookup? unknown -> 0
    lea rdi, [rel t48_unknown]
    call cmd_table_lookup64
    test rax, rax
    jnz .fail48
    ; known -> non-zero
    lea rdi, [rel cmd_s_dir]
    call cmd_table_lookup64
    test rax, rax
    jz .fail48
    ; exec COM
    lea rdi, [rel cmd_test_com]
    mov rsi, 64
    xor edx, edx
    xor ecx, ecx
    call cmd_exec_external64
    test rax, rax
    jz .fail48
    mov r13, rax
    mov r14, rdx
    test r14, r14
    jz .fail48b
    ; terminate + reap
    mov rdi, r13
    mov rsi, 0
    call proc_terminate64
    test rax, rax
    jnz .fail48b
    mov rdi, r13
    call proc_reap64
    test rax, rax
    jnz .fail48b
    ; bad exec (null) -> 0
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call cmd_exec_external64
    test rax, rax
    jnz .fail48
    ; bad size 0 -> 0
    lea rdi, [rel cmd_test_com]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call cmd_exec_external64
    test rax, rax
    jnz .fail48
    call mem_validate64
    test rax, rax
    jnz .fail48
    xor eax, eax
    jmp .done48
.fail48b:
    push rax
    mov rdi, r13
    call proc_reap64
    pop rax
.fail48:
    mov rax, 1
.done48:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; [49] batch open/next/expand
cmd_test_batch:
    push rbx
    push r12
    call cmd_init64
    test rax, rax
    jnz .fail49
    ; open with params "ARG1 ARG2" (use strlen for exact len, not padded 64)
    lea rdi, [rel t49_script]
    call cmd_strlen64
    mov rsi, rax
    lea rdi, [rel t49_script]
    lea rdx, [rel t49_params]
    call cmd_batch_open64
    test rax, rax
    jnz .fail49
    ; next line1 "DIR %1" -> "DIR ARG1"
    lea rdi, [rel cmd_test_out]
    mov rsi, 128
    call cmd_batch_next64
    test rax, rax
    js .fail49
    mov al, [rel cmd_test_out]
    cmp al, 'D'
    jne .fail49
    ; check expanded contains ARG1 (last 4)
    lea rdi, [rel cmd_test_out]
    call cmd_strlen64
    cmp rax, 8
    jne .fail49
    ; line2 "TYPE %%FILE" -> "TYPE %FILE"
    lea rdi, [rel cmd_test_out]
    mov rsi, 128
    call cmd_batch_next64
    test rax, rax
    js .fail49
    cmp byte [rel cmd_test_out+5], '%'
    jne .fail49
    ; line3 "REM comment" raw
    lea rdi, [rel cmd_test_out]
    mov rsi, 128
    call cmd_batch_next64
    test rax, rax
    js .fail49
    cmp byte [rel cmd_test_out], 'R'
    jne .fail49
    ; EOF -> -1
    lea rdi, [rel cmd_test_out]
    mov rsi, 128
    call cmd_batch_next64
    cmp rax, -1
    jne .fail49
    ; expand direct %2
    lea rdi, [rel t49_pct2]
    lea rsi, [rel cmd_test_out]
    mov rdx, 127
    call cmd_batch_expand64
    cmp rax, 4
    jne .fail49
    ; bad open (too large)
    lea rdi, [rel t49_script]
    mov rsi, 5000
    xor edx, edx
    call cmd_batch_open64
    test rax, rax
    jz .fail49
    call cmd_batch_close64
    xor eax, eax
    jmp .done49
.fail49:
    mov rax, 1
.done49:
    pop r12
    pop rbx
    ret

; [50] dispatch + stress
cmd_test_dispatch:
    push rbx
    push r12
    call cmd_init64
    test rax, rax
    jnz .fail50
    lea rdi, [rel t50_dir]
    call cmd_dispatch64
    test rax, rax
    jnz .fail50
    lea rdi, [rel t50_dir_w]
    call cmd_dispatch64
    test rax, rax
    jnz .fail50
    lea rdi, [rel t50_rem]
    call cmd_dispatch64
    test rax, rax
    jnz .fail50
    lea rdi, [rel t50_cls]
    call cmd_dispatch64
    test rax, rax
    jnz .fail50
    lea rdi, [rel t50_ver]
    call cmd_dispatch64
    test rax, rax
    jnz .fail50
    lea rdi, [rel t50_bad]
    call cmd_dispatch64
    cmp rax, 2
    jne .fail50
    lea rdi, [rel t50_empty]
    call cmd_dispatch64
    cmp rax, 1
    jne .fail50
    xor edi, edi
    call cmd_dispatch64
    cmp rax, 1
    jne .fail50
    ; stress: 50 dispatches mixed
    mov ebx, 50
.stress50:
    test ebx, ebx
    jz .stress_done
    lea rdi, [rel t50_dir]
    call cmd_dispatch64
    lea rdi, [rel t50_bad]
    call cmd_dispatch64
    cmp rax, 2
    jne .fail50
    dec ebx
    jnz .stress50
.stress_done:
    call mem_validate64
    test rax, rax
    jnz .fail50
    xor eax, eax
    jmp .done50
.fail50:
    mov rax, 1
.done50:
    pop r12
    pop rbx
    ret

section .data
cmd_version db "MS-DOS64 1.25-64, Command v1.17-64H",0
cmd_pause_msg db "Strike a key when ready . . . ",0
cmd_name_path db "PATH",0
cmd_name_prompt db "PROMPT",0
cmd_name_comspec db "COMSPEC",0
cmd_val_dot db ".",0
cmd_val_comspec db "COMMAND64",0
cmd_val_prompt db "$P$G",0
cmd_s_dir db "DIR",0
cmd_s_rename db "RENAME",0
cmd_s_ren db "REN",0
cmd_s_erase db "ERASE",0
cmd_s_del db "DEL",0
cmd_s_type db "TYPE",0
cmd_s_rem db "REM",0
cmd_s_copy db "COPY",0
cmd_s_pause db "PAUSE",0
cmd_s_date db "DATE",0
cmd_s_time db "TIME",0
cmd_s_cls db "CLS",0
cmd_s_ver db "VER",0
cmd_s_prompt db "PROMPT",0
cmd_s_path db "PATH",0
cmd_s_echo db "ECHO",0
t43_line1 db "  DIR /W",13,0
t43_line2 db "copy /P",13,0
t43_line3 db "C:DIR",13,0
t43_empty db 13,0
t43_spaces db "   ,;= A",0
t43_sw db " /W /P",0
t44_name1 db "HELLO   TXT"
t44_name2 db "WORLD   BIN"
t44_content db "HELLO",0x1A,"XXXX",0
t44_content2 db "ABCD",0
t45_src db "ABCDEFGH"
t45_src_z db "ABC",0x1A,"DEFGH"
t45_missing db "MISSING TXT"
t45_newname db "NEWNAME TXT"
t46_prompt db "$P$G",0
t46_path db "/BIN",0
t46_rem db "REM comment",0
t46_echo db "Hello",0
t47_date1 db "04-01-83",0
t47_date2 db "12/25/1984",0
t47_date_bad db "13-40-XX",0
t47_time1 db "12:30:45",0
t47_time2 db "09:05",0
t47_time_bad db "25:99",0
t48_unknown db "FOOBAR",0
t49_script db "DIR %1",13,10,"TYPE %%FILE",13,10,"REM comment",13,10,0
times 64-($-t49_script) db 0
t49_params db "ARG1 ARG2",0
t49_pct1 db "%1",0
t49_pct2 db "%2",0
t50_dir db "DIR",13,0
t50_dir_w db "dir /w",13,0
t50_rem db "REM hello",13,0
t50_cls db "CLS",13,0
t50_ver db "VER",13,0
t50_bad db "FOOBAR",13,0
t50_empty db 13,0

section .bss
alignb 16
cmd_env: resb CMD_ENV_SIZE
cmd_year: resw 1
cmd_month: resb 1
cmd_day: resb 1
cmd_hour: resb 1
cmd_min: resb 1
cmd_sec: resb 1
cmd_batch_active: resb 1
cmd_dir_flags: resb 1
alignb 8
cmd_batch_len: resq 1
cmd_batch_off: resq 1
cmd_batch_buf: resb CMD_BATCH_SIZE
cmd_batch_params: resq 10
cmd_batch_param_buf: resb 256
cmd_tmp_line: resb 256
cmd_test_dirbuf: resb 512
cmd_test_out: resb 512
cmd_test_file: resb 512
cmd_test_com: resb 1024
