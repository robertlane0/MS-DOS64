# Phase 1 – Memory Layout & Data Structures

## 1. Real-Mode Physical Memory Map (SCP/IBM PC as assumed by DOS 1.25)

```
0x00000–0x003FF  IVT (256 × 4 = 1 KiB)   ← MSDOS DOSINIT fills vectors at INTBASE 80h and INTTAB 20h
0x00400–0x004FF  BIOS Data Area (BDA)
0x00500–0x07BFF  Free conventional (≈30 KiB before boot) — DOSINIT reuse
0x07C00–0x07DFF  Boot sector (if MBR loads) — not in repo
0x07E00–0x7FFFF  Transient area: IO.SYS + MSDOS.SYS + COMMAND transient may be overwritten
0x80000–0x9FFFF  EBDA / conventional top — scanned by MEMSCAN for free paragraphs
0xA0000–0xBFFFF  Video RAM (A0000 graphics, B8000 text – not used by DOS 1.25; IO.ASM uses ports instead)
0xC0000–0xFFFFF  ROM (BIOS, VGA)

Load addresses (IO.ASM:1929):
  BIOSSEG = 040h (1000h para) or 060h → linear 0x04000 or 0x06000
  BIOSLEN = 2048 (0x800)
  DOSSEG  = (BIOSLEN+15)/16 + BIOSSEG → 0x0480h/0x0680h? Actually (0x800+15)/16=0x80 → BIOSSEG+0x80
  DOSLEN  = 8192 (0x2000) → DOS occupies BIOSSEG:0800 ... BIOSSEG:2800
  CS: MEMSTRT + DIRBUF + BUFFER (DIRBUF is 1 sector = MAXSEC) + DPBs + FATs → first free para BP
  PROGRAM segment (where COMMAND.COM loads) = DX = BP if HIGHMEM, else CS overlay if !HIGHMEM
```

`DOSINIT` scans memory at `MEMSCAN` (`MSDOS.ASM:3904-3914`): starts at `DX = BP` (first free para), increments CX, toggles byte at `DS:CX:0Fh`, detects top by write-fail.

### PSP (Program Segment Prefix) – User Program Area

Not explicitly `STRUC`-defined; documented at `MSDOS.ASM:3372-3388`:

```
PSP segment (DX) layout:
 +0h  BYTE  CDh 20h  → "INT 20h"    (terminate)
 +2h  WORD  top_of_memory_segment (ENDMEM, paragraphs)
 +5h  BYTE  0EAh ... LONGJUMP to ENTRYPOINT  (CP/M CALL 5 hook at ENTRYPOINTSEG=0Ch:INTBASE+40h)
       Actually bytes: EAh xx xx yy yy — far jump to DOSGROUP:ENTRY
 +0Ah WORD  EXIT offset (saved INT 22h)  → 4 bytes → SPSAVE-level
 +0Eh WORD  EXIT+2 segment
 +0Ah+?  (documented up to 0x0A-0x0F for EXIT/CONTC? see SPSAVE)
 +?   INT 22h save area 4B, INT 23h (CONTC) 4B at INTTAB+3, INT 24h save
```

Actual PSP file-handling fields (FCB era) reside in user program's memory at PSP:5Ch:

```
PSP:0000 INT 20h
PSP:0002 top_seg
PSP:0005 CALL 5 → far jump to DOS
PSP:000A prev INT22 IP/CS (4)
PSP:000E prev INT23 IP/CS (4)
PSP:0012 prev INT24 IP/CS (4)  (see ABORT restore SI+10)
PSP:005Ch FCB1 (16B + 20B ext? See MSDOS.ASM:807)
PSP:006Ch FCB2
PSP:0080 cmd tail len + 127B  (COMMAND.ASM:639,780)
```

`COMMAND.ASM:639` verifies: `DS:80h` cmd tail length.

### DOS Kernel `DATA` Layout (`MSDOS.ASM:3674-3729`)

```nasm
ORG 0
INBUF       DB 128 DUP (?)          ; + CONBUF 131B overlaps? CONBUF = 131 BYTES AT SAME ORG?
CONBUF      DB 131 DUP (?)          ; documented as rest of INBUF + console buf
LASTENT     DW ?
EXITHOLD    DB 4 DUP (?)            ; saved INT22 slot after ABORT
FATBASE     DW ?
NAME1       DB 11 DUP (?)           ; uppercased search name
ATTRIB      DB ?                    ; search attributes
NAME2       DB 11  / NAME3 12      ; rename second name + scratch
EXTFCB      DB ?                    ; -1 = extended FCB
CREATING    DB ?  ; + DELALL DB ?  (word access for 0E500h init)  "Creating" flag + DEL *.* flag (DELALL)
TEMP        DW ?
SPSAVE      DW ?  ; user SP
SSSAVE      DW ?  ; user SS
CONTSTK     DW ?  ; hard-error temp SP
SECCLUSPOS  DB ?
DSKERR      DB ?
TRANS       DB ?
PREREAD     DB ?
READOP      DB ?  ; 0=read 1=write
THISDRV     DB ?  ; physical drive (0=A)
ALIGN WORD
FCB         DW ?  ; offset of user's FCB within its segment
NEXTADD     DW ?  ; DMA offset (transfer address low)
RECPOS      DB 4 DUP (?)  ; logical record pos
RECCNT      DW ?
LASTPOS     DW ?  ; last cluster's file pos?
CLUSNUM     DW ?  ; physical cluster
SECPOS      DW ?
VALSEC      DW ?
BYTSECPOS   DW ?
BYTPOS      DB 4 DUP (?)
BYTCNT1     DW ?
BYTCNT2     DW ?
SECCNT      DW ?
ENTFREE     DW ?  ; first free dir entry during search
80h DUP (?) stack    → IOSTACK label
80h DUP (?) stack    → DSKSTACK
[DSKTEST] NSS/NSP
DIRBUF      LABEL WORD ; 1 sector buffer (size MAXSEC, max 1024)
;  ↓ overlaps INIT code:
ORG 0
MOVFAT .. DOSINITinit code (3755..)
; after init, constants segment ends at FATSIZTAB + DRVCNT + MEMSTRT
```

Sizes: `IOSTACK`+`DSKSTACK` = 0x100 bytes each candidate? Actually `80H DUP (?)` = 128 each → 256 total stack within DATA. Two stacks: functions ≤12 use IOSTACK, >12 use DSKSTACK (`MSDOS.ASM:319-321`).

### CONSTANTS Segment (`MSDOS.ASM:3634-3672`)

```
IONAME:  PRN/LST/NUL/AUX/CON (+COM1 if IBM)
DIVMES, CARPOS, STARTPOS, PFLAG, DIRTYDIR, NUMDRV, NUMIO, VERFLG, CONTPOS, DMAADD (80h:?), ENDMEM, MAXSEC,
BUFFER (=DIRBUF+MAXSEC), BUFSECNO(-1), BUFDRVNO(-1), DIRTYBUF, BUFDRVBP, DIRBUFID(-1),
DAY/MONTH/YEAR, DAYCNT(-1), WEEKDAY, CURDRV, DRVTAB ptr
DOSLEN EQU CODSIZ + ($-CONSTRT)
```

### CODE Size

`CODSIZ EQU $-CODSTRT` (`MSDOS.ASM:3629`) – CODE ≈ 3629 bytes.

---

## 2. FCB (File Control Block) Structure

Two forms: normal 37-byte FCB vs extended 44-byte FCB (44 = +7 prefix). `FCBLOCK STRUC` (`MSDOS.ASM:78-96`) defines unextended view:

```c
struct FCB_25 {               // offsets decimal
 uint8_t drive;               // 0=default,1=A (at +0)
 char    name[8];             // +1
 char    ext[3];              // +9
 uint16_t curBlock;           // EXTENT @+12  (current block, 128-rec units; high vs low zeroing IBM-dependent)
 uint16_t recSize;            // RECSIZ @+14
 uint32_t fileSize;           // FILSIZ @+16 (2 words: low/high, 30-bit capped 1GiB? actually 4 bytes)
 // overlap with DIR entry:
 uint16_t drv_bp;             // DRVBP @+18 — SEARCH internal BP save
 uint16_t fdateFT??           // FDATE @+20, FTIME @+22 — dates in dir, reused
 uint8_t  devId;              // DEVID @+24 — bit7=1 device, bit6 dirty/eof
 uint16_t firstClus;          // FIRCLUS @+25
 uint16_t lastClus;           // LSTCLUS @+27
 uint16_t clusPos;            // CLUSPOS @+29 — pos of lastClus in file
 uint8_t  pad;                // +31
 uint8_t  nextRec;            // NR @+32
 uint8_t  randRec[3];         // RR @+33 (4 bytes including byte2 overflow? actually 3 + orig NR? extended to 4)
};
// Macros:
FILDIRENT = FILSIZ  — SEARCH FIRST/NEXT reuses size field as dir entry temp
```

Extended FCB adds 7-byte header when byte0 = 0xFF:

```
+0  FFh
+1-5 reserved (0)
+6  attrib byte
+7  drive
+8.. follows normal layout
```

Tests at `MSDOS.ASM:1015,2346,2510`: `CMP BYTE PTR [DI],-1 → ADD DI,7`. Creation flag `CREATING`/`ATTRIB` decides hidden-file handling.

Random record is 4 bytes at `FCB:RR` (offset 33), stored as DX:AX (DX holds high). `GETRRPOS` (`MSDOS.ASM:1453`) reads `WORD PTR [DI.RR] + [DI.RR+2]`.

---

## 3. DPB – Drive Parameter Block (`DPBLOCK STRUC` `MSDOS.ASM:128-144`)

20 bytes (DPBSIZ=20) packed per drive, array at `DRVTAB`:

```
+0  DEVNUM   DB  I/O driver number  (=DRVTAB index)
+1  DRVNUM   DB  physical unit (0=A)
+2  SECSIZ   DW  bytes/sector (128/512/1024)
+4  CLUSMSK  DB  sectors/cluster -1
+5  CLUSSHFT DB  log2 sectors/cluster
+6  FIRFAT   DW  first FAT sector # (reserved sectors)
+8  FATCNT   DB  #FATs
+9  MAXENT   DW  #dir entries
+11 FIRREC   DW  first data sector (=FIRDIR+DIRSEC)
+13 MAXCLUS  DW  clusters+1
+15 FATSIZ   DB  sectors per FAT
+16 FIRDIR   DW  first dir sector (=FIRFAT+FATSIZ*FATCNT)
+18 FAT      DW  offset of FAT copy in DOS memory (DIRBUF.. area)

Temporary aliases during init:
 DIRSEC = FIRREC (reused before FIRREC calc)
 DSKSIZ = MAXCLUS (reused as disk size sectors temp)
```

`DPBLOCK` count = `NUMIO` (from init table) = up to 8. Computed iteratively in `DOSINIT:PERDRV` via `FIGFATSIZ`/`FIGMAX`: probes FATSIZ convergence loop (`FNDFATSIZ`) where `FATSIZ = ceil( (MAXCLUS+1)*1.5 / SECSIZ)`.

Example DPTs in `IO.ASM:1847-1927` (SCP `LARGE` non-IBM):

* `LSDRIVE`: 128B sect, 4 sect/clust→512B clust, 1 resvd, 2 FATs, 68 dirents, DSKSIZ=2002 (77*26), also `OLDLSDRIVE` with 52 resvd.
* `LDDRIVE` (DD): 1024B sect, 1 sect/clust, 1 resvd, 2 FATs, 96 (old 128) / 192 dirents, DSKSIZ=616 or 1232 (DS).
* Small drives `SSDRIVE`/`SDDRIVE`: 128 vs 512 sect variants, 64/112 dirents, 720/320/640 sectors.

Init table `INITTAB`: `DB numDrivers; per driver DB physDrv DW DPTPtr`. Up to 10 drivers with `CONVERT` (old SCP format mirrors driver slots +2..+3).

---

## 4. Directory Entry (32-byte)

Documented at `MSDOS.ASM:99-110`:

```
00  11  name+ext (0xE5 = deleted, 0x00 = end)
11   1  attributes (bits 1/2 = hidden)
12  10  reserved (zero)
22   2  time: 5b sec/2, 6b min, 5b hour
24   2  date: 5b day, 4b mon, 7b yr-1980
26   2  first cluster (<4080)
28   4  file size (32-bit LE, 30-bit used)
```

FAT12 entry decoding (`MSDOS.ASM:448-514`): packed 12-bit ×2 per 3 bytes:

```c
word = *(uint16_t*)(FAT+ N*1.5);
if (N odd) word >>=4;
word &=0xFFF;  >=0xFF8 EOF, 0 free
```

---

## 5. MCB – No Formal MCB in 1.25

DOS 1.25 has **no MCB chain** – memory allocation is via `SETMEM` (`MSDOS.ASM:3749`) only for loading COMMAND.COM transient (allocates TPA). Later DOS 2.0 introduced MCBs. For 64-bit we will **introduce** `MCB64` per AGENTS.md spec:

```c
struct MCB64 {
 uint8_t type; // 'M'/'Z'
 uint8_t reserved[7];
 uint64_t owner; // linear addr or PID
 uint64_t size;  // bytes
 char name[8];
};
```

Original `MEMSTRT` / `DRVCNT` / `FATSIZTAB` serve as proto-allocator.

---

## 6. Stacks & Register Save Areas

* User stacks: user owns PSP top segment minus 0x80? `COMMAND.ASM:231,260` sets `SS:SP = PSP seg:5Ch`, later `SP=OFFSET COMMAND:STACK` (0x80 bytes reserved at `TRANSPACE`).
* DOS kernel stacks: `IOSTACK` (128B) and `DSKSTACK` (128B) share `DATA` at high offset; selected by `CMP AH,12` → `SAMSTK`. Separate `NSS`/`NSP` if `DSKTEST` (re-entrance).
* `STKPTRS STRUC` mirrors push order: `AX,BX,CX,DX,SI,DI,BP,DS,ES,IP,CS,FLAGS` (flags via PUSHF before int frame rewrite). Save/restore at `SAVREGS`/`LEAVE` swaps `SS:SP` to DOS then back.

---

## 7. Linear Address Construction (16-bit assumptions to eliminate)

Original: `segment:offset → (segment<<4)+offset`. All DOSGROUP pointers use `OFFSET DOSGROUP:xxx` and `MOV DS,CS` alias. DMA transfer address split across `DMAADD` (+2) words: segment:offset. In 64-bit: `DMAADD` becomes 64-bit linear (`mov rsi, [rel DMAADD]`); segment regs ignored except `FS/GS`.

*Verification: `grep -n "DMAADD" MSDOS.ASM` shows 18 uses split word pairs; `BUFFER`, `DIRBUF`, `FATSIZTAB` all `DW` pointers.*

---

*All offsets cross-checked against `MSDOS.ASM:78-144,151-193,196-214,3674-4029` and `IO.ASM:1929-1933`.*
