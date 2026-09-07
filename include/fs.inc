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

; --- Phase 7 scratch LBAs on dos64.img (IMG_MB, see Makefile) ---
; Kernel occupies [KERNEL_LBA, KERNEL_LBA+KERNEL_SECTORS).
; ATA Phase-5 test uses LBA 100.
; Phase-7 FS tests use 500..511 (12 sectors) — safely beyond kernel, below end.
%define FS_SCRATCH_LBA   500
%define FS_SCRATCH_LBA2  501
%define FS_FILE_LBA_BASE 510  ; file-data base when DPB firrec remapped for test [26]

; --- Reserved filesystem test namespace (destructive self-tests only) ---
; Tests 71/83 (SELFTEST_DESTRUCTIVE) are the ONLY writers to the live
; volume, and they use ONLY these names: SCRATCH.TXT + RENAMED.TXT (71)
; and CRASH.TXT (83). All other volume files (HELLO.TXT, README.TXT,
; TEST.COM, DATA.BIN) are non-test files and must survive every test
; cycle unchanged — both tests verify this pre- and post-run via
; fs_vol_read_file64 + scrub/mirror checks. Mount-time recovery: each
; destructive test starts with delete-both + discard/remount + reclaim +
; heal + scrub, so an interrupted run (power loss between FAT/root/data
; writes leaves only leaks per the crash model below) is recovered
; idempotently by the next boot. Never create these three names from the
; shell or stamper; `tools/check_volume_clean.py` treats their presence
; (or any orphan/mirror mismatch) as a dirty volume. Smoke
; (RUN_SELFTEST without SELFTEST_DESTRUCTIVE) never creates them.
; --- Real on-image FAT12 volume (tools/mkfat12.py, 1.44M geometry) ---
; Extent [FS_VOL_LBA, FS_VOL_LBA+FS_VOL_TOTSEC): boot+BPB, 2x9 FAT,
; 14-sec root, data clusters 2..2848. Must stay clear of the kernel
; extent [KERNEL_LBA, KERNEL_LBA+KERNEL_SECTORS), ATA scratch (200),
; and FS scratch (500..511).
; Single source of truth: the Makefile disk-layout block generates
; build/include/layout.inc, which defines FS_VOL_LBA / FS_VOL_TOTSEC
; (aliases of VOL_LBA / VOL_SECTORS). Do not hardcode values here.
%include "build/include/layout.inc"

; --- Mounted-volume cache policy (fs_mount_volume64, fs_vol_validate64) ---
; The mount path caches the volume in fixed BSS buffers (see fs64.asm).
; A parsed BPB must prove it fits these buffers BEFORE any multi-sector
; ATA read occurs; otherwise mount fails with FS_MOUNT_GEOM_ERR (2),
; distinct from raw ATA I/O failure (1). Supported on-disk profile:
; 512 B sectors, <=9 FAT sectors (4608 B), <=224 root entries (7168 B),
; cluster (spc*secsiz) <= 32 KiB iobuf. Generic BPB parsing stays in
; fs_bpb_parse64; this policy is the mount boundary.
%define FS_VOL_BOOT_BYTES  512    ; fs_vol_boot: single boot sector
%define FS_VOL_FAT_BYTES   4608   ; fs_vol_fat: 9 sectors, first FAT copy
%define FS_VOL_ROOT_BYTES  7168   ; fs_vol_root: 14 sectors / 224 entries
%define FS_VOL_IOBUF_BYTES 32768  ; fs_vol_iobuf: cluster staging (64*512 max)
%define FS_VOL_SECSIZ      512    ; required bytes/sector for mount
%define FS_MOUNT_OK        0
%define FS_MOUNT_IO_ERR    1      ; ATA/boot-sig/parse failure
%define FS_MOUNT_GEOM_ERR  2      ; unsupported geometry (buffer/volume proof)

; --- Crash-consistency model (FAT12 has no journal; ordering is the fix) ---
; Invariants on disk after every completed op and after recovery:
;   I1 no-dangling: every cluster reachable from a live root entry is marked
;      allocated (!=0) in FAT1 (and FAT2 once healed). DIR never points to free.
;   I2 leaks-only: allocated-but-unreachable clusters are safe orphans,
;      reclaimable via fs_vol_reclaim_orphans64 (never corruption).
;   I3 chain: 2..maxclus, EOF-terminated (>=0xFF8), hop-bounded, no cycles;
;      size <= clusters*spc_bytes; size>0 requires firstclus!=0.
;   I4 mirrors: FAT1 == FAT2 byte-for-byte (healed at mount FAT1->FAT2).
;   I5 entries: firstclus in range (0 iff empty), 0x00 end / 0xE5 deleted.
; Orderings (crash between any two sector writes leaves only leaks):
;   extend/overwrite: data -> FAT flush -> root flush (never root before FAT).
;   truncate/shrink:  root flush (new smaller size) -> FAT flush (free tail).
;   delete:           root flush (0xE5) -> FAT flush (free chain).
;   create/rename:    single root flush (no FAT dependency).
;   FAT mirrors:      FAT1 then FAT2; mount heals FAT2 from FAT1 on mismatch.
; Failure rule: if the first metadata flush fails, the second is skipped
;   (disk stays at the old consistent state); if the second fails, the
;   caller returns CF=1 with an orphan leak on disk (safe, reclaimable).
; Power-loss consistency here is crash-ordering + mount healing, NOT a
; transactional filesystem: torn multi-sector writes within one FAT/root
; copy cannot be rolled back, only made deterministic (FAT1 wins).

; --- Fault-injection control (tests only; 0 in normal operation) ---
; fs_fault_inject bits force the next flush to fail WITHOUT writing,
; simulating a reset between metadata writes. FAT2 failure is special:
; copy1 is already on disk when copy2 is skipped, leaving divergent
; mirrors for the mount healer to reconcile. Sticky until cleared by test.
%define FS_FAULT_NONE  0
%define FS_FAULT_FAT1  1      ; fail first FAT copy write
%define FS_FAULT_FAT2  2      ; fail second FAT copy write (after copy1)
%define FS_FAULT_ROOT  4      ; fail root flush

; --- Scrub status bits (fs_vol_scrub64 RAX bitmask; 0 = clean) ---
%define FS_SCRUB_CLEAN    0
%define FS_SCRUB_DANGLING 1   ; live entry reaches free/bad/oob/truncated chain
%define FS_SCRUB_XLINK    2   ; one cluster reachable from two live entries
%define FS_SCRUB_MIRROR   4   ; FAT1 != FAT2 on disk

%endif
