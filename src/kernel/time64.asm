; MS-DOS64 src/kernel/time64.asm — timekeeping leaf module (RTC + software clock)
; Layering (see AGENTS.md source map):
;   time64 OWNS the software clock (time_year/month/day/hour/min/sec) and all
;   CMOS RTC access (ports 0x70/0x71, BCD helpers from src/lib/bcd64.asm).
;   DEPENDS ON: bcd64 lib only (rtc_bcd_to_bin_v2 / rtc_bin_to_bcd).
;   DEPENDED ON BY: syscall64.asm (INT 21h AH=2Ah-2Dh handlers + FAT timestamp
;   pack) and cmd64.asm/shell64.asm (DATE/TIME builtins + REPL sync).
;   Neither syscall64 nor shell64 may define or own clock state; cmd64 may not
;   be externed by syscall64. The cmd_year/cmd_date_set64/... symbols below are
;   backward-compat aliases to the canonical time_* storage/entry points so
;   pre-existing callers keep linking; all in-tree code uses the time_* names.
bits 64
default rel

section .text
global time_init64
global time_date_get64
global time_date_set64
global time_date_parse64
global time_time_get64
global time_time_set64
global time_time_parse64
global time_is_leap
global time_date_days_in_month
global cmd_date_get64
global cmd_date_set64
global cmd_date_parse64
global cmd_time_get64
global cmd_time_set64
global cmd_time_parse64
global cmd_is_leap
global cmd_date_days_in_month
global time_year
global time_month
global time_day
global time_hour
global time_min
global time_sec
global cmd_year
global cmd_month
global cmd_day
global cmd_hour
global cmd_min
global cmd_sec
global rtc_get_date64
global rtc_get_time64
global rtc_set_date64
global rtc_set_time64
global rtc_pack_fat_datetime
extern rtc_bcd_to_bin_v2
extern rtc_bin_to_bcd

; time_init64 — reset software clock to defaults 1983-04-01 12:00:00.
;   Out: RAX 0. Preserves RBX/RDI/RSI/RDX/RCX.
time_init64:
    push rbx
    mov word [rel time_year], 1983
    mov byte [rel time_month], 4
    mov byte [rel time_day], 1
    mov byte [rel time_hour], 12
    mov byte [rel time_min], 0
    mov byte [rel time_sec], 0
    xor eax, eax
    pop rbx
    ret

; ---- DATE ----
; time_date_get64 RDI=out RSI=size -> "YYYY-MM-DD" NUL, 0/1
time_date_get64:
cmd_date_get64:
    test rdi, rdi
    jz .bad_dg
    cmp rsi, 11
    jb .bad_dg
    push rbx
    push r12
    push r13
    mov r12, rdi
    movzx eax, word [rel time_year]
    movzx r13d, byte [rel time_month]
    movzx edx, byte [rel time_day]
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

; time_is_leap: AX=year -> RAX 1 leap else 0 (div by 4, no century rule needed for 1980-2099 except 2000 leap ok)
time_is_leap:
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

; time_date_days_in_month: RDI=year RSI=month -> RAX days (0 bad)
time_date_days_in_month:
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
    call time_is_leap
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

; time_date_set64 RDI=year RSI=month RDX=day -> 0/1 (valid 1980-2099, month 1-12, day valid)
time_date_set64:
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
    call time_date_days_in_month
    test rax, rax
    jz .bad_ds_pop
    cmp r14, rax
    ja .bad_ds_pop
    mov rax, r12
    mov [rel time_year], ax
    mov rax, r13
    mov [rel time_month], al
    mov rax, r14
    mov [rel time_day], al
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

; helper time_parse_num2 RDI=str -> RAX=val RDX=newptr RCX=digits(0 fail, else 1-2)
time_parse_num2:
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

; helper time_parse_num4 RDI=str -> RAX=val RDX=newptr RCX=digits(2-4 ok else 0)
time_parse_num4:
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

; time_date_parse64 RDI=str ("MM-DD-YY[YY]" or "MM/DD/YY[YY]", like INLINE/GETNUM) -> 0/1 + store
; Accepts 1-2 digit M, sep - or /, 1-2 digit D, sep, 2 or 4 digit Y (2-digit => 1900+)
time_date_parse64:
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
    call time_parse_num2
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
    call time_parse_num2
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
    call time_parse_num4
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
    call time_date_set64
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

; ---- TIME ----
; time_time_get64 RDI=out RSI=size -> "HH:MM:SS" NUL, 0/1 (needs 9)
time_time_get64:
cmd_time_get64:
    test rdi, rdi
    jz .bad_tg
    cmp rsi, 9
    jb .bad_tg
    push rbx
    movzx eax, byte [rel time_hour]
    mov bl, 10
    div bl
    add al, '0'
    mov [rdi], al
    add ah, '0'
    mov [rdi+1], ah
    mov byte [rdi+2], ':'
    movzx eax, byte [rel time_min]
    div bl
    add al, '0'
    mov [rdi+3], al
    add ah, '0'
    mov [rdi+4], ah
    mov byte [rdi+5], ':'
    movzx eax, byte [rel time_sec]
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

; time_time_set64 RDI=h RSI=m RDX=s -> 0/1 (h 0-23, m/s 0-59)
time_time_set64:
cmd_time_set64:
    cmp rdi, 23
    ja .bad_ts
    cmp rsi, 59
    ja .bad_ts
    cmp rdx, 59
    ja .bad_ts
    mov [rel time_hour], dil
    mov [rel time_min], sil
    mov [rel time_sec], dl
    xor eax, eax
    ret
.bad_ts:
    mov rax, 1
    ret

; time_time_parse64 RDI=str ("HH:MM[:SS]", like TIME INLINE) -> 0/1 + store
time_time_parse64:
cmd_time_parse64:
    test rdi, rdi
    jz .bad_tp
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov rdi, r12
    call time_parse_num2
    test rcx, rcx
    jz .fail_tp
    mov r13, rax
    mov r12, rdx
    mov al, [r12]
    cmp al, ':'
    jne .check_end_tp
    inc r12
    mov rdi, r12
    call time_parse_num2
    test rcx, rcx
    jz .fail_tp
    mov r14, rax
    mov r12, rdx
    mov al, [r12]
    cmp al, ':'
    jne .use_hm_tp
    inc r12
    mov rdi, r12
    call time_parse_num2
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
    call time_time_set64
    jmp .done_tp
.set_tp2:
    mov rdi, r13
    mov rsi, r14
    mov rdx, rbx
    call time_time_set64
    jmp .done_tp
.set_tp2b:
    mov rdi, r13
    mov rsi, r14
    mov rdx, rbx
    call time_time_set64
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

; ------------------------------------------------------------
; CMOS RTC (ports 0x70/0x71) — backs INT 21h AH=2Ah-2Dh.
; (Moved verbatim from syscall64.asm; the only caller-visible change is
; that validation now goes through time_date_set64/time_time_set64, which
; also sync the time64 software clock.)
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
;   Validates via time_date_set64 (also syncs the time64 software clock).
rtc_set_date64:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi           ; year (callee-saved; DIV below clobbers RDX)
    mov r13, rsi           ; month
    mov r14, rdx           ; day
    call time_date_set64
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
;   Validates via time_time_set64 (also syncs the time64 software clock).
rtc_set_time64:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call time_time_set64
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

; rtc_pack_fat_datetime — Out: EAX=FAT time word, EDX=FAT date word.
;   RTC first, time64 software clock fallback (never fails in practice).
;   (Moved verbatim from syscall64.asm; callers in the syscall layer.)
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
    movzx ecx, word [rel time_year]
    movzx edx, byte [rel time_month]
    movzx r8d, byte [rel time_day]
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
    movzx ecx, byte [rel time_hour]
    movzx edx, byte [rel time_min]
    movzx r8d, byte [rel time_sec]
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

section .bss
alignb 16
time_year:
cmd_year: resw 1
time_month:
cmd_month: resb 1
time_day:
cmd_day: resb 1
time_hour:
cmd_hour: resb 1
time_min:
cmd_min: resb 1
time_sec:
cmd_sec: resb 1
