; MS-DOS64 src/kernel/fs64.asm — Phase 7: FAT12 filesystem adaptation (64-bit)
; Converts MSDOS.ASM FAT12 layer (UNPACK MSDOS.ASM:448, PACK:484, GETENTRY:632,
; NEXTENTRY:673, FATREAD:936, FIGFAT:1102, DIRCOMP:1113, DIRREAD:1194, DREAD:1218,
; DWRITE:1325, FIGFATSIZ/FIGMAX:3996) to flat 64-bit with native ATA LBA driver.
;
; Original: segment:offset DMA (DMAADD split words), BX/DX 16-bit clusters/LBAs,
;           BIOS INT13 via FAR PTR BIOSREAD/WRITE, CHS addressing.
; 64-bit:   linear buffers (RDI), 64-bit LBAs (RSI), 64-bit clusters (RBX),
;           ATA LBA28 PIO ata_read/write_lba28 (src/drivers/ata.asm),
;           LBA = (C*HPC+H)*SPT+S-1 preserved in chs_to_lba for compat,
;           cluster->LBA = firrec + (cluster-2)*(clusmsk+1).
;
; DPB64 (include/dpb.inc) holds firfat/firdir/firrec/maxclus/fatsiz as 32-bit LBAs.
; DIRENT (include/fs.inc) is 32B on-disk dir entry. FCB64 (include/fcb.inc)
; holds 64-bit filsiz/rr (was 32-bit FILSIZ, DX:AX RR in MSDOS.ASM:1453).

bits 64
default rel

%include "include/fs.inc"

section .text
global fs_bpb_parse64
global fs_cluster_to_lba64
global fs_fat_sector64
global fs_get_cluster64
global fs_set_cluster64
global fs_is_eof64
global fs_is_free64
global fs_dir_find64
global fs_dir_get_firstclus64
global fs_dir_get_size64
global fs_dir_get_attr64
global fs_dread64
global fs_dwrite64
global fs_dir_read64
global fs_dir_write64
global fs_fcb_open64
global fs_file_read_cluster64
global fs_test_bpb
global fs_test_chain
global fs_test_dir
global fs_test_lba_io
global fs_test_file_read
global fs_test_fcb

extern ata_read_lba28
extern ata_write_lba28
extern ata_init

; ------------------------------------------------------------
; fs_bpb_parse64 — parse 512B boot sector BPB into DPB64
;   In: RSI = boot sector base (byte 0), RBP = DPB64 ptr
;   Out: RAX 0 ok, 1 bad (bad secsiz/secPerClus/tot/fatsiz)
;   Clobbers: RAX,RCX,RDX,R8,R9,R10,R11. Preserves RBX,RSI,RBP,R12-R15.
;   Ref: DOSINIT PERDRV/FIGFATSIZ/FIGMAX (MSDOS.ASM:3764-3843,3996-4017).
; ------------------------------------------------------------
fs_bpb_parse64:
    push rbx
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    push r10
    push r11

    movzx eax, word [rsi + BPB_BytsPerSec]
    cmp eax, 512
    je .secsiz_ok
    cmp eax, 1024
    je .secsiz_ok
    cmp eax, 128
    je .secsiz_ok
    cmp eax, 256
    je .secsiz_ok
    cmp eax, 2048
    je .secsiz_ok
    cmp eax, 4096
    je .secsiz_ok
    mov rax, 1
    jmp .exit
.secsiz_ok:
    mov r8d, eax
    mov [rbp + DPB64.secsiz], r8d

    movzx eax, byte [rsi + BPB_SecPerClus]
    test eax, eax
    jz .bad
    mov ecx, eax
    dec ecx
    test eax, ecx
    jnz .bad
    cmp eax, 64
    ja .bad
    mov r9d, eax
    dec eax
    mov [rbp + DPB64.clusmsk], al
    xor ecx, ecx
    mov edx, r9d
.log2_loop:
    cmp edx, 1
    je .log2_done
    shr edx, 1
    inc ecx
    jmp .log2_loop
.log2_done:
    mov [rbp + DPB64.clusshft], cl

    movzx eax, word [rsi + BPB_RsvdSecCnt]
    test eax, eax
    jz .bad
    mov [rbp + DPB64.firfat], eax
    mov r10d, eax

    movzx eax, byte [rsi + BPB_NumFATs]
    cmp eax, 1
    jb .bad
    cmp eax, 4
    ja .bad
    mov [rbp + DPB64.fatcnt], al
    mov r11d, eax

    movzx eax, word [rsi + BPB_RootEntCnt]
    test eax, eax
    jz .bad
    mov [rbp + DPB64.maxent], eax

    movzx eax, word [rsi + BPB_TotSec16]
    test eax, eax
    jnz .have_tot
    mov eax, [rsi + BPB_TotSec32]
    test eax, eax
    jz .bad
.have_tot:
    push rax

    movzx eax, word [rsi + BPB_FATSz16]
    test eax, eax
    jz .bad_tot
    mov [rbp + DPB64.fatsiz], eax
    mov ecx, r11d
    imul ecx, eax
    add ecx, r10d
    mov [rbp + DPB64.firdir], ecx

    mov eax, [rbp + DPB64.maxent]
    shl eax, 5
    mov ecx, r8d
    dec ecx
    add eax, ecx
    xor edx, edx
    div r8d
    mov ecx, eax
    mov eax, [rbp + DPB64.firdir]
    add eax, ecx
    mov [rbp + DPB64.firrec], eax
    mov r10d, eax

    pop rax
    cmp eax, r10d
    jbe .bad
    sub eax, r10d
    movzx ecx, byte [rbp + DPB64.clusshft]
    shr eax, cl
    inc eax
    cmp eax, 2
    jb .bad
    cmp eax, 8192
    ja .bad
    mov [rbp + DPB64.maxclus], eax

    mov byte [rbp + DPB64.devnum], 0
    mov byte [rbp + DPB64.drvnum], 0
    mov qword [rbp + DPB64.fat], 0

    xor eax, eax
    jmp .exit
.bad_tot:
    pop rax
.bad:
    mov rax, 1
.exit:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rbx
    ret

; ------------------------------------------------------------
; fs_cluster_to_lba64 — data cluster -> absolute LBA (== DREAD DX)
;   In: RBP = DPB64 ptr, RBX = cluster (2..maxclus, DOS allows ==maxclus)
;   Out: RAX = LBA, CF=0 ok; CF=1 bad cluster
;   Formula: LBA = firrec + (cluster-2)*(clusmsk+1)
; ------------------------------------------------------------
fs_cluster_to_lba64:
    push rbx
    push rcx
    push rdx
    mov eax, ebx
    cmp eax, 2
    jb .bad
    mov ecx, [rbp + DPB64.maxclus]
    cmp eax, ecx
    ja .bad
    sub eax, 2
    movzx ecx, byte [rbp + DPB64.clusmsk]
    inc ecx
    imul eax, ecx
    mov ecx, [rbp + DPB64.firrec]
    add eax, ecx
    ; EAX holds LBA; pops preserve RAX (POP does not touch flags/RAX target)
    pop rdx
    pop rcx
    pop rbx
    clc
    ret
.bad:
    pop rdx
    pop rcx
    pop rbx
    xor eax, eax
    stc
    ret

; ------------------------------------------------------------
; fs_fat_sector64 — FAT12 byte offset -> FAT LBA + intra-sector offset
;   In: RBP = DPB64, RBX = cluster
;   Out: RAX = FAT LBA (firfat + offset/secsiz), RDX = offset%secsiz, CF=0;
;        CF=1 bad cluster.
;   offset = cluster + cluster/2 (MSDOS UNPACK LEA/SHR).
; ------------------------------------------------------------
fs_fat_sector64:
    push rbx
    push rcx
    mov eax, ebx
    cmp eax, 2
    jb .bad2
    mov ecx, [rbp + DPB64.maxclus]
    cmp eax, ecx
    ja .bad2
    mov ecx, eax
    shr ecx, 1
    add eax, ecx
    xor edx, edx
    mov ecx, [rbp + DPB64.secsiz]
    test ecx, ecx
    jz .bad2
    div ecx
    mov ecx, [rbp + DPB64.firfat]
    add eax, ecx
    pop rcx
    pop rbx
    clc
    ret
.bad2:
    pop rcx
    pop rbx
    xor eax, eax
    xor edx, edx
    stc
    ret

; ------------------------------------------------------------
; fs_get_cluster64 — read 12-bit FAT entry (UNPACK analog, flat)
;   In: RSI = FAT base linear, RBX = cluster, RBP = DPB (maxclus check)
;   Out: RDI = 12-bit value, RAX 0 ok CF=0; bad -> RDI=0xFFF RAX=1 CF=1
; ------------------------------------------------------------
fs_get_cluster64:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov eax, ebx
    mov ecx, [rbp + DPB64.maxclus]
    cmp eax, ecx
    ja .hurt
    cmp eax, 2
    jb .hurt
    mov r8d, ebx
    shr r8d, 1
    add r8d, ebx
    movzx edi, word [rsi + r8]
    test bl, 1
    jz .even
    shr edi, 4
.even:
    and edi, 0x0FFF
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    xor eax, eax
    clc
    ret
.hurt:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rdi, 0x0FFF
    mov rax, 1
    stc
    ret

; ------------------------------------------------------------
; fs_set_cluster64 — write 12-bit FAT entry (PACK analog, flat)
;   In: RSI = FAT base, RBX = cluster, RDX = 12-bit value, RBP = DPB
;   Out: RAX 0 ok CF=0; bad -> RAX 1 CF=1.
; ------------------------------------------------------------
fs_set_cluster64:
    push rbx
    push rcx
    push rdi
    push r8
    push r9
    mov eax, ebx
    mov ecx, [rbp + DPB64.maxclus]
    cmp eax, ecx
    ja .badw
    cmp eax, 2
    jb .badw
    mov r8d, ebx
    shr r8d, 1
    add r8d, ebx
    lea r8, [rsi + r8]
    movzx edi, word [r8]
    mov r9d, edx
    and r9d, 0x0FFF
    test bl, 1
    jz .aligned
    shl r9d, 4
    and edi, 0x000F
    jmp .packin
.aligned:
    and edi, 0xF000
.packin:
    or edi, r9d
    mov [r8], di
    pop r9
    pop r8
    pop rdi
    pop rcx
    pop rbx
    xor eax, eax
    clc
    ret
.badw:
    pop r9
    pop r8
    pop rdi
    pop rcx
    pop rbx
    mov rax, 1
    stc
    ret

; ------------------------------------------------------------
; fs_is_eof64 — RDI=value -> RAX 1 if >=0xFF8 else 0
; fs_is_free64 — RDI=value -> RAX 1 if 0 else 0
; ------------------------------------------------------------
fs_is_eof64:
    cmp rdi, 0xFF8
    jae .is_eof
    xor eax, eax
    ret
.is_eof:
    mov eax, 1
    ret

fs_is_free64:
    test rdi, rdi
    jz .is_free
    xor eax, eax
    ret
.is_free:
    mov eax, 1
    ret

; ------------------------------------------------------------
; fs_dir_find64 — find 8.3 name in linear root-dir buffer
;   In: RBP = DPB (maxent), RSI = dir base linear, RDI = 11-byte name
;       ('?' wildcard per MSDOS.ASM:598-602 WILDCRD)
;   Out: CF=0 found, RBX = entry ptr; CF=1 not found, RBX=0
;   Skips 0xE5 deleted, stops at 0x00 end (MSDOS.ASM:590-616).
; ------------------------------------------------------------
fs_dir_find64:
    push rsi
    push rdi
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    xor ecx, ecx
    mov r10d, [rbp + DPB64.maxent]
.loop_entry:
    cmp ecx, r10d
    jae .notfound
    mov eax, ecx
    shl eax, 5
    lea r11, [rsi + rax]
    mov al, [r11]
    test al, al
    jz .notfound
    cmp al, 0xE5
    je .next_entry
    xor r8d, r8d
.cmp_loop:
    cmp r8d, 11
    jae .found_entry
    mov dl, [rdi + r8]
    cmp dl, '?'
    je .cmp_next
    mov al, [r11 + r8]
    cmp dl, al
    jne .next_entry
.cmp_next:
    inc r8d
    jmp .cmp_loop
.next_entry:
    inc ecx
    jmp .loop_entry
.found_entry:
    mov r9, r11
    mov rbx, r9
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    clc
    ret
.notfound:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rdi
    pop rsi
    xor ebx, ebx
    stc
    ret

; ------------------------------------------------------------
; fs_dir_get_firstclus64 — RBX=entry -> RAX=first cluster (word +26)
; fs_dir_get_size64 — RBX=entry -> RAX=file size (dword +28)
; fs_dir_get_attr64 — RBX=entry -> RAX=attr (+11)
; ------------------------------------------------------------
fs_dir_get_firstclus64:
    movzx eax, word [rbx + DIRENT.firstclus]
    ret
fs_dir_get_size64:
    mov eax, [rbx + DIRENT.size]
    ret
fs_dir_get_attr64:
    movzx eax, byte [rbx + DIRENT.attr]
    ret

; ------------------------------------------------------------
; fs_dread64 — absolute sector read (DREAD analog, no BIOS/retry)
;   In: RDI = buffer linear, RSI = LBA, RDX = count 1..256
;   Out: RAX 0 ok, 1 fail. (ATA PIO; HARDERR retry dropped.)
; fs_dwrite64 — same for write (DWRITE analog).
; ------------------------------------------------------------
fs_dread64:
    push rbx
    push rbp
    call ata_read_lba28
    pop rbp
    pop rbx
    ret

fs_dwrite64:
    push rbx
    push rbp
    call ata_write_lba28
    pop rbp
    pop rbx
    ret

; ------------------------------------------------------------
; fs_dir_read64 — read directory block AL into RDI (DIRREAD analog)
;   In: RBP = DPB, AL = dir block # (0..dirsec-1), RDI = 512B buffer
;   Out: RAX 0 ok, 1 fail. LBA = firdir + AL (DIRCOMP MSDOS.ASM:1113).
; fs_dir_write64 — same for write (DIRWRITE analog).
; ------------------------------------------------------------
fs_dir_read64:
    push rbx
    push rcx
    push rbp
    movzx ecx, al
    mov eax, [rbp + DPB64.firdir]
    add eax, ecx
    mov rsi, rax
    mov rdx, 1
    call ata_read_lba28
    pop rbp
    pop rcx
    pop rbx
    ret

fs_dir_write64:
    push rbx
    push rcx
    push rbp
    movzx ecx, al
    mov eax, [rbp + DPB64.firdir]
    add eax, ecx
    mov rsi, rax
    mov rdx, 1
    call ata_write_lba28
    pop rbp
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_fcb_open64 — open file by FCB name (OPEN/GETFILE analog, simplified)
;   In: RDI = FCB64 ptr (drive/name/ext filled), RBP = DPB,
;       RSI = root-dir base linear (all entries contiguous)
;   Out: RAX 0 ok CF=0 (firclus/filsiz/fdate/ftime/lstclus filled,
;        recsiz defaulted 128 if 0); RAX 1 CF=1 not found.
;   FCB name at +1 (8) + ext at +9 (3) contiguous 11 (FCBLOCK MSDOS.ASM:78).
;   Dir time at +22 -> FCB ftime, date at +24 -> FCB fdate.
; ------------------------------------------------------------
fs_fcb_open64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdi                         ; FCB ptr
    mov r9, rsi                         ; dir base
    lea rdi, [r8 + FCB64.name]          ; 11-byte name (name+ext contiguous)
    mov rsi, r9
    call fs_dir_find64
    jc .notfound_open
    ; RBX = entry. Fill FCB.
    movzx eax, word [rbx + DIRENT.firstclus]
    mov [r8 + FCB64.firclus], eax
    mov [r8 + FCB64.lstclus], eax
    mov dword [r8 + FCB64.cluspos], 0
    mov eax, [rbx + DIRENT.size]
    mov qword [r8 + FCB64.filsiz], rax  ; zero-extend dword->qword
    movzx eax, word [rbx + DIRENT.time]
    mov [r8 + FCB64.ftime], ax
    movzx eax, word [rbx + DIRENT.date]
    mov [r8 + FCB64.fdate], ax
    mov eax, [r8 + FCB64.recsiz]
    test eax, eax
    jnz .have_recsiz
    mov dword [r8 + FCB64.recsiz], 128
.have_recsiz:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    xor eax, eax
    clc
    ret
.notfound_open:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    mov rax, 1
    stc
    ret

; ------------------------------------------------------------
; fs_file_read_cluster64 — read one data cluster's sectors via ATA
;   In: RBP = DPB, RBX = cluster, RDI = buffer (>= secPerClus*secsiz)
;   Out: RAX 0 ok, 1 fail (bad cluster or ATA error).
;   Uses R12 for buffer (callee-saved, preserved across helpers).
; ------------------------------------------------------------
fs_file_read_cluster64:
    push rbx
    push rbp
    push r12
    mov r12, rdi                        ; save buffer
    call fs_cluster_to_lba64            ; RBX,RBP -> RAX=LBA (CF on bad)
    jc .fail_cl                         ; POP preserves CF on x86-64
    mov rsi, rax                        ; LBA
    movzx ecx, byte [rbp + DPB64.clusmsk]
    inc ecx
    mov edx, ecx                        ; count = secPerClus (EDX for ATA)
    mov rdi, r12                        ; buffer
    call ata_read_lba28                 ; RAX 0/1
    pop r12
    pop rbp
    pop rbx
    ret
.fail_cl:
    mov rax, 1
    pop r12
    pop rbp
    pop rbx
    ret

; ============================================================
; Phase 7 self-tests [22]..[27] — each returns RAX 0 pass, 1 fail.
; Synthetic geometries avoid touching real kernel LBAs 16..79;
; ATA scratch uses FS_SCRATCH_LBA 500..511 (10M image, 20480 sectors).
; ============================================================

; ------------------------------------------------------------
; fs_test_bpb [22] — BPB->DPB (1.44M), cluster->LBA, FAT sector
; ------------------------------------------------------------
fs_test_bpb:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_test]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    ; verify fields: 512, mask0, shft0, firfat1, fatcnt2, maxent224,
    ; fatsiz9, firdir19, firrec33, maxclus2848
    cmp dword [rbp + DPB64.secsiz], 512
    jne .fail
    cmp byte [rbp + DPB64.clusmsk], 0
    jne .fail
    cmp byte [rbp + DPB64.clusshft], 0
    jne .fail
    cmp dword [rbp + DPB64.firfat], 1
    jne .fail
    cmp byte [rbp + DPB64.fatcnt], 2
    jne .fail
    cmp dword [rbp + DPB64.maxent], 224
    jne .fail
    cmp dword [rbp + DPB64.fatsiz], 9
    jne .fail
    cmp dword [rbp + DPB64.firdir], 19
    jne .fail
    cmp dword [rbp + DPB64.firrec], 33
    jne .fail
    cmp dword [rbp + DPB64.maxclus], 2848
    jne .fail
    ; cluster->LBA: 2->33, 3->34, 4->35
    mov rbx, 2
    call fs_cluster_to_lba64
    jc .fail
    cmp rax, 33
    jne .fail
    mov rbx, 3
    call fs_cluster_to_lba64
    jc .fail
    cmp rax, 34
    jne .fail
    mov rbx, 4
    call fs_cluster_to_lba64
    jc .fail
    cmp rax, 35
    jne .fail
    ; bad clusters: 0,1 fail with CF
    mov rbx, 1
    call fs_cluster_to_lba64
    jnc .fail
    mov rbx, 0
    call fs_cluster_to_lba64
    jnc .fail
    mov ebx, 9999
    call fs_cluster_to_lba64
    jnc .fail
    ; FAT sector for cluster 2: offset=3, sec=0, LBA=firfat=1, off=3
    mov rbx, 2
    call fs_fat_sector64
    jc .fail
    cmp rax, 1
    jne .fail
    cmp rdx, 3
    jne .fail
    ; cluster 340: offset=510, LBA=1, off=510
    mov rbx, 340
    call fs_fat_sector64
    jc .fail
    cmp rax, 1
    jne .fail
    cmp rdx, 510
    jne .fail
    ; cluster 341: offset=511+... 341+170=511? 341/2=170, 341+170=511 -> LBA 1 off 511 (edge)
    mov rbx, 341
    call fs_fat_sector64
    jc .fail
    cmp rax, 1
    jne .fail
    cmp rdx, 511
    jne .fail
    ; cluster 342: offset=342+171=513 -> LBA 2 off 1 (cross-sector)
    mov rbx, 342
    call fs_fat_sector64
    jc .fail
    cmp rax, 2
    jne .fail
    cmp rdx, 1
    jne .fail
    ; bad BPB rejected: zero secsiz
    lea rsi, [rel fs_boot_bad]
    lea rbp, [rel fs_dpb_scratch]
    call fs_bpb_parse64
    test rax, rax
    jz .fail
    xor eax, eax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_test_chain [23] — FAT12 pack/unpack chain, EOF/free/bad
; ------------------------------------------------------------
fs_test_chain:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    ; init DPB from 1.44M boot (maxclus 2848 covers test clusters)
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_test]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    lea rsi, [rel fs_fat_buf]
    ; zero 1K of FAT (covers clusters 2..~682)
    mov rcx, 1024
    xor eax, eax
    mov rdi, rsi
.zero_loop:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero_loop
    lea rsi, [rel fs_fat_buf]
    lea rbp, [rel fs_dpb_test]
    ; pack chain 2->3, 3->4, 4->EOF
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rbx, 3
    mov rdx, 4
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rbx, 4
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    ; unpack and verify (even 2, odd 3, even 4)
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    cmp rdi, 3
    jne .fail
    mov rbx, 3
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    cmp rdi, 4
    jne .fail
    mov rbx, 4
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    cmp rdi, 0xFFF
    jne .fail
    ; EOF detection: 0xFFF and 0xFF8 are EOF, 0xFF7 bad is not EOF
    mov rdi, 0xFFF
    call fs_is_eof64
    cmp rax, 1
    jne .fail
    mov rdi, 0xFF8
    call fs_is_eof64
    cmp rax, 1
    jne .fail
    mov rdi, 0xFF7
    call fs_is_eof64
    cmp rax, 0
    jne .fail
    mov rdi, 3
    call fs_is_eof64
    cmp rax, 0
    jne .fail
    ; free detection: cluster 5 untouched == 0
    mov rbx, 5
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    cmp rdi, 0
    jne .fail
    call fs_is_free64
    cmp rax, 1
    jne .fail
    mov rdi, 3
    call fs_is_free64
    cmp rax, 0
    jne .fail
    ; neighbor-nibble preservation: 2 and 3 share 3 bytes; both must read back
    ; (already verified above). Extra: overwrite 2 with 0xABC, 3 must stay 4.
    mov rbx, 2
    mov rdx, 0xABC
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rbx, 3
    call fs_get_cluster64
    cmp rdi, 4
    jne .fail
    mov rbx, 2
    call fs_get_cluster64
    cmp rdi, 0xABC
    jne .fail
    ; out-of-range cluster rejected
    mov ebx, 9999
    call fs_get_cluster64
    test rax, rax
    jz .fail
    mov ebx, 9999
    mov rdx, 7
    call fs_set_cluster64
    test rax, rax
    jz .fail
    xor eax, eax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_test_dir [24] — root-dir find/delete/end/wildcard/attr
; ------------------------------------------------------------
fs_test_dir:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    ; build synthetic dir in fs_dir_buf (4 entries + end)
    lea rdi, [rel fs_dir_buf]
    mov rcx, 512
    xor eax, eax
.clear_dir:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .clear_dir
    ; entry0 @0: "TEST    TXT" attr 0x20 firstclus 2 size 1234 time/date
    ; 11-byte name: T E S T sp sp sp sp T X T (bytes 0-10; byte stores avoid attr clobber)
    lea rbx, [rel fs_dir_buf]
    mov dword [rbx+0], 'TEST'
    mov dword [rbx+4], '    '
    mov byte [rbx+8], 'T'
    mov byte [rbx+9], 'X'
    mov byte [rbx+10], 'T'
    mov byte [rbx+11], 0x20
    mov word [rbx+22], 0x7A11
    mov word [rbx+24], 0x4A21
    mov word [rbx+26], 2
    mov dword [rbx+28], 1234
    ; entry1 @32: deleted 0xE5
    lea rbx, [rel fs_dir_buf+32]
    mov byte [rbx], 0xE5
    mov dword [rbx+1], 'ELET'
    ; entry2 @64: "HELLO   COM" attr 0x20 firstclus 5 size 512
    ; 11-byte name: H E L L O sp sp sp C O M (bytes 0-10)
    lea rbx, [rel fs_dir_buf+64]
    mov dword [rbx+0], 'HELL'
    mov dword [rbx+4], 'O   '
    mov byte [rbx+8], 'C'
    mov byte [rbx+9], 'O'
    mov byte [rbx+10], 'M'
    mov byte [rbx+11], 0x20
    mov word [rbx+26], 5
    mov dword [rbx+28], 512
    ; entry3 @96: 0x00 end (already zero)
    ; entry4 @128 beyond end: "SHOULD  NOT" (must NOT be found)
    lea rbx, [rel fs_dir_buf+128]
    mov dword [rbx+0], 'SHOU'
    mov dword [rbx+4], 'LD  '
    ; DPB with maxent 16 (buffer holds 16 entries)
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_test]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    mov dword [rbp + DPB64.maxent], 16
    lea rsi, [rel fs_dir_buf]
    ; find TEST TXT
    lea rdi, [rel fs_name_test]
    call fs_dir_find64
    jc .fail
    mov r8, rbx
    call fs_dir_get_firstclus64
    cmp rax, 2
    jne .fail
    mov rbx, r8
    call fs_dir_get_size64
    cmp rax, 1234
    jne .fail
    mov rbx, r8
    call fs_dir_get_attr64
    cmp rax, 0x20
    jne .fail
    ; find HELLO COM
    lea rsi, [rel fs_dir_buf]
    lea rdi, [rel fs_name_hello]
    call fs_dir_find64
    jc .fail
    call fs_dir_get_firstclus64
    cmp rax, 5
    jne .fail
    ; wildcard TEST ??? matches TEST TXT
    lea rsi, [rel fs_dir_buf]
    lea rdi, [rel fs_name_wild]
    call fs_dir_find64
    jc .fail
    call fs_dir_get_firstclus64
    cmp rax, 2
    jne .fail
    ; deleted entry NOT found (search its leftover name)
    lea rsi, [rel fs_dir_buf]
    lea rdi, [rel fs_name_deleted]
    call fs_dir_find64
    jnc .fail
    ; beyond-end NOT found
    lea rsi, [rel fs_dir_buf]
    lea rdi, [rel fs_name_beyond]
    call fs_dir_find64
    jnc .fail
    ; missing file NOT found
    lea rsi, [rel fs_dir_buf]
    lea rdi, [rel fs_name_missing]
    call fs_dir_find64
    jnc .fail
    xor eax, eax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_test_lba_io [25] — ATA-backed DREAD/DWRITE + DIRREAD (INT13->LBA)
; ------------------------------------------------------------
fs_test_lba_io:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    call ata_init
    ; fill scratch with 0xA5+index pattern
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    mov al, 0xA5
    mov rbx, rdi
.fill_pat:
    mov [rbx], al
    inc rbx
    inc al
    dec rcx
    jnz .fill_pat
    ; write to FS_SCRATCH_LBA via fs_dwrite64
    lea rdi, [rel fs_scratch_buf]
    mov rsi, FS_SCRATCH_LBA
    mov rdx, 1
    call fs_dwrite64
    test rax, rax
    jnz .fail
    ; clear buffer
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    xor eax, eax
    mov rbx, rdi
.clear_s:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .clear_s
    ; read back via fs_dread64
    lea rdi, [rel fs_scratch_buf]
    mov rsi, FS_SCRATCH_LBA
    mov rdx, 1
    call fs_dread64
    test rax, rax
    jnz .fail
    ; verify pattern
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    mov al, 0xA5
    mov rbx, rdi
.verify_pat:
    cmp [rbx], al
    jne .fail
    inc rbx
    inc al
    dec rcx
    jnz .verify_pat
    ; DIRREAD analog: DPB firdir=FS_SCRATCH_LBA, block 2 -> LBA+2
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_test]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    mov dword [rbp + DPB64.firdir], FS_SCRATCH_LBA
    ; write distinct marker to LBA+2
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    mov al, 0x5A
    mov rbx, rdi
.fill_dir:
    mov [rbx], al
    inc rbx
    inc al
    dec rcx
    jnz .fill_dir
    lea rdi, [rel fs_scratch_buf]
    mov rsi, FS_SCRATCH_LBA+2
    mov rdx, 1
    call fs_dwrite64
    test rax, rax
    jnz .fail
    ; clear then dir_read block 2
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    xor eax, eax
    mov rbx, rdi
.clear_dir2:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .clear_dir2
    lea rdi, [rel fs_scratch_buf]
    mov al, 2
    call fs_dir_read64
    test rax, rax
    jnz .fail
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    mov al, 0x5A
    mov rbx, rdi
.verify_dir:
    cmp [rbx], al
    jne .fail
    inc rbx
    inc al
    dec rcx
    jnz .verify_dir
    ; cleanup scratch LBAs (zero 500,502)
    lea rdi, [rel fs_scratch_buf]
    mov rcx, 512
    xor eax, eax
    mov rbx, rdi
.zero_c:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .zero_c
    lea rdi, [rel fs_scratch_buf]
    mov rsi, FS_SCRATCH_LBA
    mov rdx, 1
    call fs_dwrite64
    lea rdi, [rel fs_scratch_buf]
    mov rsi, FS_SCRATCH_LBA+2
    mov rdx, 1
    call fs_dwrite64
    xor eax, eax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_test_file_read [26] — multi-cluster file via chain + ATA
;   DPB remapped firrec=FS_FILE_LBA_BASE (510) so clusters hit scratch.
; ------------------------------------------------------------
fs_test_file_read:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    call ata_init
    ; DPB: 1.44M base then remap firrec to scratch, maxclus small
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_file]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    mov dword [rbp + DPB64.firrec], FS_FILE_LBA_BASE
    ; FAT chain 2->3->EOF in fs_fat_buf2
    lea rdi, [rel fs_fat_buf2]
    mov rsi, rdi
    mov rcx, 1024
    xor eax, eax
.zero_fat:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero_fat
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rbx, 3
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    ; write cluster2 data "CLUS2-" pattern to LBA 510
    lea rdi, [rel fs_file_buf]
    mov rcx, 512
    mov al, 'A'
    mov rbx, rdi
.fill_c2:
    mov [rbx], al
    inc rbx
    inc al
    cmp al, 'Z'+1
    jne .no_wrap2
    mov al, 'A'
.no_wrap2:
    dec rcx
    jnz .fill_c2
    lea rdi, [rel fs_file_buf]
    mov rsi, FS_FILE_LBA_BASE
    mov rdx, 1
    call fs_dwrite64
    test rax, rax
    jnz .fail
    ; write cluster3 data 0xC3+index to LBA 511
    lea rdi, [rel fs_file_buf]
    mov rcx, 512
    mov al, 0xC3
    mov rbx, rdi
.fill_c3:
    mov [rbx], al
    inc rbx
    inc al
    dec rcx
    jnz .fill_c3
    lea rdi, [rel fs_file_buf]
    mov rsi, FS_FILE_LBA_BASE+1
    mov rdx, 1
    call fs_dwrite64
    test rax, rax
    jnz .fail
    ; read cluster2 via fs_file_read_cluster64, verify 'A' pattern
    lea rdi, [rel fs_file_buf]
    mov rcx, 512
    xor eax, eax
    mov rbx, rdi
.clear_f:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .clear_f
    lea rdi, [rel fs_file_buf]
    mov rbx, 2
    call fs_file_read_cluster64
    test rax, rax
    jnz .fail
    lea rdi, [rel fs_file_buf]
    mov rcx, 512
    mov al, 'A'
    mov rbx, rdi
.verify_c2:
    cmp [rbx], al
    jne .fail
    inc rbx
    inc al
    cmp al, 'Z'+1
    jne .no_wv2
    mov al, 'A'
.no_wv2:
    dec rcx
    jnz .verify_c2
    ; read cluster3, verify 0xC3 pattern
    lea rdi, [rel fs_file_buf]
    mov rbx, 3
    call fs_file_read_cluster64
    test rax, rax
    jnz .fail
    lea rdi, [rel fs_file_buf]
    mov rcx, 512
    mov al, 0xC3
    mov rbx, rdi
.verify_c3:
    cmp [rbx], al
    jne .fail
    inc rbx
    inc al
    dec rcx
    jnz .verify_c3
    ; walk chain 2->3->EOF (RSI clobbered by ATA reads above -> reload FAT base)
    lea rsi, [rel fs_fat_buf2]
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    cmp rdi, 3
    jne .fail
    mov rbx, 3
    call fs_get_cluster64
    cmp rdi, 0xFFF
    jne .fail
    mov rdi, rdi
    call fs_is_eof64
    cmp rax, 1
    jne .fail
    ; bad cluster read fails
    lea rdi, [rel fs_file_buf]
    mov ebx, 9999
    call fs_file_read_cluster64
    test rax, rax
    jz .fail
    ; cleanup 510/511
    lea rdi, [rel fs_file_buf]
    mov rcx, 512
    xor eax, eax
    mov rbx, rdi
.zero_f2:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .zero_f2
    lea rdi, [rel fs_file_buf]
    mov rsi, FS_FILE_LBA_BASE
    mov rdx, 1
    call fs_dwrite64
    lea rdi, [rel fs_file_buf]
    mov rsi, FS_FILE_LBA_BASE+1
    mov rdx, 1
    call fs_dwrite64
    xor eax, eax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_test_fcb [27] — FCB64 open, 64-bit filsiz/rr/DMA/handles
;   Uses DMAADD via extern dma_get/set_linear (fat64.asm) to prove
;   64-bit linear buffers (was DMAADD split DW segment:offset).
; ------------------------------------------------------------
extern dma_get_linear
extern dma_set_linear
fs_test_fcb:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    ; reuse dir setup from [24]
    lea rdi, [rel fs_dir_buf]
    mov rcx, 512
    xor eax, eax
.clear_d3:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .clear_d3
    lea rbx, [rel fs_dir_buf]
    mov dword [rbx+0], 'TEST'
    mov dword [rbx+4], '    '
    mov byte [rbx+8], 'T'
    mov byte [rbx+9], 'X'
    mov byte [rbx+10], 'T'
    mov byte [rbx+11], 0x20
    mov word [rbx+22], 0x7A11
    mov word [rbx+24], 0x4A21
    mov word [rbx+26], 7
    mov dword [rbx+28], 123456
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_test]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    mov dword [rbp + DPB64.maxent], 16
    ; build FCB64: drive 1, name TEST, ext TXT, recsiz 0 (default 128)
    lea rdi, [rel fs_fcb_test]
    mov rcx, 80
    xor eax, eax
.clear_fcb:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .clear_fcb
    lea rdi, [rel fs_fcb_test]
    mov byte [rdi + FCB64.drive], 1
    mov dword [rdi + FCB64.name+0], 'TEST'
    mov dword [rdi + FCB64.name+4], '    '
    mov byte [rdi + FCB64.ext+0], 'T'
    mov byte [rdi + FCB64.ext+1], 'X'
    mov byte [rdi + FCB64.ext+2], 'T'
    mov dword [rdi + FCB64.recsiz], 0
    lea rsi, [rel fs_dir_buf]
    call fs_fcb_open64
    test rax, rax
    jnz .fail
    cmp dword [rdi + FCB64.firclus], 7
    jne .fail
    cmp dword [rdi + FCB64.lstclus], 7
    jne .fail
    mov rax, [rdi + FCB64.filsiz]
    cmp rax, 123456
    jne .fail
    cmp dword [rdi + FCB64.recsiz], 128
    jne .fail
    ; 64-bit filsiz holds >4G (was 32-bit FILSIZ MSDOS.ASM:83)
    mov rax, 0x100000000
    mov [rdi + FCB64.filsiz], rax
    mov rbx, [rdi + FCB64.filsiz]
    mov rax, 0x100000000
    cmp rbx, rax
    jne .fail
    ; 64-bit random-record byte position: RR * recsiz in 64-bit
    ; RR=0x1000000 recsiz=512 -> 0x200000000 (8G, overflows 32-bit)
    mov rax, 0x1000000
    mov [rdi + FCB64.rr], rax
    mov rcx, [rdi + FCB64.rr]
    mov rax, 512
    imul rcx, rax
    mov rax, 0x200000000
    cmp rcx, rax
    jne .fail
    ; DMA linear 64-bit (was split DMAADD words MSDOS.ASM DMAADD)
    mov rdi, 0x200000
    call dma_set_linear
    call dma_get_linear
    cmp rdi, 0x200000
    jne .fail
    mov rdi, 0x12345678
    call dma_set_linear
    call dma_get_linear
    cmp rdi, 0x12345678
    jne .fail
    ; open missing file fails
    lea rdi, [rel fs_fcb_test2]
    mov rcx, 80
    xor eax, eax
.clear_fcb2:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .clear_fcb2
    lea rdi, [rel fs_fcb_test2]
    mov byte [rdi + FCB64.drive], 1
    mov dword [rdi + FCB64.name+0], 'NOPE'
    mov byte [rdi + FCB64.ext+0], 'T'
    mov byte [rdi + FCB64.ext+1], 'X'
    mov byte [rdi + FCB64.ext+2], 'T'
    lea rsi, [rel fs_dir_buf]
    call fs_fcb_open64
    test rax, rax
    jz .fail
    xor eax, eax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ============================================================
; Static data: 1.44M BPB boot template + names + DPBs + buffers
; 1.44M geometry: 512B, 1 sec/clus, 1 rsvd, 2 FAT, 224 root,
; 2880 tot, F0 media, 9 FATsec, 18 SPT, 2 heads (IBM standard).
; firdir=1+18=19, dirsec=14, firrec=33, maxclus=2848.
; ============================================================
section .data
align 16
fs_boot144:
    db 0xEB, 0x3C, 0x90
    db 'MSDOS64 '               ; OEM 8
    dw 512                      ; +11 BytsPerSec
    db 1                        ; +13 SecPerClus
    dw 1                        ; +14 RsvdSecCnt
    db 2                        ; +16 NumFATs
    dw 224                      ; +17 RootEntCnt
    dw 2880                     ; +19 TotSec16
    db 0xF0                     ; +21 Media
    dw 9                        ; +22 FATSz16
    dw 18                       ; +24 SecPerTrk
    dw 2                        ; +26 NumHeads
    dd 0                        ; +28 HiddSec
    dd 0                        ; +32 TotSec32
    db 0x00, 0x00, 0x00         ; drive/reserved/sig padding
    times 448 db 0              ; boot code area (zero for test)
    dw 0xAA55                   ; +510 boot sig

fs_boot_bad:
    db 0xEB, 0x3C, 0x90
    db 'MSDOS64 '
    dw 0                        ; BAD secsiz 0
    db 1
    dw 1
    db 2
    dw 224
    dw 2880
    db 0xF0
    dw 9
    dw 18
    dw 2
    dd 0
    dd 0
    db 0x00, 0x00, 0x00
    times 448 db 0
    dw 0xAA55

fs_name_test:    db 'TEST    TXT'
fs_name_hello:   db 'HELLO   COM'
fs_name_wild:    db 'TEST    ???'
fs_name_deleted: db 'ELETED  TXT'
fs_name_beyond:  db 'SHOULD  NOT'
fs_name_missing: db 'NOFILE  TXT'

section .bss
align 16
fs_dpb_test:    resb 64
fs_dpb_scratch: resb 64
fs_dpb_file:    resb 64
fs_fat_buf:     resb 8192
fs_fat_buf2:    resb 8192
fs_dir_buf:     resb 8192
fs_scratch_buf: resb 1024
fs_file_buf:    resb 1024
fs_fcb_test:    resb 128
fs_fcb_test2:   resb 128


