; MS-DOS64 src/kernel/shell64.asm — interactive COMMAND64 REPL (G3)
; A real prompt loop on top of the tested parser/builtins/volume/EXEC:
; prompt (PROMPT env, mini $P$G expansion), line input (PS/2 kbd + COM1
; serial RX, so QEMU -serial stdio can drive it), parse via
; cmd_parse_line64, builtins against the mounted volume (DIR/TYPE/DEL/REN
; /COPY), config/date/time/echo/pause, HELP, EXIT, and external *.COM
; EXEC from the volume. Unknown names print the DOS error text.
; Size discipline: thin orchestration only; all work is delegated to
; cmd64/fs64/mem64/proc64/vga/kbd/serial handlers (keeps kernel ≤128 sec).
bits 64
default rel

%include "include/dpb.inc"
%include "include/fcb.inc"

section .text
global shell_repl64
global sh_exec_line

extern vga_print
extern vga_putc
extern vga_clear
extern kbd_getc
extern handler_reader
extern handler_punch
extern cmd_init64
extern cmd_parse_line64
extern cmd_table_lookup64
extern cmd_dir_format64
extern cmd_type_buffer64
extern cmd_copy_buffer64
extern cmd_cls64
extern cmd_ver64
extern cmd_prompt_set64
extern cmd_prompt_get64
extern cmd_path_set64
extern cmd_path_get64
extern cmd_rem64
extern cmd_pause64
extern cmd_echo64
extern cmd_date_get64
extern cmd_time_get64
extern cmd_date_parse64
extern cmd_time_parse64
extern cmd_del_entry64
extern cmd_ren_entry64
extern fs_mount_volume64
extern fs_vol_read_file64
extern fs_vol_flush_root64
extern fs_vol_root
extern fs_vol_dpb
extern fs_make_fcb64
extern mem_alloc64
extern mem_free64
extern proc_terminate64
extern proc_reap64
extern cmd_exec_external64
extern handler_create
extern handler_delete
extern handler_rename
extern handler_setdma
extern handler_blkwrt
extern handler_close
extern cmd_date_set64
extern cmd_time_set64
extern CURDRV64
extern pic_unmask_irq64
extern rtc_get_date64
extern rtc_get_time64
extern rtc_set_date64
extern rtc_set_time64
extern cmd_year
extern cmd_month
extern cmd_day
extern cmd_hour
extern cmd_min
extern cmd_sec

section .bss
alignb 16
sh_line:    resb 128
sh_cmd:     resb 16
sh_tail:    resb 128
sh_sw:      resd 1
sh_out:     resb 4096
sh_file:    resb 4096
sh_fcb:     resb 80
sh_fcb2:    resb 80
sh_prompt:  resb 64
sh_dtbuf:   resb 16

section .rodata
sh_banner:  db 13,10,"MS-DOS64 shell (COMMAND64). Type HELP for commands.",13,10,0
sh_help:    db "Builtins: DIR TYPE COPY DEL REN CLS VER PROMPT PATH ECHO REM PAUSE DATE TIME HELP EXIT",13,10
            db "External: <name> runs <name>.COM from the FAT12 volume.",13,10,0
sh_bad:     db "Bad command or file name",13,10,0
sh_nofile:  db "File not found",13,10,0
sh_nomem:   db "Insufficient memory",13,10,0
sh_loaded:  db "Loaded, pid ",0
sh_crlf:    db 13,10,0
sh_ext_com: db "COM"

section .text

; sh_serial_putc — AL=char -> COM1 (for serial echo; ignores timeout).
sh_serial_putc:
    push rdx
    push rax
    mov ah, al
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .drop_sp
    mov al, ah
    mov dx, 0x3F8
    out dx, al
.drop_sp:
    pop rax
    pop rdx
    ret

; sh_emit — AL=char -> VGA + serial.
sh_emit:
    push rax
    call vga_putc
    pop rax
    push rax
    call sh_serial_putc
    pop rax
    ret

; sh_print — RSI=string -> VGA + serial.
sh_print:
    push rax
    push rsi
.loop_sp:
    lodsb
    test al, al
    jz .done_sp
    call sh_emit
    jmp .loop_sp
.done_sp:
    pop rsi
    pop rax
    ret

; sh_poll_char — Out: CF=0 AL=char (kbd first, then serial), CF=1 none.
; Preserves RBX/RCX/RDX (handler_reader clobbers RCX/RDX live).
sh_poll_char:
    push rcx
    push rdx
    call kbd_getc
    jnc .have_pc
    call handler_reader
    jnc .have_pc
    stc
    jmp .done_pc
.have_pc:
    clc
.done_pc:
    pop rdx
    pop rcx
    ret

; sh_read_line — RDI=buf RSI=maxlen -> RAX=len (CR/LF submits, BS edits,
;   ESC clears). Echoes to VGA+serial. Spins on PAUSE when idle.
sh_read_line:
    push rbx
    push rcx
    push rdx
    push rdi
    mov rbx, rdi
    xor ecx, ecx
.poll_rl:
    call sh_poll_char
    jc .idle_rl
    cmp al, 13
    je .submit_rl
    cmp al, 10
    je .submit_rl
    cmp al, 8
    je .bs_rl
    cmp al, 127
    je .bs_rl
    cmp al, 27
    je .clear_rl
    cmp al, 32
    jb .poll_rl
    mov rdx, rsi
    dec rdx                       ; reserve one byte for NUL
    cmp rcx, rdx
    jae .poll_rl                  ; line full: drop char
    mov [rbx + rcx], al
    inc rcx
    call sh_emit
    jmp .poll_rl
.bs_rl:
    test rcx, rcx
    jz .poll_rl
    dec rcx
    mov al, 8
    call sh_emit
    mov al, ' '
    call sh_emit
    mov al, 8
    call sh_emit
    jmp .poll_rl
.clear_rl:
    test rcx, rcx
    jz .poll_rl
    dec rcx
    mov al, 8
    call sh_emit
    mov al, ' '
    call sh_emit
    mov al, 8
    call sh_emit
    test rcx, rcx
    jnz .clear_rl
    jmp .poll_rl
.idle_rl:
    pause
    jmp .poll_rl
.submit_rl:
    mov byte [rbx + rcx], 0
    mov rsi, sh_crlf
    call sh_print
    mov rax, rcx
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_prompt_show — expand PROMPT env (mini $X set) and print it.
sh_prompt_show:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    lea rdi, [rel sh_prompt]
    mov rsi, 64
    call cmd_prompt_get64
    test rax, rax
    jnz .default_pr
    cmp byte [rel sh_prompt], 0
    je .default_pr
    lea rsi, [rel sh_prompt]
.next_pr:
    lodsb
    test al, al
    jz .done_pr
    cmp al, '$'
    jne .emit_pr
    lodsb
    test al, al
    jz .done_pr
    cmp al, 'a'
    jb .code_pr
    cmp al, 'z'
    ja .code_pr
    sub al, 32
.code_pr:
    cmp al, 'P'
    je .drv_pr
    cmp al, 'N'
    je .drv_pr
    cmp al, 'G'
    je .ch_gt
    cmp al, 'L'
    je .ch_lt
    cmp al, 'B'
    je .ch_pipe
    cmp al, 'Q'
    je .ch_eq
    cmp al, '$'
    je .emit_pr
    cmp al, '_'
    je .crlf_pr
    cmp al, 'D'
    je .date_pr
    cmp al, 'T'
    je .time_pr
    cmp al, 'V'
    je .ver_pr
    jmp .next_pr
.emit_pr:
    call sh_emit
    jmp .next_pr
.drv_pr:
    mov al, [rel CURDRV64]
    add al, 'A'
    call sh_emit
    jmp .next_pr
.ch_gt:
    mov al, '>'
    call sh_emit
    jmp .next_pr
.ch_lt:
    mov al, '<'
    call sh_emit
    jmp .next_pr
.ch_pipe:
    mov al, '|'
    call sh_emit
    jmp .next_pr
.ch_eq:
    mov al, '='
    call sh_emit
    jmp .next_pr
.crlf_pr:
    mov rsi, sh_crlf
    call sh_print                 ; preserves RSI (scan continues after $_)
    jmp .next_pr
.date_pr:
    push rsi
    lea rdi, [rel sh_dtbuf]
    mov rsi, 16
    call cmd_date_get64
    pop rsi
    test rax, rax
    jnz .next_pr
    push rsi
    lea rsi, [rel sh_dtbuf]
    call sh_print
    pop rsi
    jmp .next_pr
.time_pr:
    push rsi
    lea rdi, [rel sh_dtbuf]
    mov rsi, 16
    call cmd_time_get64
    pop rsi
    test rax, rax
    jnz .next_pr
    push rsi
    lea rsi, [rel sh_dtbuf]
    call sh_print
    pop rsi
    jmp .next_pr
.ver_pr:
    push rsi
    lea rsi, [rel sh_verstr]
    call sh_print
    pop rsi
    jmp .next_pr
.default_pr:
    mov al, [rel CURDRV64]
    add al, 'A'
    call sh_emit
    mov al, '>'
    call sh_emit
.done_pr:
    mov al, ' '
    call sh_emit
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; sh_streq — RDI=a RSI=b(static upper) -> RAX 0 eq else 1 (a tolerant).
sh_streq:
    push rbx
    push rcx
    push rdi
    push rsi
.loop_sq:
    mov bl, [rdi]
    mov cl, [rsi]
    cmp bl, 'a'
    jb .cmp_sq
    cmp bl, 'z'
    ja .cmp_sq
    sub bl, 32
.cmp_sq:
    cmp bl, cl
    jne .diff_sq
    test cl, cl
    jz .eq_sq
    inc rdi
    inc rsi
    jmp .loop_sq
.diff_sq:
    mov rax, 1
    jmp .done_sq
.eq_sq:
    xor eax, eax
.done_sq:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ---- REPL builtins (all operate on the mounted volume) ----

; sh_do_dir — R8D=flags (/W). Lists vol_root via cmd_dir_format64.
sh_do_dir:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    call fs_mount_volume64
    test rax, rax
    jnz .fail_dir
    lea rbp, [rel fs_vol_dpb]
    mov esi, [rbp + DPB64.maxent]
    lea rdi, [rel fs_vol_root]
    lea rdx, [rel sh_out]
    mov rcx, 4096
    mov r8d, r8d
    and r8d, 1                    ; SW_W only
    call cmd_dir_format64
    cmp rax, -1
    je .fail_dir
    lea rsi, [rel sh_out]
    call sh_print
    xor eax, eax
    jmp .done_dir
.fail_dir:
    lea rsi, [rel sh_nofile]
    call sh_print
    mov rax, 1
.done_dir:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_do_type — RSI=filename tail. Reads file, stops at ^Z, prints.
sh_do_type:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    test rsi, rsi
    jz .fail_ty
    mov rdx, rsi
    lea rdi, [rel sh_fcb]
    mov rsi, rdx
    mov al, 1
    call fs_make_fcb64
    cmp al, 0xFF
    je .fail_ty
    lea rdi, [rel sh_fcb+1]      ; 11-byte name
    lea rsi, [rel sh_file]
    mov rdx, 4096
    call fs_vol_read_file64
    jc .fail_ty
    mov rsi, rax                 ; len
    lea rdi, [rel sh_file]
    lea rdx, [rel sh_out]
    mov rcx, 4096
    call cmd_type_buffer64
    lea rsi, [rel sh_out]
    call sh_print
    mov rsi, sh_crlf
    call sh_print
    xor eax, eax
    jmp .done_ty
.fail_ty:
    lea rsi, [rel sh_nofile]
    call sh_print
    mov rax, 1
.done_ty:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_do_del — RSI=tail. Deletes first matching entry, flushes root.
sh_do_del:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    test rsi, rsi
    jz .fail_dl2
    mov rdx, rsi
    lea rdi, [rel sh_fcb]
    mov rsi, rdx
    mov al, 1
    call fs_make_fcb64
    cmp al, 0xFF
    je .fail_dl2
    lea rdx, [rel sh_fcb]
    call handler_delete
    jc .fail_dl2
    xor eax, eax
    jmp .done_dl2
.fail_dl2:
    lea rsi, [rel sh_nofile]
    call sh_print
    mov rax, 1
.done_dl2:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_do_ren — RSI=tail ("old new"). Renames, flushes via handler.
sh_do_ren:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    test rsi, rsi
    jz .fail_rn3
    lea rdi, [rel sh_fcb]
    mov al, 1
    call fs_make_fcb64           ; RSI=tail -> old; RSI=end returned
    cmp al, 0xFF
    je .fail_rn3
    mov rdx, rsi                 ; second spec
    lea rdi, [rel sh_fcb2]
    mov rsi, rdx
    mov al, 1
    call fs_make_fcb64
    cmp al, 0xFF
    je .fail_rn3
    ; new 11-byte name -> sh_fcb+16
    lea rsi, [rel sh_fcb2+1]
    lea rdi, [rel sh_fcb+16]
    mov ecx, 11
    cld
    rep movsb
    lea rdx, [rel sh_fcb]
    call handler_rename
    jc .fail_rn3
    xor eax, eax
    jmp .done_rn3
.fail_rn3:
    lea rsi, [rel sh_nofile]
    call sh_print
    mov rax, 1
.done_rn3:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_do_copy — RSI=tail ("src dst"). Read src, create+write dst.
sh_do_copy:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    test rsi, rsi
    jz .fail_cp
    lea rdi, [rel sh_fcb]
    mov al, 1
    call fs_make_fcb64
    cmp al, 0xFF
    je .fail_cp
    mov rdx, rsi                 ; dst spec start
    lea rdi, [rel sh_fcb2]
    mov rsi, rdx
    mov al, 1
    call fs_make_fcb64
    cmp al, 0xFF
    je .fail_cp
    ; read src file -> sh_file
    lea rdi, [rel sh_fcb+1]
    lea rsi, [rel sh_file]
    mov rdx, 4096
    call fs_vol_read_file64
    jc .fail_cp
    mov r8, rax                  ; len
    test r8, r8
    jz .empty_cp
    ; DMA = file, create dst, block-write ceil(len/128) records
    lea rdx, [rel sh_file]
    call handler_setdma
    lea rdx, [rel sh_fcb2]
    call handler_create
    jc .fail_cp
    mov rax, r8
    add rax, 127
    shr rax, 7                   ; count
    mov rcx, rax
    mov qword [rel sh_fcb2+65], 0
    lea rdx, [rel sh_fcb2]
    call handler_blkwrt
    jc .fail_cp
    ; Truncate to the true byte length (block writes pad to 128B records).
    mov [rel sh_fcb2+20], r8      ; FCB64.filsiz (close syncs it to dir)
    lea rdx, [rel sh_fcb2]
    call handler_close
    jc .fail_cp
    xor eax, eax
    jmp .done_cp
.empty_cp:
    ; zero-length: create + close (empty file)
    lea rdx, [rel sh_fcb2]
    call handler_create
    jc .fail_cp
    lea rdx, [rel sh_fcb2]
    call handler_close
    jc .fail_cp
    xor eax, eax
    jmp .done_cp
.fail_cp:
    lea rsi, [rel sh_nofile]
    call sh_print
    mov rax, 1
.done_cp:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_do_exec — RDI=cmd name (upper, <=8), RSI=tail. Runs <name>.COM.
sh_do_exec:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r8, rdi                  ; cmd
    mov r9, rsi                  ; tail
    ; build 11-byte name in sh_fcb
    lea rdi, [rel sh_fcb]
    mov rcx, 11
    mov al, ' '
    cld
    rep stosb
    lea rbx, [rel sh_fcb]        ; (RIP-rel has no index form; use base)
    mov rcx, 8
    xor edx, edx
.copy_ex:
    cmp edx, 8
    jae .ext_ex
    mov al, [r8 + rdx]
    test al, al
    jz .ext_ex
    mov [rbx + rdx], al
    inc edx
    jmp .copy_ex
.ext_ex:
    lea rsi, [rel sh_ext_com]
    lea rdi, [rel sh_fcb+8]
    mov ecx, 3
    rep movsb
    ; stage file via mem_alloc
    lea rdi, [rel sh_fcb]
    lea rsi, [rel sh_file]
    mov rdx, 4096
    call fs_vol_read_file64
    jc .bad_ex
    mov r10, rax                 ; len
    test r10, r10
    jz .bad_ex
    mov rdi, r10
    call mem_alloc64
    test rax, rax
    jz .nomem_ex
    mov rbx, rax                 ; staging buffer
    lea rsi, [rel sh_file]
    mov rdi, rbx
    mov rcx, r10
    cld
    rep movsb
    mov rdi, rbx
    mov rsi, r10
    mov rdx, r9                  ; cmdline tail (may be empty string)
    call sh_tail_len
    mov rcx, rax
    call cmd_exec_external64     ; -> RAX=pid RDX=psp
    test rax, rax
    jz .exec_fail_ex
    mov r8, rax
    lea rsi, [rel sh_loaded]
    call sh_print                 ; (preserves R8/RBX/R10: pushes rax,rsi)
    mov rax, r8
    call sh_print_dec
    mov rsi, sh_crlf
    call sh_print
    mov rdi, r8
    xor esi, esi
    call proc_terminate64
    mov rdi, r8
    call proc_reap64
    mov rdi, rbx
    call mem_free64
    xor eax, eax
    jmp .done_ex
.exec_fail_ex:
    mov rdi, rbx
    call mem_free64
.bad_ex:
    lea rsi, [rel sh_bad]
    call sh_print
    mov rax, 1
    jmp .done_ex
.nomem_ex:
    lea rsi, [rel sh_nomem]
    call sh_print
    mov rax, 1
.done_ex:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_print_dec — RAX=u64 -> decimal to VGA+serial (pid display; 15 digits).
sh_print_dec:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [rel sh_dtbuf+15]
    mov byte [rdi], 0
    mov rbx, 10
    mov rcx, 15
    test rax, rax
    jnz .loop_pd
    dec rdi
    mov byte [rdi], '0'
    jmp .out_pd
.loop_pd:
    test rax, rax
    jz .out_pd
    test rcx, rcx
    jz .out_pd
    xor edx, edx
    div rbx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    dec rcx
    jmp .loop_pd
.out_pd:
    mov rsi, rdi
    call sh_print
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sh_tail_len — RDX=str (may be 0) -> RAX=len (max 127).
sh_tail_len:
    push rbx
    xor eax, eax
    test rdx, rdx
    jz .done_tl
    mov rbx, rdx
.loop_tl:
    cmp rax, 127
    jae .done_tl
    cmp byte [rbx + rax], 0
    je .done_tl
    inc rax
    jmp .loop_tl
.done_tl:
    pop rbx
    ret

; sh_exec_line — RDI=line. Parse + run one command. RAX 0 ok, 1 empty/fail,
;   2 exit-requested.
sh_exec_line:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    test rdi, rdi
    jz .empty_el
    lea rsi, [rel sh_cmd]
    lea rdx, [rel sh_tail]
    lea rcx, [rel sh_sw]
    call cmd_parse_line64
    test rax, rax
    jnz .empty_el
    cmp byte [rel sh_cmd], 0
    je .empty_el
    ; EXIT / HELP first (no table entries).
    lea rdi, [rel sh_cmd]
    lea rsi, [rel sh_s_exit]
    call sh_streq
    test rax, rax
    jz .exit_el
    lea rdi, [rel sh_cmd]
    lea rsi, [rel sh_s_help]
    call sh_streq
    test rax, rax
    jz .help_el
    ; Table lookup -> handler pointer compare.
    lea rdi, [rel sh_cmd]
    call cmd_table_lookup64
    test rax, rax
    jz .external_el
    lea rbx, [rel cmd_dir_format64]
    cmp rax, rbx
    je .dir_el
    lea rbx, [rel cmd_type_buffer64]
    cmp rax, rbx
    je .type_el
    lea rbx, [rel cmd_copy_buffer64]
    cmp rax, rbx
    je .copy_el
    lea rbx, [rel cmd_del_entry64]
    cmp rax, rbx
    je .del_el
    lea rbx, [rel cmd_ren_entry64]
    cmp rax, rbx
    je .ren_el
    lea rbx, [rel cmd_rem64]
    cmp rax, rbx
    je .ok_el
    lea rbx, [rel cmd_pause64]
    cmp rax, rbx
    je .pause_el
    lea rbx, [rel cmd_cls64]
    cmp rax, rbx
    je .cls_el
    lea rbx, [rel cmd_ver64]
    cmp rax, rbx
    je .ver_el
    lea rbx, [rel cmd_prompt_get64]
    cmp rax, rbx
    je .prompt_el
    lea rbx, [rel cmd_path_get64]
    cmp rax, rbx
    je .path_el
    lea rbx, [rel cmd_echo64]
    cmp rax, rbx
    je .echo_el
    lea rbx, [rel cmd_date_get64]
    cmp rax, rbx
    je .date_el
    lea rbx, [rel cmd_time_get64]
    cmp rax, rbx
    je .time_el
    jmp .ok_el
.dir_el:
    mov r8d, [rel sh_sw]
    call sh_do_dir
    jmp .done_el_rc
.type_el:
    lea rsi, [rel sh_tail]
    call sh_do_type
    jmp .done_el_rc
.copy_el:
    lea rsi, [rel sh_tail]
    call sh_do_copy
    jmp .done_el_rc
.del_el:
    lea rsi, [rel sh_tail]
    call sh_do_del
    jmp .done_el_rc
.ren_el:
    lea rsi, [rel sh_tail]
    call sh_do_ren
    jmp .done_el_rc
.pause_el:
    call cmd_pause64
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.cls_el:
    call cmd_cls64
    jmp .ok_el
.ver_el:
    lea rdi, [rel sh_out]
    mov rsi, 4096
    call cmd_ver64
    lea rsi, [rel sh_out]
    call sh_print
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.prompt_el:
    cmp byte [rel sh_tail], 0
    je .prompt_show_el
    lea rdi, [rel sh_tail]
    call cmd_prompt_set64
    jmp .ok_el
.prompt_show_el:
    lea rdi, [rel sh_out]
    mov rsi, 4096
    call cmd_prompt_get64
    lea rsi, [rel sh_out]
    call sh_print
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.path_el:
    cmp byte [rel sh_tail], 0
    je .path_show_el
    lea rdi, [rel sh_tail]
    call cmd_path_set64
    jmp .ok_el
.path_show_el:
    lea rdi, [rel sh_out]
    mov rsi, 4096
    call cmd_path_get64
    lea rsi, [rel sh_out]
    call sh_print
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.echo_el:
    lea rdi, [rel sh_tail]
    call cmd_echo64
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.date_el:
    cmp byte [rel sh_tail], 0
    je .date_show_el
    lea rdi, [rel sh_tail]
    call cmd_date_parse64
    test rax, rax
    jnz .bad_el
    ; Sync the RTC too (REPL DATE sets both clocks, like INT 21h AH=2Bh).
    movzx edi, word [rel cmd_year]
    movzx esi, byte [rel cmd_month]
    movzx edx, byte [rel cmd_day]
    call rtc_set_date64
    jmp .ok_el
.date_show_el:
    lea rdi, [rel sh_out]
    mov rsi, 16
    call cmd_date_get64
    lea rsi, [rel sh_out]
    call sh_print
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.time_el:
    cmp byte [rel sh_tail], 0
    je .time_show_el
    lea rdi, [rel sh_tail]
    call cmd_time_parse64
    test rax, rax
    jnz .bad_el
    movzx edi, byte [rel cmd_hour]
    movzx esi, byte [rel cmd_min]
    movzx edx, byte [rel cmd_sec]
    call rtc_set_time64
    jmp .ok_el
.time_show_el:
    lea rdi, [rel sh_out]
    mov rsi, 16
    call cmd_time_get64
    lea rsi, [rel sh_out]
    call sh_print
    mov rsi, sh_crlf
    call sh_print
    jmp .ok_el
.help_el:
    lea rsi, [rel sh_help]
    call sh_print
    jmp .ok_el
.external_el:
    lea rdi, [rel sh_cmd]
    lea rsi, [rel sh_tail]
    call sh_do_exec
    jmp .done_el_rc
.bad_el:
    lea rsi, [rel sh_bad]
    call sh_print
    mov rax, 1
    jmp .done_el
.ok_el:
    xor eax, eax
    jmp .done_el
.done_el_rc:
    ; RAX already 0/1 from the builtin.
    jmp .done_el
.empty_el:
    mov rax, 1
    jmp .done_el
.exit_el:
    mov rax, 2
.done_el:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; shell_repl64 — the interactive loop. No return (EXIT halts to .hlt path
; via ret -> caller halts; documented).
shell_repl64:
    call cmd_init64
    ; Sync the shell clock from the RTC so DATE/TIME show real values
    ; (cmd_init64 defaults to 1983-04-01 12:00:00).
    call rtc_get_date64              ; ECX=y EDX=m R8D=d
    jc .no_rtc_sync_sh
    mov edi, ecx
    mov esi, edx
    mov edx, r8d
    call cmd_date_set64
    call rtc_get_time64              ; ECX=h EDX=min R8D=s
    jc .no_rtc_sync_sh
    mov edi, ecx
    mov esi, edx
    mov edx, r8d
    call cmd_time_set64
.no_rtc_sync_sh:
    call fs_mount_volume64
    lea rsi, [rel sh_banner]
    call sh_print
    ; Live IRQs from here: timer ticks + key scancodes via IDT
    ; (tests run masked for determinism; the shell runs live).
    push rdi
    xor edi, edi
    call pic_unmask_irq64
    mov edi, 1
    call pic_unmask_irq64
    pop rdi
.loop_repl:
    call sh_prompt_show
    lea rdi, [rel sh_line]
    mov rsi, 127
    call sh_read_line
    lea rdi, [rel sh_line]
    call sh_exec_line
    cmp rax, 2
    je .done_repl
    jmp .loop_repl
.done_repl:
    ret

section .rodata
sh_s_exit:  db "EXIT",0
sh_s_help:  db "HELP",0
sh_verstr:  db "1.25-64",0
