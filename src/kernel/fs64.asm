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
;
; Crash-consistency (no journal; ordering + mount healing — see include/fs.inc):
;   extend: data -> FAT flush -> root flush; truncate: root -> FAT (free tail);
;   delete: root (0xE5) -> FAT (free chain); create/rename: single root flush;
;   FAT mirrors FAT1->FAT2, healed at mount (FAT1 wins). First-flush failure
;   skips the second (old consistent state kept); second-flush failure
;   returns CF=1 with an orphan leak (safe, via fs_vol_reclaim_orphans64).
;   fs_fault_inject (FS_FAULT_*) simulates a reset between metadata writes;
;   fs_vol_scrub64 validates entries/chains/mirrors, fs_vol_discard64 drops
;   RAM caches so tests can remount from disk like a reboot.

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
global fs_mount_volume64
global fs_vol_read_file64
global fs_vol_flush_fat64
global fs_vol_flush_root64
global fs_alloc_cluster64
global fs_vol_dpb
global fs_vol_fat
global fs_vol_root
global fs_vol_iobuf
global fs_vol_boot
global fs_vol_mounted
global fs_file_write_cluster64
global fs_vol_find_free64
global fs_chain_free_mem64
global fs_vol_free_chain64
global fs_fcb_close64
global fs_fcb_delete64
global fs_fcb_create64
global fs_fcb_rename64
global fs_fcb_search64
global fs_make_fcb64
global fs_fcb_io64
global fs_vol_validate64
global fs_fault_inject
global fs_vol_check_mirrors64
global fs_vol_heal_mirrors64
global fs_vol_scrub64
global fs_vol_reclaim_orphans64
global fs_vol_discard64
global fs_test_geom
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
    cmp eax, FAT12_MAXCLUS
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
; fs_vol_validate64 — mounted-volume geometry policy (mount boundary)
;   In: RSI = boot sector base (512B BPB), RBP = DPB64 ptr (parsed)
;   Out: RAX 0 ok (FS_MOUNT_OK), 2 unsupported geometry (FS_MOUNT_GEOM_ERR)
;   Clobbers: RAX,RCX,RDX,R8,R9,R10,R11. Preserves RBX,RSI,RBP,R12-R15.
;   Proves BEFORE any multi-sector ATA read that the parsed BPB fits the
;   fixed cache: secsiz==512, spc*secsiz<=IOBUF, root*32<=ROOT
;   (and dirsec*secsiz<=ROOT), fatsiz*secsiz<=FAT, maxclus<=FAT12_MAXCLUS
;   with FAT offset fitting, firfat/firdir/firrec/data-end within TotSec
;   (overflow-safe 64-bit), and absolutized LBAs (FS_VOL_LBA+...) < 2^28
;   without wrap. Never writes to cache buffers; safe on synthetic BPBs.
; ------------------------------------------------------------
fs_vol_validate64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    test rsi, rsi
    jz .geom_fail
    test rbp, rbp
    jz .geom_fail
    ; ---- 1. secsiz == 512 (fixed cache contract) ----
    mov eax, [rbp + DPB64.secsiz]
    cmp eax, FS_VOL_SECSIZ
    jne .geom_fail
    movzx eax, word [rsi + BPB_BytsPerSec]
    cmp eax, FS_VOL_SECSIZ
    jne .geom_fail
    ; ---- 2. spc 1..64 pow2, matches boot+shft, spc*secsiz <= IOBUF ----
    movzx ebx, byte [rbp + DPB64.clusmsk]
    inc ebx
    cmp ebx, 1
    jb .geom_fail
    cmp ebx, 64
    ja .geom_fail
    mov eax, ebx
    dec eax
    test ebx, eax
    jnz .geom_fail
    movzx ecx, byte [rbp + DPB64.clusshft]
    cmp ecx, 6
    ja .geom_fail
    mov eax, 1
    shl eax, cl
    cmp eax, ebx
    jne .geom_fail
    movzx eax, byte [rsi + BPB_SecPerClus]
    cmp eax, ebx
    jne .geom_fail
    mov r8d, [rbp + DPB64.secsiz]
    imul r8, rbx
    jo .geom_fail
    cmp r8, FS_VOL_IOBUF_BYTES
    ja .geom_fail
    test r8, r8
    jz .geom_fail
    ; RBX = spc (kept for data-end), R8 free from here
    ; ---- 3. TotSec reload + volume-end proof ----
    movzx eax, word [rsi + BPB_TotSec16]
    test eax, eax
    jnz .v_have_tot
    mov eax, [rsi + BPB_TotSec32]
    test eax, eax
    jz .geom_fail
.v_have_tot:
    mov r10d, eax                  ; R10 = tot
    mov rax, r10
    add rax, FS_VOL_LBA
    jc .geom_fail
    cmp rax, 0x10000000
    jae .geom_fail
    mov r8, rax                    ; R8 = vol_end (FS_VOL_LBA+tot)
    ; ---- 4. root entries -> dirsec, firrec proof ----
    mov eax, [rbp + DPB64.maxent]
    test eax, eax
    jz .geom_fail
    movzx ecx, word [rsi + BPB_RootEntCnt]
    cmp ecx, eax
    jne .geom_fail
    mov r9d, eax
    shl r9, 5                      ; R9 = root_bytes
    mov rax, r9
    shr rax, 5
    mov ecx, [rbp + DPB64.maxent]
    cmp eax, ecx
    jne .geom_fail                 ; shl wrapped
    cmp r9, FS_VOL_ROOT_BYTES
    ja .geom_fail
    mov ecx, [rbp + DPB64.secsiz]  ; RCX = secsiz
    mov rax, r9
    add rax, rcx
    jc .geom_fail
    dec rax                        ; root+secsiz-1
    xor edx, edx
    div rcx                        ; RAX = dirsec
    test rax, rax
    jz .geom_fail
    mov rdi, rax                   ; RDI = dirsec (kept)
    imul rax, rcx                  ; dirsec*secsiz
    jo .geom_fail
    cmp rax, FS_VOL_ROOT_BYTES
    ja .geom_fail
    ; ---- 5. FAT size + firdir/firrec proof ----
    mov eax, [rbp + DPB64.fatsiz]
    test eax, eax
    jz .geom_fail
    movzx ecx, word [rsi + BPB_FATSz16]
    cmp ecx, eax
    jne .geom_fail
    mov ecx, [rbp + DPB64.secsiz]
    mov r11d, eax                  ; R11 = fatsiz sectors
    imul r11, rcx                  ; R11 = fatsiz_bytes
    jo .geom_fail
    test r11, r11
    jz .geom_fail
    cmp r11, FS_VOL_FAT_BYTES
    ja .geom_fail
    movzx eax, byte [rbp + DPB64.fatcnt]
    cmp eax, 1
    jb .geom_fail
    cmp eax, 4
    ja .geom_fail
    movzx ecx, byte [rsi + BPB_NumFATs]
    cmp ecx, eax
    jne .geom_fail
    mov ecx, eax                   ; ECX = fatcnt
    mov eax, [rbp + DPB64.fatsiz]
    mov r9d, eax
    imul r9, rcx                   ; R9 = fat_total sectors
    jo .geom_fail
    mov eax, [rbp + DPB64.firfat]
    movzx ecx, word [rsi + BPB_RsvdSecCnt]
    cmp ecx, eax
    jne .geom_fail
    test eax, eax
    jz .geom_fail
    ; R9 = fat_total sectors, EDX/EAX = firfat_rel
    mov edx, eax                   ; EDX = firfat_rel (zero-extends to RDX)
    mov rax, rdx
    add rax, r9                    ; firfat + fat_total = firdir_calc
    jc .geom_fail
    mov edx, [rbp + DPB64.firdir]
    cmp rax, rdx
    jne .geom_fail                 ; DPB inconsistent (32-bit wrap in parser)
    mov r9, rax                    ; R9 = firdir_rel
    cmp rdx, r10                   ; firdir < tot
    jae .geom_fail
    ; firfat < tot
    mov edx, [rbp + DPB64.firfat]
    cmp rdx, r10
    jae .geom_fail
    ; firrec = firdir + dirsec
    mov rax, r9
    add rax, rdi
    jc .geom_fail
    mov edx, [rbp + DPB64.firrec]
    cmp rax, rdx
    jne .geom_fail
    cmp rax, r10
    jae .geom_fail                 ; firrec must be < tot
    mov r9, rax                    ; R9 = firrec_rel (kept for data-end)
    ; ---- 6. maxclus <= FAT12_MAXCLUS and FAT offset fits ----
    mov eax, [rbp + DPB64.maxclus]
    cmp eax, 2
    jb .geom_fail
    cmp eax, FAT12_MAXCLUS
    ja .geom_fail
    mov ecx, eax                   ; ECX = maxclus (kept for data-end)
    ; offset = maxclus + maxclus/2
    mov edx, eax
    shr edx, 1
    add edx, eax
    jc .geom_fail
    add edx, 2                     ; +2 for word access
    jc .geom_fail
    mov rax, rdx                   ; RAX = offset+2
    cmp rax, r11
    ja .geom_fail
    cmp rax, FS_VOL_FAT_BYTES
    ja .geom_fail
    ; ---- 7. data end = firrec + (maxclus-1)*spc <= tot ----
    mov rax, rcx
    dec rax                        ; maxclus-1
    imul rax, rbx                  ; *spc (RBX)
    jo .geom_fail
    add rax, r9                    ; +firrec
    jc .geom_fail
    cmp rax, r10
    ja .geom_fail
    ; ---- 8. absolutized LBAs < 2^28 without wrap ----
    mov edx, [rbp + DPB64.firfat]
    mov rax, rdx
    add rax, FS_VOL_LBA
    jc .geom_fail
    cmp rax, 0x10000000
    jae .geom_fail
    mov edx, [rbp + DPB64.fatsiz]
    add rax, rdx                   ; firfat_abs + fatsiz (= firdir_abs) <= vol_end?
    jc .geom_fail
    cmp rax, r8
    ja .geom_fail
    mov edx, [rbp + DPB64.firdir]
    mov rax, rdx
    add rax, FS_VOL_LBA
    jc .geom_fail
    cmp rax, 0x10000000
    jae .geom_fail
    add rax, rdi                   ; +dirsec (= firrec_abs) <= vol_end?
    jc .geom_fail
    cmp rax, r8
    ja .geom_fail
    mov edx, [rbp + DPB64.firrec]
    mov rax, rdx
    add rax, FS_VOL_LBA
    jc .geom_fail
    cmp rax, 0x10000000
    jae .geom_fail
    ; data end abs = firrec_abs + (maxclus-1)*spc <= vol_end
    mov rax, rcx
    dec rax
    imul rax, rbx
    jo .geom_fail
    mov edx, [rbp + DPB64.firrec]
    add rdx, FS_VOL_LBA
    jc .geom_fail
    add rax, rdx
    jc .geom_fail
    cmp rax, r8
    ja .geom_fail
    cmp rax, 0x10000000
    jae .geom_fail
    ; ---- ok ----
    xor eax, eax
    jmp .geom_done
.geom_fail:
    mov rax, FS_MOUNT_GEOM_ERR
.geom_done:
    pop r11
    pop r10
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
;   In: RDI = buffer linear, RSI = LBA, RDX = count (strict 1..64,
;       LBA+count-1 <= 0x0FFFFFFF; see ata_validate_range64).
;   Out: RAX 0 ok, 1 fail (incl. invalid range). (ATA PIO; HARDERR retry dropped.)
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
    ; ---- free-chain hop bound (fs_chain_free_mem64, in-memory fixture) ----
    ; Synthetic DPB in fs_dpb_scratch (parsed, then maxclus overridden for
    ; small-bound tests); FAT in fs_fat_buf (re-zeroed per case). Proves:
    ; empty/no-op, valid EOF ok + cleared, 2->3->2 corrupt, 2->2 corrupt,
    ; long 2->3->4->2 corrupt, all bounded (return) with best-effort clears.
    lea rsi, [rel fs_boot144]
    lea rbp, [rel fs_dpb_scratch]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    ; Empty/free is a no-op success (no FAT touch needed).
    lea rsi, [rel fs_fat_buf]
    lea rbp, [rel fs_dpb_scratch]
    mov rdi, 0
    call fs_chain_free_mem64
    jc .fail
    test rax, rax
    jnz .fail
    mov rdi, 1
    call fs_chain_free_mem64
    jc .fail
    test rax, rax
    jnz .fail
    ; Valid EOF chain 2->3->EOF with maxclus=10 => ok, entries cleared.
    mov dword [rbp + DPB64.maxclus], 10
    lea rdi, [rel fs_fat_buf]
    mov rcx, 64
    xor eax, eax
.zero_fc1:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero_fc1
    lea rsi, [rel fs_fat_buf]
    lea rbp, [rel fs_dpb_scratch]
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
    mov rdi, 2
    call fs_chain_free_mem64
    jc .fail
    test rax, rax
    jnz .fail
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    mov rbx, 3
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    ; Cycle 2->3->2 with maxclus=3 => corruption, best-effort cleared.
    mov dword [rbp + DPB64.maxclus], 3
    lea rdi, [rel fs_fat_buf]
    mov rcx, 64
    xor eax, eax
.zero_fc2:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero_fc2
    lea rsi, [rel fs_fat_buf]
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rbx, 3
    mov rdx, 2
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rdi, 2
    call fs_chain_free_mem64
    jnc .fail
    cmp rax, 1
    jne .fail
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    mov rbx, 3
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    ; Self-loop 2->2 with maxclus=2 => corruption, entry cleared.
    mov dword [rbp + DPB64.maxclus], 2
    lea rdi, [rel fs_fat_buf]
    mov rcx, 64
    xor eax, eax
.zero_fc3:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero_fc3
    lea rsi, [rel fs_fat_buf]
    mov rbx, 2
    mov rdx, 2
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rdi, 2
    call fs_chain_free_mem64
    jnc .fail
    cmp rax, 1
    jne .fail
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    ; Long cycle 2->3->4->2 with maxclus=4 => corruption, all cleared.
    mov dword [rbp + DPB64.maxclus], 4
    lea rdi, [rel fs_fat_buf]
    mov rcx, 64
    xor eax, eax
.zero_fc4:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero_fc4
    lea rsi, [rel fs_fat_buf]
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
    mov rdx, 2
    call fs_set_cluster64
    test rax, rax
    jnz .fail
    mov rdi, 2
    call fs_chain_free_mem64
    jnc .fail
    cmp rax, 1
    jne .fail
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    mov rbx, 3
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
    mov rbx, 4
    call fs_get_cluster64
    test rax, rax
    jnz .fail
    test rdi, rdi
    jnz .fail
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

; ------------------------------------------------------------
; fs_test_geom — mounted-volume geometry negative paths (no disk I/O)
;   Out: RAX 0 pass, 1 fail. Synthetic BPBs in fs_geom_boot/dpb only;
;   never touches FS_VOL_LBA or the mounted volume. Proves the mount
;   boundary rejects before any FAT/root ATA read:
;     FATSz16=10, RootEntCnt=225, SecPerClus=128, 1024B sectors,
;     data-end beyond TotSec, maxclus beyond FAT bytes, valid still ok.
;   Also proves the validator is read-only: guard bytes around the
;   scratch boot/DPB and samples of fs_vol_fat/root/iobuf are unchanged.
; ------------------------------------------------------------
fs_test_geom:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    sub rsp, 64
    ; Snapshot fixed-buffer samples + scratch guards (read-only proof).
    mov rax, [rel fs_vol_fat]
    mov [rsp+0], rax
    mov rax, [rel fs_vol_fat+FS_VOL_FAT_BYTES-8]
    mov [rsp+8], rax
    mov rax, [rel fs_vol_root]
    mov [rsp+16], rax
    mov rax, [rel fs_vol_root+FS_VOL_ROOT_BYTES-8]
    mov [rsp+24], rax
    mov rax, [rel fs_vol_iobuf]
    mov [rsp+32], rax
    mov rax, [rel fs_vol_iobuf+FS_VOL_IOBUF_BYTES-8]
    mov [rsp+40], rax
    mov dword [rel fs_geom_pre], 0xA5A5A5A5
    mov dword [rel fs_geom_pre+4], 0xA5A5A5A5
    mov dword [rel fs_geom_pre+8], 0xA5A5A5A5
    mov dword [rel fs_geom_pre+12], 0xA5A5A5A5
    mov dword [rel fs_geom_post], 0x5A5A5A5A
    mov dword [rel fs_geom_post+4], 0x5A5A5A5A
    mov dword [rel fs_geom_post+8], 0x5A5A5A5A
    mov dword [rel fs_geom_post+12], 0x5A5A5A5A
    mov dword [rel fs_geom_dpb_post], 0xA55A5AA5
    mov dword [rel fs_geom_dpb_post+4], 0xA55A5AA5
    mov dword [rel fs_geom_dpb_post+8], 0xA55A5AA5
    mov dword [rel fs_geom_dpb_post+12], 0xA55A5AA5
    ; ---- valid 1.44M must parse+validate ok ----
    call .geom_copy
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail
    call fs_vol_validate64
    test rax, rax
    jnz .g_fail
    cmp dword [rbp + DPB64.maxclus], 2848
    jne .g_fail
    ; ---- FATSz16=10 must fail with GEOM_ERR (parse ok) ----
    call .geom_copy
    mov word [rel fs_geom_boot + BPB_FATSz16], 10
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail                  ; parse must succeed; validator must reject
    call fs_vol_validate64
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .g_fail
    ; ---- RootEntCnt=225 must fail with GEOM_ERR (parse ok) ----
    call .geom_copy
    mov word [rel fs_geom_boot + BPB_RootEntCnt], 225
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail
    call fs_vol_validate64
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .g_fail
    ; ---- SecPerClus=128 must fail before FAT read (parse rejects) ----
    call .geom_copy
    mov byte [rel fs_geom_boot + BPB_SecPerClus], 128
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jz .g_spc128_parsed
    jmp .g_spc128_ok             ; parse failed as expected
.g_spc128_parsed:
    call fs_vol_validate64       ; if parser ever allows it, validator must reject
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .g_fail
.g_spc128_ok:
    ; ---- 1024B sectors must fail GEOM_ERR under 512B cache (parse ok) ----
    call .geom_copy
    mov word [rel fs_geom_boot + BPB_BytsPerSec], 1024
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail
    call fs_vol_validate64
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .g_fail
    ; ---- data end beyond TotSec must fail (valid DPB, shrunk TotSec) ----
    call .geom_copy
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail
    mov word [rel fs_geom_boot + BPB_TotSec16], 100
    call fs_vol_validate64
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .g_fail
    ; ---- maxclus beyond FAT bytes must fail (Tot=4112 -> maxclus 4080) ----
    call .geom_copy
    mov word [rel fs_geom_boot + BPB_TotSec16], 4112
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail                  ; must parse (4080 <= FAT12_MAXCLUS)
    cmp dword [rbp + DPB64.maxclus], FAT12_MAXCLUS
    jne .g_fail
    call fs_vol_validate64       ; offset 4080+2040+2=6122 > 4608
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .g_fail
    ; ---- valid again after negatives (no sticky state) ----
    call .geom_copy
    lea rsi, [rel fs_geom_boot]
    lea rbp, [rel fs_geom_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .g_fail
    call fs_vol_validate64
    test rax, rax
    jnz .g_fail
    ; ---- read-only proof: guards + fixed buffers unchanged ----
    cmp dword [rel fs_geom_pre], 0xA5A5A5A5
    jne .g_fail
    cmp dword [rel fs_geom_pre+4], 0xA5A5A5A5
    jne .g_fail
    cmp dword [rel fs_geom_pre+8], 0xA5A5A5A5
    jne .g_fail
    cmp dword [rel fs_geom_pre+12], 0xA5A5A5A5
    jne .g_fail
    cmp dword [rel fs_geom_post], 0x5A5A5A5A
    jne .g_fail
    cmp dword [rel fs_geom_post+4], 0x5A5A5A5A
    jne .g_fail
    cmp dword [rel fs_geom_post+8], 0x5A5A5A5A
    jne .g_fail
    cmp dword [rel fs_geom_post+12], 0x5A5A5A5A
    jne .g_fail
    cmp dword [rel fs_geom_dpb_post], 0xA55A5AA5
    jne .g_fail
    mov rax, [rel fs_vol_fat]
    cmp rax, [rsp+0]
    jne .g_fail
    mov rax, [rel fs_vol_fat+FS_VOL_FAT_BYTES-8]
    cmp rax, [rsp+8]
    jne .g_fail
    mov rax, [rel fs_vol_root]
    cmp rax, [rsp+16]
    jne .g_fail
    mov rax, [rel fs_vol_root+FS_VOL_ROOT_BYTES-8]
    cmp rax, [rsp+24]
    jne .g_fail
    mov rax, [rel fs_vol_iobuf]
    cmp rax, [rsp+32]
    jne .g_fail
    mov rax, [rel fs_vol_iobuf+FS_VOL_IOBUF_BYTES-8]
    cmp rax, [rsp+40]
    jne .g_fail
    xor eax, eax
    jmp .g_done
.geom_copy:
    lea rsi, [rel fs_boot144]
    lea rdi, [rel fs_geom_boot]
    mov ecx, 512
    cld
    rep movsb
    ret
.g_fail:
    mov rax, 1
.g_done:
    add rsp, 64
    pop r11
    pop r10
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
; Mounted real volume (G2) — tools/mkfat12.py stamps a 1.44M FAT12
; at LBA FS_VOL_LBA; the kernel mounts it into fs_vol_dpb/fat/root.
; All pointers flat; FAT+root are write-through cached in RAM.
; ============================================================

; ------------------------------------------------------------
; fs_mount_volume64 — mount the on-image FAT12 volume
;   Out: RAX 0 ok (mounted), 1 ATA/boot-sig/parse error (FS_MOUNT_IO_ERR),
;        2 unsupported geometry (FS_MOUNT_GEOM_ERR). Idempotent.
;   Geometry is proven by fs_vol_validate64 BEFORE absolutizing LBAs and
;   BEFORE any multi-sector ATA read, so a malformed BPB fails without
;   touching fs_vol_fat/root or issuing FAT/root reads. All LBA additions
;   are range-checked (< 2^28, no wrap) before ATA access.
;   Crash healing: after FAT1+root are cached and mounted=1 is set, the
;   second FAT mirror is reconciled best-effort (FAT1->FAT2) via
;   fs_vol_heal_mirrors64; its status is ignored here so mount keeps its
;   historical 0-on-loaded contract — use fs_vol_scrub64 to query
;   DANGLING/XLINK/MIRROR bits explicitly after remount.
; ------------------------------------------------------------
fs_mount_volume64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    cmp byte [rel fs_vol_mounted], 0
    jne .already_ok
    call ata_init
    test rax, rax
    jnz .fail
    lea rdi, [rel fs_vol_boot]
    mov rsi, FS_VOL_LBA
    mov rdx, 1
    call ata_read_lba28
    test rax, rax
    jnz .fail
    cmp word [rel fs_vol_boot + 510], 0xAA55
    jne .fail
    lea rsi, [rel fs_vol_boot]
    lea rbp, [rel fs_vol_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail
    ; Geometry boundary: prove the parsed BPB fits the fixed cache
    ; before absolutizing or issuing any FAT/root ATA read.
    lea rsi, [rel fs_vol_boot]
    lea rbp, [rel fs_vol_dpb]
    call fs_vol_validate64
    test rax, rax
    jnz .fail_geom
    ; Absolutize volume-relative LBAs (proven wrap-free by validator).
    add dword [rbp + DPB64.firfat], FS_VOL_LBA
    add dword [rbp + DPB64.firdir], FS_VOL_LBA
    add dword [rbp + DPB64.firrec], FS_VOL_LBA
    ; Cache dir sector count: (maxent*32 + secsiz-1) / secsiz.
    mov eax, [rbp + DPB64.maxent]
    shl eax, 5
    mov ecx, [rbp + DPB64.secsiz]
    dec ecx
    add eax, ecx
    inc ecx
    xor edx, edx
    div ecx
    mov [rel fs_vol_dirsec], rax
    ; Range-check the cached FAT/root reads before ATA access
    ; (defense-in-depth: validator already proved these).
    mov eax, [rbp + DPB64.secsiz]
    cmp eax, FS_VOL_SECSIZ
    jne .fail_geom
    mov edx, [rbp + DPB64.fatsiz]
    test edx, edx
    jz .fail_geom
    cmp edx, 64
    ja .fail_geom                  ; ATA driver contract is strict 1..64
    mov r8d, edx
    mov r9d, eax
    imul r8, r9                    ; R8 = fatsiz_bytes
    jo .fail_geom
    cmp r8, FS_VOL_FAT_BYTES
    ja .fail_geom
    mov edx, [rbp + DPB64.firfat]  ; absolutized LBA
    mov rax, rdx
    cmp rax, 0x10000000
    jae .fail_geom
    mov edx, [rbp + DPB64.fatsiz]
    add rax, rdx                   ; firfat_abs + fatsiz, no wrap, < 2^28
    jc .fail_geom
    cmp rax, 0x10000000
    jae .fail_geom
    mov rdx, [rel fs_vol_dirsec]
    test rdx, rdx
    jz .fail_geom
    cmp rdx, 64
    ja .fail_geom                  ; ATA driver contract is strict 1..64
    mov rax, rdx
    mov r8d, [rbp + DPB64.secsiz]
    imul rax, r8                   ; dirsec_bytes
    jo .fail_geom
    cmp rax, FS_VOL_ROOT_BYTES
    ja .fail_geom
    mov edx, [rbp + DPB64.firdir]  ; absolutized LBA
    mov rax, rdx
    cmp rax, 0x10000000
    jae .fail_geom
    mov rdx, [rel fs_vol_dirsec]
    add rax, rdx                   ; firdir_abs + dirsec, no wrap, < 2^28
    jc .fail_geom
    cmp rax, 0x10000000
    jae .fail_geom
    ; Load first FAT copy into RAM.
    lea rdi, [rel fs_vol_fat]
    mov eax, [rbp + DPB64.firfat]
    mov rsi, rax
    mov edx, [rbp + DPB64.fatsiz]
    call ata_read_lba28
    test rax, rax
    jnz .fail
    lea rax, [rel fs_vol_fat]
    mov [rbp + DPB64.fat], rax
    ; Load root directory into RAM.
    lea rdi, [rel fs_vol_root]
    mov eax, [rbp + DPB64.firdir]
    mov rsi, rax
    mov rdx, [rel fs_vol_dirsec]
    call ata_read_lba28
    test rax, rax
    jnz .fail
    mov byte [rel fs_vol_mounted], 1
    ; Best-effort mirror heal (FAT1 wins); ignored for mount status.
    push rax
    call fs_vol_heal_mirrors64
    pop rax
.already_ok:
    xor eax, eax
    jmp .done
.fail_geom:
    mov rax, FS_MOUNT_GEOM_ERR
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
; fs_vol_flush_fat64 — write RAM FAT back to both on-disk copies
;   Out: RAX 0 ok, 1 fail (or not mounted, or injected fault).
;   Order FAT1 then FAT2; a fault/IO failure on copy1 skips copy2
;   (disk keeps the old pair); a failure on copy2 leaves FAT1 new and
;   FAT2 old (divergent mirrors, healed at mount FAT1->FAT2).
;   Faults (fs_fault_inject, tests only): FS_FAULT_FAT1 fails before
;   copy1 without writing; FS_FAULT_FAT2 writes copy1 then fails
;   before copy2. Sticky until cleared by the test.
; ------------------------------------------------------------
fs_vol_flush_fat64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    cmp byte [rel fs_vol_mounted], 0
    je .fail_novol
    mov eax, [rel fs_fault_inject]
    test eax, FS_FAULT_FAT1
    jnz .fail_io
    lea rbp, [rel fs_vol_dpb]
    lea rdi, [rel fs_vol_fat]
    mov eax, [rbp + DPB64.firfat]
    mov rsi, rax
    mov edx, [rbp + DPB64.fatsiz]
    call ata_write_lba28
    test rax, rax
    jnz .fail_io
    mov eax, [rel fs_fault_inject]
    test eax, FS_FAULT_FAT2
    jnz .fail_io
    lea rdi, [rel fs_vol_fat]
    mov eax, [rbp + DPB64.firfat]
    add eax, [rbp + DPB64.fatsiz]
    mov rsi, rax
    mov edx, [rbp + DPB64.fatsiz]
    call ata_write_lba28
    test rax, rax
    jnz .fail_io
    xor eax, eax
    jmp .done
.fail_novol:
.fail_io:
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
; fs_vol_flush_root64 — write RAM root dir back to disk
;   Out: RAX 0 ok, 1 fail (or not mounted, or injected fault).
;   Fault (tests only): FS_FAULT_ROOT fails without writing.
; ------------------------------------------------------------
fs_vol_flush_root64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    cmp byte [rel fs_vol_mounted], 0
    je .fail_novol2
    mov eax, [rel fs_fault_inject]
    test eax, FS_FAULT_ROOT
    jnz .fail_io2
    lea rbp, [rel fs_vol_dpb]
    lea rdi, [rel fs_vol_root]
    mov eax, [rbp + DPB64.firdir]
    mov rsi, rax
    mov rdx, [rel fs_vol_dirsec]
    call ata_write_lba28
    test rax, rax
    jnz .fail_io2
    xor eax, eax
    jmp .done2
.fail_novol2:
.fail_io2:
    mov rax, 1
.done2:
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_vol_discard64 — drop RAM caches to simulate a reboot/power loss
;   Out: RAX 0. Clears mounted so the next fs_mount_volume64 reloads
;   FAT1+root from disk (RAM-only unflushed state is lost, like DRAM).
;   Fault mask is left untouched (tests clear it explicitly).
;   Clobbers: RAX. Preserves all other registers.
; ------------------------------------------------------------
fs_vol_discard64:
    mov byte [rel fs_vol_mounted], 0
    xor eax, eax
    ret

; ------------------------------------------------------------
; fs_vol_check_mirrors64 — compare RAM FAT1 vs on-disk FAT2
;   Out: RAX 0 match CF=0; 1 mismatch CF=1; 2 error (not mounted/ATA) CF=1.
;   Reads FAT2 (firfat+fatsiz, fatsiz sectors) into fs_vol_iobuf and
;   compares fatsiz*512 bytes with fs_vol_fat. Clobbers iobuf.
;   Preserves RBX,RBP,R12-R15; clobbers RAX,RCX,RDX,RSI,RDI,R8-R11.
; ------------------------------------------------------------
fs_vol_check_mirrors64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    cmp byte [rel fs_vol_mounted], 0
    je .cm_err
    lea rbp, [rel fs_vol_dpb]
    mov edx, [rbp + DPB64.fatsiz]
    test edx, edx
    jz .cm_err
    cmp edx, 64
    ja .cm_err
    mov r8d, edx
    mov eax, [rbp + DPB64.secsiz]
    cmp eax, FS_VOL_SECSIZ
    jne .cm_err
    mov r9, r8
    imul r9, 512
    jo .cm_err
    cmp r9, FS_VOL_FAT_BYTES
    ja .cm_err
    mov eax, [rbp + DPB64.firfat]
    add eax, [rbp + DPB64.fatsiz]
    jc .cm_err
    cmp rax, 0x10000000
    jae .cm_err
    mov rsi, rax
    lea rdi, [rel fs_vol_iobuf]
    mov rdx, r8
    call ata_read_lba28
    test rax, rax
    jnz .cm_err
    lea rsi, [rel fs_vol_fat]
    lea rdi, [rel fs_vol_iobuf]
    mov rcx, r9
    cld
.rep_cm:
    test rcx, rcx
    jz .cm_match
    mov al, [rsi]
    cmp al, [rdi]
    jne .cm_mismatch
    inc rsi
    inc rdi
    dec rcx
    jmp .rep_cm
.cm_match:
    xor eax, eax
    clc
    jmp .cm_done
.cm_mismatch:
    mov rax, 1
    stc
    jmp .cm_done
.cm_err:
    mov rax, 2
    stc
.cm_done:
    pop r11
    pop r10
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
; fs_vol_heal_mirrors64 — reconcile FAT2 from RAM FAT1 on mismatch
;   Out: RAX 0 healed-or-match CF=0; 1 fail (not mounted/ATA) CF=1.
;   Writes RAM FAT1 (fatsiz sectors) to FAT2 LBA (firfat+fatsiz).
;   Recovery writes bypass fs_fault_inject (faults model the crash,
;   not the repair; tests clear the mask before remount/heal).
; ------------------------------------------------------------
fs_vol_heal_mirrors64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    call fs_vol_check_mirrors64
    cmp rax, 0
    je .heal_ok
    cmp rax, 1
    jne .heal_fail
    cmp byte [rel fs_vol_mounted], 0
    je .heal_fail
    lea rbp, [rel fs_vol_dpb]
    lea rdi, [rel fs_vol_fat]
    mov eax, [rbp + DPB64.firfat]
    add eax, [rbp + DPB64.fatsiz]
    mov rsi, rax
    mov edx, [rbp + DPB64.fatsiz]
    call ata_write_lba28
    test rax, rax
    jnz .heal_fail
.heal_ok:
    xor eax, eax
    clc
    jmp .heal_done
.heal_fail:
    mov rax, 1
    stc
.heal_done:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_vol_build_marks — internal: fill fs_scrub_marks + detect bad chains
;   In: none (uses mounted vol_dpb/fat/root).
;   Out: RAX = DANGLING/XLINK bits (0 clean for chains), CF=0 ok;
;        RAX = 0xFFFFFFFF CF=1 if not mounted.
;   Marks every cluster reachable from a live root entry (0x00 stops,
;   0xE5 skips, attr 0x08 vol-label and 0x0F LFN skip chain walk).
;   A referenced free(0)/reserved(1)/oob/bad(0xFF7)/truncated chain sets
;   DANGLING; a cluster reached twice sets XLINK. Bitmap covers 0..4095.
;   Preserves RBX,RBP,R12-R15; uses iobuf? No — RAM FAT only, no disk I/O.
; ------------------------------------------------------------
fs_vol_build_marks:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    cmp byte [rel fs_vol_mounted], 0
    je .bm_nomnt
    lea rbp, [rel fs_vol_dpb]
    mov r12d, [rbp + DPB64.maxclus]
    cmp r12d, 2
    jb .bm_nomnt
    mov r13d, [rbp + DPB64.maxent]
    test r13d, r13d
    jz .bm_nomnt
    lea r14, [rel fs_vol_fat]
    lea r15, [rel fs_vol_root]
    ; clear 512B bitmap
    lea rdi, [rel fs_scrub_marks]
    mov rcx, 512
    xor eax, eax
    cld
    rep stosb
    xor r10d, r10d                  ; R10D = status bits
    xor r11d, r11d                  ; R11D = slot index
.slot_bm:
    cmp r11d, r13d
    jae .bm_done_ok
    mov eax, r11d
    shl eax, 5
    lea rsi, [r15 + rax]            ; entry ptr
    mov al, [rsi]
    test al, al
    jz .bm_done_ok                  ; 0x00 end
    cmp al, 0xE5
    je .bm_next
    mov al, [rsi + DIRENT.attr]
    cmp al, 0x0F
    je .bm_next                     ; LFN (not used, skip)
    test al, 0x08
    jnz .bm_next                     ; volume label: no chain
    movzx ebx, word [rsi + DIRENT.firstclus]
    mov ecx, [rsi + DIRENT.size]
    test ecx, ecx
    jnz .nonempty_bm
    test ebx, ebx
    jz .bm_next                      ; empty file, no chain
    ; size==0 but firstclus!=0: still walk to mark (avoid orphan false+)
    jmp .walk_bm
.nonempty_bm:
    cmp ebx, 2
    jb .dangling_bm                 ; size>0 needs cluster
    cmp ebx, r12d
    ja .dangling_bm
.walk_bm:
    cmp ebx, 2
    jb .bm_next                      ; empty-cluster case already handled
    mov r8d, ebx                     ; c
    xor r9d, r9d                     ; hops
.chain_bm:
    cmp r8d, 2
    jb .dangling_bm
    cmp r8d, r12d
    ja .dangling_bm
    inc r9d
    cmp r9d, r12d
    jae .dangling_bm                 ; hops >= maxclus: cycle/overlong
    ; xlink test+set: CF=1 means already visited.
    mov eax, r8d
    lea rdi, [rel fs_scrub_marks]
    bts dword [rdi], eax
    jc .xlink_bm
    ; next = FAT[c] (RAM)
    mov rbx, r8
    push rsi
    push r9
    push r10
    push r11
    mov rsi, r14
    call fs_get_cluster64            ; RSI=FAT RBX=c RBP=DPB -> RDI=next
    mov r8d, edi
    mov edx, eax                     ; save get status
    pop r11
    pop r10
    pop r9
    pop rsi
    test edx, edx
    jnz .dangling_bm
    cmp r8d, 0xFF8
    jae .bm_next                     ; EOF: file walk done
    cmp r8d, 2
    jb .dangling_bm                  ; 0 free / 1 reserved: truncated
    cmp r8d, 0xFF7
    je .dangling_bm                  ; bad cluster in chain
    cmp r8d, r12d
    ja .dangling_bm                  ; oob link
    jmp .chain_bm
.dangling_bm:
    or r10d, FS_SCRUB_DANGLING
    jmp .bm_next
.xlink_bm:
    or r10d, FS_SCRUB_XLINK
    jmp .bm_next
.bm_next:
    inc r11d
    jmp .slot_bm
.bm_done_ok:
    mov rax, r10
    clc
    jmp .bm_done
.bm_nomnt:
    mov rax, -1
    stc
.bm_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
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
; fs_vol_scrub64 — validate entries/chains/mirrors + count orphans
;   Out: RAX = bitmask (0 clean; DANGLING/XLINK/MIRROR), RCX = orphan
;   count (allocated non-bad unvisited clusters), CF=0 iff clean,
;   CF=1 on any bit or error. Error (not mounted/ATA): RAX=-1, RCX=0.
;   Read-only except clobbering fs_vol_iobuf (mirror read) and the
;   marks bitmap. Orphans alone are leaks (safe) and do NOT set bits;
;   use fs_vol_reclaim_orphans64 to free them.
; ------------------------------------------------------------
fs_vol_scrub64:
    push rbx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    cmp byte [rel fs_vol_mounted], 0
    je .sc_err
    call fs_vol_build_marks
    jc .sc_err
    mov r15, rax                     ; chain bits
    call fs_vol_check_mirrors64
    cmp rax, 1
    jne .sc_nomirror
    or r15, FS_SCRUB_MIRROR
    jmp .sc_count
.sc_nomirror:
    cmp rax, 0
    jne .sc_err                      ; check error (2)
.sc_count:
    ; count orphans: allocated && !=0xFF7 && unvisited
    lea rbp, [rel fs_vol_dpb]
    mov r12d, [rbp + DPB64.maxclus]
    lea r14, [rel fs_vol_fat]
    xor ecx, ecx                     ; orphan count (RCX)
    mov ebx, 2
.orph_sc:
    cmp ebx, r12d
    ja .sc_ret
    push rcx
    push rbx
    mov rsi, r14
    call fs_get_cluster64            ; -> RDI
    mov r8d, edi
    mov r9d, eax
    pop rbx
    pop rcx
    test r9d, r9d
    jnz .next_sc                      ; get failed (oob?) -> not orphan
    test r8d, r8d
    jz .next_sc                       ; free
    cmp r8d, 0xFF7
    je .next_sc                       ; bad: reserved, not orphan
    mov eax, ebx
    lea rdi, [rel fs_scrub_marks]
    bt dword [rdi], eax
    jc .next_sc                       ; visited
    inc rcx
.next_sc:
    inc ebx
    jmp .orph_sc
.sc_ret:
    mov rax, r15
    test rax, rax
    jnz .sc_bad
    clc
    jmp .sc_done
.sc_bad:
    stc
    jmp .sc_done
.sc_err:
    mov rax, -1
    xor ecx, ecx
    stc
.sc_done:
    ; Pops restore every pushed reg except RAX/RCX: RAX carries the
    ; bitmask (POP never targets it), RCX carries the orphan count
    ; (never pushed, so it survives directly).
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_vol_reclaim_orphans64 — free orphan (allocated, unvisited) clusters
;   Out: RAX = reclaimed count, CF=0 ok (flush ok or nothing to do);
;        CF=1 fail (not mounted or FAT flush failed; RAM still updated
;        best-effort, disk keeps old state until next successful flush).
;   Bad clusters (0xFF7) are never reclaimed. Cross-linked clusters are
;   visited and left alone. Call fs_vol_scrub64 first to diagnose.
; ------------------------------------------------------------
fs_vol_reclaim_orphans64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    cmp byte [rel fs_vol_mounted], 0
    je .rc_fail
    call fs_vol_build_marks
    jc .rc_fail
    lea rbp, [rel fs_vol_dpb]
    mov r12d, [rbp + DPB64.maxclus]
    lea rsi, [rel fs_vol_fat]
    xor r15d, r15d                   ; reclaimed
    mov ebx, 2
.scan_rc:
    cmp ebx, r12d
    ja .flush_rc
    push rsi
    push rbx
    push r15
    call fs_get_cluster64
    mov r8d, edi
    mov r9d, eax
    pop r15
    pop rbx
    pop rsi
    test r9d, r9d
    jnz .next_rc
    test r8d, r8d
    jz .next_rc
    cmp r8d, 0xFF7
    je .next_rc
    mov eax, ebx
    lea rdi, [rel fs_scrub_marks]
    bt dword [rdi], eax
    jc .next_rc
    mov rdx, 0
    push rsi
    push rbx
    push r15
    call fs_set_cluster64
    mov r10d, eax
    pop r15
    pop rbx
    pop rsi
    test r10d, r10d
    jnz .next_rc
    inc r15d
.next_rc:
    inc ebx
    jmp .scan_rc
.flush_rc:
    test r15d, r15d
    jz .rc_ok0
    call fs_vol_flush_fat64
    test rax, rax
    jnz .rc_flushfail
.rc_ok0:
    mov eax, r15d
    clc
    jmp .rc_done
.rc_flushfail:
    mov eax, r15d
    stc
    jmp .rc_done
.rc_fail:
    xor eax, eax
    stc
.rc_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
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
; fs_alloc_cluster64 — allocate one free cluster (marks EOF)
;   Out: RAX = cluster (0 = none/bad), CF 0/1. Flushes FAT on success.
;   If the FAT flush fails (I/O or injected fault) the RAM entry is
;   rolled back to free and failure is returned, so RAM and disk stay
;   at the old consistent state and no dangling dir entry can be
;   published for the cluster.
; ------------------------------------------------------------
fs_alloc_cluster64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    cmp byte [rel fs_vol_mounted], 0
    je .none_ac
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov ecx, [rbp + DPB64.maxclus]
    mov ebx, 2
.scan_ac:
    cmp ebx, ecx
    ja .none_ac
    mov r8, rsi
    push rbx
    push rcx
    call fs_get_cluster64
    mov r8d, edi
    pop rcx
    pop rbx
    test rax, rax
    jnz .next_ac
    test r8d, r8d
    jnz .next_ac
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .none_ac
    call fs_vol_flush_fat64
    test rax, rax
    jnz .rollback_ac
    mov rax, rbx
    clc
    jmp .done_ac
.rollback_ac:
    ; Flush failed: roll RAM entry back to free so RAM==disk (old state).
    mov rdx, 0
    call fs_set_cluster64
    jmp .none_ac
.next_ac:
    inc ebx
    jmp .scan_ac
.none_ac:
    xor eax, eax
    stc
.done_ac:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_vol_read_file64 — read a root-dir file from the mounted volume
;   In: RDI = 11-byte name, RSI = dest buffer, RDX = buffer size
;   Out: RAX = bytes read (min(size, bufsize)), CF 0 ok; CF 1 not found/fail.
; ------------------------------------------------------------
fs_vol_read_file64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    cmp byte [rel fs_vol_mounted], 0
    je .fail_rf
    test rsi, rsi
    jz .fail_rf
    mov r12, rsi          ; dest
    mov r11, rdx          ; bufsize
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    ; RDI already = name
    call fs_dir_find64
    jc .fail_rf
    mov r8, rbx           ; entry
    mov rbx, r8
    call fs_dir_get_size64
    mov r9, rax           ; file size
    mov rbx, r8
    call fs_dir_get_firstclus64
    mov r10, rax          ; cluster
    ; total = min(file size R9, bufsize R11) -> R9.
    ; (R9 survives fs_file_read_cluster64/fs_get_cluster64; RCX does not.)
    cmp r9, r11
    jbe .have_total
    mov r9, r11
.have_total:
    test r9, r9
    jz .ok_empty
    test r10, r10
    jz .fail_rf           ; non-empty file must have a cluster
    xor r11, r11          ; copied
.copy_loop:
    cmp r11, r9
    jae .ok_done
    ; read cluster r10 -> iobuf (spc==1, one sector)
    lea rdi, [rel fs_vol_iobuf]
    mov rbx, r10
    call fs_file_read_cluster64
    test rax, rax
    jnz .fail_rf
    ; chunk = min(512, remaining)
    mov rax, r9
    sub rax, r11
    cmp rax, 512
    jbe .have_chunk
    mov rax, 512
.have_chunk:
    lea rsi, [rel fs_vol_iobuf]
    mov rdi, r12
    add rdi, r11
    mov rdx, rax
    push r9
    mov rcx, rax
    cld
    rep movsb
    pop r9
    add r11, rdx
    cmp r11, r9
    jae .ok_done
    ; next cluster
    lea rsi, [rel fs_vol_fat]
    mov rbx, r10
    call fs_get_cluster64
    test rax, rax
    jnz .fail_rf
    call fs_is_eof64      ; RDI = next value
    cmp rax, 1
    je .fail_rf           ; chain ended before size satisfied
    mov r10, rdi
    jmp .copy_loop
.ok_done:
    mov rax, r11
    clc
    jmp .done_rf
.ok_empty:
    xor eax, eax
    clc
    jmp .done_rf
.fail_rf:
    xor eax, eax
    stc
.done_rf:
    ; Pops restore regs but touch neither RAX nor RFLAGS, so the
    ; return value (RAX) and status (CF) survive directly.
    pop r12
    pop r11
    pop r10
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
; FCB file-operation core (G1) — INT 21h FCB handlers' backend.
; All ops target the mounted volume (vol_dpb/fat/root), write-through.
; Position model: absolute record number (recsiz units). Sequential
;   position P = extent*128 + nr (exact when recsiz=128; the handlers
;   keep extent/nr mirrored from P — see syscall64 file handlers).
; ============================================================

; ------------------------------------------------------------
; fs_file_write_cluster64 — write one data cluster's sectors via ATA
;   In: RBP = DPB, RBX = cluster, RSI = src buffer (>= spc*secsiz)
;   Out: RAX 0 ok CF=0; 1/CF=1 fail. (Write twin of fs_file_read_cluster64.)
; ------------------------------------------------------------
fs_file_write_cluster64:
    push rbx
    push rbp
    push r12
    mov r12, rsi                      ; save src
    call fs_cluster_to_lba64          ; RBX,RBP -> RAX=LBA (CF on bad)
    jc .fail_wc
    mov rsi, rax                      ; LBA
    movzx ecx, byte [rbp + DPB64.clusmsk]
    inc ecx
    mov edx, ecx
    mov rdi, r12
    call ata_write_lba28
    pop r12
    pop rbp
    pop rbx
    ret
.fail_wc:
    mov rax, 1
    pop r12
    pop rbp
    pop rbx
    ret

; ------------------------------------------------------------
; fs_vol_find_free64 — find a free root-dir slot (0xE5 or 0x00 end)
;   Out: CF=0 RBX=entry ptr; CF=1 full/not-mounted (RBX=0).
; ------------------------------------------------------------
fs_vol_find_free64:
    push rax
    push rcx
    push rdx
    push r11
    cmp byte [rel fs_vol_mounted], 0
    je .full_ff
    lea r11, [rel fs_vol_root]
    lea rbp, [rel fs_vol_dpb]
    mov ecx, [rbp + DPB64.maxent]
    xor eax, eax
.scan_ff:
    cmp eax, ecx
    jae .full_ff
    mov rbx, rax
    shl rbx, 5
    add rbx, r11
    mov dl, [rbx]
    test dl, dl
    jz .have_ff
    cmp dl, 0xE5
    je .have_ff
    inc eax
    jmp .scan_ff
.have_ff:
    clc
    jmp .done_ff
.full_ff:
    xor ebx, ebx
    stc
.done_ff:
    pop r11
    pop rdx
    pop rcx
    pop rax
    ret

; ------------------------------------------------------------
; fs_chain_free_mem64 — free chain in explicit FAT buffer with hop bound
;   In: RDI = first cluster, RSI = FAT base linear, RBP = DPB ptr.
;   Out: RAX 0 ok CF=0; 1 hop-bound exceeded (corruption) CF=1.
;   Best-effort: visited entries cleared to 0 in both cases. Empty (<2)
;   => 0 (no-op). Success terminators (preserved legacy):
;   next <2, next >maxclus, next >=0xFF8 (EOF). Untrusted on-disk FAT is
;   bounded: hops counts each visited cluster (2..maxclus); fails when
;   hops >= maxclus, i.e. hops > max_data_clusters (maxclus-1), the
;   maximum possible distinct data clusters. NULL RSI/RBP or maxclus<2
;   with a non-empty chain => corruption (bound cannot be proven).
; ------------------------------------------------------------
fs_chain_free_mem64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    cmp rdi, 2
    jb .done_ok_cm
    test rsi, rsi
    jz .corrupt_cm
    test rbp, rbp
    jz .corrupt_cm
    mov ecx, [rbp + DPB64.maxclus]
    cmp ecx, 2
    jb .corrupt_cm
    mov r10, rcx                  ; R10 = maxclus bound (get/set keep R10)
    mov rbx, rdi
    xor r9d, r9d                  ; R9 = hops (get keeps R9, set restores R9)
.next_cm:
    cmp rbx, 2
    jb .done_ok_cm
    mov ecx, [rbp + DPB64.maxclus]
    cmp rbx, rcx
    ja .done_ok_cm
    inc r9
    cmp r9, r10
    jae .corrupt_cm               ; hops >= maxclus => exceeds max_data
    call fs_get_cluster64            ; RSI,RBX,RBP -> RDI=next
    mov r8, rdi                      ; next (R8 survives set below)
    mov rdx, 0
    call fs_set_cluster64            ; clear current (RBX restored by callee)
    mov rdi, r8
    cmp rdi, 0xFF8
    jae .done_ok_cm
    cmp rdi, 2
    jb .done_ok_cm
    mov rbx, rdi
    jmp .next_cm
.corrupt_cm:
    mov rax, 1
    stc
    jmp .done_cm
.done_ok_cm:
    xor eax, eax
    clc
.done_cm:
    pop r10
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
; fs_vol_free_chain64 — release a cluster chain (FAT entries -> 0)
;   In: RDI = first cluster (0/1 = nothing to do).
;   Out: RAX 0 ok CF=0 (flushes FAT unless empty);
;        RAX 1 CF=1 hop-bound corruption (best-effort clears flushed)
;        or FAT flush failure.
;   Hop bound is derived from the validated mounted geometry
;   (DPB maxclus); see fs_chain_free_mem64.
; ------------------------------------------------------------
fs_vol_free_chain64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    cmp byte [rel fs_vol_mounted], 0
    je .done_fc_ok
    cmp rdi, 2
    jb .done_fc_ok
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    call fs_chain_free_mem64       ; RDI/RSI/RBP -> RAX core status
    mov r10, rax                   ; save core status (flush keeps R10)
    call fs_vol_flush_fat64        ; best-effort write-back in both cases
    test r10, r10
    jnz .done_fc_corrupt           ; hop-bound corruption dominates
    test rax, rax
    jnz .done_fc_corrupt           ; flush I/O failure
.done_fc_ok:
    xor eax, eax
    clc
    jmp .done_fc
.done_fc_corrupt:
    mov rax, 1
    stc
.done_fc:
    pop r10
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
; fs_fcb_close64 — sync FCB firclus/size + caller time/date to dir
;   In: RDI = FCB64 ptr, RSI = time word, RDX = date word.
;   Out: RAX 0 ok CF=0; 1/CF=1 not found (or not mounted).
;   Stack map at the time/date reload (7 pushes: rbx,rcx,rdx,rsi,rdi,
;   rbp,r8): orig RSI (time) at [rsp+24], orig RDX (date) at [rsp+32].
; ------------------------------------------------------------
fs_fcb_close64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    cmp byte [rel fs_vol_mounted], 0
    je .fail_cl
    test rdi, rdi
    jz .fail_cl
    mov r8, rdi
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [r8 + FCB64.name]
    call fs_dir_find64
    jc .fail_cl
    mov eax, [r8 + FCB64.firclus]
    mov [rbx + DIRENT.firstclus], ax
    mov rax, [r8 + FCB64.filsiz]
    mov [rbx + DIRENT.size], eax
    mov rax, [rsp + 24]              ; orig RSI = time
    mov [rbx + DIRENT.time], ax
    mov rax, [rsp + 32]              ; orig RDX = date
    mov [rbx + DIRENT.date], ax
    call fs_vol_flush_root64
    test rax, rax
    jnz .fail_cl
    xor eax, eax
    jmp .done_cl
.fail_cl:
    mov rax, 1
    stc
    jmp .done_cl2
.done_cl:
    clc
.done_cl2:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_fcb_delete64 — delete a root-dir file (mark 0xE5, then free chain)
;   In: RDI = FCB64 ptr (name/ext). Out: RAX 0 ok CF=0; 1/CF=1 not found,
;   FAT corruption (hop-bound exceeded, best-effort clears flushed), or
;   flush failure.
;   Crash order is root-first: the 0xE5 mark is flushed BEFORE the FAT
;   chain is freed, so a reset between the two leaves an orphan leak
;   (deleted entry + still-allocated clusters, reclaimable) and never a
;   dangling live entry pointing at freed clusters. If the root flush
;   fails the chain is NOT freed (disk keeps the old live+allocated
;   state); if the FAT flush fails afterwards the leak is reported.
; ------------------------------------------------------------
fs_fcb_delete64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    cmp byte [rel fs_vol_mounted], 0
    je .fail_dl
    test rdi, rdi
    jz .fail_dl
    mov r8, rdi
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [r8 + FCB64.name]
    call fs_dir_find64
    jc .fail_dl
    movzx ecx, word [rbx + DIRENT.firstclus]
    mov r8d, ecx                   ; save chain (flush_root preserves R8)
    mov byte [rbx], 0xE5
    call fs_vol_flush_root64       ; publish deletion first
    test rax, rax
    jnz .fail_dl
    mov edi, r8d
    call fs_vol_free_chain64       ; frees + flushes FAT (ok if 0)
    test rax, rax                  ; propagate hop-bound/flush failure
    jnz .fail_dl                   ; (root already deleted: orphan leak)
    xor eax, eax
    jmp .done_dl
.fail_dl:
    mov rax, 1
    stc
    jmp .done_dl2
.done_dl:
    clc
.done_dl2:
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; fs_fcb_create64 — create (or truncate) a root-dir file
;   In: RDI = FCB64 ptr (drive/name/ext; recsiz defaulted to 128).
;   Out: RAX 0 ok CF=0 (RBX=dir entry, FCB firclus/filsiz/lstclus set);
;        1/CF=1 dir full, not mounted, FAT corruption on truncate
;        (hop-bound exceeded, best-effort clears kept), or flush failure.
;   Truncate order is root-first: the zeroed size/firstclus is flushed
;   BEFORE the old chain is freed, so a reset between the two leaves an
;   orphan leak (truncated entry + still-allocated tail, reclaimable)
;   and never a dangling entry pointing at freed clusters. R10D carries
;   the saved old chain (0 = create-new, nothing to free). If the root
;   flush fails the old chain is NOT freed (disk keeps the old state).
; ------------------------------------------------------------
fs_fcb_create64:
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    cmp byte [rel fs_vol_mounted], 0
    je .fail_cr
    test rdi, rdi
    jz .fail_cr
    mov r8, rdi
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [r8 + FCB64.name]
    call fs_dir_find64
    jc .notfound_cr
    ; Exists: truncate — publish truncation BEFORE freeing (leak-only).
    movzx ecx, word [rbx + DIRENT.firstclus]
    mov r9, rbx
    mov r10d, ecx                ; save old chain (flush keeps R10)
    mov dword [r9 + DIRENT.firstclus], 0
    mov dword [r9 + DIRENT.size], 0
    mov rbx, r9
    jmp .fill_fcb_cr
.notfound_cr:
    xor r10d, r10d               ; create-new: nothing to free afterwards
    call fs_vol_find_free64
    jc .fail_cr
    ; Zero the 32B entry, install name/attr.
    mov rcx, 32
    xor eax, eax
.clear_cr:
    mov [rbx], al
    inc rbx
    dec rcx
    jnz .clear_cr
    sub rbx, 32
    mov rsi, r8
    add rsi, FCB64.name
    mov rdi, rbx
    mov rcx, 11
    cld
    rep movsb
    mov byte [rbx + DIRENT.attr], 0x20
.fill_fcb_cr:
    mov dword [r8 + FCB64.firclus], 0
    mov dword [r8 + FCB64.lstclus], 0
    mov dword [r8 + FCB64.cluspos], 0
    mov qword [r8 + FCB64.filsiz], 0
    mov eax, [r8 + FCB64.recsiz]
    test eax, eax
    jnz .have_rs_cr
    mov dword [r8 + FCB64.recsiz], 128
.have_rs_cr:
    call fs_vol_flush_root64     ; publish create/truncate first
    test rax, rax
    jnz .fail_cr                 ; root failed: old chain kept on disk
    cmp r10d, 2
    jb .done_cr_ok               ; create-new or empty truncate: nothing to free
    mov edi, r10d
    call fs_vol_free_chain64     ; free old tail after commit (leak on fail)
    test rax, rax
    jnz .fail_cr
.done_cr_ok:
    xor eax, eax
    jmp .done_cr
.fail_cr:
    xor ebx, ebx
    mov rax, 1
    stc
    jmp .done_cr2
.done_cr:
    clc
.done_cr2:
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; fs_fcb_rename64 — rename a root-dir file (dup-checked)
;   In: RDI = FCB64 ptr (old name at +1, new 11-byte name at +16).
;   Out: RAX 0 ok CF=0; 1/CF=1 not found or duplicate.
; ------------------------------------------------------------
fs_fcb_rename64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    cmp byte [rel fs_vol_mounted], 0
    je .fail_rn
    test rdi, rdi
    jz .fail_rn
    mov r8, rdi
    lea rbp, [rel fs_vol_dpb]
    ; Duplicate check on the new name first.
    lea rsi, [rel fs_vol_root]
    lea rdi, [r8 + 16]
    call fs_dir_find64
    jnc .fail_rn
    ; Find the old name.
    lea rsi, [rel fs_vol_root]
    lea rdi, [r8 + FCB64.name]
    call fs_dir_find64
    jc .fail_rn
    mov r9, rbx
    lea rsi, [r8 + 16]
    mov rdi, r9
    mov rcx, 11
    cld
    rep movsb
    call fs_vol_flush_root64
    test rax, rax
    jnz .fail_rn
    xor eax, eax
    jmp .done_rn
.fail_rn:
    mov rax, 1
    stc
    jmp .done_rn2
.done_rn:
    clc
.done_rn2:
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
; fs_fcb_search64 — find the Nth (0-based slot scan) wildcard match
;   In: RDI = 11-byte pattern ('?' wild), RSI = start slot.
;   Out: CF=0 RBX=entry RAX=next slot; CF=1 none (RBX=0).
;   Skips 0xE5, stops at 0x00 end (DOS FINDNAME/CONTSRCH shape).
; ------------------------------------------------------------
fs_fcb_search64:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp byte [rel fs_vol_mounted], 0
    je .none_sr
    test rdi, rdi
    jz .none_sr
    lea rbp, [rel fs_vol_dpb]
    mov r10d, [rbp + DPB64.maxent]
    lea r11, [rel fs_vol_root]
    mov rcx, rsi                  ; slot
.loop_sr:
    cmp rcx, r10
    jae .none_sr
    mov rax, rcx
    shl rax, 5
    lea r9, [r11 + rax]
    mov al, [r9]
    test al, al
    jz .none_sr
    cmp al, 0xE5
    je .next_sr
    xor r8d, r8d
.cmp_sr:
    cmp r8d, 11
    jae .found_sr
    mov dl, [rdi + r8]
    cmp dl, '?'
    je .cmp_next_sr
    cmp dl, [r9 + r8]
    jne .next_sr
.cmp_next_sr:
    inc r8d
    jmp .cmp_sr
.next_sr:
    inc rcx
    jmp .loop_sr
.found_sr:
    mov rbx, r9
    mov rax, rcx
    inc rax                       ; next slot for SRCHNXT
    jmp .done_sr
.none_sr:
    xor ebx, ebx
    xor eax, eax
    stc
    jmp .done_sr2
.done_sr:
    clc
.done_sr2:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; fs_make_fcb64 — parse a path string into an FCB (INT 21h AH=29h)
;   In: RDI = FCB64 dst (80B), RSI = src ASCIIZ, AL = mode bit0:
;         1 = skip leading separators first (DOS PARSEFCB flag).
;   Out: AL = 0 ok, 1 wildcards present, 0xFF bad drive; RSI = end ptr
;        (first unconsumed char), CF 0/1.
;   Drive: 0 = none/default, else letter-'A'+1. Name/ext upper-cased,
;   blank-padded; '*' -> '?' + '?' fill; '?' kept (wild).
; ------------------------------------------------------------
fs_make_fcb64:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    test rdi, rdi
    jz .bad_mf
    test rsi, rsi
    jz .bad_mf
    mov r8, rdi                   ; FCB
    mov r9, rsi                   ; src cursor
    mov r10b, al                  ; mode
    ; Zero the FCB name area (drive..rr = 80B).
    mov rcx, 80
    xor eax, eax
.zero_mf:
    mov [r8], al
    inc r8
    dec rcx
    jnz .zero_mf
    mov r8, rdi                   ; restore FCB base
    xor ecx, ecx                  ; ECX = wild flag
    test r10b, 1
    jz .noskip_mf
.skip_mf:
    mov al, [r9]
    call .is_sep_mf
    jnc .noskip_mf
    inc r9
    jmp .skip_mf
.noskip_mf:
    ; Drive: X: ?
    mov al, [r9]
    mov bl, [r9+1]
    cmp bl, ':'
    jne .nodrive_mf
    call .is_alpha_mf             ; AL = letter?
    jc .bad_mf
    call .to_upper_mf
    sub al, 'A'-1                 ; 1-based
    mov [r8 + FCB64.drive], al
    add r9, 2
    jmp .name_mf
.nodrive_mf:
    mov byte [r8 + FCB64.drive], 0
.name_mf:
    ; Blank-pad name+ext first.
    mov dword [r8 + FCB64.name+0], '    '
    mov dword [r8 + FCB64.name+4], '    '
    mov byte [r8 + FCB64.ext+0], ' '
    mov byte [r8 + FCB64.ext+1], ' '
    mov byte [r8 + FCB64.ext+2], ' '
    xor ebx, ebx                  ; name index 0..7
.nameloop_mf:
    cmp ebx, 8
    jae .namefull_mf
    mov al, [r9]
    test al, al
    jz .done_mf
    cmp al, '.'
    je .ext_mf
    cmp al, '*'
    je .star_name_mf
    push rax
    call .is_term_mf
    pop rax
    jc .done_mf
    cmp al, 'a'
    jb .store_nm
    cmp al, 'z'
    ja .store_nm
    sub al, 32
.store_nm:
    mov [r8 + FCB64.name + rbx], al
    cmp al, '?'
    jne .next_nm
    or ecx, 1
.next_nm:
    inc rbx
    inc r9
    jmp .nameloop_mf
.namefull_mf:
    ; Name full: skip until '.' or terminator ('*' inside still wild).
.fullskip_mf:
    mov al, [r9]
    test al, al
    jz .done_mf
    cmp al, '.'
    je .ext_mf
    cmp al, '*'
    jne .fullchk_mf
    or ecx, 1
    inc r9
    jmp .fullskip_mf
.fullchk_mf:
    push rax
    call .is_term_mf
    pop rax
    jc .done_mf
    inc r9
    jmp .fullskip_mf
.star_name_mf:
    or ecx, 1
    mov al, '?'
.fillq_nm:
    cmp ebx, 8
    jae .skip_to_dot_mf
    mov [r8 + FCB64.name + rbx], al
    inc rbx
    jmp .fillq_nm
.skip_to_dot_mf:
    inc r9                        ; consume '*'
.skip_more_nm:                    ; '*' eats the rest of the name field
    mov al, [r9]
    test al, al
    jz .ext_mf
    cmp al, '.'
    je .ext_mf
    push rax
    call .is_term_mf
    pop rax
    jc .ext_mf
    inc r9
    jmp .skip_more_nm
.ext_mf:
    mov al, [r9]
    cmp al, '.'
    jne .done_mf
    inc r9
    xor ebx, ebx                  ; ext index 0..2
.extloop_mf:
    cmp ebx, 3
    jae .extfull_mf
    mov al, [r9]
    test al, al
    jz .done_mf
    cmp al, '*'
    je .star_ext_mf
    push rax
    call .is_term_mf
    pop rax
    jc .done_mf
    cmp al, 'a'
    jb .store_ex
    cmp al, 'z'
    ja .store_ex
    sub al, 32
.store_ex:
    mov [r8 + FCB64.ext + rbx], al
    cmp al, '?'
    jne .next_ex
    or ecx, 1
.next_ex:
    inc rbx
    inc r9
    jmp .extloop_mf
.extfull_mf:
    mov al, [r9]
    test al, al
    jz .done_mf
    cmp al, '*'
    jne .extchk_mf
    or ecx, 1
    inc r9
    jmp .extfull_mf
.extchk_mf:
    push rax
    call .is_term_mf
    pop rax
    jc .done_mf
    inc r9
    jmp .extfull_mf
.star_ext_mf:
    or ecx, 1
    mov al, '?'
.fillq_ex:
    cmp ebx, 3
    jae .extconsume_mf
    mov [r8 + FCB64.ext + rbx], al
    inc rbx
    jmp .fillq_ex
.extconsume_mf:
    inc r9                        ; consume '*'
.skip_more_ex:                    ; '*' eats the rest of the ext field
    mov al, [r9]
    test al, al
    jz .done_mf
    push rax
    call .is_term_mf
    pop rax
    jc .done_mf
    inc r9
    jmp .skip_more_ex
.done_mf:
    mov rsi, r9
    mov eax, ecx
    and al, 1
    clc
    jmp .exit_mf
.bad_mf:
    xor esi, esi
    mov al, 0xFF
    stc
.exit_mf:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; Local char-class helpers (near, use AL/flags only; preserve nothing else).
.is_sep_mf:                       ; CF=1 if AL in " ,;=\t"
    cmp al, ' '
    je .yes_sep
    cmp al, ','
    je .yes_sep
    cmp al, ';'
    je .yes_sep
    cmp al, '='
    je .yes_sep
    cmp al, 9
    je .yes_sep
    clc
    ret
.yes_sep:
    stc
    ret
.is_term_mf:                      ; CF=1 if AL terminates a filespec
    test al, al
    jz .yes_term
    cmp al, 13
    je .yes_term
    cmp al, ' '
    je .yes_term
    cmp al, ','
    je .yes_term
    cmp al, ';'
    je .yes_term
    cmp al, '='
    je .yes_term
    cmp al, '+'
    je .yes_term
    cmp al, '/'
    je .yes_term
    cmp al, ':'
    je .yes_term
    cmp al, '"'
    je .yes_term
    cmp al, '['
    je .yes_term
    cmp al, ']'
    je .yes_term
    cmp al, '<'
    je .yes_term
    cmp al, '>'
    je .yes_term
    cmp al, '|'
    je .yes_term
    cmp al, 9
    je .yes_term
    clc
    ret
.yes_term:
    stc
    ret
.is_alpha_mf:                     ; CF=0 if AL is A-Z/a-z
    cmp al, 'A'
    jb .try_low_mf
    cmp al, 'Z'
    jbe .ok_alpha_mf
.try_low_mf:
    cmp al, 'a'
    jb .no_alpha_mf
    cmp al, 'z'
    ja .no_alpha_mf
.ok_alpha_mf:
    clc
    ret
.no_alpha_mf:
    stc
    ret
.to_upper_mf:                     ; AL -> upper
    cmp al, 'a'
    jb .done_up_mf
    cmp al, 'z'
    ja .done_up_mf
    sub al, 32
.done_up_mf:
    ret

; ------------------------------------------------------------
; fs_fcb_io64 — record read/write workhorse for FCB file handles
;   In: RDI = FCB64 ptr, RSI = record number (recsiz units, u64),
;       RDX = DMA buffer, ECX = record count, R8D = 0 read / 1 write.
;   Out: RAX = records transferred; CF 0 ok (read short at EOF is ok),
;        CF 1 hard fail (ATA/range/flush). Write-through FAT-first:
;        dir entry updated in RAM, then FAT flushed, then root flushed
;        (see crash model in include/fs.inc). FAT failure skips root.
;   Fixed allocation: R13=FCB R14D=recsiz R15=done R12=DMA R11=recno
;   R10D=spc_bytes R9=orig filsiz (all survive callees);
;   RAX/RCX/RDX/RSI/RDI/RBP/RBX reloaded per call (RBX is scratch:
;   the record count lives in a stack local because per-call RBX reuse
;   would otherwise destroy it across push/pop callees).
;   Locals (64B): [rsp]=ci [rsp+8]=intra [rsp+16]=cluster [rsp+24]=fresh
;   [rsp+32]=pos [rsp+40]=n [rsp+48]=count [rsp+56]=rw. Fresh clusters
;   are zeroed. Count AND rw live in stack locals (not RBX/R8D): RBX is
;   per-call scratch and R8D is caller-saved (clobbered by FAT helpers
;   across the record loop), so register copies would not survive.
; ------------------------------------------------------------
fs_fcb_io64:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    test ecx, ecx
    jz .io_zero
    test rdx, rdx
    jz .io_hard0
    test rdi, rdi
    jz .io_hard0
    cmp r8d, 1
    ja .io_hard0
    mov r13, rdi
    mov r12, rdx
    mov [rsp+48], rcx             ; count (RBX is per-call scratch)
    mov [rsp+56], r8d             ; rw flag (R8D is caller-saved)
    mov r11, rsi
    mov r15, 0
    call fs_mount_volume64
    test rax, rax
    jnz .io_hard
    mov r9, [r13 + FCB64.filsiz]  ; snapshot (dir sync compares live value)
    mov r14d, [r13 + FCB64.recsiz]
    test r14d, r14d
    jnz .have_rs_io
    mov r14d, 128
    mov [r13 + FCB64.recsiz], r14d
.have_rs_io:
    lea rbp, [rel fs_vol_dpb]
    movzx eax, byte [rbp + DPB64.clusmsk]
    inc eax
    imul eax, [rbp + DPB64.secsiz]
    mov r10d, eax                 ; spc_bytes
    test r10d, r10d
    jz .io_hard
.record_loop:
    cmp r15, [rsp+48]
    jae .io_ok
    mov rax, r11
    mul r14                       ; RDX:RAX = recno*recsiz
    test rdx, rdx
    jnz .io_hard                  ; absurd position
    mov [rsp+32], rax             ; pos
    cmp dword [rsp+56], 0
    jne .pos_ok
    cmp rax, [r13 + FCB64.filsiz]
    jae .io_ok                    ; read at/over EOF -> short, CF=0
.pos_ok:
    mov rax, [rsp+32]
    xor edx, edx
    div r10                       ; RAX=ci, RDX=intra
    mov [rsp], rax
    mov [rsp+8], rdx
    mov qword [rsp+24], 0         ; fresh = 0
    ; n = min(recsiz, spc - intra[, filsiz - pos for reads])
    mov eax, r10d
    sub eax, dword [rsp+8]
    cmp eax, r14d
    jbe .n1_io
    mov eax, r14d
.n1_io:
    cmp dword [rsp+56], 0
    jne .n2_io
    mov rcx, [r13 + FCB64.filsiz]
    sub rcx, [rsp+32]
    cmp rax, rcx
    jbe .n2_io
    mov rax, rcx
.n2_io:
    mov [rsp+40], rax             ; n
    ; Walk to cluster ci, allocating on the write path.
    mov eax, [r13 + FCB64.firclus]
    mov [rsp+16], rax
    cmp rax, 2
    jae .walk_io
    cmp dword [rsp+56], 0
    je .io_ok                     ; read, no head (pos<filsiz = corrupt) -> short
    call fs_alloc_cluster64
    test rax, rax
    jz .io_hard
    mov [r13 + FCB64.firclus], eax
    mov [r13 + FCB64.lstclus], eax
    mov [rsp+16], rax
    mov qword [rsp+24], 1         ; fresh
.walk_io:
    xor ecx, ecx                  ; k = 0
.walk_loop_io:
    cmp rcx, [rsp]
    jae .have_c_io
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov rbx, [rsp+16]             ; c (RBX is scratch; count is local)
    call fs_get_cluster64         ; -> RDI=next
    test rax, rax
    jnz .walk_bad_io
    cmp rdi, 2
    jb .walk_bad_io
    mov eax, [rbp + DPB64.maxclus]
    cmp rdi, rax
    ja .walk_bad_io
    mov [rsp+16], rdi             ; c = next
    inc rcx
    jmp .walk_loop_io
.walk_bad_io:
    cmp dword [rsp+56], 0
    je .io_ok                     ; read: chain ends -> short
    call fs_alloc_cluster64
    test rax, rax
    jz .io_hard
    mov rdi, rax                  ; new
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov rbx, [rsp+16]             ; link after current c
    mov rdx, rdi
    call fs_set_cluster64
    test rax, rax
    jnz .io_hard
    mov [rsp+16], rdi             ; c = new
    mov qword [rsp+24], 1         ; fresh
    inc rcx
    jmp .walk_loop_io
.have_c_io:
    lea rbp, [rel fs_vol_dpb]
    lea rdi, [rel fs_vol_iobuf]
    mov rbx, [rsp+16]
    call fs_file_read_cluster64
    test rax, rax
    jnz .io_hard
    cmp dword [rsp+56], 0
    jne .do_write_io
    ; read: iobuf+intra -> DMA + done*recsiz
    lea rsi, [rel fs_vol_iobuf]
    add rsi, [rsp+8]
    mov rdi, r12
    mov rax, r15
    imul rax, r14
    add rdi, rax
    mov ecx, [rsp+40]
    cld
    rep movsb
    jmp .rec_done_io
.do_write_io:
    cmp qword [rsp+24], 0
    je .have_buf_io
    lea rdi, [rel fs_vol_iobuf]   ; fresh cluster: zero so holes read 0
    xor eax, eax
    mov ecx, r10d                 ; spc_bytes (iobuf sized 32K max)
    cld
    rep stosb
.have_buf_io:
    mov rsi, r12                  ; DMA + done*recsiz -> iobuf+intra
    mov rax, r15
    imul rax, r14
    add rsi, rax
    lea rdi, [rel fs_vol_iobuf]
    add rdi, [rsp+8]
    mov ecx, [rsp+40]
    cld
    rep movsb
    lea rbp, [rel fs_vol_dpb]
    mov rbx, [rsp+16]
    lea rsi, [rel fs_vol_iobuf]
    call fs_file_write_cluster64
    test rax, rax
    jnz .io_hard
    mov ebx, [rsp+16]
    mov [r13 + FCB64.lstclus], ebx
    mov rax, [rsp+32]
    add rax, [rsp+40]
    cmp rax, [r13 + FCB64.filsiz]
    jbe .rec_done_io
    mov [r13 + FCB64.filsiz], rax
.rec_done_io:
    inc r15
    inc r11
    jmp .record_loop
.io_zero:
    xor r15d, r15d
.io_ok:
    cmp r15, 0
    je .io_ret_ok
    cmp dword [rsp+56], 0
    je .io_ret_ok
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [r13 + FCB64.name]
    call fs_dir_find64
    jc .io_hard
    mov eax, [r13 + FCB64.firclus]
    mov [rbx + DIRENT.firstclus], ax
    mov rax, [r13 + FCB64.filsiz]
    mov [rbx + DIRENT.size], eax
    ; Commit order is FAT-first: newly linked clusters reach stable
    ; storage BEFORE the directory entry that points at them, so a
    ; reset between the two leaves an orphan leak (reclaimable) and
    ; never a dangling entry pointing at free clusters. If the FAT
    ; flush fails the root flush is skipped (disk keeps the old
    ; consistent size/chain); if the root flush fails afterwards the
    ; leak is reported via CF=1.
    call fs_vol_flush_fat64
    test rax, rax
    jnz .io_hard
    call fs_vol_flush_root64
    test rax, rax
    jnz .io_hard
.io_ret_ok:
    mov rax, r15
    clc
    jmp .io_epi
.io_hard0:
    xor r15d, r15d
.io_hard:
    mov rax, r15
    stc
.io_epi:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
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
; --- Geometry validator test scratch (fs_test_geom, RAM-only, no ATA) ---
fs_geom_pre:    resb 16        ; guard before boot (0xA5 pattern)
fs_geom_boot:   resb 512       ; writable BPB copy for malformed cases
fs_geom_post:   resb 16        ; guard after boot (0x5A pattern)
fs_geom_dpb:    resb 64        ; scratch DPB for parse+validate
fs_geom_dpb_post: resb 16      ; guard after DPB
; --- Mounted real volume (LBA FS_VOL_LBA, tools/mkfat12.py) ---
; Sizes are the FS_VOL_*_BYTES policy constants (see include/fs.inc);
; fs_vol_validate64 proves a BPB fits them before any FAT/root read.
fs_vol_boot:    resb FS_VOL_BOOT_BYTES
fs_vol_dpb:     resb 64
fs_vol_fat:     resb FS_VOL_FAT_BYTES      ; 9 sectors, first FAT copy in RAM
fs_vol_root:    resb FS_VOL_ROOT_BYTES     ; 14 sectors, 224-entry root dir in RAM
fs_vol_iobuf:   resb FS_VOL_IOBUF_BYTES    ; cluster staging (spc up to 64)
fs_vol_mounted: resb 1
alignb 8
fs_vol_dirsec:  resq 1         ; cached root size in sectors
; --- Crash-consistency support (see include/fs.inc model) ---
; fs_fault_inject: test-only fault mask (FS_FAULT_*), 0 = normal.
; fs_scrub_marks: 512B visited bitmap (clusters 0..4095) for scrub/reclaim.
global fs_fault_inject
fs_fault_inject: resd 1
alignb 16
fs_scrub_marks: resb 512


