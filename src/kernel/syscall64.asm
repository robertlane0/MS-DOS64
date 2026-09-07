bits 64
default rel
%include "include/regs.inc"
%include "include/fcb.inc"
%include "include/dpb.inc"
%include "include/psp.inc"
extern vga_putc
extern vga_print
extern mem_alloc64
extern mem_free64
extern mem_resize64
extern mem_max_free64
extern mem_bytes_to_para
extern mem_para_to_bytes
extern mem_para_to_bytes_checked64
extern proc_spawn64
extern proc_terminate64
extern proc_exit_current64
extern proc_init64
extern proc_get_psp64
extern proc_get_current64
extern proc_current
extern proc_psp
extern kbd_poll
extern kbd_has_data
extern kbd_queue_push
extern kbd_queue_pop
extern kbd_flush
extern kbd_scancode_to_ascii
extern kbd_init
extern idt_set_vector64
extern idt_get_vector64
; time64 leaf module (owns software clock + CMOS RTC; syscall date/time + FAT
; timestamps delegate). Layering: syscall64 -> time64, never the command
; interpreter clock (see AGENTS.md source map). No cmd64 clock externs here.
extern rtc_get_date64
extern rtc_get_time64
extern rtc_set_date64
extern rtc_set_time64
extern rtc_pack_fat_datetime
extern time_year
extern time_month
extern time_day
extern time_hour
extern time_min
extern time_sec
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
global handler_open_file
global handler_close_file
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
; N2b handle layer (AH=3Dh/3Eh; 3Ch/42h + file 3Fh/40h land in N2c).
; kern_fd_table mirrors PSP64.fd_table (16 qwords) for the kernel context
; (proc_current slot with no PSP, e.g. shell/harness): slot content is a
; 1-based index into fs_hdesc, 0 = free. Fds 0-2 are reserved console
; handles (never allocated); files live at 3..15.
; fs_hdesc: 16 system-wide open-file descriptions, 5 qwords each:
;   +0 state (0 free, 1 open read-only; 2 open read/write lands in N2c),
;   +8 first cluster, +16 size bytes, +24 position (N2c; 0),
;   +32 owner PSP (0 = kernel context; close-on-exit sweep lands in N2d).
kern_fd_table: resq 16
fs_hdesc:      resq 16*5
; Scratch FCB for 3Dh name parse + open (single-threaded cooperative use,
; same pattern as selftest aux_fcb; handlers run on IOSTACK/DSKSTACK).
hdl_fcb:       resb FCBSIZ64
; Debug/self-test hooks (fail-point markers, EXEC introspection).
; Gated behind -DDEBUG_SELFTEST (same pattern as SELFTEST_DESTRUCTIVE):
; default/smoke/full/lean builds omit them so release objects stay
; symbol-clean (see `make check-debug-symbols`). Debug builds define
; DEBUG_SELFTEST explicitly to retain the markers.
%ifdef DEBUG_SELFTEST
global exec_dbg_pid
exec_dbg_pid: resq 1
%endif

section .text
syscall_init:
    push rax
    push rcx
    push rdi
    xor rax, rax
    mov [rel SPSAVE64], rax
    mov [rel SSSAVE64], rax
    mov byte [rel THISDRV64], 0
    mov byte [rel CURDRV64], 0
    mov byte [rel NUMDRV64], 2   ; A:+B: (Phase9: SELDSK bounds, GETDRV)
    ; N2b handle layer starts empty (BSS is not trusted zeroed).
    cld
    lea rdi, [rel kern_fd_table]
    mov rcx, 16
    rep stosq
    lea rdi, [rel fs_hdesc]
    mov rcx, 16*5
    rep stosq
    pop rdi
    pop rcx
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
    dq handler_inuse      ; 3C (N2c: CREATE)
    dq handler_open_file  ; 3D 61 AH=3Dh OPEN (N2b: read-only files)
    dq handler_close_file ; 3E 62 AH=3Eh CLOSE (N2b)
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
    ; in future; for tests single-char so exact).
    ; IRQ-safety: kbd_queue_pop/push are individually atomic (pushfq/cli/
    ; popfq, caller IF preserved), so an IRQ1 producer cannot corrupt count
    ; mid-update; at most the peek rotates once more under IRQ, which is
    ; immaterial for an availability check (still FF iff any data).
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

; ------------------------------------------------------------
; N2b: handle file layer — AH=3Dh OPEN + AH=3Eh CLOSE (read-only).
; PLAN.md Phase N2 slices N2b (this) / N2c (3Ch + file 3Fh/40h + 42h).
; fds 0-2 stay reserved console handles (3Fh stdin / 40h stdout+stderr);
; files allocate fds 3..15 from the current context's table.
%define FD_FILE_MIN 3
%define FD_FILE_MAX 15
%define HDESC_N 16
%define HDESC_QWORDS 5
%define HDESC_STATE 0       ; qword idx: 0 free, 1 open read-only (2 = rw, N2c)
%define HDESC_FIRST 1       ; first cluster
%define HDESC_SIZEB 2       ; size bytes
%define HDESC_POS 3         ; position (N2c; 0)
%define HDESC_OWNER 4       ; owner PSP, 0 = kernel context (sweep: N2d)

; fd_table_base64 — Out: RAX = 16-qword fd table for the current context:
;   entered-child slot PSP (proc_psp[]) + fd_table, else kern_fd_table.
;   Clobbers RAX/RBX only. Slot bounds-checked (garbage -> kern table).
fd_table_base64:
    mov rbx, [rel proc_current]
    cmp rbx, 16                  ; == PROC_MAX (proc64.asm %define, not global)
    jae .fd_kern
    lea rax, [rel proc_psp]
    mov rax, [rax + rbx*8]
    test rax, rax
    jz .fd_kern
    lea rax, [rax + PSP64.fd_table]
    ret
.fd_kern:
    lea rax, [rel kern_fd_table]
    ret

; handler_open_file — AH=3Dh OPEN handle (N2b: read-only files).
;   Direct: RDI=mode (0 read-only; 1/2 fail until N2c), RDX=name ptr
;           (NUL-terminated 8.3, flat root only).
;   Trap: RAX=0x3Dmm (AL=mode, DOS 0/1/2), RDX=name; mode comes from AL
;           iff AH==0x3D (same trap/direct split as handler_exit_process).
;   Out: RAX=fd (3..15, DOS-ish errors below), CF 0 ok / 1 fail. Trap path
;        also writes RAX to the SPSAVE64 rax_save slot (3Fh pattern).
;   Fail codes (DOS-flavored): 2 not-found/bad-name, 4 table full,
;        5 access-denied (write modes until N2c).
;   Name rules: X: drive prefix parsed by the FCB layer (0/A: accepted);
;        '\' '/' subdirs rejected (flat root only); wildcards rejected.
;   Zero device writes on every path: mount is read-only on clean images
;        and open fills only the scratch FCB + RAM tables.
handler_open_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov r10d, 2                  ; default err: file not found
    mov ebx, eax
    shr ebx, 8
    and ebx, 0xFF
    cmp bl, 0x3D
    jne .use_rdi_of
    movzx edi, al                ; trap: DOS AL mode
.use_rdi_of:
    test rdi, rdi                ; N2b: mode 0 (read-only) only
    jz .mode_ok_of
    mov r10d, 5                  ; write modes -> denied until N2c
    jmp .fail_of
.mode_ok_of:
    test rdx, rdx
    jz .fail_of
    cmp byte [rdx], 0
    je .fail_of
    mov rsi, rdx                 ; RDX intact: name
    lea rdi, [rel hdl_fcb]
    xor eax, eax                 ; AL=0: no separator skipping (DOS-strict)
    call fs_make_fcb64
    jc .fail_of                  ; AL=0xFF malformed
    test al, al
    jnz .fail_of                 ; wild flag: no ?/* for 3Dh
    cmp byte [rsi], 0            ; parser must consume the whole string:
    jne .fail_of                 ; '\' '/' and trailing junk stop the cursor
                                 ; (flat root only; stricter than not-found)
    mov al, [rel hdl_fcb + FCB64.drive]
    cmp al, 1                    ; 0 default / 1 A: only (one volume)
    ja .fail_of
    call vol_ensure_mounted
    jc .fail_of
    lea rdi, [rel hdl_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    test rax, rax
    jnz .fail_of                 ; not found (err already 2)
    mov r9d, [rel hdl_fcb + FCB64.firclus]
    mov r10, [rel hdl_fcb + FCB64.filsiz]   ; size (kept live; err stays 2)
    test r10, r10
    jz .empty_ok_of
    cmp r9d, 2                   ; nonzero size needs a real first cluster;
    jb .fail_of                  ; refuse corrupt dirents (scrub DANGLING)
.empty_ok_of:
    call fd_table_base64         ; RAX=table (clobbers RAX/RBX only)
    mov r11, rax
    mov ecx, FD_FILE_MIN         ; alloc fd slot first (no rollback needed)
.fdscan_of:
    cmp ecx, FD_FILE_MAX+1
    jae .full_of
    cmp qword [r11 + rcx*8], 0
    je .fdfound_of
    inc ecx
    jmp .fdscan_of
.full_of:
    mov r10d, 4                  ; too many open files
    jmp .fail_of
.fdfound_of:                     ; ECX=fd
    lea rbx, [rel fs_hdesc]      ; alloc description
    xor r8d, r8d
.dscan_of:
    cmp r8d, HDESC_N
    jae .full_of
    mov rax, r8
    imul rax, rax, HDESC_QWORDS*8
    cmp qword [rbx + rax + HDESC_STATE*8], 0
    je .dfound_of
    inc r8d
    jmp .dscan_of
.dfound_of:                      ; R8=desc idx, ECX=fd, R9D=firstclus,
                                 ; R10=size (live since open; scans spared it)
    mov qword [rbx + rax + HDESC_STATE*8], 1
    mov [rbx + rax + HDESC_FIRST*8], r9
    mov [rbx + rax + HDESC_SIZEB*8], r10
    mov qword [rbx + rax + HDESC_POS*8], 0
    mov rdx, [rel proc_current]  ; owner PSP (0 = kernel context)
    cmp rdx, 16
    jae .owner0_of
    lea rax, [rel proc_psp]
    mov rdx, [rax + rdx*8]
    jmp .owner1_of
.owner0_of:
    xor edx, edx
.owner1_of:
    lea rax, [rel fs_hdesc]      ; recompute desc addr (rax reused above)
    mov rbx, r8
    imul rbx, rbx, HDESC_QWORDS*8
    mov [rax + rbx + HDESC_OWNER*8], rdx
    lea rax, [r8 + 1]            ; table slot = 1-based desc idx
    mov [r11 + rcx*8], rax
    mov eax, ecx                 ; RAX=fd
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .noframe_of
    mov [rbx + STKPTRS64.rax_save], rax
.noframe_of:
    clc
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_of:
    mov eax, r10d
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .noframe_fof
    mov [rbx + STKPTRS64.rax_save], rax
.noframe_fof:
    stc
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; handler_close_file — AH=3Eh CLOSE handle (N2b).
;   In: RBX=fd, direct and trap (BX) alike — same reg, no AH split needed.
;   Out: RAX=0 ok / 6 invalid handle, CF accordingly; trap frame updated.
;   Fds 0-2 (console) fail honestly; double close fails. N2b descs are
;   read-only so no flush is needed (N2c hook: writable+dirty flush here).
handler_close_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov ecx, ebx
    and ecx, 0xFFFF
    cmp ecx, FD_FILE_MIN
    jb .fail_cf
    cmp ecx, FD_FILE_MAX
    ja .fail_cf
    call fd_table_base64         ; RAX=table (clobbers RAX/RBX only)
    mov r8, rax
    mov rdx, [r8 + rcx*8]        ; 1-based desc idx, 0 = not open
    test rdx, rdx
    jz .fail_cf
    dec edx
    cmp edx, HDESC_N
    jae .fail_cf                 ; table/descriptor desync (paranoia)
    lea rax, [rel fs_hdesc]
    imul rdx, rdx, HDESC_QWORDS*8
    cmp qword [rax + rdx + HDESC_STATE*8], 0
    je .fail_cf
    mov qword [rax + rdx + HDESC_STATE*8], 0
    mov qword [rax + rdx + HDESC_FIRST*8], 0
    mov qword [rax + rdx + HDESC_SIZEB*8], 0
    mov qword [rax + rdx + HDESC_POS*8], 0
    mov qword [rax + rdx + HDESC_OWNER*8], 0
    mov qword [r8 + rcx*8], 0
    xor eax, eax
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .noframe_cf
    mov [rbx + STKPTRS64.rax_save], rax
.noframe_cf:
    clc
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
.fail_cf:
    mov eax, 6                   ; invalid handle
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .noframe_fcf
    mov [rbx + STKPTRS64.rax_save], rax
.noframe_fcf:
    stc
    pop r11
    pop r10
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
;   (Char is stashed in BL: RCX is the spin budget and DX holds the
;   port, so neither CL nor DH can hold it across the wait loop.)
com1_write_char:
    push rax
    push rbx
    push rcx
    push rdx
    mov bl, dl                ; stash char (BL survives port I/O + countdown)
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
    mov al, bl
    out dx, al
    clc
.done_tx:
    pop rdx
    pop rcx
    pop rbx
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
; CMOS RTC + software clock: owned by src/kernel/time64.asm.
; The INT 21h date/time handlers below call the time64 rtc_* APIs and read
; the time64 time_year/... fallback state (never cmd64/shell state).
; See AGENTS.md source map for layering.
; ------------------------------------------------------------


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
    ; RTC unreadable: fall back to the time64 software clock so the
    ; call still returns a usable date (documented layering).
    movzx ecx, word [rel time_year]
    movzx edx, byte [rel time_month]
    movzx r8d, byte [rel time_day]
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
    movzx ecx, byte [rel time_hour]
    movzx edx, byte [rel time_min]
    movzx r8d, byte [rel time_sec]
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

; rtc_pack_fat_datetime lives in src/kernel/time64.asm (RTC first, time64
; software-clock fallback). Called by the FCB create/close paths below.


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

handler_rename:             ; AH=17h RENAME (new name at FCB64.recsiz overlap) (was stub)
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
;   Overflow safety: every legacy paragraph count (untrusted, full 64-bit
;   RBX) goes through mem_para_to_bytes_checked64. On CF=1 the handler
;   fails cleanly (AH=8/CF=1 for ALLOC, CF=1 for FREE/RESIZE) WITHOUT
;   touching the MCB chain, so mem_validate64 still succeeds. Direct RDI/
;   RSI byte sizes stay on the mem_alloc64/mem_resize64 path, which already
;   rejects size+15 wrap and over-capacity. The fail-path max-free
;   bytes->para uses the fast helper only because max-free is heap-bounded
;   (<6 MiB, trusted); see the TRUSTED ONLY note in mem64.asm.
; ------------------------------------------------------------
handler_alloc_mem:
    push rbx
    push rcx
    push rdx
    ; Try direct RDI bytes first (Phase6 tests call with RDI)
    test rdi, rdi
    jnz .use_rdi
    ; else use RBX paragraphs (from trap frame or caller RBX):
    ; checked para->bytes, overflow -> clean insufficient-memory failure.
    mov rax, rbx
    call mem_para_to_bytes_checked64
    jc .fail_a
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
    ; Compatibility path: RBX paragraphs -> linear = RBX*16 + 0x200000.
    ; Both steps are checked: shift overflow or base-add wrap fails cleanly
    ; (CF=1) without calling mem_free64, heap untouched.
    mov rax, rbx
    call mem_para_to_bytes_checked64
    jc .fail_f
    add rax, 0x200000
    jc .fail_f
    mov rdi, rax
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
    ; Compatibility path: RBX paragraphs -> bytes via checked conversion
    ; (preserves RDI=ptr: helper uses RAX in/out, saves RDI). Overflow
    ; fails cleanly without calling mem_resize64, heap untouched.
    mov rax, rbx
    call mem_para_to_bytes_checked64
    jc .fail_r
    mov rsi, rax
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
%ifdef DEBUG_SELFTEST
    mov [rel exec_dbg_pid], rax
%endif
    test rax, rax
    jz .fail_e
    mov r9, rax          ; save pid (R9 orig is on the stack, safe as temp)
    mov rbx, [rel SPSAVE64]
    test rbx, rbx
    jz .no_frame_e
    mov [rbx + STKPTRS64.rax_save], rax
    mov [rbx + STKPTRS64.rbx_save], rax
.no_frame_e:
    mov rax, r9          ; restore pid
    ; RDX still holds psp from proc_spawn (frame code above preserves RDX).
    ; A plain `pop rdx` would restore the orig RDX (cmdline arg) over psp,
    ; so discard that slot instead — pid/psp survive in RAX/RDX with no
    ; BSS statics (exec_ret_pid/psp removed; see check-debug-symbols).
    clc
    pop r9
    pop r8
    pop rdi
    pop rsi
    add rsp, 8          ; discard saved orig RDX, keep psp in RDX
    pop rcx
    pop rbx
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
