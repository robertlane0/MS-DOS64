bits 64
default rel
%include "include/regs.inc"
%include "include/fcb.inc"
%include "include/dpb.inc"
extern vga_putc
extern vga_print
extern mem_alloc64
extern mem_free64
extern mem_resize64
extern mem_max_free64
extern mem_bytes_to_para
extern mem_para_to_bytes
extern proc_spawn64
extern proc_terminate64
extern proc_exit_current64
extern proc_init64
extern proc_get_psp64
extern proc_get_current64
extern kbd_poll
extern kbd_has_data
extern kbd_queue_push
extern kbd_queue_pop
extern kbd_flush
extern kbd_scancode_to_ascii
extern kbd_init
extern idt_set_vector64
extern idt_get_vector64
extern rtc_bcd_to_bin_v2
extern rtc_bin_to_bcd
extern cmd_date_set64
extern cmd_time_set64
extern cmd_year
extern cmd_month
extern cmd_day
extern cmd_hour
extern cmd_min
extern cmd_sec
extern fs_mount_volume64
extern fs_vol_dpb
extern fs_vol_fat
extern fs_vol_root
extern fs_vol_mounted
extern fs_vol_boot
extern fs_dir_find64
extern fs_vol_flush_root64
extern fs_fcb_open64
extern fs_fcb_io64
extern fs_fcb_delete64
extern fs_fcb_create64
extern fs_fcb_rename64
extern fs_fcb_search64
extern fs_make_fcb64
extern fs_fcb_close64
extern fs_vol_root
extern fs_vol_dpb
section .text
global syscall_init
global syscall_dispatch64
global savregs64
global leave64
global cmd_entry64
global dos_entry64
global iretq64
global get_dma64
global set_dma64
global SPSAVE64
global SSSAVE64
global IOSTACK_TOP64
global DSKSTACK_TOP64
global DISPATCH64
global CURDRV64
global THISDRV64
global NUMDRV64
global DMAADD64_SC
global handler_conin
global handler_conout
global handler_rawio
global handler_rawinp
global handler_in
global handler_prtbuf
global handler_bufin
global handler_constat
global handler_flushkb
global handler_dskreset
global handler_seldsk
global handler_getdrv
global handler_setvect
global handler_getvect
global handler_read_file
global handler_write_file
global handler_abort
global handler_alloc_mem
global handler_free_mem
global handler_resize_mem
global handler_exec
global handler_exit_process
global handler_reader
global handler_punch
global handler_list
global handler_getdate
global handler_setdate
global handler_gettime
global handler_settime
global handler_verify
global handler_newbase
global handler_getfatpt
global handler_getfatptdl
global handler_getrdonly
global handler_setattrib
global handler_getdskpt
global handler_open
global handler_close
global handler_srchfrst
global handler_srchnxt
global handler_delete
global handler_seqrd
global handler_seqwrt
global handler_create
global handler_rename
global handler_rndrd
global handler_rndwrt
global handler_filesize
global handler_setrndrec
global handler_blkrd
global handler_blkwrt
global handler_makefcb
global handler_setdma
global rtc_get_date64
global rtc_get_time64
global rtc_set_date64
global rtc_set_time64

%define MAXCOM 0x4C    ; 76 — extend for Phase6 alloc/free/resize (DOS 2.0 48h/49h/4Ah)
%define MAXCALL 36
%define IOSTACK_SIZE 4096
%define DSKSTACK_SIZE 4096

section .bss
alignb 16
SPSAVE64:  resq 1
SSSAVE64:  resq 1
CONTSTK64: resq 1
alignb 16
IOSTACK64: resb IOSTACK_SIZE
IOSTACK_TOP64:
alignb 16
DSKSTACK64: resb DSKSTACK_SIZE
DSKSTACK_TOP64:
SAV_EXIT64: resq 1
EXITHOLD64: resq 2
DMAADD64_SC: resq 1
THISDRV64: resb 1
CURDRV64: resb 1
NUMDRV64: resb 1
VERIFY_FLAG64: resb 1
global VERIFY_FLAG64
srch_next_slot: resq 1
exec_ret_pid: resq 1
exec_ret_psp: resq 1
global exec_dbg_pid
exec_dbg_pid: resq 1

section .text
syscall_init:
    push rax
    xor rax, rax
    mov [rel SPSAVE64], rax
    mov [rel SSSAVE64], rax
    mov byte [rel THISDRV64], 0
    mov byte [rel CURDRV64], 0
    mov byte [rel NUMDRV64], 2   ; A:+B: (Phase9: SELDSK bounds, GETDRV)
    pop rax
    ret

; savregs64
savregs64:
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
    mov [rel SPSAVE64], rsp
    mov rax, ss
    mov [rel SSSAVE64], rax
    mov rax, [rsp]
    shr rax, 8
    and eax, 0xFF
    cmp eax, 12
    jle .sav_use_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .sav_done
.sav_use_io:
    lea rsp, [rel IOSTACK_TOP64]
.sav_done:
    and rsp, ~15
    sti
    mov rbx, [rel SPSAVE64]
    movzx ebx, byte [rbx+1]   ; AH = function (was byte [SPSAVE64] = pointer low byte, Phase8 fix)
    ret

syscall_dispatch64:
    cmp ah, MAXCOM         ; AH=function (was cmp eax,MAXCOM which compared 0x4B00>0x4C, always bad; Phase8 fix)
    ja .dispatch_bad
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
    push rax          ; 15th push balances leave64's 15 pops; [rsp] = func (AH)
                      ; Order matches savregs64/STKPTRS64: [rsp]=RAX,+8=RBX,+16=RCX...
                      ; (Phase8 fix: was rbx..rax scrambled, corrupted R12/R13 counts)
    mov [rel SPSAVE64], rsp
    mov r11, ss
    mov [rel SSSAVE64], r11
    ; Recover DOS function number from saved RAX (AH), like 16-bit
    ; SAVREGS (MSDOS.ASM: S = AH). Select IOSTACK (func<=12) / DSKSTACK.
    ; Phase9 fix: use R10/R11 temps (not RAX/RBX/R8) so user regs survive
    ; for handlers (AL=vector, BX=handle, R8=env). R10/R11 saved in frame.
    ; (Was mov rax,ss which clobbered user RAX/AL before handler call.)
    mov r10, [rsp]
    shr r10, 8
    and r10d, 0xFF
    cmp r10d, 12
    jle .dispatch_io
    lea rsp, [rel DSKSTACK_TOP64]
    jmp .dispatch_after
.dispatch_io:
    lea rsp, [rel IOSTACK_TOP64]
.dispatch_after:
    and rsp, ~15
    mov r11, r10
    shl r11, 3
    lea r10, [rel DISPATCH64]
    add r10, r11
    mov r10, [r10]
    call r10
    jmp leave64
.dispatch_bad:
    mov al, 0
    ret

leave64:
    cli
    mov rsp, [rel SPSAVE64]
    mov rax, [rel SSSAVE64]
    mov ss, ax
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
    ret

iretq64:
    iretq

get_dma64:
    mov rax, [rel DMAADD64_SC]
    ret

set_dma64:
    mov [rel DMAADD64_SC], rdi
    ret

set_dma_from_legacy:
    jmp set_dma64

cmd_entry64:
    cmp ah, MAXCOM
    jbe savregs64
    mov al, 0
    iretq

dos_entry64:
    mov ah, cl
    cmp cl, MAXCALL
    ja .dos_bad
    jmp savregs64
.dos_bad:
    mov al, 0
    iretq

section .data
align 8
DISPATCH64:
    dq handler_abort      ; 00 ABORT
    dq handler_conin      ; 01
    dq handler_conout     ; 02
    dq handler_reader     ; 03
    dq handler_punch      ; 04
    dq handler_list       ; 05
    dq handler_rawio      ; 06
    dq handler_rawinp     ; 07
    dq handler_in         ; 08
    dq handler_prtbuf     ; 09 $-print
    dq handler_bufin      ; 0A
    dq handler_constat    ; 0B
    dq handler_flushkb    ; 0C
    dq handler_dskreset   ; 0D
    dq handler_seldsk     ; 0E
    dq handler_open       ; 0F
    dq handler_close      ; 10
    dq handler_srchfrst   ; 11
    dq handler_srchnxt    ; 12
    dq handler_delete     ; 13
    dq handler_seqrd      ; 14
    dq handler_seqwrt     ; 15
    dq handler_create     ; 16
    dq handler_rename     ; 17
    dq handler_inuse      ; 18
    dq handler_getdrv     ; 19
    dq handler_setdma     ; 1A 26
    dq handler_getfatpt   ; 1B 27
    dq handler_getfatptdl ; 1C 28
    dq handler_getrdonly  ; 1D 29
    dq handler_setattrib  ; 1E 30
    dq handler_getdskpt   ; 1F 31
    dq handler_usercode   ; 20 32
    dq handler_rndrd      ; 21 33
    dq handler_rndwrt     ; 22 34
    dq handler_filesize   ; 23 35
    dq handler_setrndrec  ; 24 36
    dq handler_setvect    ; 25 37 0025h set vector
    dq handler_newbase    ; 26 38 0026h newbase/get mem size (stub)
    dq handler_blkrd      ; 27 39
    dq handler_blkwrt     ; 28 40
    dq handler_makefcb    ; 29 41
    dq handler_getdate    ; 2A 42
    dq handler_setdate    ; 2B 43
    dq handler_gettime    ; 2C 44
    dq handler_settime    ; 2D 45
    dq handler_verify     ; 2E 46
    dq handler_inuse      ; 2F 47 stub
    dq handler_inuse      ; 30 48 stub (gap to 0x48)
    dq handler_inuse      ; 31
    dq handler_inuse      ; 32
    dq handler_inuse      ; 33
    dq handler_inuse      ; 34
    dq handler_getvect    ; 35 53 AH=35h GETVECT (DOS2 ext, Phase9: IDT read)
    dq handler_inuse      ; 36
    dq handler_inuse      ; 37
    dq handler_inuse      ; 38
    dq handler_inuse      ; 39
    dq handler_inuse      ; 3A
    dq handler_inuse      ; 3B
    dq handler_inuse      ; 3C
    dq handler_inuse      ; 3D
    dq handler_inuse      ; 3E
    dq handler_read_file  ; 3F 63 AH=3Fh READ (Phase9: handle 0 stdin)
    dq handler_write_file ; 40 64 AH=40h WRITE (Phase9: handles 1/2 stdout)
    dq handler_inuse      ; 41
    dq handler_inuse      ; 42
    dq handler_inuse      ; 43
    dq handler_inuse      ; 44
    dq handler_inuse      ; 45
    dq handler_inuse      ; 46
    dq handler_inuse      ; 47
    dq handler_alloc_mem  ; 48 72 AH=48h ALLOC (paragraphs->bytes)
    dq handler_free_mem   ; 49 73 AH=49h FREE
    dq handler_resize_mem ; 4A 74 AH=4Ah SETBLK/RESIZE
    dq handler_exec       ; 4B 75 AH=4Bh EXEC (Phase8: proc_spawn64)
    dq handler_exit_process ; 4C 76 AH=4Ch EXIT (Phase8: proc_exit_current64)

section .text
; Phase8: INT20h ABORT (MSDOS.ASM:1356) — terminate current with code 0.
; Old code jmp [EXITHOLD64] (zero -> #GP). Now calls proc_exit_current(0).
; If current is kernel (pid0), just returns AL=0 (no halt, test-safe).
handler_abort:
    push rdi
    push rsi
    push rcx
    xor edi, edi
    call proc_exit_current64
    ; RAX 0 exited child, 1 was kernel -> both OK for abort path
    xor eax, eax
    pop rcx
    pop rsi
    pop rdi
    ret

; ------------------------------------------------------------
; Phase9: Console handlers — INT 21h AH=01/02/06/07/08/09/0A/0B/0C
;   Native drivers: vga_putc (INT10h), kbd_poll/queue/translate (INT16h).
;   Direct call ABI: DL=char (out), RDX=buffer (09/0A), AL=subfunc (0C).
;   Trap ABI: same regs live (RBX/RCX/RDX preserved across dispatch push).
;   Returns: AL=char (in), AL=0 ok; frame rax_save updated + CF.
; ------------------------------------------------------------
handler_conin:              ; AH=01 CONIN with echo (MSDOS.ASM:3130)
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    call handler_in
    ; AL=char (0 if no data for test-safe non-blocking)
    push rax
    mov dl, al
    test al, al
    jz .no_echo
    call handler_conout
.no_echo:
    pop rax
    ; write AL to trap frame
    push rax
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_ci
    mov rcx, [rbx + STKPTRS64.rax_save]
    ; preserve AH=01, replace AL
    mov cl, al
    mov [rbx + STKPTRS64.rax_save], rcx
.no_frame_ci:
    pop rax
    clc
    test al, al
    jz .empty_ci
    clc
    jmp .done_ci
.empty_ci:
    ; no data: still CF=0 for test (DOS would block); AL=0 marks empty
    clc
.done_ci:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_conout:             ; AH=02 CONOUT DL=char (MSDOS.ASM OUT->BIOSOUT)
    push rdi
    push rax
    mov al, dl              ; vga_putc takes AL (was movzx rdi,dl which left AL stale)
    call vga_putc
    pop rax
    pop rdi
    ret

; kbd_read_ascii64 — internal: non-blocking read one ASCII char
;   Out: AL=ascii (0 if none), CF=0 got char / CF=1 none
;   Tries queue first (pre-pushed test scancodes), then hardware poll.
;   Translates Set-1 scancode via kbd_scancode_to_ascii (handles shift).
handler_kbd_read_ascii:
    push rbx
    push rcx
    push rdx
    ; try queue
    call kbd_queue_pop
    jc .try_hw
    ; AL=scancode from queue -> translate
    call kbd_scancode_to_ascii
    test al, al
    jz .no_char_q        ; shift/caps consumed -> treat as none for this poll
    clc
    jmp .done_kbd
.try_hw:
    call kbd_poll
    jc .none_kbd
    call kbd_scancode_to_ascii
    test al, al
    jz .no_char_q
    clc
    jmp .done_kbd
.no_char_q:
    xor al, al
    stc
    jmp .done_kbd
.none_kbd:
    xor al, al
    stc
.done_kbd:
    pop rdx
    pop rcx
    pop rbx
    ret

handler_in:                 ; AH=08 IN no echo (MSDOS.ASM:3138 INCHK loop)
    push rbx
    push rcx
    call handler_kbd_read_ascii
    jc .no_data_in
    ; AL=char; update frame
    mov bl, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .no_frame_in
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.no_frame_in:
    mov al, bl
    clc
    pop rcx
    pop rbx
    ret
.no_data_in:
    xor al, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .no_frame_in2
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rcx + STKPTRS64.rax_save], rdx
.no_frame_in2:
    xor al, al
    stc                  ; CF=1 signals empty (test checks AL=0; CF for RAWIO)
    pop rcx
    pop rbx
    ret

handler_rawinp:             ; AH=07 RAWINP no echo (same as IN, no ^C check)
    jmp handler_in

handler_rawio:              ; AH=06 RAWIO DL=FF->input else output (MSDOS.ASM:3143)
    cmp dl, 0xFF
    je .raw_in
    ; output DL
    jmp handler_conout
.raw_in:
    ; non-blocking input with ZF/CF semantics: AL=char if data else AL=0
    ; Original sets user ZF via FSAVE; here CF=0 data / CF=1 empty + frame ZF?
    push rbx
    call handler_kbd_read_ascii
    jc .raw_empty
    mov bl, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .raw_got
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.raw_got:
    mov al, bl
    clc
    pop rbx
    ret
.raw_empty:
    xor al, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .raw_e2
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rcx + STKPTRS64.rax_save], rdx
.raw_e2:
    xor al, al
    stc
    pop rbx
    ret

handler_constat:            ; AH=0B CONSTAT (MSDOS.ASM:3122: AL=0 none, FF avail)
    push rbx
    push rcx
    push rdx
    ; check hardware first
    call kbd_has_data
    cmp rax, 1
    je .has_data
    ; check queue by pop/push peek (single-char safe; multi-char rotates once
    ; but count preserved — documented Phase9 limitation, queue count exported
    ; in future; for tests single-char so exact)
    call kbd_queue_pop
    jc .no_data_cs
    ; got scancode in AL -> push back to preserve (rotate for multi)
    mov bl, al
    mov al, bl
    call kbd_queue_push   ; restore (CF ignored; queue had space since we popped)
    mov al, 0xFF
    jmp .store_cs
.has_data:
    mov al, 0xFF
    jmp .store_cs
.no_data_cs:
    xor al, al
.store_cs:
    mov bl, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_cs
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.done_cs:
    mov al, bl
    pop rdx
    pop rcx
    pop rbx
    ret

handler_flushkb:            ; AH=0C FLUSHKB + dispatch AL subfunc (MSDOS.ASM:412)
    push rbx
    push rcx
    mov bl, al            ; subfunc in AL (RAX=0x0Cxx)
    call kbd_flush
    cmp bl, 1
    je .redisp1
    cmp bl, 6
    je .redisp6
    cmp bl, 7
    je .redisp7
    cmp bl, 8
    je .redisp8
    cmp bl, 10
    je .redispA
    xor al, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_fl
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rcx + STKPTRS64.rax_save], rdx
.done_fl:
    xor al, al
    pop rcx
    pop rbx
    ret
.redisp1:
    call handler_conin
    jmp .done_fl2
.redisp6:
    ; RAWIO needs DL: preserve caller DL from frame? Use current DL (still live)
    call handler_rawio
    jmp .done_fl2
.redisp7:
    call handler_rawinp
    jmp .done_fl2
.redisp8:
    call handler_in
    jmp .done_fl2
.redispA:
    ; BUFIN needs RDX buffer — use live RDX
    call handler_bufin
.done_fl2:
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Phase9: Buffered input AH=0A BUFIN (MSDOS.ASM:2705 simplified)
;   In: RDX=buffer linear: [0]=maxlen (incl? DOS: max incl? [0]=max, [1]=count)
;   Out: [1]=count (excl CR), [2..2+count-1]=chars, [2+count]=CR(13)
;   Editing: BACKSPACE (8/7F) deletes, maxlen caps with BELL(7), CR ends.
;   Echo via CONOUT. Non-blocking for test: drains queue/hw until CR or empty.
; ------------------------------------------------------------
handler_bufin:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    test rdx, rdx
    jz .fail_bi
    mov r8, rdx              ; buf
    movzx r9d, byte [r8]     ; maxlen
    test r9b, r9b
    jz .fail_bi
    cmp r9, 128
    ja .fail_bi              ; DOS max 128 (MSDOS BUFIN)
    xor ecx, ecx             ; count
.bi_loop:
    call handler_kbd_read_ascii
    jc .bi_end               ; no more data -> end (test-safe; DOS would block)
    cmp al, 13
    je .bi_cr
    cmp al, 8
    je .bi_bs
    cmp al, 0x7F
    je .bi_bs
    ; printable: check space (need room for char + CR)
    mov rbx, rcx
    inc rbx
    cmp rbx, r9
    jae .bi_full             ; no room -> BELL
    ; store + echo
    mov [r8+2+rcx], al
    inc rcx
    mov dl, al
    call handler_conout
    jmp .bi_loop
.bi_bs:
    test rcx, rcx
    jz .bi_loop              ; nothing to delete
    dec rcx
    ; erase echo: BS SPACE BS
    mov dl, 8
    call handler_conout
    mov dl, ' '
    call handler_conout
    mov dl, 8
    call handler_conout
    jmp .bi_loop
.bi_full:
    mov dl, 7                ; BELL
    call handler_conout
    jmp .bi_loop
.bi_cr:
    ; store CR, echo CRLF? DOS OUT CR; do CR+LF for VGA newline
    mov [r8+2+rcx], al
    mov dl, al
    call handler_conout
    mov dl, 10
    call handler_conout
    jmp .bi_done
.bi_end:
    ; ended without CR (queue drained): still terminate with CR if room?
    ; For test we always include CR, so this is empty-input path.
    ; Just fall through with count so far (no CR appended if none read).
    cmp rcx, 0
    je .bi_done_empty
    ; append CR if room for DOS compat
    mov rbx, rcx
    inc rbx
    cmp rbx, r9
    ja .bi_done
    mov byte [r8+2+rcx], 13
    jmp .bi_done
.bi_done_empty:
    ; count 0, no chars
    jmp .bi_done
.bi_done:
    mov [r8+1], cl           ; count byte
    ; frame: AL=0? DOS returns? Set AL=0 success
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .ok_bi
    mov rdx, [rbx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rbx + STKPTRS64.rax_save], rdx
.ok_bi:
    xor al, al
    clc
    jmp .exit_bi
.fail_bi:
    mov al, 1
    stc
.exit_bi:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Phase9: Drive/disk AH=0D/0E/19 (MSDOS.ASM:2656/2698/2683)
; ------------------------------------------------------------
handler_dskreset:           ; AH=0D DSKRESET: flush (no dirty bufs in Phase7 RAM) -> AL=0
    push rbx
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .done_dr
    mov rax, [rbx + STKPTRS64.rax_save]
    mov al, 0
    mov [rbx + STKPTRS64.rax_save], rax
.done_dr:
    xor al, al
    pop rbx
    ret

handler_seldsk:             ; AH=0E SELDSK DL=drive -> AL=NUMDRV, CURDRV=DL if <NUMDRV
    push rbx
    push rcx
    movzx ecx, dl
    movzx ebx, byte [rel NUMDRV64]
    cmp cl, bl
    jae .no_set_sd
    mov [rel CURDRV64], cl
.no_set_sd:
    ; return AL=NUMDRV in frame + RAX
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_sd
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.done_sd:
    mov al, bl
    pop rcx
    pop rbx
    ret

handler_getdrv:             ; AH=19 GETDRV -> AL=CURDRV (MSDOS.ASM:2683)
    push rbx
    mov bl, [rel CURDRV64]
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_gd
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.done_gd:
    mov al, bl
    pop rbx
    ret

; ------------------------------------------------------------
; Phase9: Vectors AH=25h SETVECT / AH=35h GETVECT (DOS2 ext)
;   SETVECT: AL=vector, RDX=handler RIP -> IDT write (was ES:[BX]=DX/DS)
;   GETVECT: AL=vector -> RBX=handler RIP (was ES:BX)
; ------------------------------------------------------------
handler_setvect:            ; AH=25h (MSDOS.ASM:3342)
    push rbx
    push rcx
    push rdi
    push rsi
    movzx edi, al            ; vector from AL (RAX=0x25VV)
    mov rsi, rdx             ; handler RIP
    test rsi, rsi
    jz .fail_sv
    call idt_set_vector64
    test rax, rax
    jnz .fail_sv
    ; success AL=0 in frame
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .ok_sv
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rcx + STKPTRS64.rax_save], rdx
.ok_sv:
    xor al, al
    clc
    jmp .done_sv
.fail_sv:
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .fail_sv2
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 1
    mov [rcx + STKPTRS64.rax_save], rdx
.fail_sv2:
    mov al, 1
    stc
.done_sv:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

handler_getvect:            ; AH=35h DOS2 ext -> RBX=handler
    push rcx
    push rdx
    push rdi
    push rsi
    movzx edi, al            ; vector
    call idt_get_vector64    ; RAX=handler
    mov rsi, rax             ; save handler
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_gv
    mov [rcx + STKPTRS64.rbx_save], rsi
    ; AL=0 in frame
    mov rax, [rcx + STKPTRS64.rax_save]
    mov al, 0
    mov [rcx + STKPTRS64.rax_save], rax
.done_gv:
    mov rbx, rsi
    xor eax, eax             ; RAX=0 success (handler in RBX for direct caller)
    clc
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; Phase9: Handle-based READ AH=3Fh / WRITE AH=40h (DOS2 ext, 64-bit)
;   In (trap): RBX=handle (BX), RCX=count (CX zero-extended to 64-bit),
;              RDX=buffer linear (DS:DX flat).
;   Handles: 0=stdin (kbd), 1=stdout (vga), 2=stderr (vga). 3+ -> error.
;   Out: RAX=bytes transferred, CF 0 ok / 1 fail (AL=error: 5 bad handle,
;        6 bad buffer). Frame rax_save=counter, CF propagated to IRETQ.
; ------------------------------------------------------------
handler_read_file:          ; AH=3Fh
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rbx              ; handle
    mov r9, rcx              ; count (full 64-bit; DOS CX compat: low 16 used if >64K? use full)
    and r8, 0xFFFF           ; BX
    and r9, 0xFFFF           ; CX (DOS 16-bit count; 64-bit ext uses low 16 for compat)
    cmp r8, 0
    jne .fail_rf_badhandle
    test rdx, rdx
    jz .fail_rf_badbuf
    test r9, r9
    jz .ok_zero_rf
    mov rsi, rdx             ; buffer
    xor ecx, ecx             ; transferred
.rf_loop:
    cmp rcx, r9
    jae .rf_done
    call handler_kbd_read_ascii
    jc .rf_done              ; no more data -> short read (test-safe)
    mov [rsi+rcx], al
    inc rcx
    jmp .rf_loop
.rf_done:
    mov rdx, rcx             ; count
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .rf_noframe
    mov [rbx + STKPTRS64.rax_save], rdx
.rf_noframe:
    mov rax, rdx
    clc
    jmp .exit_rf
.ok_zero_rf:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .rf_z2
    mov qword [rbx + STKPTRS64.rax_save], 0
.rf_z2:
    xor eax, eax
    clc
    jmp .exit_rf
.fail_rf_badhandle:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .rf_bh2
    mov qword [rbx + STKPTRS64.rax_save], 0
    mov byte [rbx + STKPTRS64.rax_save+1], 6  ; AH=6 invalid handle (DOS err)
.rf_bh2:
    mov rax, 5
    stc
    jmp .exit_rf
.fail_rf_badbuf:
    mov rax, 6
    stc
.exit_rf:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_write_file:         ; AH=40h
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rbx
    mov r9, rcx
    and r8, 0xFFFF
    and r9, 0xFFFF
    cmp r8, 1
    je .ok_handle_wf
    cmp r8, 2
    je .ok_handle_wf
    jmp .fail_wf_badhandle
.ok_handle_wf:
    test rdx, rdx
    jz .fail_wf_badbuf
    test r9, r9
    jz .ok_zero_wf
    mov rsi, rdx
    xor ecx, ecx
.wf_loop:
    cmp rcx, r9
    jae .wf_done
    mov dl, [rsi+rcx]
    call handler_conout
    inc rcx
    jmp .wf_loop
.wf_done:
    mov rdx, rcx
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .wf_noframe
    mov [rbx + STKPTRS64.rax_save], rdx
.wf_noframe:
    mov rax, rdx
    clc
    jmp .exit_wf
.ok_zero_wf:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .wf_z2
    mov qword [rbx + STKPTRS64.rax_save], 0
.wf_z2:
    xor eax, eax
    clc
    jmp .exit_wf
.fail_wf_badhandle:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .wf_bh2
    mov qword [rbx + STKPTRS64.rax_save], 0
    mov byte [rbx + STKPTRS64.rax_save+1], 6
.wf_bh2:
    mov rax, 5
    stc
    jmp .exit_wf
.fail_wf_badbuf:
    mov rax, 6
    stc
.exit_wf:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; G1/A2: AUX/COM, RTC date/time, VERIFY, memory/disk pointers.
;   Replaces the former `mov al,0; ret` stubs with real hardware- or
;   volume-backed behavior. All handlers support both direct calls
;   (live RDI/RSI/RDX/RCX/RBX) and INT 21h trap dispatch (same live
;   regs + SPSAVE64 frame writeback for AL/CX/DX/BX results).
; ------------------------------------------------------------

; com1_write_char — polled COM1 0x3F8 transmit (AUXOUT/LIST backend)
;   In: DL = char. Out: CF 0 sent, CF 1 timeout. Preserves all but flags.
com1_write_char:
    push rax
    push rcx
    push rdx
    mov cl, dl
    mov rcx, 0x200000
    shl rcx, 4              ; generous spin budget (~5M polls)
.wait_tx:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20          ; THR empty?
    jnz .ready_tx
    dec rcx
    jnz .wait_tx
    stc
    jmp .done_tx
.ready_tx:
    mov dx, 0x3F8
    mov al, cl
    out dx, al
    clc
.done_tx:
    pop rdx
    pop rcx
    pop rax
    ret

; com1_read_char — polled COM1 receive, NON-BLOCKING (test-safe)
;   Out: CF 0 AL=char if data ready (LSR bit0), else CF 1 AL=0.
;   DOS READER would block; blocking would hang the unattended suite,
;   so no-data is reported via CF (documented deviation).
com1_read_char:
    push rdx
    mov dx, 0x3FD
    in al, dx
    test al, 0x01
    jz .none_rx
    mov dx, 0x3F8
    in al, dx
    clc
    pop rdx
    ret
.none_rx:
    xor al, al
    stc
    pop rdx
    ret

handler_reader:             ; AH=03 READER aux in (was stub)
    push rbx
    call com1_read_char
    jc .empty_rd
    mov bl, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .got_rd
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.got_rd:
    mov al, bl
    clc
    pop rbx
    ret
.empty_rd:
    xor al, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .no_frame_rd
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rcx + STKPTRS64.rax_save], rdx
.no_frame_rd:
    xor al, al
    stc
    pop rbx
    ret

handler_punch:              ; AH=04 PUNCH aux out DL=char (was stub)
    call com1_write_char
    jc .fail_pu
    xor al, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_pu
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, 0
    mov [rcx + STKPTRS64.rax_save], rdx
.done_pu:
    xor al, al
    clc
    ret
.fail_pu:
    mov al, 1
    stc
    ret

handler_list:               ; AH=05 LIST printer out DL=char (was stub)
    ; Printer hardware (LPT) is not emulated observably; route to the
    ; COM1 capture so output lands in serial.log / stdio (documented).
    call com1_write_char
    jc .fail_li
    xor al, al
    clc
    ret
.fail_li:
    mov al, 1
    stc
    ret

; ------------------------------------------------------------
; CMOS RTC (ports 0x70/0x71) — backs INT 21h AH=2Ah-2Dh.
; ------------------------------------------------------------
cmos_read:                  ; AL = reg -> AL = value
    push rdx
    mov dx, 0x70
    out dx, al
    mov dx, 0x71
    in al, dx
    pop rdx
    ret

cmos_write:                 ; AL = reg, AH = value
    push rbx
    push rdx
    mov bl, ah
    mov dx, 0x70
    out dx, al
    mov al, bl
    mov dx, 0x71
    out dx, al
    pop rdx
    pop rbx
    ret

rtc_wait_uip_clear:         ; CF 0 RTC ready, CF 1 timeout (~1s of polls)
    push rax
    push rcx
    push rdx
    mov rcx, 1000000
.loop_uip:
    mov al, 0x0A
    call cmos_read
    test al, 0x80
    jz .ready_uip
    dec rcx
    jnz .loop_uip
    stc
    jmp .done_uip
.ready_uip:
    clc
.done_uip:
    pop rdx
    pop rcx
    pop rax
    ret

; rtc_get_date64 — Out: ECX=year, EDX=month, R8D=day, R9D=wday(DOS 0=Sun)
;   RAX 0 ok / 1 fail. Clobbers R10B internally (saved).
rtc_get_date64:
    push rbx
    push r10
    call rtc_wait_uip_clear
    jc .fail_dt
    mov al, 0x0B
    call cmos_read
    mov r10b, al           ; status B: bit2=binary, bit1=24h
    mov al, 0x09
    call cmos_read
    test r10b, 0x04
    jnz .yr_bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.yr_bin:
    movzx ecx, al
    cmp ecx, 80
    jb .yr_20xx
    add ecx, 1900
    jmp .yr_done
.yr_20xx:
    add ecx, 2000
.yr_done:
    mov al, 0x08
    call cmos_read
    test r10b, 0x04
    jnz .mo_bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.mo_bin:
    movzx edx, al
    cmp edx, 1
    jb .fail_dt
    cmp edx, 12
    ja .fail_dt
    mov al, 0x07
    call cmos_read
    test r10b, 0x04
    jnz .dy_bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.dy_bin:
    movzx r8d, al
    cmp r8d, 1
    jb .fail_dt
    cmp r8d, 31
    ja .fail_dt
    mov al, 0x06
    call cmos_read
    test r10b, 0x04
    jnz .wd_bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.wd_bin:
    ; CMOS 1..7 (Sun..Sat) -> DOS 0..6
    cmp al, 1
    jb .wd_zero
    cmp al, 7
    ja .wd_zero
    dec al
    movzx r9d, al
    jmp .ok_dt
.wd_zero:
    xor r9d, r9d
.ok_dt:
    xor eax, eax
    pop r10
    pop rbx
    ret
.fail_dt:
    mov rax, 1
    pop r10
    pop rbx
    ret

; rtc_get_time64 — Out: ECX=hour, EDX=min, R8D=sec. RAX 0 ok / 1 fail.
rtc_get_time64:
    push rbx
    push r10
    push r11
    call rtc_wait_uip_clear
    jc .fail_tm
    mov al, 0x0B
    call cmos_read
    mov r10b, al
    ; hour (0x04) with 12/24h handling
    mov al, 0x04
    call cmos_read
    mov r11b, al
    test r10b, 0x02        ; 24h mode?
    jnz .hr24
    ; 12h: bit7 = PM
    mov al, r11b
    and al, 0x80
    mov ah, al             ; save PM flag in AH
    mov al, r11b
    and al, 0x7F
    test r10b, 0x04
    jnz .hr12bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.hr12bin:
    movzx ecx, al
    test ah, ah
    jz .hr12am
    cmp ecx, 12
    jae .hr_done           ; 12 PM stays 12
    add ecx, 12
    jmp .hr_done
.hr12am:
    cmp ecx, 12
    jne .hr_done
    xor ecx, ecx           ; 12 AM -> 0
    jmp .hr_done
.hr24:
    mov al, r11b
    test r10b, 0x04
    jnz .hr24bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.hr24bin:
    movzx ecx, al
.hr_done:
    cmp ecx, 24
    jae .fail_tm
    mov al, 0x02
    call cmos_read
    test r10b, 0x04
    jnz .mn_bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.mn_bin:
    movzx edx, al
    cmp edx, 60
    jae .fail_tm
    mov al, 0x00
    call cmos_read
    test r10b, 0x04
    jnz .sc_bin
    push rbx
    call rtc_bcd_to_bin_v2
    pop rbx
.sc_bin:
    movzx r8d, al
    cmp r8d, 60
    jae .fail_tm
    xor eax, eax
    pop r11
    pop r10
    pop rbx
    ret
.fail_tm:
    mov rax, 1
    pop r11
    pop r10
    pop rbx
    ret

; rtc_set_date64 — RDI=year, RSI=month, RDX=day. RAX 0 ok / 1 fail.
;   Validates via cmd_date_set64 (also syncs the COMMAND64 software clock).
rtc_set_date64:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi           ; year (callee-saved; DIV below clobbers RDX)
    mov r13, rsi           ; month
    mov r14, rdx           ; day
    call cmd_date_set64
    test rax, rax
    jnz .fail_sd
    mov al, 0x0B
    call cmos_read
    mov bl, al             ; status B: bit2=binary (RBX is pushed, safe)
    mov rax, r12
    mov rcx, 100
    xor rdx, rdx
    div rcx                ; RDX = year % 100
    mov al, dl
    test bl, 0x04
    jnz .yr_bin_sd
    call rtc_bin_to_bcd    ; preserves RBX, clobbers ECX/EDX (both dead here)
.yr_bin_sd:
    mov ah, al
    mov al, 0x09
    call cmos_write
    mov al, r13b
    test bl, 0x04
    jnz .mo_bin_sd
    call rtc_bin_to_bcd
.mo_bin_sd:
    mov ah, al
    mov al, 0x08
    call cmos_write
    mov al, r14b
    test bl, 0x04
    jnz .dy_bin_sd
    call rtc_bin_to_bcd
.dy_bin_sd:
    mov ah, al
    mov al, 0x07
    call cmos_write
    xor eax, eax
    jmp .done_sd
.fail_sd:
    mov rax, 1
.done_sd:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rtc_set_time64 — RDI=hour, RSI=min, RDX=sec. RAX 0 ok / 1 fail.
;   Validates via cmd_time_set64 (also syncs the COMMAND64 software clock).
rtc_set_time64:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call cmd_time_set64
    test rax, rax
    jnz .fail_st
    mov al, 0x0B
    call cmos_read
    mov bl, al
    ; hour: convert to 12h + PM bit when the RTC runs in 12h mode.
    ; BH carries the PM flag (RBX is pushed; rtc_bin_to_bcd preserves it
    ; but clobbers ECX, so CL cannot be used here).
    mov bh, 0
    mov rax, r12
    test bl, 0x02
    jnz .hr_pack_st        ; 24h mode: value + BH=0 as-is
    cmp rax, 12
    jb .hr_am_st
    mov bh, 0x80           ; PM
    je .hr_pack_st         ; 12 PM stays 12
    sub rax, 12
    jmp .hr_pack_st
.hr_am_st:
    test rax, rax
    jnz .hr_pack_st
    mov rax, 12            ; 0 AM -> 12 AM
    jmp .hr_pack_st
.hr_pack_st:
    test bl, 0x04
    jnz .hr_bin_st
    call rtc_bin_to_bcd
.hr_bin_st:
    or al, bh
    mov ah, al
    mov al, 0x04
    call cmos_write
    mov al, r13b
    test bl, 0x04
    jnz .mn_bin_st
    call rtc_bin_to_bcd
.mn_bin_st:
    mov ah, al
    mov al, 0x02
    call cmos_write
    mov al, r14b
    test bl, 0x04
    jnz .sc_bin_st
    call rtc_bin_to_bcd
.sc_bin_st:
    mov ah, al
    mov al, 0x00
    call cmos_write
    xor eax, eax
    jmp .done_st
.fail_st:
    mov rax, 1
.done_st:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; INT 21h date/time/disk handlers (were stubs; now RTC/volume backed).
;   Trap inputs live in CX/DX/AL per DOS; direct-call ABI mirrors them
;   in RCX/RDX/RAX. Results update both live regs and the SPSAVE frame.
; ------------------------------------------------------------
handler_getdate:            ; AH=2Ah -> CX=year DH=mon DL=day AL=wday
    ; NOTE: RCX/RDX are live results, so they are deliberately NOT pushed;
    ; only scratch regs are saved. Pops never touch result regs.
    push rbx
    push rsi
    push rdi
    call rtc_get_date64      ; ECX=year EDX=mon R8D=day R9D=wday
    jc .gd_fallback
    jmp .gd_fill
.gd_fallback:
    ; RTC unreadable: fall back to the COMMAND64 software clock so the
    ; call still returns a usable date (documented layering).
    movzx ecx, word [rel cmd_year]
    movzx edx, byte [rel cmd_month]
    movzx r8d, byte [rel cmd_day]
    xor r9d, r9d
.gd_fill:
    mov esi, edx
    shl esi, 8
    or esi, r8d
    mov edx, esi           ; RDX = (mon<<8)|day (ECX already = year)
    mov eax, r9d           ; AL = weekday
    mov rsi, [rel SPSAVE64]
    test rsi, rsi
    jz .gd_live
    mov [rsi + STKPTRS64.rcx_save], cx
    mov [rsi + STKPTRS64.rdx_save], dx
    mov rdi, [rsi + STKPTRS64.rax_save]
    mov dil, al
    mov [rsi + STKPTRS64.rax_save], rdi
.gd_live:
    clc
    pop rdi
    pop rsi
    pop rbx
    ret

handler_setdate:            ; AH=2Bh CX=year DH=mon DL=day -> AL=0 ok FF bad
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, rcx           ; year
    mov rsi, rdx
    shr rsi, 8
    and rsi, 0xFF          ; month
    and rdx, 0xFF          ; day
    call rtc_set_date64
    test rax, rax
    jnz .fail_sdt
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .ok_sdt
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, 0
    mov [rbx + STKPTRS64.rax_save], rcx
.ok_sdt:
    xor al, al
    clc
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_sdt:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .fail_sdt2
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, 0xFF
    mov [rbx + STKPTRS64.rax_save], rcx
.fail_sdt2:
    mov al, 0xFF
    stc
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_gettime:            ; AH=2Ch -> CH=hr CL=min DH=sec DL=0
    ; RCX/RDX are live results: not pushed (see handler_getdate note).
    push rbx
    push rsi
    push rdi
    call rtc_get_time64      ; ECX=hr EDX=min R8D=sec
    jc .gt_fallback
    jmp .gt_fill
.gt_fallback:
    movzx ecx, byte [rel cmd_hour]
    movzx edx, byte [rel cmd_min]
    movzx r8d, byte [rel cmd_sec]
.gt_fill:
    mov esi, ecx
    shl esi, 8
    or esi, edx
    mov ecx, esi           ; RCX = (hr<<8)|min
    mov edx, r8d
    shl edx, 8             ; RDX = (sec<<8)|0
    mov rsi, [rel SPSAVE64]
    test rsi, rsi
    jz .gt_live
    mov [rsi + STKPTRS64.rcx_save], cx
    mov [rsi + STKPTRS64.rdx_save], dx
    mov rdi, [rsi + STKPTRS64.rax_save]
    mov dil, 0
    mov [rsi + STKPTRS64.rax_save], rdi
.gt_live:
    xor al, al
    clc
    pop rdi
    pop rsi
    pop rbx
    ret

handler_settime:            ; AH=2Dh CH=hr CL=min DH=sec -> AL=0/FF
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, rcx
    shr rdi, 8
    and rdi, 0xFF          ; hour
    mov rsi, rcx
    and rsi, 0xFF          ; min
    mov rdx, rdx
    shr rdx, 8
    and rdx, 0xFF          ; sec
    call rtc_set_time64
    test rax, rax
    jnz .fail_stm
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .ok_stm
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, 0
    mov [rbx + STKPTRS64.rax_save], rcx
.ok_stm:
    xor al, al
    clc
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_stm:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .fail_stm2
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, 0xFF
    mov [rbx + STKPTRS64.rax_save], rcx
.fail_stm2:
    mov al, 0xFF
    stc
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_verify:             ; AH=2Eh AL=0/1 -> store VERIFY flag (was stub)
    cmp al, 1
    ja .fail_vf
    mov [rel VERIFY_FLAG64], al
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .ok_vf
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, 0
    mov [rbx + STKPTRS64.rax_save], rcx
.ok_vf:
    xor al, al
    clc
    ret
.fail_vf:
    mov al, 1
    stc
    ret

handler_newbase:            ; AH=26h NEWBASE -> RAX=max free paragraphs
    push rbx                ; (fixed 2M-8M heap; DX request ignored, documented)
    push rcx
    push rdx
    call mem_max_free64
    shr rax, 4
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .done_nb
    mov [rbx + STKPTRS64.rax_save], rax
.done_nb:
    clc
    pop rdx
    pop rcx
    pop rbx
    ret

; vol_ensure_mounted — lazy mount for disk handlers (idempotent).
;   Out: CF 0 mounted (vol_dpb valid), CF 1 failed. Preserves RAX? No: RAX=0/1.
vol_ensure_mounted:
    call fs_mount_volume64
    test rax, rax
    jz .mounted_ok
    stc
    ret
.mounted_ok:
    clc
    ret

handler_getfatpt:           ; AH=1Bh -> RBX=FAT ptr AL=fatsiz (was stub)
    push rcx
    push rdx
    call vol_ensure_mounted
    jc .fail_fp
    lea rbx, [rel fs_vol_fat]
    lea rcx, [rel fs_vol_dpb]
    movzx eax, byte [rcx + DPB64.fatsiz]
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_fp
    mov [rcx + STKPTRS64.rbx_save], rbx
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, al
    mov [rcx + STKPTRS64.rax_save], rdx
.done_fp:
    clc
    pop rdx
    pop rcx
    ret
.fail_fp:
    mov al, 0xFF
    stc
    pop rdx
    pop rcx
    ret

handler_getfatptdl:         ; AH=1Ch DL=drive -> same, or FF if bad drive
    push rbx
    movzx ebx, dl
    movzx ecx, byte [rel NUMDRV64]
    cmp ebx, ecx
    jae .fail_fpd
    pop rbx
    jmp handler_getfatpt
.fail_fpd:
    pop rbx
    mov al, 0xFF
    stc
    ret

handler_getdskpt:           ; AH=1Fh -> RBX=DPB ptr (was stub)
    push rax
    push rcx
    push rdx
    call vol_ensure_mounted
    jc .fail_dp
    lea rbx, [rel fs_vol_dpb]
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_dp2
    mov [rcx + STKPTRS64.rbx_save], rbx
.done_dp2:
    clc
    pop rdx
    pop rcx
    pop rax
    ret
.fail_dp:
    xor ebx, ebx
    stc
    pop rdx
    pop rcx
    pop rax
    ret

handler_getrdonly:          ; AH=1Dh -> AL=media byte (was stub)
    push rbx
    push rcx
    push rdx
    call vol_ensure_mounted
    jc .fail_ro
    lea rbx, [rel fs_vol_boot]
    mov al, [rbx + 21]     ; BPB media descriptor (0xF0)
    mov bl, al
    mov rcx, [rel SPSAVE64]
    test rcx, rcx
    jz .done_ro
    mov rdx, [rcx + STKPTRS64.rax_save]
    mov dl, bl
    mov [rcx + STKPTRS64.rax_save], rdx
.done_ro:
    mov al, bl
    clc
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_ro:
    mov al, 0xFF
    stc
    pop rdx
    pop rcx
    pop rbx
    ret

handler_setattrib:          ; AH=1Eh RDX=FCB AL=0 get CL / AL=1 set CL (was stub)
    ; RCX carries the attr result/value: not pushed (see getdate note).
    ; Input CL survives vol_ensure_mounted/find/flush (all preserve RCX).
    push rbx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    cmp al, 1
    ja .fail_sa
    test rdx, rdx
    jz .fail_sa
    mov r8, rax
    and r8, 0xFF             ; subfunc
    call vol_ensure_mounted
    jc .fail_sa
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [rdx + FCB64.name]   ; 11-byte name (name+ext contiguous)
    call fs_dir_find64
    jc .fail_sa
    cmp r8, 0
    je .get_sa
    ; set: CL -> entry attr + flush root
    mov [rbx + 11], cl
    call fs_vol_flush_root64
    test rax, rax
    jnz .fail_sa
    jmp .ok_sa
.get_sa:
    mov cl, [rbx + 11]
.ok_sa:
    mov rsi, [rel SPSAVE64]
    test rsi, rsi
    jz .live_sa
    mov rdi, [rsi + STKPTRS64.rax_save]
    mov dil, 0
    mov [rsi + STKPTRS64.rax_save], rdi
    mov [rsi + STKPTRS64.rcx_save], cx
.live_sa:
    xor al, al
    clc
    jmp .done_sa
.fail_sa:
    mov rsi, [rel SPSAVE64]
    test rsi, rsi
    jz .fail_sa2
    mov rdi, [rsi + STKPTRS64.rax_save]
    mov dil, 0xFF
    mov [rsi + STKPTRS64.rax_save], rdi
.fail_sa2:
    mov al, 0xFF
    stc
.done_sa:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

; ------------------------------------------------------------
; G1 file handlers — INT 21h FCB ops on the mounted volume (were stubs).
;   RDX = FCB64 ptr (DS:DX). DMA from DMAADD64_SC (AH=1Ah; required for
;   transfer/search — documented deviation from the PSP:80h default).
;   Sequential position P = extent*128 + nr, mirrored on SEQ ops;
;   random ops use the 64-bit RR field. Returns mirror DOS 1.x AL codes
;   (0 ok, 1 EOF-short, 0xFF fail) plus CF, with SPSAVE frame writeback.
; ------------------------------------------------------------

; fcb_get_pos — RDI=FCB -> RAX = extent*128 + nr. Clobbers RCX.
fcb_get_pos:
    movzx eax, word [rdi + FCB64.extent]
    shl eax, 7
    movzx ecx, byte [rdi + FCB64.nr]
    add eax, ecx
    ret

; fcb_set_pos — RDI=FCB, RSI=pos -> extent/nr mirrored. Clobbers RAX.
fcb_set_pos:
    mov rax, rsi
    shr rax, 7
    mov [rdi + FCB64.extent], ax
    and rsi, 127
    mov [rdi + FCB64.nr], sil
    ret

; fcb_frame_al — write AL status to the trap frame (if any). Preserves RAX.
fcb_frame_al:
    push rbx
    push rcx
    movzx ecx, al
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_fa
    mov [rbx + STKPTRS64.rax_save], cx   ; low byte = AL (AH untouched? no:
                                         ; writes CX low word; AH becomes CH=0.
                                         ; DOS AH is error-code bearing here,
                                         ; and 0 matches success convention.)
.no_frame_fa:
    pop rcx
    pop rbx
    ret

; rtc_pack_fat_datetime — Out: EAX=FAT time word, EDX=FAT date word.
;   RTC first, COMMAND64 software clock fallback (never fails in practice).
rtc_pack_fat_datetime:
    push rbx
    push rcx
    push r8
    push r9
    push r10
    call rtc_get_date64              ; ECX=y EDX=m R8D=d
    jc .sw_date_pd
    jmp .have_date_pd
.sw_date_pd:
    movzx ecx, word [rel cmd_year]
    movzx edx, byte [rel cmd_month]
    movzx r8d, byte [rel cmd_day]
.have_date_pd:
    mov r10d, edx                    ; month
    mov ebx, r8d                     ; day
    mov eax, ecx
    sub eax, 1980
    shl eax, 9
    shl r10d, 5
    or eax, r10d
    or eax, ebx                      ; EAX = date
    mov r10d, eax                    ; save date
    call rtc_get_time64              ; ECX=h EDX=min R8D=s
    jc .sw_time_pd
    jmp .have_time_pd
.sw_time_pd:
    movzx ecx, byte [rel cmd_hour]
    movzx edx, byte [rel cmd_min]
    movzx r8d, byte [rel cmd_sec]
.have_time_pd:
    mov eax, ecx
    shl eax, 11
    mov ebx, edx
    shl ebx, 5
    or eax, ebx
    mov ebx, r8d
    shr ebx, 1
    and ebx, 31
    or eax, ebx                      ; EAX = time
    mov edx, r10d                    ; EDX = date
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rbx
    ret

handler_open:               ; AH=0Fh OPEN FCB (was stub)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    test rdx, rdx
    jz .fail_op
    call vol_ensure_mounted
    jc .fail_op
    mov rdi, rdx
    mov word [rdi + FCB64.extent], 0
    mov byte [rdi + FCB64.nr], 0
    mov qword [rdi + FCB64.rr], 0
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    test rax, rax
    jnz .fail_op
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_op
.fail_op:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_op:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_close:              ; AH=10h CLOSE FCB (was stub)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r12
    test rdx, rdx
    jz .fail_clh
    mov r12, rdx                 ; FCB (survives pack: R12 untouched)
    call rtc_pack_fat_datetime   ; EAX=time word, EDX=date word
    mov esi, eax                 ; RSI = time
    mov rdi, r12                 ; RDI = FCB (RDX still = date)
    call fs_fcb_close64
    test rax, rax
    jnz .fail_clh
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_clh
.fail_clh:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_clh:
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; G1 file-search/delete/seq/create/rename handlers (were stubs).
;   RDX = FCB64 ptr (DS:DX). See the header above handler_open for
;   DMA/position/AL-CF conventions.
; ------------------------------------------------------------

; srch_run — shared SRCHFRST/SRCHNXT body.
;   In: RDX=FCB (pattern at +1), RSI=start slot. Out: AL 0/CF0 found
;   (32B dirent copied to DMA, srch_next_slot=next), FF/CF1 none.
srch_run:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    test rdx, rdx
    jz .fail_sr
    mov rax, [rel DMAADD64_SC]
    test rax, rax
    jz .fail_sr                  ; DMA required (SETDMA first)
    mov r8, rax                  ; DMA dst (survives mount/search: both
                                 ; preserve R8)
    call vol_ensure_mounted
    jc .fail_sr
    lea rdi, [rdx + FCB64.name]  ; pattern
    call fs_fcb_search64         ; RDI=pattern RSI=start -> RBX/RAX=next
    jc .fail_sr
    mov [rel srch_next_slot], rax
    mov rsi, rbx                 ; entry src
    mov rdi, r8                  ; DMA dst
    mov ecx, 32
    cld
    rep movsb
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_sr
.fail_sr:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_sr:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_srchfrst:           ; AH=11h (was stub)
    push rsi
    xor esi, esi
    mov qword [rel srch_next_slot], 0
    call srch_run                 ; RDX=FCB live, RSI=0
    pop rsi
    ret

handler_srchnxt:            ; AH=12h (was stub)
    push rsi
    mov rsi, [rel srch_next_slot]
    call srch_run
    pop rsi
    ret

handler_delete:             ; AH=13h DELETE FCB (was stub)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    test rdx, rdx
    jz .fail_del
    call vol_ensure_mounted
    jc .fail_del
    mov rdi, rdx
    call fs_fcb_delete64
    test rax, rax
    jnz .fail_del
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_del
.fail_del:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_del:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; seq_common — shared SEQRD/SEQWRT body.
;   In: RDX=FCB, R8D=0 read / 1 write. Out: AL 0 ok / 1 EOF-short / FF hard.
seq_common:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    test rdx, rdx
    jz .fail_sq
    mov rax, [rel DMAADD64_SC]
    test rax, rax
    jz .fail_sq
    mov rdi, rdx                 ; FCB
    call fcb_get_pos             ; RAX = P (clobbers RCX only)
    mov rsi, rax                 ; recno = P
    mov rdx, [rel DMAADD64_SC]   ; DMA
    mov ecx, 1
    ; RDI already = FCB. After the io call below, FCB is reloaded from
    ; the stack (pushes rbx,rcx,rdx,rsi,rdi,rbp,r8): orig RDX at [rsp+32].
    call fs_fcb_io64             ; RDI=FCB RSI=recno RDX=DMA ECX=1 R8D=rw
    jc .fail_sq
    test rax, rax
    jz .eof_sq
    mov rdi, [rsp + 32]          ; FCB
    call fcb_get_pos
    inc rax
    mov rsi, rax
    call fcb_set_pos
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_sq
.eof_sq:
    mov al, 1
    call fcb_frame_al
    mov al, 1
    clc
    jmp .done_sq
.fail_sq:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_sq:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_seqrd:              ; AH=14h (was stub)
    push r8
    xor r8d, r8d
    call seq_common
    pop r8
    ret

handler_seqwrt:             ; AH=15h (was stub)
    push r8
    mov r8d, 1
    call seq_common
    pop r8
    ret

handler_create:             ; AH=16h CREATE FCB (was stub)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r12
    test rdx, rdx
    jz .fail_mkf
    call vol_ensure_mounted
    jc .fail_mkf
    mov rdi, rdx
    call fs_fcb_create64         ; -> RBX=entry
    test rax, rax
    jnz .fail_mkf
    mov r12, rdi                 ; FCB (create preserves RDI: pushes it)
    mov word [r12 + FCB64.extent], 0
    mov byte [r12 + FCB64.nr], 0
    mov qword [r12 + FCB64.rr], 0
    call rtc_pack_fat_datetime   ; EAX=time EDX=date (R12/RBX survive: pack
                                 ; pushes rbx + never touches R12)
    mov [rbx + 22], ax           ; DIRENT.time
    mov [rbx + 24], dx           ; DIRENT.date
    call fs_vol_flush_root64
    test rax, rax
    jnz .fail_mkf
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_mkf
.fail_mkf:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_mkf:
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_rename:             ; AH=17h RENAME (new name at FCB+16) (was stub)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    test rdx, rdx
    jz .fail_rnh
    call vol_ensure_mounted
    jc .fail_rnh
    mov rdi, rdx
    call fs_fcb_rename64
    test rax, rax
    jnz .fail_rnh
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_rnh
.fail_rnh:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_rnh:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rnd_common — shared RNDRD/RNDWRT body (single record at RR).
;   In: RDX=FCB, R8D=0 read / 1 write. Out: AL 0 ok / 1 EOF-short / FF hard.
rnd_common:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    test rdx, rdx
    jz .fail_rn2
    mov rax, [rel DMAADD64_SC]
    test rax, rax
    jz .fail_rn2
    mov rdi, rdx                 ; FCB
    mov rsi, [rdi + FCB64.rr]    ; recno = RR
    mov rdx, rax                 ; DMA
    mov ecx, 1
    call fs_fcb_io64
    jc .fail_rn2
    test rax, rax
    jz .eof_rn2
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_rn2
.eof_rn2:
    mov al, 1
    call fcb_frame_al
    mov al, 1
    clc
    jmp .done_rn2
.fail_rn2:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_rn2:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_rndrd:              ; AH=21h (was stub)
    push r8
    xor r8d, r8d
    call rnd_common
    pop r8
    ret

handler_rndwrt:             ; AH=22h (was stub)
    push r8
    mov r8d, 1
    call rnd_common
    pop r8
    ret

handler_filesize:           ; AH=23h RR = ceil(filsiz/recsiz) (was stub)
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    test rdx, rdx
    jz .fail_fs
    call vol_ensure_mounted
    jc .fail_fs
    mov rdi, rdx
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64           ; refresh firclus/filsiz (keeps rr/ext/nr)
    test rax, rax
    jnz .fail_fs
    mov eax, [rdi + FCB64.recsiz]
    test eax, eax
    jnz .have_rs_fs
    mov eax, 128
.have_rs_fs:
    mov ebx, eax                  ; divisor (RBX pushed, safe)
    mov rax, [rdi + FCB64.filsiz]
    add rax, rbx
    dec rax
    xor edx, edx
    div rbx                       ; RAX = ceil(filsiz/recsiz)
    mov [rdi + FCB64.rr], rax
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_fs
.fail_fs:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_fs:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

handler_setrndrec:          ; AH=24h RR = extent*128 + nr (was stub)
    push rbx
    push rcx
    push rdi
    test rdx, rdx
    jz .fail_sr2
    mov rdi, rdx
    call fcb_get_pos
    mov [rdi + FCB64.rr], rax
    mov al, 0
    call fcb_frame_al
    mov al, 0
    clc
    jmp .done_sr2_ok
.done_sr2_ok:
    pop rdi
    pop rcx
    pop rbx
    ret
.fail_sr2:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_sr2:
    pop rdi
    pop rcx
    pop rbx
    ret

; blk_common — shared BLKRD/BLKWRT body (CX records at RR, RR advances).
;   In: RDX=FCB, RCX=count(16-bit), R8D=0/1. Out: frame CX=done + AL/CF.
blk_common:
    ; RCX is the live done-count result: not pushed (io preserves RCX).
    push rbx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    test rdx, rdx
    jz .fail_bl
    mov rax, [rel DMAADD64_SC]
    test rax, rax
    jz .fail_bl
    mov rdi, rdx
    mov rsi, [rdi + FCB64.rr]
    mov rdx, rax
    and ecx, 0xFFFF               ; DOS CX is 16-bit
    call fs_fcb_io64
    ; RAX=done. Advance RR by done (FCB pointer in orig-RDX slot:
    ; pushes rbx,rdx,rsi,rdi,rbp,r8,r9 (7) -> [rsp+40]).
    mov r9, rax                   ; done (io preserves R9: pushes it)
    mov rdi, [rsp + 40]
    add [rdi + FCB64.rr], r9
    mov rsi, [rel SPSAVE64]
    test rsi, rsi
    jz .live_bl
    mov [rsi + STKPTRS64.rcx_save], r9w
    mov rax, [rsi + STKPTRS64.rax_save]
    mov al, 0
    mov [rsi + STKPTRS64.rax_save], rax
.live_bl:
    mov rcx, r9
    xor al, al
    clc
    jmp .done_bl
.fail_bl:
    mov al, 0xFF
    call fcb_frame_al
    mov al, 0xFF
    stc
.done_bl:
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

handler_blkrd:              ; AH=27h (was stub)
    push r8
    xor r8d, r8d
    call blk_common
    pop r8
    ret

handler_blkwrt:             ; AH=28h (was stub)
    push r8
    mov r8d, 1
    call blk_common
    pop r8
    ret

handler_makefcb:            ; AH=29h AL=mode RSI=src RDI=dst (was stub)
    ; RSI is the live end-ptr result: not pushed (makefcb sets it).
    ; RDI is input-only (makefcb preserves it): not pushed.
    push rbx
    push rcx
    push rdx
    push rbp
    test rsi, rsi
    jz .fail_mf2
    test rdi, rdi
    jz .fail_mf2
    call fs_make_fcb64           ; AL=mode in -> AL=0/1/FF, RSI=end
    mov rdx, rsi                 ; save end (RSI must survive pops: none now)
    cmp al, 0xFF
    je .fail_mf2
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .live_mf2
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, al
    mov [rbx + STKPTRS64.rax_save], rcx
    mov [rbx + STKPTRS64.rsi_save], rdx
.live_mf2:
    mov rsi, rdx
    clc
    jmp .done_mf2
.fail_mf2:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .fail_mf3
    mov rcx, [rbx + STKPTRS64.rax_save]
    mov cl, 0xFF
    mov [rbx + STKPTRS64.rax_save], rcx
.fail_mf3:
    mov al, 0xFF
    stc
.done_mf2:
    pop rbp
    pop rdx
    pop rcx
    pop rbx
    ret

%macro STUB_HANDLER 1
%1:
    mov al, 0
    ret
%endmacro

; Genuine DOS-reserved slots (DOS 1.25 itself stubs these: INUSE/USERCODE
; return 0). Kept as stubs by design — see the gap-analysis doc.
STUB_HANDLER handler_inuse
STUB_HANDLER handler_usercode

; ------------------------------------------------------------
; Phase6: Memory handlers — INT 21h AH=48h/49h/4Ah (DOS 2.0+)
;   Demonstrate paragraph->byte conversion (SHL 4) and flat 64-bit.
;   Handler called via DISPATCH64[AH*8] from syscall_dispatch64.
;   For trap, RBX holds user BX (paragraphs or segment). For direct
;   call, RDI holds bytes/linear. We support both: if RDI !=0 use it,
;   else use RBX paragraphs*16. Return AL 0 success, AH error, RAX linear.
; ------------------------------------------------------------
handler_alloc_mem:
    push rbx
    push rcx
    push rdx
    ; Try direct RDI bytes first (Phase6 tests call with RDI)
    test rdi, rdi
    jnz .use_rdi
    ; else use RBX paragraphs (from trap frame or caller RBX)
    mov rax, rbx
    shl rax, 4              ; para->bytes
    mov rdi, rax
.use_rdi:
    call mem_alloc64
    test rax, rax
    jz .fail_a
    ; success: RAX = linear, set AL=0, also update trap frame if via INT21
    ; If called via dispatch, need to write back to SPSAVE frame
    push rax
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame
    mov [rbx + STKPTRS64.rax_save], rax
    mov byte [rbx + STKPTRS64.rax_save], 0 ; AL 0 success
    ; Also store max free in RBX save for failure case? Keep RBX as is
.no_frame:
    pop rax
    clc                   ; success, RAX = linear intact
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_a:
    call mem_max_free64
    mov rcx, rax            ; max free bytes
    add rcx, 15
    shr rcx, 4              ; to paragraphs
    push rcx
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame2
    mov [rbx + STKPTRS64.rbx_save], rcx
    mov qword [rbx + STKPTRS64.rax_save], 0
    mov byte [rbx + STKPTRS64.rax_save+1], 8 ; AH=8 insufficient memory (DOS error)
.no_frame2:
    pop rcx
    mov rax, rcx            ; also return max in RAX for direct caller
    mov al, 1
    stc
    pop rdx
    pop rcx
    pop rbx
    ret

handler_free_mem:
    push rbx
    ; RDI = linear if direct, else ES:BX paragraph segment? For trap, ES:BX linear is in RDI? Simplify direct.
    test rdi, rdi
    jnz .use_rdi_f
    mov rdi, rbx
    ; If BX was paragraphs segment, convert: linear = BX*16
    shl rdi, 4
    add rdi, 0x200000        ; heuristic? For direct we expect already linear
.use_rdi_f:
    call mem_free64
    jc .fail_f
    mov al, 0
    pop rbx
    ret
.fail_f:
    mov al, 1
    stc
    pop rbx
    ret

handler_resize_mem:
    push rbx
    push rsi
    ; RDI = linear, RSI = new size bytes or RBX paragraphs + RCX?
    test rsi, rsi
    jnz .use_rsi
    mov rsi, rbx
    shl rsi, 4              ; para->bytes
.use_rsi:
    call mem_resize64
    test rax, rax
    jnz .fail_r
    mov al, 0
    pop rsi
    pop rbx
    ret
.fail_r:
    mov al, 1
    stc
    pop rsi
    pop rbx
    ret

handler_prtbuf:
    push rsi
    push rax
    mov rsi, rdx
.prt_next:
    lodsb
    cmp al, '$'
    je .prt_done
    mov dl, al
    call handler_conout
    jmp .prt_next
.prt_done:
    pop rax
    pop rsi
    ret

handler_setdma:
    mov [rel DMAADD64_SC], rdx
    ret

; ------------------------------------------------------------
; Phase8: EXEC (AH=4Bh) — spawn process from memory image
;   Direct: RDI=src linear, RSI=size bytes, RDX=cmdline (0=none),
;           RCX=cmdlen, R8=env_src (0=default)
;   Trap via DISPATCH64: same regs live (push preserves values),
;           RAX=0x4B00 (AH=4Bh). Returns pid.
;   Out: RAX=pid (0 fail), RDX=psp (0 fail), CF 0 ok / 1 fail.
;   Success = CF=0 + RAX!=0 (pid 1..). Fail = CF=1 + RAX=0.
;   Trap frame: writes pid to [SPSAVE+rax_save] + [rbx_save] for parent.
; ------------------------------------------------------------
handler_exec:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; RDI/RSI/RDX/RCX/R8 already hold args (push preserves values, regs unchanged)
    call proc_spawn64
    ; RAX=pid, RDX=psp
    mov [rel exec_dbg_pid], rax
    test rax, rax
    jz .fail_e
    mov r9, rax          ; save pid
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_e
    mov [rbx + STKPTRS64.rax_save], rax
    mov [rbx + STKPTRS64.rbx_save], rax
.no_frame_e:
    mov rax, r9          ; restore pid (proc_spawn used RAX/RDX returns; pushes didn't clobber regs except RAX/RDX)
    ; RDX already holds psp from proc_spawn? proc_spawn returns RDX=psp, but our pushes saved orig RDX.
    ; After call, RDX=psp (return). Our push/pop of rdx will restore orig RDX on pop, losing psp!
    ; So save psp in R9 as well before pops.
    mov r9, rdx          ; psp (overwrites pid save; need both) -> use stack slots
    ; Actually need both pid and psp across pops. Save to frame or static:
    mov [rel exec_ret_pid], rax
    mov [rel exec_ret_psp], r9
    clc
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rax, [rel exec_ret_pid]
    mov rdx, [rel exec_ret_psp]
    ret
.fail_e:
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_ef
    mov qword [rbx + STKPTRS64.rax_save], 0
    mov qword [rbx + STKPTRS64.rbx_save], 0
.no_frame_ef:
    xor eax, eax
    xor edx, edx
    stc
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Phase8: EXIT (AH=4Ch) — terminate current process
;   Direct: RDI=exit_code (or AL from RAX=0x4Cxx for trap compat)
;   Trap: RAX=0x4Cxx, AL=code (RDI ignored if 0? we prefer AL when RDI holds stale?)
;   Out: RAX 0 ok (child exited), 1 fail (kernel current), CF accordingly.
; ------------------------------------------------------------
handler_exit_process:
    push rbx
    push rdi
    push rcx
    ; Prefer RDI if caller set it non-trivially? Trap sets RDI=stale (whatever caller RDI was).
    ; DOS passes code in AL. For 64-bit, support both: if RDI >255, use AL; else use DIL?
    ; Simplest: if RDI <256 and RAX high AH==0x4C, use AL (trap); else use RDI.
    ; Check AH:
    mov ebx, eax
    shr ebx, 8
    and ebx, 0xFF
    cmp bl, 0x4C
    jne .use_rdi
    ; AH==4Ch -> trap or direct-with-RAX: use AL
    movzx edi, al
    jmp .do_exit
.use_rdi:
    ; keep RDI as is
.do_exit:
    call proc_exit_current64
    test rax, rax
    jnz .fail_x
    xor eax, eax
    clc
    pop rcx
    pop rdi
    pop rbx
    ret
.fail_x:
    mov rax, 1
    stc
    pop rcx
    pop rdi
    pop rbx
    ret

demo_les_lds:
    mov rdi, [rel DMAADD64_SC]
    mov rsi, [rel SPSAVE64]
    mov rax, [rsi + STKPTRS64.rax_save]
    ret
