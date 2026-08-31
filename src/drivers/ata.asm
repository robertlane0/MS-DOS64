; MS-DOS64 ATA PIO disk driver — native 64-bit, replaces BIOS INT 13h
; Direct port I/O to ATA primary channel 0x1F0-0x1F7 / 0x3F6. No BIOS calls.
; Implements LBA28 PIO polling (no IRQ/DMA), identity-mapped.
; References: docs/02 §4-5, AGENTS.md Phase 5 Option C, ATA-1 spec.
; Original DOS via INT13: CHS through IO.ASM READ/WRITE (0xE0/0x78 etc.)
; 64-bit: LBA = (C*HPC+H)*SPT + S -1 ; convert CHS→LBA then use LBA28 PIO.
; Ports: 0x1F0 data (16b), 0x1F1 err, 0x1F2 cnt, 0x1F3 LBA0, 0x1F4 LBA1, 0x1F5 LBA2,
;        0x1F6 drive/head (LBA bits 24-27), 0x1F7 status/cmd, 0x3F6 alt/status
; Status bits: 0x80 BSY, 0x40 DRDY, 0x20 DF, 0x08 DRQ, 0x01 ERR
; Commands: 0x20 READ SECTORS PIO, 0x30 WRITE SECTORS PIO, 0xEC IDENTIFY
; Testing: read LBA0 (MBR) and check 0xAA55; write/readback verify.

bits 64
default rel

%define ATA_DATA        0x1F0
%define ATA_ERROR       0x1F1
%define ATA_SECCNT      0x1F2
%define ATA_LBA_LO      0x1F3
%define ATA_LBA_MID     0x1F4
%define ATA_LBA_HI      0x1F5
%define ATA_DRIVE       0x1F6
%define ATA_STATUS      0x1F7
%define ATA_COMMAND     0x1F7
%define ATA_ALTSTATUS   0x3F6
%define ATA_CONTROL     0x3F6

%define ATA_SR_BSY      0x80
%define ATA_SR_DRDY     0x40
%define ATA_SR_DF       0x20
%define ATA_SR_DRQ      0x08
%define ATA_SR_ERR      0x01

%define ATA_CMD_READ    0x20
%define ATA_CMD_WRITE   0x30
%define ATA_CMD_IDENTIFY 0xEC

%define ATA_TIMEOUT     1000000  ; loop iterations (~few ms per 100k? enough for Bochs/QEMU)

section .text
global ata_init
global ata_wait_not_busy
global ata_wait_drq
global ata_wait_ready
global ata_read_lba28
global ata_write_lba28
global ata_read_sectors
global ata_write_sectors
global ata_identify
global ata_status
global ata_error
global ata_flush
global lba_to_chs_demo
global chs_to_lba

; ------------------------------------------------------------
; Helpers: small delay (400ns) via reading alt status 4 times
; ------------------------------------------------------------
ata_delay_400ns:
    push rax
    push rdx
    mov dx, ATA_ALTSTATUS
    in al, dx
    in al, dx
    in al, dx
    in al, dx
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------
; ata_wait_not_busy — poll until BSY clear
;   Out: CF=0 success, CF=1 timeout
;   Clobbers: RAX, RCX, RDX
; ------------------------------------------------------------
ata_wait_not_busy:
    push rcx
    push rdx
    mov dx, ATA_ALTSTATUS   ; use alt status to avoid clearing IRQ
    mov rcx, ATA_TIMEOUT
.loop:
    in al, dx
    test al, ATA_SR_BSY
    jz .done
    dec rcx
    jnz .loop
    stc
    jmp .exit
.done:
    clc
.exit:
    pop rdx
    pop rcx
    ret

; alternate using primary status (also valid)
ata_wait_not_busy_pri:
    push rcx
    push rdx
    mov dx, ATA_STATUS
    mov rcx, ATA_TIMEOUT
.loop2:
    in al, dx
    test al, ATA_SR_BSY
    jz .done2
    dec rcx
    jnz .loop2
    stc
    jmp .exit2
.done2:
    clc
.exit2:
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; ata_wait_ready — wait BSY=0 and DRDY=1
;   CF=0 ok, CF=1 timeout
; ------------------------------------------------------------
ata_wait_ready:
    push rcx
    push rdx
    mov dx, ATA_ALTSTATUS
    mov rcx, ATA_TIMEOUT
.loop:
    in al, dx
    test al, ATA_SR_BSY
    jnz .next
    test al, ATA_SR_DRDY
    jnz .done
.next:
    dec rcx
    jnz .loop
    stc
    jmp .exit
.done:
    clc
.exit:
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; ata_wait_drq — wait BSY=0, DRQ=1, ERR=0
;   CF=0 DRQ ready, CF=1 timeout or error
; ------------------------------------------------------------
ata_wait_drq:
    push rcx
    push rdx
    mov dx, ATA_STATUS
    mov rcx, ATA_TIMEOUT
.loop:
    in al, dx
    test al, ATA_SR_BSY
    jnz .dec
    test al, ATA_SR_ERR
    jnz .err
    test al, ATA_SR_DRQ
    jnz .done
.dec:
    dec rcx
    jnz .loop
    stc
    jmp .exit
.err:
    stc
    jmp .exit
.done:
    clc
.exit:
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; ata_status — return status byte in AL
; ------------------------------------------------------------
ata_status:
    mov dx, ATA_STATUS
    in al, dx
    ret

; ------------------------------------------------------------
; ata_error — return error byte in AL (port 0x1F1)
; ------------------------------------------------------------
ata_error:
    mov dx, ATA_ERROR
    in al, dx
    ret

; ------------------------------------------------------------
; ata_flush — CACHE FLUSH 0xE7 (not needed for PIO but helper)
; ------------------------------------------------------------
ata_flush:
    push rax
    push rdx
    mov dx, ATA_COMMAND
    mov al, 0xE7
    out dx, al
    call ata_wait_not_busy
    pop rdx
    pop rax
    ret

; ------------------------------------------------------------
; ata_init — wait for drive ready (no software reset by default)
;   Primary master only (Bochs/QEMU ata0-master). No slave handling.
;   Performs gentle init: wait BSY clear, select master, wait DRDY.
;   Software reset is only used if drive not ready after generous timeout.
;   Returns: RAX 0 success, 1 timeout/error
; ------------------------------------------------------------
ata_init:
    push rdx
    push rcx
    ; First, wait for BSY clear without reset (drive already ready after BIOS)
    mov rcx, ATA_TIMEOUT*4
    mov dx, ATA_ALTSTATUS
.wait_bsy:
    in al, dx
    test al, ATA_SR_BSY
    jz .check_rdy
    dec rcx
    jnz .wait_bsy
    ; Still busy -> try software reset
    mov dx, ATA_CONTROL
    mov al, 0x04
    out dx, al
    call ata_delay_400ns
    xor al, al
    out dx, al
    call ata_delay_400ns
    mov rcx, ATA_TIMEOUT*4
    mov dx, ATA_ALTSTATUS
.wait_rst:
    in al, dx
    test al, ATA_SR_BSY
    jz .check_rdy
    dec rcx
    jnz .wait_rst
.check_rdy:
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_ERR
    jnz .fail
    ; Select master LBA to ensure drive selected
    mov dx, ATA_DRIVE
    mov al, 0xE0
    out dx, al
    call ata_delay_400ns
    ; Wait for DRDY
    call ata_wait_ready
    jc .fail
    xor eax, eax
    pop rcx
    pop rdx
    ret
.fail:
    mov eax, 1
    pop rcx
    pop rdx
    ret

; ------------------------------------------------------------
; ata_init_clean — alias (kept for compatibility)
; ------------------------------------------------------------
ata_init_clean:
    jmp ata_init

; ------------------------------------------------------------
; ata_select_drive — select master/slave, LBA mode
;   In: AL = drive (0=master, 1=slave), AH = LBA high nibble (bits 24-27)
; ------------------------------------------------------------
ata_select_drive:
    push rdx
    push rax
    mov dx, ATA_DRIVE
    ; AL already has drive bit? Construct: 0xE0 | (drive<<4) | high_nibble
    ; Input: AL=drive, AH=high
    mov bl, al
    shl bl, 4
    or bl, 0xE0
    or bl, ah
    mov al, bl
    out dx, al
    call ata_delay_400ns
    pop rax
    pop rdx
    ret

; ------------------------------------------------------------
; ata_read_lba28 — read sectors via LBA28 PIO
;   In:  RDI = destination buffer (linear, must be writable, 512*count bytes)
;        RSI = LBA (28-bit, 0 .. 0x0FFFFFFF)
;        RDX = sector count (1..256, 0 means 256 per ATA spec but we treat 0 as 256? We require 1..64)
;   Out: RAX = 0 success, 1 error/timeout
;   Clobbers: RCX, RSI, RDI temp but restores? Buffer pointer advanced internally.
;   Uses flat addressing only.
; ------------------------------------------------------------
ata_read_lba28:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12

    mov r8, rdi          ; r8 = current buffer pointer
    mov r9, rsi          ; r9 = LBA
    mov r10, rdx         ; r10 = remaining sectors (low byte valid)
    and r10, 0xFF
    test r10, r10
    jz .use256
    jmp .cnt_ok
.use256:
    mov r10, 256
.cnt_ok:
    ; Validate LBA < 2^28
    mov rax, r9
    shr rax, 28
    test rax, rax
    jnz .fail_range

    ; Wait for not busy
    call ata_wait_not_busy
    jc .fail

    ; Select drive: master, LBA high nibble
    mov eax, r9d
    shr eax, 24
    and al, 0x0F
    mov ah, al           ; high nibble to AH
    mov al, 0            ; drive 0 (master)
    ; Manually construct drive/head
    push rdx
    mov dx, ATA_DRIVE
    mov bl, ah
    or bl, 0xE0          ; 1110xxxx master LBA
    mov al, bl
    out dx, al
    pop rdx
    call ata_delay_400ns
    call ata_wait_not_busy
    jc .fail

    ; Sector count
    mov dx, ATA_SECCNT
    mov al, r10b
    out dx, al

    ; LBA bytes
    mov eax, r9d
    mov dx, ATA_LBA_LO
    out dx, al           ; LBA 0-7
    mov dx, ATA_LBA_MID
    shr eax, 8
    out dx, al           ; 8-15
    mov dx, ATA_LBA_HI
    shr eax, 8
    out dx, al           ; 16-23
    ; High nibble already in drive register

    ; Command
    mov dx, ATA_COMMAND
    mov al, ATA_CMD_READ
    out dx, al

    ; For each sector: wait DRQ, read 256 words
.sector_loop:
    call ata_wait_drq
    jc .fail

    mov dx, ATA_DATA
    mov rcx, 256
    mov rbx, r8          ; current buffer
.read_word:
    in ax, dx
    mov [rbx], ax
    add rbx, 2
    dec rcx
    jnz .read_word

    add r8, 512
    dec r10
    jz .done
    jmp .sector_loop

.done:
    ; Wait BSY clear after last sector
    call ata_wait_not_busy
    ; Check ERR/DF
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_ERR | ATA_SR_DF
    jnz .fail
    xor rax, rax
    jmp .exit
.fail_range:
.fail:
    mov rax, 1
.exit:
    pop r12
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

; Alias for generic read (count in EDX)
ata_read_sectors:
    jmp ata_read_lba28

; ------------------------------------------------------------
; ata_write_lba28 — write sectors via LBA28 PIO
;   In: RDI = source buffer (linear), RSI = LBA, RDX = count
;   Out: RAX 0 success
; ------------------------------------------------------------
ata_write_lba28:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11

    mov r8, rdi
    mov r9, rsi
    mov r10, rdx
    and r10, 0xFF
    test r10, r10
    jz .w256
    jmp .wcnt_ok
.w256:
    mov r10, 256
.wcnt_ok:
    mov rax, r9
    shr rax, 28
    test rax, rax
    jnz .wfail

    call ata_wait_not_busy
    jc .wfail

    ; Drive select
    mov eax, r9d
    shr eax, 24
    and al, 0x0F
    mov dx, ATA_DRIVE
    or al, 0xE0
    out dx, al
    call ata_delay_400ns
    call ata_wait_not_busy
    jc .wfail

    mov dx, ATA_SECCNT
    mov al, r10b
    out dx, al
    mov eax, r9d
    mov dx, ATA_LBA_LO
    out dx, al
    mov dx, ATA_LBA_MID
    shr eax, 8
    out dx, al
    mov dx, ATA_LBA_HI
    shr eax, 8
    out dx, al

    mov dx, ATA_COMMAND
    mov al, ATA_CMD_WRITE
    out dx, al

.wsector_loop:
    call ata_wait_drq
    jc .wfail

    mov dx, ATA_DATA
    mov rcx, 256
    mov rbx, r8
.w_word:
    mov ax, [rbx]
    out dx, ax
    add rbx, 2
    dec rcx
    jnz .w_word

    add r8, 512
    dec r10
    jz .wdone
    jmp .wsector_loop

.wdone:
    call ata_wait_not_busy
    jc .wfail
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_ERR | ATA_SR_DF
    jnz .wfail
    ; Flush cache
    mov dx, ATA_COMMAND
    mov al, 0xE7
    out dx, al
    call ata_wait_not_busy
    xor rax, rax
    jmp .wexit
.wfail:
    mov rax, 1
.wexit:
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

ata_write_sectors:
    jmp ata_write_lba28

; ------------------------------------------------------------
; ata_identify — PIO IDENTIFY DEVICE (0xEC)
;   In: RDI = buffer 512 bytes
;   Out: RAX 0 success, 1 no device/error
; ------------------------------------------------------------
ata_identify:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8

    call ata_wait_not_busy
    jc .ifail

    ; Select master
    mov dx, ATA_DRIVE
    mov al, 0xE0
    out dx, al
    call ata_delay_400ns

    mov dx, ATA_SECCNT
    xor al, al
    out dx, al
    mov dx, ATA_LBA_LO
    out dx, al
    mov dx, ATA_LBA_MID
    out dx, al
    mov dx, ATA_LBA_HI
    out dx, al
    mov dx, ATA_COMMAND
    mov al, ATA_CMD_IDENTIFY
    out dx, al

    ; Wait for BSY clear, then check if status=0 => no device
    mov dx, ATA_STATUS
    in al, dx
    test al, al
    jz .ifail
    call ata_wait_not_busy
    jc .ifail
    ; Check ERR
    mov dx, ATA_STATUS
    in al, dx
    test al, ATA_SR_ERR
    jnz .ifail
    test al, ATA_SR_DRQ
    jz .ifail

    ; Read 256 words
    mov dx, ATA_DATA
    mov rcx, 256
    mov rbx, rdi
.iread:
    in ax, dx
    mov [rbx], ax
    add rbx, 2
    dec rcx
    jnz .iread

    xor rax, rax
    jmp .iexit
.ifail:
    mov rax, 1
.iexit:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; CHS ↔ LBA helpers — for DOS CHS compatibility
;   Original DOS used CHS via INT13 (track/head/sector). ATA uses LBA.
;   Provide conversion: LBA = (C*HPC + H)*SPT + S -1
;   and inverse.
;   HPC=16, SPT=63 for our Bochs/QEMU image (cylinders=20 etc.)
;   Demo function for testing conversion correctness.
; ------------------------------------------------------------
chs_to_lba:
    ; In:  EAX = cylinder, BL = head, CL = sector (1-based)
    ;      EDX = HPC, ESI = SPT  (or use defaults 16,63 if zero)
    ; Out: EAX = LBA  (64-bit RAX but low 32 used)
    ; Flat 64-bit version using IMUL to avoid EDX:EAX complications
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    movzx ebx, bl        ; head
    movzx ecx, cl        ; sector
    mov r8d, eax         ; cylinder
    mov r9, rdx
    test r9, r9
    jnz .hpc_ok
    mov r9, 16
.hpc_ok:
    mov r10, rsi
    test r10, r10
    jnz .spt_ok
    mov r10, 63
.spt_ok:
    mov rax, r8
    imul rax, r9         ; C*HPC
    add rax, rbx         ; +H
    imul rax, r10        ; *SPT
    add rax, rcx         ; +S
    dec rax              ; -1
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

lba_to_chs_demo:
    ; In: EAX = LBA, EDX = HPC (16), ESI = SPT (63)
    ; Out: EAX = cylinder, BL=head, CL=sector
    ; 64-bit safe version
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov r8d, eax         ; LBA
    mov r9, rdx
    test r9, r9
    jnz .ok1
    mov r9, 16
.ok1:
    mov r10, rsi
    test r10, r10
    jnz .ok2
    mov r10, 63
.ok2:
    mov rax, r8
    xor rdx, rdx
    div r10              ; RAX=temp, RDX= LBA%SPT
    inc rdx
    mov cl, dl           ; sector
    xor rdx, rdx
    ; temp is in RAX (16)
    div r9               ; RAX=cyl, RDX=head
    mov bl, dl
    ; RAX already cyl
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; ata_test helpers — used by kernel main harness
; ------------------------------------------------------------
section .bss
align 16
global ata_test_buf
ata_test_buf: resb 1024   ; two sectors buffer
global ata_debug_status
global ata_debug_error
ata_debug_status: resb 1
ata_debug_error: resb 1

section .text
global ata_test_mbr_read
global ata_test_write_readback
global ata_test_chs_conversion

; Test reading MBR at LBA0 and checking 0xAA55
ata_test_mbr_read:
    push rdi
    push rsi
    push rdx
    push rbx
    lea rdi, [rel ata_test_buf]
    xor rsi, rsi         ; LBA 0
    mov rdx, 1
    call ata_read_lba28
    test rax, rax
    jnz .fail
    lea rdi, [rel ata_test_buf]
    mov bx, [rdi + 510]
    mov [rel ata_debug_status], bl  ; store low for debug (actually status)
    cmp word [rdi + 510], 0xAA55
    jne .fail_sig
    xor rax, rax
    jmp .done
.fail_sig:
    ; store actual word low/high in debug vars for inspection (reuse)
    lea rdi, [rel ata_test_buf]
    mov al, [rdi+510]
    mov [rel ata_debug_status], al
    mov al, [rdi+511]
    mov [rel ata_debug_error], al
    mov rax, 2  ; distinct code for signature mismatch
    jmp .done
.fail:
    ; store status/error for debug
    push rax
    mov dx, ATA_STATUS
    in al, dx
    mov [rel ata_debug_status], al
    mov dx, ATA_ERROR
    in al, dx
    mov [rel ata_debug_error], al
    pop rax
    mov rax, 1
.done:
    pop rbx
    pop rdx
    pop rsi
    pop rdi
    ret

; Test write LBA 1 then read back (uses stage2 area? but safe to test on unused LBA 100)
; We pick LBA 100 which is beyond kernel (kernel at 16..80). Image is 10M (~20480 sectors), so 100 is safe.
ata_test_write_readback:
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    lea rdi, [rel ata_test_buf]
    ; Fill buffer with pattern 0xA5 + ascending
    mov rcx, 512
    mov al, 0xA5
    mov rbx, rdi
.fill:
    mov [rbx], al
    inc rbx
    inc al
    dec rcx
    jnz .fill
    ; Write to LBA 100
    lea rdi, [rel ata_test_buf]
    mov rsi, 100
    mov rdx, 1
    call ata_write_lba28
    test rax, rax
    jnz .fail2
    ; Clear buffer
    lea rdi, [rel ata_test_buf]
    mov rcx, 512
    xor al, al
    mov rbx, rdi
.clear:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .clear
    ; Read back
    lea rdi, [rel ata_test_buf]
    mov rsi, 100
    mov rdx, 1
    call ata_read_lba28
    test rax, rax
    jnz .fail2
    ; Verify pattern
    lea rdi, [rel ata_test_buf]
    mov rcx, 512
    mov al, 0xA5
    mov rbx, rdi
.verify:
    cmp [rbx], al
    jne .fail2
    inc rbx
    inc al
    dec rcx
    jnz .verify
    ; Restore original? Not needed, but we wrote pattern to disk LBA100 - could leave
    ; Optional: zero it back to avoid dirtying image for next boot? Write zeros
    lea rdi, [rel ata_test_buf]
    mov rcx, 512
    xor al, al
    mov rbx, rdi
.zero2:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .zero2
    lea rdi, [rel ata_test_buf]
    mov rsi, 100
    mov rdx, 1
    call ata_write_lba28
    ; ignore result
    xor rax, rax
    jmp .done2
.fail2:
    mov rax, 1
.done2:
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

ata_test_chs_conversion:
    push rbx
    push rcx
    ; Test vector: LBA = (C*16+H)*63 + S -1
    ; Choose C=1, H=0, S=1 => LBA = (1*16+0)*63+0 = 1008
    mov eax, 1
    mov bl, 0
    mov cl, 1
    mov edx, 16
    mov esi, 63
    call chs_to_lba
    cmp eax, 1008
    jne .fail3
    ; Inverse: LBA 1008 -> C=1 H=0 S=1
    mov eax, 1008
    mov edx, 16
    mov esi, 63
    call lba_to_chs_demo
    cmp eax, 1
    jne .fail3
    cmp bl, 0
    jne .fail3
    cmp cl, 1
    jne .fail3
    ; Another: LBA 0 -> C0 H0 S1
    mov eax, 0
    mov edx, 16
    mov esi, 63
    call lba_to_chs_demo
    cmp eax, 0
    jne .fail3
    cmp bl, 0
    jne .fail3
    cmp cl, 1
    jne .fail3
    xor rax, rax
    jmp .done3
.fail3:
    mov rax, 1
.done3:
    pop rcx
    pop rbx
    ret
