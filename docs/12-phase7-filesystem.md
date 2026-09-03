# Phase 7 Completion Report — File System Adaptation (FAT12 on LBA)

**Date:** 2026-09-03
**Branch:** `phase7-filesystem` (building on `phase6-memory`)
**Engineer:** Muse Spark
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 7 (AGENTS.md §Phase 7, docs/01 §2.2, docs/03 §3-4) is **complete and verified**.
DOS 1.25's FAT12 layer (`UNPACK MSDOS.ASM:448`, `PACK:484`, `GETENTRY:632`,
`FATREAD:936`, `DIRREAD:1194`, `DREAD:1218`, `DWRITE:1325`,
`FIGFATSIZ/FIGMAX:3996`, CHS via `FAR PTR BIOSREAD/WRITE`) is now a flat
64-bit filesystem on the native ATA LBA28 PIO driver (Phase 5, Option C):
BPB→DPB init, cluster→LBA mapping, 12-bit chain pack/unpack with EOF/free
semantics, root-dir find (deleted/end/wildcard), `DREAD`/`DWRITE`/`DIRREAD`
via `ata_read/write_lba28`, multi-cluster file read by chain walk, and
`FCB64` open with 64-bit `filsiz`/`rr`/DMA-linear (was split `DMAADD` words).

6 new tests extend the harness to **27 total — all 27 PASS** on Bochs and QEMU,
no `#UD/#GP/#PF`, no BIOS calls.

```
 Bochs / QEMU serial.log after Phase 7 (tail):

  [22] BPB->DPB + cluster->LBA + FAT sector... PASS
  [23] FAT12 chain pack/unpack + EOF/free... PASS
  [24] Root-dir find/delete/end/wildcard... PASS
  [25] ATA DREAD/DWRITE + DIRREAD (LBA)... PASS
  [26] Multi-cluster file read via chain... PASS
  [27] FCB64 open + 64-bit filsiz/rr/DMA... PASS

 Summary: 27 passed, 0 failed
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
 Phase6 memory management (MCB64): ALL TESTS PASS
 Phase7 filesystem adaptation (FAT12): ALL TESTS PASS
```

---

## 1. Scope (AGENTS.md Phase 7 checklist)

| Requirement | Implementation | Test |
|---|---|---|
| Keep FAT12 format | 12-bit packed entries, `DI & 0xFFF`, odd `SHR 4` / even direct (DOS `UNPACK` algorithm preserved), `0xFF8+` EOF, `0xFF7` bad, `0` free | `[23]` chain 2→3→4→EOF, odd/even, nibble preservation, EOF/free |
| Replace disk layer (BIOS INT13 → ATA, CHS→LBA) | `fs_dread64/fs_dwrite64` wrap `ata_read/write_lba28`; `LBA=(C*HPC+H)*SPT+S-1` stays in `chs_to_lba` (Phase 5); absolute record `DX` == LBA 1:1 | `[25]` pattern write/readback at LBA 500, `DIRREAD` block→LBA |
| Convert FAT12 parsing to 64-bit | `fs_bpb_parse64`: BPB bytes/sec, sec/clus→`clusmsk/shft` (`log2`), `firfat/fatcnt/maxent/fatsiz→firdir→dirsec→firrec→maxclus` (`FIGMAX` formula) | `[22]` 1.44M BPB → 512/0/0/1/2/224/9/19/33/2848 |
| Update directory handling | `DIRENT` 32B struct, `fs_dir_find64` (`0x00` end, `0xE5` skip, `?` wildcard per `WILDCRD`), `firstclus/size/attr` getters | `[24]` find/skip/end/wildcard/attr |
| Rewrite open/read/write (FCB 1.x style) | `fs_fcb_open64` (name→entry→`firclus/lstclus/filsiz/ftime/fdate`, `recsiz` default 128), `fs_file_read_cluster64` (cluster→LBA→ATA) | `[26]` 2-cluster file, `[27]` open fills 7/123456/128 |
| 64-bit buffer pointers/handles/positions | `filsiz/rr/drvbp` `dq`, `RR*recsiz` 64-bit `IMUL` (8 GiB vector), `dma_get/set_linear` `dq` (was split words) | `[27]` 4 GiB `filsiz`, `0x1000000*512=0x200000000`, DMA `0x200000/0x12345678` |

New exports (`src/kernel/fs64.asm`, 19 globals): `fs_bpb_parse64`,
`fs_cluster_to_lba64`, `fs_fat_sector64`, `fs_get/set_cluster64`,
`fs_is_eof/free64`, `fs_dir_find64`, `fs_dir_get_firstclus/size/attr64`,
`fs_dread/dwrite64`, `fs_dir_read/write64`, `fs_fcb_open64`,
`fs_file_read_cluster64`, `fs_test_bpb/chain/dir/lba_io/file_read/fcb`.
New include (`include/fs.inc`): `DIRENT` struc, BPB offsets, `FAT12_*`,
`FS_SCRATCH_LBA 500` / `FS_FILE_LBA_BASE 510`.

---

## 2. What Was Built

### 2.1 `fs_bpb_parse64` — BPB→DPB (DOSINIT `PERDRV`/`FIGMAX` analog)

Reads the 512 B boot sector at BPB offsets 11–32, validates
`secsiz ∈ {128,256,512,1024,2048,4096}`, power-of-two `secPerClus ≤ 64`,
`fatcnt 1..4`, non-zero `reserved/maxent/tot/fatsiz`, then computes
`clusmsk/shft`, `firdir = firfat+fatsiz*fatcnt`,
`dirsec = (maxent*32+secsiz-1)/secsiz`, `firrec = firdir+dirsec`,
`maxclus = (totsec-firrec)>>shft+1`. Reference vector is the standard
1.44M BPB (512,1,1,2,224,2880,F0,9,18,2 → firdir 19, firrec 33, maxclus 2848).
Zero-`fatsiz` BPBs are rejected (iterative `FIGFATSIZ` documented as fallback,
not needed when BPB carries the size — all FAT12 BPBs since DOS 2.0 do).

### 2.2 `fs_cluster_to_lba64` / `fs_fat_sector64` — addressing

`cluster→LBA = firrec+(cluster-2)*(clusmsk+1)` with DOS `JA` bounds
(`2..maxclus` inclusive, `MSDOS.ASM:460`). Absolute record numbers
(`DREAD DX`) equal LBAs 1:1, so no CHS remains on the I/O path.
`fat_sector = firfat+(cluster+cluster/2)/secsiz`, remainder = intra-sector
offset; the `511→512` cross-sector edge (cluster 341→342 at 512 B) is tested.

### 2.3 `fs_get/set_cluster64` — UNPACK/PACK (flat)

Same packed algorithm as `MSDOS.ASM:448-514` (`offset = clus+clus/2`,
odd `SHR 4`, mask `0xFFF` / preserve `0x000F` vs `0xF000`), but with
`[rsi+offset]` flat base, `RBX` cluster, `RBP` DPB bounds, `RDI/RDX` values.
Out-of-range returns `0xFFF` + `RAX=1/CF=1` (DOS `HURTFAT` analog without
the `INT 24h` trip).

### 2.4 `fs_dir_find64` — GETNAME/FINDNAME (simplified)

Linear scan `0..maxent-1`, entry = base+index*32. `0x00` stops (end),
`0xE5` skips (deleted, `MSDOS.ASM:590-616`), `?` matches any char
(`WILDCRD`), 11-byte space-padded compare. Returns `RBX` = entry or `0+CF`.

### 2.5 `fs_dread/dwrite/dir_read/dir_write64` — DREAD/DWRITE/DIRREAD

Thin ATA wrappers: `DIRCOMP` (`firdir+AL`, `MSDOS.ASM:1113`) then
`ata_read/write_lba28` count 1. `HARDERR` retry/`INT 24h` is dropped —
errors return `RAX=1` for the caller (Abort/Retry/Ignore lives in Phase 8+).

### 2.6 `fs_fcb_open64` / `fs_file_read_cluster64` — OPEN + file read

`FCB name/ext` (11 contiguous at `FCB+1`, `FCBLOCK MSDOS.ASM:78`) →
`dir_find` → fill `firclus/lstclus/cluspos=0`, `filsiz` zero-extended
`dword→qword`, `ftime/fdate` from dir `+22/+24`, `recsiz` default 128.
Cluster read = `cluster_to_lba` + `ata_read` of `secPerClus` sectors in a
caller buffer. Full `SETUP`/`LOAD`/`STORE` record mapping stays Phase 8 work.

---

## 3. Bugs Found & Fixed (via QEMU serial FAIL isolation)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `[22]` FAIL (also broke `[26]` file reads) | `fs_cluster_to_lba64` saved LBA in `ECX`, then `pop rcx` restored caller value before `mov eax,ecx` — returned garbage | return LBA directly in `EAX` across pops (POP preserves RAX) |
| 2 | `[24]` HELLO not found | test entry built as `HELLO   OM ` — `dword [5]='   C'` wrote `C` to byte 8, then `dword [8]='OM '` overwrote it | explicit byte stores for bytes 8/9/10 (`C/O/M`) |
| 3 | `[26]` chain walk garbage | `RSI` (FAT base) clobbered by interleaved ATA reads (`mov rsi,rax` LBA) before `fs_get_cluster` | `lea rsi,[fs_fat_buf2]` before walk |
| 4 | build error `cannot use high byte register` | `mov dh,[r11+r8]` — `DH` illegal with REX (r11/r8) | `mov al,[r11+r8]` + `cmp dl,al` |
| 5 | `warning: signed dword exceeds bounds` ×2 | `cmp rbx,0x100000000` — `cmp r64,imm` takes imm32 only | `mov rax,imm64` then `cmp` |
| 6 | latent clobbers (no failure, hardened) | `mov dword [ext],'TXT'` wrote 4 B over `extent`; `mov dword [8],'TXT'` over `attr` | byte stores for 3-char fields |

Total: 6 defects (1 return-value, 2 test-data, 1 calling-convention, 1 encoding,
1 hygiene), all reproduced on QEMU before fixing; Bochs confirms.

---

## 4. Verification

```bash
make clean && make
# mbr.bin 512 (55 aa), stage2.bin ~1K, kernel.elf 79432, kernel.bin 22644 (44 sectors ≤ 64)

# QEMU
timeout 15 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# → 27 passed, 0 failed + 5× ALL TESTS PASS

# Bochs (target)
rm -f bochs.log serial.log build/dos64.img.lock && timeout 30 bochs -f bochsrc.txt -q
# → serial.log identical 27 PASS; bochs.log: no #GP/#UD/#PF (only SNDCTL notice)
```

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | ~1K | ≤ 15-sector slot |
| `build/kernel.bin` | 22644 (44 sectors @16) | ≤ 64 (`KERNEL_SECTORS`) |
| `build/dos64.img` | 10 M | MBR + stage2@1 + kernel@16 |

Scratch discipline: FS tests use LBA 500–511 only (kernel 16–79, ATA test 100
untouched); `[25]`/`[26]` zero their scratch after verify. Synthetic 1.44M
geometry is RAM-only (parse/math tests); file-data tests remap `firrec→510`
so `cluster→LBA` hits scratch, never the real image.

---

## 5. Checklist (AGENTS.md Phase 7)

- [x] Convert FAT12 parsing code to 64-bit (`fs_bpb_parse64`, `get/set_cluster`)
- [x] Update directory entry handling (`DIRENT`, `dir_find`, firstclus/size/attr)
- [x] Rewrite file open/read/write functions (`fcb_open`, `file_read_cluster`, `dread/dwrite`)
- [x] Convert FCB-based operations (`FCB64` 64-bit `filsiz/rr`, `recsiz` default)
- [x] Buffer pointer handling 64-bit (`dma linear dq`, `RDI` linear buffers)
- [x] Boot + 27 PASS on Bochs & QEMU, no faults

**Next:** Phase 8 PSP/process loader (64-bit `PSP64` already in `include/psp.inc`;
`fs_fcb_open`/`file_read_cluster` are the loader's disk primitives).
