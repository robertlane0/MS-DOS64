; MS-DOS64 include/fs.inc — Phase 7: FAT12 filesystem structures (64-bit)
; Replaces MSDOS.ASM DIR entry layout (MSDOS.ASM:99-110), DPBLOCK (128-144),
; and BPB handling in DOSINIT FIGFATSIZ/FIGMAX (MSDOS.ASM:3996-4017).
; All pointers flat 64-bit linear; sector numbers are absolute LBA (== DREAD DX).
; Original DREAD/DWRITE used BIOS INT13 via FAR PTR BIOSREAD/WRITE (MSDOS.ASM:1290,1337);
; 64-bit uses ATA LBA28 PIO (src/drivers/ata.asm) — see fs_dread64/fs_dwrite64.

%ifndef FS64_INC
%define FS64_INC

%include "include/dpb.inc"
%include "include/fcb.inc"

; --- On-disk BPB offsets within 512-byte boot sector (FAT12) ---
; Standard IBM BPB starting at boot+11 (see FAT spec, DOS 2.0+ BPB).
%define BPB_BytsPerSec   11    ; WORD bytes/sector (512)
%define BPB_SecPerClus   13    ; BYTE sectors/cluster (1)
%define BPB_RsvdSecCnt   14    ; WORD reserved sectors (=FIRFAT)
%define BPB_NumFATs      16    ; BYTE #FATs (=FATCNT)
%define BPB_RootEntCnt   17    ; WORD root dir entries (=MAXENT)
%define BPB_TotSec16     19    ; WORD total sectors (if 0 use TotSec32)
%define BPB_Media        21    ; BYTE media descriptor (F0/F8/FC...)
%define BPB_FATSz16      22    ; WORD sectors per FAT (=FATSIZ)
%define BPB_SecPerTrk    24    ; WORD sectors/track (CHS geometry, 18 for 1.44M)
%define BPB_NumHeads     26    ; WORD heads (2 for 1.44M)
%define BPB_HiddSec      28    ; DWORD hidden sectors
%define BPB_TotSec32     32    ; DWORD total sectors (if TotSec16==0)
%define BPB_BootSig      510   ; WORD 0xAA55

; --- On-disk directory entry (32 bytes, MSDOS.ASM:99-110) ---
struc DIRENT
    .name       resb 11   ; +0  8.3 name+ext, 0x00=end 0xE5=deleted
    .attr       resb 1    ; +11 attributes (0x20 archive, 0x10 dir, 0x08 vol, 0x02 hidden)
    .reserved   resb 10   ; +12 reserved (zero; NT/lowercase in later DOS)
    .time       resw 1    ; +22 time (5s/2,6m,5h)
    .date       resw 1    ; +24 date (5d,4m,7y-1980)
    .firstclus  resw 1    ; +26 first cluster (<4080 for FAT12)
    .size       resd 1    ; +28 file size LE (30-bit used in 1.25)
endstruc
%define DIRENT_SIZE 32

; --- FAT12 cluster constants (MSDOS.ASM UNPACK/PACK, FATREAD) ---
%define FAT12_FREE   0x000
%define FAT12_BAD    0xFF7
%define FAT12_EOF_MIN 0xFF8
%define FAT12_EOF    0xFFF
%define FAT12_MAXCLUS 4080  ; clusters <4080 valid (MSDOS dir firstclus comment)

; --- Phase 7 scratch LBAs on dos64.img (10M, ~20480 sectors) ---
; Kernel occupies LBA 16..79 (64 sectors). ATA Phase-5 test uses LBA 100.
; Phase-7 FS tests use 500..511 (12 sectors) — safely beyond kernel, below end.
%define FS_SCRATCH_LBA   500
%define FS_SCRATCH_LBA2  501
%define FS_FILE_LBA_BASE 510  ; file-data base when DPB firrec remapped for test [26]

%endif
