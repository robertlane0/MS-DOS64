; MS-DOS64 Register mapping & STKPTRS64 — Phase 3
; Documents 16-bit → 64-bit conversion and defines 64-bit trap frame.
; See docs/04-16bit-constructs-and-conversion-map.md §2 and MSDOS.ASM:196 STKPTRS

%ifndef REGS64_INC
%define REGS64_INC

; Original STKPTRS (MSDOS.ASM:196) 12 words = 24 bytes:
;   AXSAVE DW ; BXSAVE DW ; CXSAVE DW ; DXSAVE DW ; SISAVE DW ; DISAVE DW
;   BPSAVE DW ; DSSAVE DW ; ESSAVE DW ; IPSAVE DW ; CSSAVE DW ; FSAVE DW
;
; In 64-bit, trap frame is IRETQ (RIP,CS,RFLAGS,RSP,SS) plus 64-bit GPRs.
; We preserve DOS-style SAVREGS/LEAVE but expand to QWORDS and add R8-R15.

struc STKPTRS64
    .rax_save   resq 1    ; +0 : RAX (original AXSAVE, AH=func)
    .rbx_save   resq 1    ; +8 : RBX (dispatch BX*2)
    .rcx_save   resq 1    ; +16: RCX (loop counter, REP)
    .rdx_save   resq 1    ; +24: RDX (FCB ptr high)
    .rsi_save   resq 1    ; +32: RSI (source, FCB fields)
    .rdi_save   resq 1    ; +40: RDI (dest, DIRBUF)
    .rbp_save   resq 1    ; +48: RBP (DPB pointer)
    .r8_save    resq 1    ; +56: R8  (new temp)
    .r9_save    resq 1    ; +64: R9
    .r10_save   resq 1    ; +72: R10
    .r11_save   resq 1    ; +80: R11
    .r12_save   resq 1    ; +88: R12 callee-saved
    .r13_save   resq 1    ; +96: R13
    .r14_save   resq 1    ; +104: R14
    .r15_save   resq 1    ; +112: R15
    .ds_save    resq 1    ; +120: DS (ignored in long mode, kept for compat)
    .es_save    resq 1    ; +128: ES
    .rip_save   resq 1    ; +136: RIP (was IPSAVE)
    .cs_save    resq 1    ; +144: CS  (was CSSAVE)
    .rflags     resq 1    ; +152: RFLAGS (was FSAVE = FLAGS)
    .rsp_save   resq 1    ; +160: RSP (user)
    .ss_save    resq 1    ; +168: SS  (user)
endstruc
%define STKPTRS64_SIZE STKPTRS64_size

; Offsets for direct [rbp+...] or [rsp+...] access mirroring original
%define AXSAVE64  STKPTRS64.rax_save
%define BXSAVE64  STKPTRS64.rbx_save
%define CXSAVE64  STKPTRS64.rcx_save
%define DXSAVE64  STKPTRS64.rdx_save
%define SISAVE64  STKPTRS64.rsi_save
%define DISAVE64  STKPTRS64.rdi_save
%define BPSAVE64  STKPTRS64.rbp_save

; Helper macros: demonstrate register conversion patterns.
; Use these as documentation for manual conversion.

; Example: original `MOV AX,CS` -> 64-bit `mov rax, cs`? CS not writable, so use:
;   mov ax, cs  ; still valid in 64-bit for reading segment selector? but DS ignored.
; Better: eliminate DS=CS alias: use RIP-relative.

; Example: LDS SI, [SPSAVE] -> mov rsi, [rel SPSAVE] ; manual flat load
;   ; In 16-bit:  LDS SI, DWORD PTR [SPSAVE]  loads DS:SI
;   ; In 64-bit:  mov rsi, [rel SPSAVE_linear] ; single 64-bit ptr
;   ;            mov rbx, [rel SPSAVE_seg]    ; if segment needed, but flat deletes it.

; Example: AAM (invalid in 64-bit) -> manual BCD:
;   ; original: AAM ; AH = AL/10, AL = AL%10
;   ; 64-bit: mov ah, 0 ; mov bl,10 ; div bl ; xchg al,ah

; Example: LES DI, [DMAADD] -> mov rdi, [rel DMAADD_linear] ; DQ

; Example: REP MOVSB with CX -> RCX, ensure DF=0 via CLD
;   ; original: mov cx, len ; rep movsb
;   ; 64-bit: mov rcx, len ; rep movsb (RCX) ; or rep movsq for 8-byte

; Example: LOOP -> dec rcx / jnz
;   ; original: loop label
;   ; 64-bit: dec rcx ; jnz label   (LOOP still valid but slow, avoid)

; Example: CBW -> cbw/cwde/cdqe/cqo depending on width
;   ; original: cbw ; AL->AX
;   ; 64-bit: cbw ; same, or cwde (AX->EAX), cdqe (EAX->RAX), cqo (RAX->RDX:RAX)

; Segment elimination:
;   ; original: mov ax,0x1000 ; mov ds,ax ; mov si,0x50 ; mov al,[ds:si]
;   ; 64-bit:  mov rsi,0x10050 ; mov al,[rsi]

%endif
