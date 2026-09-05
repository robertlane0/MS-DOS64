; MS-DOS64 Stage2 — real -> protected -> long -> kernel at 0x100000
; Implements AGENTS.md Phase 2 & docs/05: A20, CPUID LM, PAE, paging, EFER, GDT64
; Loaded by MBR at 0x7E00 via BIOS INT13h
bits 16
org 0x7E00

; Jump over GDT if include placed early; execution starts here so GDT bytes aren't decoded
    jmp stage2_start
%include "src/boot/gdt.asm"
    ; if we include here again after the jump, we duplicate: so guard ensures only one copy.
    ; To avoid duplication, we rely on the jmpover: GDT sits between jump and entry, not executed.

KERNEL_LBA       equ 16
KERNEL_SECTORS   equ 176        ; 88 KiB — shell+tests headroom (was 160)
KERNEL_STAGING_SEG  equ 0x7000
KERNEL_STAGING_OFF  equ 0x0000  ; linear 0x70000 - staging buffer in low memory
KERNEL_DEST_LINEAR  equ 0x100000
PML4_ADDR        equ 0x1000
PDPT_ADDR        equ 0x2000
PD_ADDR          equ 0x3000
STACK_PM         equ 0x90000

stage2_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00               ; reuse MBR stack, grows down
    sti
    mov [boot_drive2], dl

    call init_serial2

    mov si, msg_stage2
    call print16

    call enable_a20_stage2

    mov si, msg_a20_ok2
    call print16

    ; Load kernel from disk (LBA 16) to 0x100000 before leaving real mode
    mov si, msg_load_kernel
    call print16
    call load_kernel
    mov si, msg_kernel_ok
    call print16

    ; ---- Switch to protected mode ----
    cli
    lgdt [gdt32_ptr]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x08:pmode

; ------------------------------------------------------------
; Real-mode helpers (still in 16-bit)
init_serial2:
    push ax
    push dx
    mov dx, 0x3F8 + 3
    mov al, 0x80
    out dx, al
    mov dx, 0x3F8 + 0
    mov al, 0x03
    out dx, al
    mov dx, 0x3F8 + 1
    xor al, al
    out dx, al
    mov dx, 0x3F8 + 3
    mov al, 0x03
    out dx, al
    mov dx, 0x3F8 + 2
    xor al, al              ; disable FIFO
    out dx, al
    mov dx, 0x3F8 + 4
    mov al, 0x03
    out dx, al
    pop dx
    pop ax
    ret

print16:
    push ax
    push bx
    push dx
    mov ah, 0x0E
    mov bx, 0x0007
.loop:
    lodsb
    test al, al
    jz .done
    int 0x10
    push ax
.wait_ser2:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait_ser2
    pop ax
    mov dx, 0x3F8
    out dx, al
    jmp .loop
.done:
    pop dx
    pop bx
    pop ax
    ret

enable_a20_stage2:
    push ax
    in al, 0x92
    or al, 2
    and al, 0xFE
    out 0x92, al
    call kbc_wait2
    mov al, 0xD1
    out 0x64, al
    call kbc_wait2
    mov al, 0xDF
    out 0x60, al
    call kbc_wait2
    in al, 0x92
    or al, 2
    and al, 0xFE
    out 0x92, al
    pop ax
    ret

kbc_wait2:
    in al, 0x64
    test al, 2
    jnz kbc_wait2
    ret

; Load kernel via LBA extended read; fallback to CHS 1-sector loop
load_kernel:
    ; Check INT13h extensions
    mov ah, 0x41
    mov bx, 0x55AA
    mov dl, [boot_drive2]
    int 0x13
    jc .try_chs
    cmp bx, 0xAA55
    jne .try_chs
    test cl, 1
    jz .try_chs

    ; LBA path — chunked DAP reads (<=16 sectors each: conservative for
    ; old BIOS 64K/DMA limits; 16*512=8KiB never spans 64K from 16B-aligned
    ; staging). Staging linear 0x70000+: seg = 0x7000 + done*32.
    ; NOTE: staging MUST stay clear of 0x90000 — BIOS INT 13h uses a stack
    ; at 0x90000 that overwrites the last bytes of any transfer ending
    ; there (corrupted shift-table TYUI -> Shift+T/Y/U/I dead, see QEMU
    ; GUI "PE HELLO.X" bug). 0x70000-0x86000 avoids it.
    mov ebx, KERNEL_SECTORS      ; remaining
    xor ebp, ebp                 ; done
.lba_chunk:
    test ebx, ebx
    jz .ok
    mov eax, ebx
    cmp eax, 16
    jbe .have_chunk_n
    mov eax, 16
.have_chunk_n:
    mov [dap_count], ax
    mov word [dap_off], 0
    mov ecx, ebp
    shl ecx, 5                   ; done*32 paragraphs (512B = 32 paras)
    add cx, KERNEL_STAGING_SEG
    mov [dap_seg], cx
    mov ecx, ebp
    add ecx, KERNEL_LBA
    mov [dap_lba_lo], ecx
    mov dword [dap_lba_hi], 0
    push eax                     ; chunk count (BIOS clobbers AX)
    push ebx
    push ebp
    mov si, dap_kernel
    mov ah, 0x42
    mov dl, [boot_drive2]
    int 0x13
    pop ebp
    pop ebx
    pop ecx
    jc .lba_fail_chunk
    add ebp, ecx
    sub ebx, ecx
    jmp .lba_chunk
.lba_fail_chunk:
    ; fall through to CHS on error
    mov si, msg_lba_fail
    call print16

.try_chs:
    mov si, msg_try_chs
    call print16
    call load_kernel_chs
.ok:
    ret

; CHS fallback: read KERNEL_SECTORS sectors 1-by-1, converting LBA->CHS -> staging 0x70000
load_kernel_chs:
    push es
    push bx
    xor ax, ax
    mov cx, KERNEL_SECTORS
    mov ebx, KERNEL_LBA          ; current LBA (use EBX for 32-bit)
    mov di, KERNEL_STAGING_OFF   ; offset in staging segment
    mov dx, KERNEL_STAGING_SEG
    mov es, dx
.chs_loop:
    push cx
    push ebx
    push di

    ; Convert EAX/EBX LBA to CHS  (SPT=63, HPC=16, cyl <256 so high bits 0)
    mov eax, ebx
    xor edx, edx
    mov ecx, 63
    div ecx              ; EAX=temp, EDX= lba % 63
    inc edx              ; sector = remainder+1
    push dx              ; save sector
    xor edx, edx
    mov ecx, 16
    div ecx              ; EAX=cyl, EDX=head
    mov dh, dl           ; head
    mov ch, al           ; cyl low (cyl <=20 <256, so no high bits)
    pop ax
    mov cl, al           ; sector (bits 0-5) ; high cyl bits 0

    mov dl, [boot_drive2]
    mov bx, di           ; ES:BX destination
    mov ah, 0x02
    mov al, 1            ; one sector at a time
    int 0x13
    jc .chs_err

    pop di
    pop ebx
    pop cx
    add di, 512
    jnc .chs_nowrap
    mov ax, es                   ; 64K wrap: advance segment by 0x1000
    add ax, 0x1000
    mov es, ax
.chs_nowrap:
    inc ebx
    loop .chs_loop

    pop bx
    pop es
    ret
.chs_err:
    mov si, msg_disk_err2
    call print16
    jmp halt16

halt16:
    cli
    hlt
    jmp halt16

; Data for real-mode
boot_drive2: db 0
dap_kernel:
    db 0x10
    db 0
dap_count:
    dw 0                         ; (filled per chunk; <=64)
dap_off:
    dw KERNEL_STAGING_OFF
dap_seg:
    dw KERNEL_STAGING_SEG
dap_lba_lo:
    dd KERNEL_LBA
dap_lba_hi:
    dd 0

msg_stage2:        db 13,10,"Stage2 @0x7E00 entered (real)",13,10,0
msg_a20_ok2:       db "A20 stage2 OK",13,10,0
msg_load_kernel:   db "Loading kernel LBA16 -> 0x100000 ...",13,10,0
msg_kernel_ok:     db "Kernel loaded",13,10,0
msg_lba_fail:      db "LBA kernel read failed, trying CHS",13,10,0
msg_try_chs:       db "CHS kernel load...",13,10,0
msg_disk_err2:     db "Kernel CHS read error! halt",13,10,0

; ------------------------------------------------------------
; Protected mode (32-bit) — entered via far jump above
bits 32
pmode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, STACK_PM

    ; ----- CPUID support check (EFLAGS ID toggle) -----
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 1 << 21
    push eax
    popfd
    pushfd
    pop eax
    xor eax, ecx
    jz no_cpuid_32

    ; ----- Long mode capability -----
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb no_long_mode_32
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz no_long_mode_32

    ; ----- Enable PAE -----
    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; ----- Build page tables at 0x1000 -----
    ; Zero 16 KiB (PML4 4K + PDPT 4K + PD 4K + padding)
    mov edi, PML4_ADDR
    xor eax, eax
    mov ecx, 4096                ; 16384 /4
    rep stosd

    ; PML4[0] = PDPT | P | RW
    mov dword [PML4_ADDR], PDPT_ADDR | 0x03
    ; PDPT[0] = PD | P | RW
    mov dword [PDPT_ADDR], PD_ADDR | 0x03
    ; PD[0] = 0x000000 | P | RW | PS (2MiB)
    mov dword [PD_ADDR + 0*8], 0x000000 | 0x83
    mov dword [PD_ADDR + 0*8 +4], 0x00
    ; PD[1] = 0x200000 | P | RW | PS (covers 2MiB-4MiB, includes kernel 0x100000)
    mov dword [PD_ADDR + 1*8], 0x200000 | 0x83
    mov dword [PD_ADDR + 1*8 +4], 0x00
    ; Optional: map next 2M for stack 0x90000 already covered, but add PD[2] for 4-6MiB safety
    mov dword [PD_ADDR + 2*8], 0x400000 | 0x83
    mov dword [PD_ADDR + 2*8 +4], 0x00
    mov dword [PD_ADDR + 3*8], 0x600000 | 0x83
    mov dword [PD_ADDR + 3*8 +4], 0x00

    ; Load PML4 base into CR3
    mov eax, PML4_ADDR
    mov cr3, eax

    ; ----- Enable Long Mode via EFER.LME -----
    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    ; ----- Enable paging (CR0.PG) -----
    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ; Now in compatibility mode; load 64-bit GDT and far jump
    lgdt [gdt64_ptr]
    jmp 0x08:long_entry

no_cpuid_32:
    mov esi, err_no_cpuid
    call vga_print32
    jmp halt32
no_long_mode_32:
    mov esi, err_no_lm
    call vga_print32
    jmp halt32

halt32:
    cli
    hlt
    jmp halt32

err_no_cpuid: db "No CPUID",0
err_no_lm:    db "No Long Mode",0

; 32-bit VGA helper (identity-mapped 0xB8000)
vga_print32:
    push eax
    push edi
    mov edi, 0xB8000
    ; find end? just write at start
.loop32:
    lodsb
    test al, al
    jz .done32
    stosb
    mov al, 0x4F     ; white on red for errors
    stosb
    jmp .loop32
.done32:
    pop edi
    pop eax
    ret

; ------------------------------------------------------------
bits 64
long_entry:
    ; In long mode now (CS.L=1), selector 0x08
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov rsp, STACK_PM
    and rsp, ~15
    cld

    ; Copy kernel from staging 0x70000 to dest 0x100000 (identity mapped 0-8MiB)
    mov rsi, 0x70000
    mov rdi, KERNEL_DEST_LINEAR
    mov rcx, KERNEL_SECTORS * 512 / 8   ; qwords
    rep movsq

    ; Small proof: write "64" to VGA if kernel doesn't boot, then jump to kernel
    ; Use direct store: show we reached long mode before kernel prints
    mov rdi, 0xB8000
    mov byte [rdi], '6'
    mov byte [rdi+1], 0x1F
    mov byte [rdi+2], '4'
    mov byte [rdi+3], 0x1F
    mov byte [rdi+4], '>'
    mov byte [rdi+5], 0x1F

    ; Jump to kernel at 0x100000
    mov rax, KERNEL_DEST_LINEAR
    jmp rax

    ; Should not return — if kernel returns, halt
.lhalt:
    cli
    hlt
    jmp .lhalt

; Pad stage2 to avoid overlapping kernel LBA? We load 64 sectors, but stage2 itself should be <= 15 sectors.
; Ensure stage2.bin fits in build image's 15-sector slot.
; No signature needed here; image is simply dd'd.
