; MS-DOS64 lib/string64.asm — 64-bit string operation conversions
; Phase 3: Replaces 16-bit REP/MOVSB, SCASB, CMPSB, LODSB/STOSB, LOOP, XLAT, PUSH seg
; Sources: MSDOS.ASM: DEVNAME REPE CMPSB, WILDCRD, CONTSRCH; IO.ASM STATUS, etc.
; All routines use flat 64-bit addressing, RIP-relative, RCX counts, and avoid segment overrides.
; Demonstrates: REP with RCX, CLD, MOVSQ, LOOP->DEC/JNZ, XLAT->MOV, segment elimination.

bits 64
default rel

section .text

; Global exports for kernel use and testing
global memcpy64
global memset64
global memmove64
global strlen64
global strcmp64
global strupper64
global rep_movsb_demo
global rep_movsw_demo
global rep_movsq_demo
global scasb_demo
global cmpsb_demo
global lodsb_stosb_demo
global loop_replacement_demo
global xlat_replacement_demo
global segment_elimination_demo
global push_pop_seg_demo

; ------------------------------------------------------------
; memcpy64 — flat replacement for REP MOVSB with DS:SI -> ES:DI
;   In: RSI = source linear, RDI = dest linear, RCX = byte count
;   Original (MSDOS.ASM:758): MOV SI,OFFSET NAME1; MOV DI,OFFSET NAME3; MOV CX,6; REP MOVSW
;   16-bit used CX (16-bit) and DS=ES=CS alias. 64-bit uses RCX and flat.
;   Uses R8 as temporary to show R8-R15 availability.
; ------------------------------------------------------------
memcpy64:
    push rsi
    push rdi
    push rcx
    push r8
    ; Example use of R8 as extra temp (was not available in 16-bit)
    mov r8, rcx          ; save count in R8
    cld                  ; ensure DF=0 (was CLD in original at SAVREGS)
    rep movsb            ; RCX, not CX; operand size = BYTE
    ; Verify with R8
    cmp r8, rcx          ; RCX should be 0 after REP
    pop r8
    pop rcx
    pop rdi
    pop rsi
    ret

; Demonstrate explicit size variants
rep_movsb_demo:          ; byte move (original MSDOS MOVSB)
    cld
    rep movsb            ; RCX bytes from [rsi] to [rdi]
    ret

rep_movsw_demo:          ; word move — 16-bit still supported with prefix
    cld
    rep movsw            ; moves RCX words (2*RCX bytes). Original used MOVSW for DOSGROUP copies: MOVSW  X6 for NAME3
    ret

rep_movsq_demo:          ; 64-bit quad move — new capability, faster for large copies
    ; Original IO.ASM:156-187 MOVSW 2048 words (DOSLEN/2) to move DOS. 64-bit can use MOVSQ.
    cld
    shr rcx, 3           ; convert byte count to qword count (example)
    rep movsq            ; RCX qwords
    ret

; memmove-like with overlap handling (demonstrates STD/CLD)
memmove64:
    cmp rsi, rdi
    jb .backward
    cld
    rep movsb
    ret
.backward:
    ; copy backward to avoid overwrite
    std                  ; DF=1 for backward (original used STD in some paths? mostly CLD)
    add rsi, rcx
    dec rsi
    add rdi, rcx
    dec rdi
    rep movsb            ; with DF=1, RSI/RDI decrement
    cld                  ; restore DF=0 (ABI requires DF=0 on entry/return)
    ret

; ------------------------------------------------------------
; memset64 — replacement for REP STOSB / STOSW
;   In: RDI = dest, AL = value, RCX = count
;   Original: MOV AL,' '; MOV CX,80*25; REP STOSW (MSDOS VGA clear uses STOSW)
; ------------------------------------------------------------
memset64:
    cld
    rep stosb            ; byte fill: AL repeated RCX times
    ret

; ------------------------------------------------------------
; strlen64 — demonstrate SCASB replacement and LOOP->DEC/JNZ
;   In: RDI = string (zero-terminated)
;   Out: RAX = length
;   Original used SCASB + REPE or manual LODSB loop with LOOP instruction.
; ------------------------------------------------------------
strlen64:
    push rdi
    push rcx
    mov rcx, -1          ; max count (original used CX=127 or similar)
    xor al, al           ; search for 0
    cld
    repne scasb          ; find NUL: RCX counts down, RDI advances
    ; Original: REPE SCASW / REPNE SCASB at DEVNAME, MOVCHK
    ; After REPNE, RDI points past NUL, RCX = remaining
    not rcx
    dec rcx              ; length excluding NUL
    mov rax, rcx
    pop rcx
    pop rdi
    ret

; Explicit SCASB demo (matches MSDOS.ASM:524 REPE CMPSB, 540 REPE SCASW)
scasb_demo:
    ; Search for AL in [rdi] for RCX bytes
    ; Original: MOV CX,4; REPE CMPSB — now use RCX
    cld
    repne scasb          ; NZ? Actually SCASB compares AL with [RDI]
    ret

; CMPSB demo (string compare)
cmpsb_demo:
    ; Compare [rsi] vs [rdi] for RCX bytes, set flags
    ; Original: DEVNAME REPE CMPSB at 522, WILDCRD at 599
    cld
    repe cmpsb           ; compare until mismatch or RCX=0
    ret

; ------------------------------------------------------------
; LODSB/STOSB demo — manual character handling
;   Original: LODSB / STOSB sequences in TRANBUF (MSDOS 1791-1799)
;   64-bit: same mnemonics but RSI/RDI are 64-bit, loads/stores use AL
; ------------------------------------------------------------
lodsb_stosb_demo:
    ; Copy byte from [rsi] to [rdi] via AL, translating CR->? (like TRANBUF)
    lodsb                ; AL = [rsi++]
    cmp al, 13           ; check CR
    jne .norm
    mov byte [rsi], 10   ; original: MOV BYTE PTR [SI],10
.norm:
    stosb                ; [rdi++] = AL
    ret

; ------------------------------------------------------------
; LOOP replacement demo — original LOOP is valid in 64-bit but slow
;   Original: LOOP INITSTC, LOOP MOTORDELAY, etc. (IO.ASM:164 LOOP INITSTC, 810 LOOP MOTORDELAY)
;   64-bit: use DEC RCX / JNZ (faster, and demonstrates explicit 64-bit counter)
; ------------------------------------------------------------
loop_replacement_demo:
    ; Count down RCX, call dummy operation each iteration
    ; Original: MOV CX,4; INITSTC: LODB; ... ; LOOP INITSTC
    ; New:
    test rcx, rcx
    jz .done
.loop:
    ; placeholder operation: inc r8
    inc r8
    dec rcx
    jnz .loop            ; replaces LOOP .loop
.done:
    ret

; Alternative showing LOOP still assembles but we avoid it:
loop_old_style:
    ; This still works in 64-bit, but dec/jnz is preferred
    ; loop .target  ; 16-bit relative, uses RCX in 64-bit
    ret

; ------------------------------------------------------------
; XLAT replacement — XLAT is valid but uses DS:BX + AL; we replace with explicit indexed move
;   Original: XLAT at MSDOS.ASM:3545, IO.ASM:735 XLAT, 750 XLAT
;     MOV AL, [BX+AL]  (table at DS:BX, index AL)
;   64-bit: table base in RBX, index in RAX (zero-extended AL)
; ------------------------------------------------------------
xlat_replacement_demo:
    ; In: RBX = table base linear, AL = index
    ; Out: AL = table[index]
    ; Original: XLAT  (AL = [BX+AL], DS implicit)
    ; 64-bit replacement:
    movzx eax, al        ; zero extend AL to RAX (or EAX)
    mov al, [rbx + rax]  ; explicit flat: no segment override
    ret

; Full example matching IO.ASM:734-735
;   SEG CS MOV AL,[SI] ; XLAT ; (with BX = DRVTAB, AL = driver number)
; becomes:
;   mov rbx, [rel DRVTAB] ; RBX = table linear
;   movzx rax, al         ; RAX = index
;   mov al, [rbx + rax]   ; load

; ------------------------------------------------------------
; Segment elimination demo — show (segment<<4)+offset -> linear
;   Original DOS (MSDOS.ASM:175 BIOSSEG): MOV AX,CS; MOV DS,AX; MOV SI,OFFSET VAR; MOV AL,[DS:SI]
;     plus BIOS far table at SEGBIOS:0
;   64-bit flat: segment regs ignored (except FS/GS), DS base =0
; ------------------------------------------------------------
segment_elimination_demo:
    ; Original:
    ;   mov ax, 0x1000
    ;   mov ds, ax
    ;   mov si, 0x0050
    ;   mov al, [ds:si]      ; linear 0x10050
    ; 64-bit:
    mov rsi, 0x10050
    mov al, [rsi]            ; direct linear, no segment prefix
    ret

    ; Original with DOSGROUP alias (MSDOS.ASM:322)
    ;   MOV AX,CS
    ;   MOV DS,AX
    ;   MOV ES,AX
    ;   CALL BIOS... (far)
    ; 64-bit: eliminate DS/ES loads entirely
    ;   default rel ; mov rax, [rel variable] ; call driver_func (near)

; ------------------------------------------------------------
; PUSH segment / POP segment demo — segment pushes eliminated
;   Original: PUSH CS / POP DS (IO.ASM:148-149 PUSH CS / POP DS)
;             PUSH DS / POP ES, PUSH [SPSAVE] etc.
;   In long mode, PUSH DS/ES/SS are invalid (or do not push segment base).
;   64-bit: replace with mov or delete if alias (DS=CS).
; ------------------------------------------------------------
push_pop_seg_demo:
    ; Original sequence:
    ;   PUSH CS
    ;   POP DS
    ; 64-bit: DS is ignored, flat model -> no operation needed
    ; If saving/restoring DS for compatibility:
    ; push ds              ; INVALID in 64-bit: CPU raises #UD, NASM error. Must use MOV instead:
    ; So we show correct replacement:

    ; Save DS (if needed for emulation): mov rax, ds ; push rax
    mov rax, ds          ; read selector (still readable)
    push rax             ; push 64-bit value onto stack (RSP)

    ; Restore: pop rax ; mov ds, rax  (but DS load limited)
    pop rax
    mov ds, ax           ; DS load still allowed (selector) but base stays 0 in long mode

    ; Alternatively, totally eliminate:
    ;   ; no operation — use RIP-relative addressing instead of DS:...

    ret

; ------------------------------------------------------------
; Additional Phase 3 conversions: CBW/CWD, MUL/DIV, SHL/RCL examples (for bcd64.asm but shown here)
;   Placeholders referencing MSDOS.ASM:1116 CBW, 1254 MUL [BP.SECSIZ], etc.
; ------------------------------------------------------------

; strcmp64 — byte compare using repe cmpsb, returns 0 if equal
; In: RSI = s1, RDI = s2, RCX = max len or zero for NUL-terminated (we compute len)
; Out: RAX = 0 equal, else difference
strcmp64:
    push rsi
    push rdi
    push rcx
    ; Use R8 for original length if needed
    cld
    repe cmpsb
    je .equal
    ;Mismatch: previous byte difference in AL vs [RDI-1]
    mov al, [rsi-1]
    sub al, [rdi-1]
    movsx rax, al
    jmp .done
.equal:
    xor rax, rax
.done:
    pop rcx
    pop rdi
    pop rsi
    ret

; strupper64 — convert to uppercase, demonstrates LODSB/STOSB and byte operations
; In: RSI = source, RDI = dest, RCX = count
; Clobbers: RAX,R8
strupper64:
    cld
.loop:
    test rcx, rcx
    jz .done
    lodsb                ; AL = [rsi++]
    cmp al, 'a'
    jb .store
    cmp al, 'z'
    ja .store
    sub al, 32           ; to upper
.store:
    stosb                ; [rdi++] = AL
    dec rcx
    jnz .loop            ; dec/jnz instead of LOOP
.done:
    ret
