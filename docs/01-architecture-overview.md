# Phase 1 – Architecture Analysis: MS-DOS 1.25 (86-DOS) Overview

> Generated: 2026-08-30 · Source: MS-DOS v1.25 (MIT, Tim Paterson, Microsoft) — 5 asm files totaling **13,580 lines**.
> Assembler: Seattle Computer Products 8086 Assembler dialect (non-NASM, `PUT`, `SEGMENT AT`, `IF` macros).
> Target conversion: x86-64 long mode, flat addressing, BIOS MBR boot.

---

## 1. Repository Inventory

| File | Lines | Role | Modern Equivalent |
|------|------:|------|-------------------|
| `MSDOS.ASM` (incl. `STDDOS.ASM` wrapper) | 4030 (+23) | Kernel: FAT12, FCB I/O, INT vectors, memory mgmt | `src/kernel/` |
| `IO.ASM` | 1933 | I/O System = IO.SYS: console, aux, printer, floppy drivers + `INIT` loader | `src/drivers/` + `src/boot/stage2` |
| `COMMAND.ASM` | 2165 | COMMAND.COM: resident (handlers) + init + transient (parser + 10 builtin cmds) | `src/kernel/shell/` |
| `ASM.ASM` | 4005 | SCP 8086 Assembler v2.44 – self-hosting assembler (tool, not OS) | `tools/` (preserve, not port) |
| `TRANS.ASM` | 1212 | Z80→8086 translator – tool | `tools/` |
| `HEX2BIN.ASM` | 213 | Intel HEX→binary converter – tool | `tools/` |
| `STDDOS.ASM` | 23 | Build wrapper: `MSVER=TRUE`, `IBM=FALSE`, `HIGHMEM=FALSE` → `INCLUDE MSDOS.ASM` | Build config |
| **Total OS** | **~8,128** | Core OS | — |
| **Total tools** | **~5,430** | Not ported to kernel | — |

All original files use `ORG 100H / PUT 100H` (CP/M .COM model) and real-mode segmentation.

---

## 2. Module Responsibilities

### 2.1 Boot / Load Chain (in `IO.ASM`)

```
BIOS MBR (not in repo, supplied by PC BIOS) → IO.SYS (IO.ASM)
  │
  ├─ BIOSSEG = 040H (non-IBM) / 060H (IBM)  [IO.ASM:74-76]
  ├─ DOSSEG = (BIOSSEG*16 + BIOSLEN +15)/16  [IO.ASM:1929]
  │         BIOSLEN=2048, DOSLEN=8192 → DOS immediately above IO.SYS
  ├─ INIT (IO.ASM:130): sets SS:SP below BIOSSEG*16, installs INT 64h (keyboard),
  │     inits 9513 timer (4 regs), optional Multiport Serial (4 regs + 2 baud),
  │     REP MOVSW DOS from BIOSSEG+BIOSLEN → DOSSEG, calls DOSINIT,
  │     patches INT 37/38 → DIRECTREAD/DIRECTWRITE, loads COMMAND.COM via FCB
  └─ Fallback: prints "Error in loading Command Interpreter" / "Insert DOS disk" and halts (STALL JP STALL)
```

*No MBR in repo — SCP assumed pre-loaded IO.SYS+MSDOS.SYS via external boot. For 64-bit we must write MBR.*

### 2.2 Kernel – `MSDOS.ASM` (`DOSGROUP = CODE + CONSTANTS + DATA`)

**Three segments grouped as `DOSGROUP`:**

* `CODE SEGMENT` – all executable code, `ASSUME CS:DOSGROUP,DS:DOSGROUP,ES:DOSGROUP,SS:DOSGROUP`, origin 0 → `JMP DOSINIT`
* `CONSTANTS SEGMENT BYTE` – `IONAME`, `DIVMES`, `CARPOS`, `DRVTAB` ptr, `NUMIO`, etc.
* `DATA SEGMENT WORD` – overlaps init code; contains `INBUF` (128B), `CONBUF` (131B), `FCB` fields, stacks, `DIRBUF`

**Entry points (DOSGROUP offsets):**

| Label | Address | Purpose |
|-------|---------|---------|
| `CODSTRT` | 0 | `JMP DOSINIT` |
| `COMMAND` | – | System-call entry via INT 21h/33 (AH=MAXCOM check) |
| `ENTRY` | – | `CALL 5` long-call entry (CP/M compat), decodes `CL` |
| `ABORT` | INTBASE | Terminate |
| `ENTRYPOINT` = INTBASE+40h | `C0H:40h` long jump to `ENTRY` | CP/M `CALL 5` vector |

**Dispatch table** `DISPATCH` at `MSDOS.ASM:349` – 47 vectors (0-46):

```
00 ABORT        10 BUFIN        20 SEQRD       30 SETATTRIB   40 MAKEFCB
01 CONIN        11 CONSTAT      21 SEQWRT      31 GETDSKPT    41 GETDATE
02 CONOUT       12 FLUSHKB      22 CREATE      32 USERCODE    42 SETDATE
03 READER       13 DSKRESET     23 RENAME      33 RNDRD       43 GETTIME
04 PUNCH        14 SELDSK       24 INUSE       34 RNDWRT      44 SETTIME
05 LIST         15 OPEN         25 GETDRV      35 FILESIZE    45 VERIFY
06 RAWIO        16 CLOSE        26 SETDMA      36 SETRNDREC   46 (MAXCOM)
07 RAWINP       17 SRCHFRST     27 GETFATPT    37 SETVECT
08 IN           18 SRCHNXT      28 GETFATPTDL  38 NEWBASE
09 PRTBUF       19 DELETE       29 GETRDONLY   39 BLKRD
```

Many stubs (`INUSE`, `GETIO`, `USERCODE` etc. return AL=0).

### 2.3 I/O System – `IO.ASM`

`SEGBIOS SEGMENT AT BIOSSEG` reserves **13 far jumps** (3 bytes each = `JMP` opcode + offset) as BIOS call table at `BIOSSEG:0`:

```
+00 JMP INIT       +03 BIOSSTAT  +06 BIOSIN   +09 BIOSOUT  +0C BIOSPRINT
+0F BIOSAUXIN +12 BIOSAUXOUT +15 BIOSREAD +18 BIOSWRITE +1B BIOSDSKCHG
+1E BIOSSETDATE +21 BIOSSETTIME +24 BIOSGETTIME +27 BIOSFLUSH +2A BIOSMAPDEV (RET)
```

Implemented features:

| Feature | Ports / HW | Poll vs IRQ | Notes |
|---------|------------|-------------|-------|
| Console IN/OUT/STATUS | `BASE=0F0h` (CPU Support card), `STAT=0F7h`, `DATA=0F6h`, `DAV=2`, `TBMT=1` | `INTINP=1` → IRQ queue 80B `QUEUE`, else polled `QUEUE DB -1` | ESC handling, `^P` printer toggle, `^S`/`^C` |
| Printer | `PRNSTAT/DATA = BASE+13/12` (parallel) or `SIOBASE+1/0` | Buffered queue `PQUEUE` 128B | Spooled via FCB `PRNFCB` |
| Aux | `AUXSTAT/DATA` similarly selectable | Polled | |
| Timer | `STCDATA=0F4h`, `STCCOM=0F5h`, 9513 timer chip | — | `STCTAB` programs master+3 counters; GETTIME/SETTIME BCD → binary |
| Disk | `DISK=0E0h` (SCP), `DISK+1/2/3/4/5` WD1791 (SCP) or WD1771 (Tarbell/Cromemco) | PIO + status | `TARBELL`/`CROMEMCO`/`SCP` conditionals, CHS, densities |

**Disk driver complexity (≈1000 lines):** `SEEK`, `READSECT`, `WRITESECT`, `DSKCHG` with density auto-detect (SD/DD, single/double-sided via `BACKBIT`, `DDENBIT`, `SMALLBIT`), retry loops, `GETSTAT`, `HOME`.

### 2.4 Command Interpreter – `COMMAND.ASM`

**Three-part layout:**

```
CODERES (org 0, org 100h RSTACK)  →  DATARES  →  INIT  →  TAIL (PARA label TRANSTART)  →  TRANCODE (org 100h) + TRANDATA + TRANSPACE
RESGROUP = CODERES+DATARES+INIT+TAIL
TRANGROUP = TRANCODE+TRANDATA+TRANSPACE
```

* **Resident (`CODERES`+`DATARES`)** – Always resident at PSP+100h. Handlers for INT 22h (terminate `LODCOM`), INT 23h (`CONTC`), INT 24h (`DSKERR` → "Abort, Retry, Ignore?" + FAT bad handler), INT 27h (`RESIDENT` – TSR). Reload-checks transient via 16-bit checksum `CHKSUM` (sum of words). Prints all fault messages. Holds `BATFCB` (AUTOEXEC.BAT), `COMFCB`, `TRANS` far ptr. Size: `RESCODESIZE+RESDATASIZE` (computed `HIGHMEM` moves to top of memory if `HIGHMEM=TRUE`).
* **Init (`INIT:CONPROC`)** – One-shot: moves resident to `MEMSIZ - RESLEN` if `HIGHMEM`, reserves `TRNLEN`, hooks vectors, loads transient, checks `AUTOEXEC.BAT`, prints `Header` ("Command v. 1.17H" or IBM header).
* **Transient (`TRANCODE`)** – Loaded at `TRNSEG = MEMSIZ - TRNLEN`, may be overwritten. Main loop `COMMAND` prints `defaultDrive+":"` prompt, handles `BATCH` mode (reads AUTOEXEC.BAT sector-by-sector, expands `%0..%9` via `PARMTAB` in resident), parses with INT 21h AH=29h `MAKEFCB`, dispatches via `COMTAB`:

| Internal | Handler | Notes |
|----------|---------|-------|
| DIR | `CATALOG` | Switches `/W` (wide, 5/line) `/P` (pause) `/V` `/A` `/B` ; calls SRCHFRST/NXT, decodes FAT date/time |
| RENAME/REN | `RENAME` | |
| ERASE/DEL | `ERASE` | `DEL *.*` prompt "Are you sure?" |
| TYPE | `TYPEFIL` | Pipes via TPA buffer, stops on `1Ah` |
| REM | `COMMAND` (NOP) | |
| COPY | `COPY` | Heavy: `PLUS` concatenation, `/A` ascii vs `/B` binary, multi-source, append, verify, overflow check vs `BYTCNT`, `FLSHFIL` |
| PAUSE | `PAUSE` | |
| DATE | `DATE` | BCD, weekday table |
| TIME | `TIME` | |
| *else* | `EXECUTE` | Tries `.COM` → `.EXE` → `.BAT`; `.COM` uses `CALL 5` load via `SETBASE`/`RDBLK`; `.EXE` parses MZ header (`LOADLOW`, `RELCNT` etc.) |

Batch: resident `PARMTAB` holds 10 `%` pointers, `BATBYT` single-byte DMA for batch reads.

---

## 3. Cross-Module Call Graph

```
COMMAND (user types "DIR")
  └→ INT 21h AH=17 (SRCHFRST)
       └→ SAVREGS (MSDOS.ASM:288) saves ES/DS/BP/DI/SI/DX/CX/BX/AX, switches SS:SP to DOS IOSTACK/DSKSTACK
            └→ MOVNAME → DEVNAME → STARTSRCH → FATREAD → BIOSDSKCHG (far call to IO.ASM:DSKCHG)
            └→ GETENTRY → DIRREAD → DREAD → DSKREAD → BIOSREAD (far) → IO.ASM:READ → SEEK→READSECT (port I/O)
            └→ IRET via LEAVE (restores SS:SP, pops regs, IRET)

CONOUT (AH=2)
  └→ OUT → BIOSOUT (far) → IO.ASM:OUTP → IN STAT / OUT DATA (port 0F6h/0F7h) + BIOSPRINT if PFLAG
```

All DOS→BIOS calls are **far calls** through `SEGBIOS` jump table (3-byte `JMP`). BIOS returns with `RET L` (far return).

---

## 4. Limits & Quirks

* `INTBASE=80h` for DOS; `INTTAB=20h` for CP/M (`INT 20h` = terminate, `CALL 5` at `CS:0`). BIOS jump table prefixed at `CS:5`.
* `MAXCALL=36`, `MAXCOM=46` – two entry points (COMMAND vs ENTRY/CP/M). Functions 37-46 are COMMAND-only.
* `HIGHMEM`, `DSKTEST`, `IBM`, `CONVERT`, `FASTSEEK`, `LARGEDS` are compile-time `EQU` toggles – generate 8-10 distinct binaries.
* `ASM.ASM` is not used at runtime; it is a distribution tool.

---

## 5. Conversion Implications (preview)

* IO.SYS BIOS port code (0xF0, DISK=0xE0) is SCP-specific → must be replaced with ATA PIO + VGA + 8042. BIOS far-call table disappears.
* DOS `SAVREGS` stack-switching assumes DOSGROUP flat; in 64-bit we need per-CPU IST or simple kernel stack.
* `COMMAND` resident/transient split & checksum trick is obsolete in flat 64-bit; keep as single module.
* `CALL 5` compat is optional in 64-bit.

*Line refs verified by `grep -n` execution on 2026-08-30.*
