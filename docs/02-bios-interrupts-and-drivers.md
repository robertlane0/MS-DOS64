# Phase 1 – BIOS Interrupt Dependencies & Driver Catalog

## 1. BIOS Call Table (IO.ASM → MSDOS.ASM interface)

IO.ASM exports 13 vectors at `BIOSSEG:0` (each `JMP` 3 bytes). MSDOS.ASM declares them as `SEGBIOS SEGMENT AT BIOSSEG` and `CALL FAR PTR …` (`MSDOS.ASM:175-193`, `414,435,950,982,1296,1343`).

| Offset | Symbol | MSDOS Caller | IO Handler | Function |
|--------|--------|--------------|------------|----------|
| +3 | `BIOSSTAT` | `STATCHK` (3027) → `BIOSSTAT` | `STATUS` (360) | Console input status; Z=empty |
| +6 | `BIOSIN` | `IN` (3138,3040) | `INP` (382/514) | Blocking console input; 7-bit mask |
| +9 | `BIOSOUT` | `OUT`/`OUTCH` (3027) | `OUTP` (566) | Polled `TBMT` → `OUT DATA` |
| +0C | `BIOSPRINT` | `LIST` (3030,3169) | `PRINT` (576) | Buffered printer |
| +0F | `BIOSAUXIN` | `READER` (435) | `AUXIN` (599) | `DAV` poll → `IN AUXDATA` |
| +12 | `BIOSAUXOUT` | `AUXOUT` (444) | `AUXOUT` (607) | `TBMT` poll → `OUT AUXDATA` |
| +15 | `BIOSREAD` | `DSKREAD` (1296) | `READ` (838) | CHS disk read, CX sectors, DX LBA-like logical rec |
| +18 | `BIOSWRITE` | `DWRITE` (1343) | `WRITE` (856) | CHS disk write |
| +1B | `BIOSDSKCHG` | `FATREAD` (950) | `DSKCHG` (689/714) | AH=-1 changed, 0 unknown, 1 not |
| +1E | `BIOSSETDATE` | `SETDATE` (3571) | `SETDATE` (340) | AX=days? |
| +21 | `BIOSSETTIME` | `SETTIME` (3613) | `SETTIME` (301) | CX/DX time |
| +24 | `BIOSGETTIME` | `GETTIME` (3438) | `GETTIME` (268) | CX:DH time, AX days |
| +27 | `BIOSFLUSH` | `FLUSHKB` (414) | `FLUSH` (396/528) | Clear input queue |
| +2A | `BIOSMAPDEV` | `NEWDSK`/`MAPDRV` (982) | `MAPDEV: RET` (127) | NOP – maps driver→BP |
| — | `STAT/DATA` | — | `BASE+7/+6=0F7h/0F6h` | Direct port I/O (not BIOS) |

**Remaining BIOS work done via direct port I/O, not INT 10h/13h/16h:** IO.ASM uses `IN`/`OUT` to `BASE=0F0h`, `SIOBASE=10h`, `DISK=0E0h`, `STCCOM=0F5h`. No `INT 10h` etc. appear in MSDOS.ASM; all hardware is abstracted via far calls.

## 2. Emulated PC-BIOS Interrupts (not used)

MS-DOS 1.25 **does not use IBM PC BIOS INT 10h/13h/16h**. SCP hardware predates IBM PC. For 64-bit conversion we *introduce* them conceptually, then replace:

| Original `IO.ASM` function | PC-BIOS equivalent | 64-bit replacement |
|----------------------------|-------------------|--------------------|
| `OUTP`/`INP`/`STATUS` | `INT 10h` (video) + `INT 16h` (kbd) | VGA text 0xB8000 + port 0x60/0x64 PS/2 driver |
| `READ`/`WRITE`/`DSKCHG` | `INT 13h` CHS/LBA | ATA PIO (0x1F0) or AHCI, LBA28 |
| `GETTIME`/`SETTIME` | `INT 1Ah` RTC | CMOS ports 0x70/0x71 + PIT |
| `PRINT` | `INT 17h` | Parallel/serial ignore; optional COM1 0x3F8 |

MSDOS also uses DOS interrupts internally (see §3).

## 3. DOS-Internal Interrupts & Far Calls

| Vector | Symbol | MSDOS Setup (`DOSINIT`) | Purpose |
|--------|--------|-------------------------|---------|
| `INT 20h` (`INTTAB`) | `ABORT` | `MOV DS:[0],20CDH` (INT 20h opcode) at PSP:0 (`MSDOS.ASM:3408`) | Program terminate |
| `INT 21h` (`INTTAB+1`? actually `COMMAND`) | `COMMAND` | `DS:[INTBASE+4]=COMMAND` (`3951`) | System-call dispatch (AH 1-46) |
| `INT 22h` (`EXIT`) | `INTBASE+8` | `DS:[EXIT]=100h` prog seg, `DS:[EXIT+2]=DX` (`3961`) | Terminate address saved at PSP:0Ah |
| `INT 23h` (`CONTC`) | `INTBASE+0Ch` | `DS:[INTBASE+12]=IRET` default (`3952`) | Ctrl-C handler |
| `INT 24h` (`INTBASE+10h`) | Fatal | `DS:[INTBASE+16]=IRET` default | Hard error (called via `INT 24h` at `MSDOS.ASM:1278`) |
| `INT 27h` | `RESIDENT` | `MSDOS.ASM:350` теп | Keep resident (COMMAND 27h) |
| `CALL 5` (`ENTRYPOINT`) | `INTBASE+40h` | `DS:[ENTRYPOINT]=EAh (LONGJUMP) + ENTRY + seg` (`3944`) | CP/M compat long jump |

COMMAND installs:

* `INT 22h → LODCOM` (reload transient checksum loop) (`COMMAND.ASM:500,298`)
* `INT 23h → CONTC` (prompt "Terminate batch job?") 
* `INT 24h → DSKERR` (disk error "Abort, Retry, Ignore?")
* `INT 27h → RESIDENT` (adjust `LTPA`)

`ENTRY` (MSDOS.ASM:277) handles `CALL 5` by popping `IP`/`CS`/user `IP`, pushing flags, reordering to `IRET` frame, validating `CL` ≤ MAXCALL. `SAVREGS` then saves 9 registers and switches stacks.

Error dispatch via `INT 24h` at `HARDERR:INT 24H` with `AH` encoding area: `0=resvd,1=FAT,2=dir,3=data` shifted + `READOP` LSB.

## 4. Port-Level Hardware Details (from IO.ASM)

### Console / Printer / Aux (SCP Support Card)

```
BASE = 0F0h, STAT = 0F7h, DATA = 0F6h, DAV=2, TBMT=1
SIOBASE = 10h (Multiport Serial optional)
STCDATA=0F4h, STCCOM=0F5h, STCTAB programs 9513 timer: master 084F3h + counters 1/2/3 (0138h/0038h/0008h)
Keyboard IRQ (INTINP=1): victim at 0:64h = KBINT (CS:KBINT), ACK port BASE+2 with 20h, queues 80B
Print queue: PQUEUE 128B, PFRONT/PREAR, parallel TBMT poll
```

### Disk (WD179X family)

```
If SCP: DISK=0E0h, SMALLBIT=10h, BACKBIT=04h, DDENBIT=08h, DONEBIT=01h
If TARBELL: DISK=78h, BACKBIT=40h, DONEBIT=80h (Force Interrupt 0D0h required)
If CROMEMCO: DISK=30h, port 4 for side select, auto-wait bit 80h

Registers: DISK+0 = command/status, +1 = track, +2 = sector, +3 = data, +4 = drive select/status, +5 = wait
Commands: READCOM=80h/88h, WRITECOM=0A0h/0A8h (1791 vs 1771), SEEK 1Ch+STPSPD, RESTORE 0Ch+STPSPD, READ ADDRESS 0C4h
```

Densities derived from `DRVTAB` bits: `TEST DH,SMALLBIT/DDENBIT`, fallback via `SETUP` side-selection and track stepping (`INC DL` + `58H+STPSPD`).

### Timer

`STCTAB` → `OUT STCCOM/STCDATA` ×4; `GETTIME` does `A7h/E0h/19h` hold cycle + `STCTIME` BCD unpack via `AAD` + shifts.

## 5. Register-Stack Trap Frame

`STKPTRS STRUC` (`MSDOS.ASM:196`):

```
AXSAVE, BXSAVE, CXSAVE, DXSAVE, SISAVE, DISAVE, BPSAVE, DSSAVE, ESSAVE, IPSAVE, CSSAVE, FSAVE
```

`SPSAVE`/`SSSAVE` hold user SP/SS before `MOV SS,SP (=CS)` and `SP=IOSTACK/DSKSTACK` (disk funcs >12 use `DSKSTACK`). `ABORT` restores via `LDS SI, [SPSAVE]` + `DS:[SI.CSSAVE]`. Ctrl-C abort at `STATCHK` pops user frame and `INT CONTC`.

## 6. 64-bit Replacement Strategy

| Legacy mechanism | 64-bit design |
|------------------|---------------|
| Far `CALL BIOS*` jump table at absolute BIOSSEG | Eliminate; compile-time linked drivers expose `vga_putc`, `ata_read_lba`, `kbd_poll` |
| Port 0xF0 / 0xE0 SCP | Ports 0x3F8 (COM1 debug), 0xB8000 (VGA), 0x1F0/0x3F6 (ATA), 0x60/0x64 (8042), 0x70/0x71 (CMOS) |
| 9513 timer | PIT 0x40 / HPET, or TSC via CPUID |
| Disk `DSKCHG` density probe | ATA IDENTIFY, always LBA, no geometry probe |
| BIOS GETDATE/SETTIME BCD | Direct CMOS/RTC driver |
| INT 20h/21h/24h vectors in IVT 0:0 | IDT gates (64-bit): `INT 21h` compat gate + `SYSCALL` (MSR_LSTAR) |
| `SAVREGS` stack switch to DOSGROUP | Per-CPU kernel stack, IST for #DF, SYSENTER trap frame is `pt_regs` |

All 13 far-call sites (`CALL FAR PTR BIOS*`) become near `call driver_*` after Phase 5 driver implementation. No BIOS interrupts are issued in long mode.

*Line refs: IO.ASM 74-193, 130-248, 268-355, 401-561, 689-871; MSDOS.ASM 162-193, 277-347, 3940-3961, 1278.*
