# Appendix – DOS 1.25 System-Call Reference (from MSDOS.ASM DISPATCH)

> **As built:** the 64-bit kernel implements a 77-entry `DISPATCH64`
> (`AH=00h–4Ch`, `src/kernel/syscall64.asm:315`) via the DPL3 `INT 0x21` IDT
> gate. Only DOS-reserved slots (`18h/20h/2Fh–34h/36h–3Eh/41h–47h`,
> `INUSE`/`USERCODE` in DOS 1.25 itself) stay stubbed; everything else —
> consoles, AUX/COM/LIST, drives, vectors, DMA, handles, alloc, FCB files,
> date/time (CMOS RTC), VERIFY, EXEC/EXIT — is real. See
> `docs/19-closure-g1-g6.md` G1 table for the handler→backing map. The
> `00–46` table below documents the original DOS 1.25 source this was
> converted from.

Source: `MSDOS.ASM:349-397` `DISPATCH DW ABORT ... VERIFY` (MAXCALL=36, MAXCOM=46). Entry via:

* `INT 21h / INT 33` (DOSGROUP:COMMAND, AH=func) – full 00-46
* `CALL 5` (ENTRYPOINT = INTBASE+40h far jump to ENTRY, CL=func) – 00-36 only (`MAXCALL`)

All calls preserve BP onward via `SAVREGS` → `IOSTACK/DSKSTACK` then `IRET`. Returns `AL` (0 ok, FF err; file funcs) and `AH` for read/write error codes.

| AH/CL | Label (MSDOS.ASM:349) | Mnemonic | Args (user regs at `SPSAVE`) | Effect | 64-bit Plan |
|------:|----------------------|----------|-------------------------------|--------|-------------|
| 00 | `ABORT` | Terminate | — (`LDS SI,[SPSAVE]` restore SS:SP, jump `DS:[EXIT]`) | Restores sav EXIT vectors, flush FATs, `DS:=0:[EXIT]`, pops user regs, `JMP [EXITHOLD]` | Keep as `exit_process` syscall (RAX=0) + IDT IRETQ |
| 01 | `CONIN` | Char in w/ echo | — | via `IN` → BIOSIN echo → `BUFOUT` | → kbd driver |
| 02 | `CONOUT` | Char out | DL=char | `OUT` → BIOSOUT (+ BIOSPRINT if `PFLAG`) | → vga_putc |
| 03 | `READER` | Aux in | — | `BIOS AUXIN` | → COM1 0x3F8 |
| 04 | `PUNCH` | Aux out | DL | `BIOS AUXOUT` | |
| 05 | `LIST` | Printer out | DL | `BIOSPRINT` | stub |
| 06 | `RAWIO` | Direct console I/O | DL=FF → input else output | raw without echo | |
| 07 | `RAWINP` | Direct in no echo | — | | |
| 08 | `IN` | Console in no echo | — | | |
| 09 | `PRTBUF` | Print $-string | DS:DX → `$` term | loops `OUT` | → `vga_print` |
| 10 | `BUFIN` | Buffered input | DS:DX → len+buf (max 128) | `CARPOS/STARTPOS`, ESC table (42h,77,59 etc.), insert/toggle, `^C` check via `STATCHK` | → line-edit keep, but RIP-rel |
| 11 | `CONSTAT` | Check status | — | `BIOSSTAT` NZ? | |
| 12 | `FLUSHKB` | Flush + dispatch | AL=subfunc (1/6/7/8/10 redispatch) | `BIOSFLUSH`, if AL in set re-dispatch via `REDISPJ` | |
| 13 | `DSKRESET` | Reset disks | — | Flush `DIRTYBUF`/`DIRTYDIR`? iterate? | |
| 14 | `SELDSK` | Select drive | DL=drive | Set `CURDRV` if < `NUMDRV` | expand to mount |
| 15 | `OPEN` | Open file FCB | DS:DX→FCB | `GETFILE`→`DOOPEN`: copies FIRCLUS/FILSIZ/FDATE to FCB RECSIZ default 128 | |
| 16 | `CLOSE` | Close FCB | DS:DX→FCB | If dirty `DEVID&COh`, flush `BUFRD`? write dir entry, `FATWRT` | |
| 17 | `SRCHFRST` | Search first | DS:DX→FCB (? allowed) | `GETNAME`→ `FINDNAME` fills `DIRBUF`? returns dir entry at `DIRBUF` | LBA |
| 18 | `SRCHNXT` | Search next | — | `CONTSRCH` | |
| 19 | `DELETE` | Delete | DS:DX→FCB wild? | `DELALL` flag for `*.*`, marks `E5h/00`, `RELEASE` clusters chain, `FATWRT` | |
| 20 | `SEQRD` | Seq read | DS:DX→FCB | `GETREC` → `LOAD` → `SETNREX` ext | |
| 21 | `SEQWRT` | Seq write | | `GETREC`→`STORE` | |
| 22 | `CREATE` | Create | DS:DX→FCB | `MOVNAME` (? illegal), `FINDNAME`; if exists free chain else `ENTFREE` | |
| 23 | `RENAME` | Rename | DS:DX→FCB (FCB+16 second name) | wildcard `?` merging `NEWNAM`, `DEVNAME` check, dup search | |
| 24 | `INUSE` | (reserved) | — | `MOV AL,0; RET` stub (`INUSE:` = `GETIO:`) | |
| 25 | `GETDRV` | Get cur drive | — | `AL=CURDRV` | |
| 26 | `SETDMA` | Set DMA | DS:DX addr | `MOV [DMAADD],DX ; [DMAADD+2],DS` | → 64-bit `dma_addr` |
| 27 | `GETFATPT` | Get FAT ptr | — | BX→FAT, AL sectors/FAT? | rename |
| 28 | `GETFATPTDL` | Get FAT for DL | DL=drive | | |
| 29 | `GETRDONLY` | Get ? | | stub | |
| 30 | `SETATTRIB` | Set attrib | | stub | |
| 31 | `GETDSKPT` | Get DPB | | `BX→DPB, DX=??` | keep, widen pointers |
| 32 | `USERCODE` | | | stub | |
| 33 | `RNDRD` | Random read | DS:DX→FCB RR set | `GETRRPOS1`→`LOAD`→`FINRND` | |
| 34 | `RNDWRT` | Random write | | `GETRRPOS1`→`STORE` | |
| 35 | `FILESIZE` | Get file size | | uses dirent size → RR? | |
| 36 | `SETRNDREC` | Set RR from seq | | sets random record from CURRENT BLOCK/NR | |
| 37 | `SETVECT` | Set vector | AL=int, DS:DX→handler | `MOV DS:[INTBASE+AL*4],DX/DS`? (see `SETVECT` at ~3050) | → IDT set |
| 38 | `NEWBASE` | Get mem size & set alloc | DX=end para | `MOV AX,DX` `MOV DS,[6]` etc., `SETMEM` | → page allocator |
| 39 | `BLKRD` | Block read | DS:DX→FCB CX count | `GETRRPOS`→`LOAD`→return CX | |
| 40 | `BLKWRT` | Block write | | `GETRRPOS`→`STORE` | |
| 41 | `MAKEFCB` | Parse FCB | AL=mode, DS:SI→str ES:DI→FCB | `MAKEFCB` (3189) parses `CAM`/`?`, returns AL 0/FF/-1 | |
| 42 | `GETDATE` | Get date | | `DIVMES`? pack? | → CMOS |
| 43 | `SETDATE` | Set date | | `BIOSSETDATE` | |
| 44 | `GETTIME` | Get time | | `BIOSGETTIME` | |
| 45 | `SETTIME` | Set time | | `BIOSSETTIME` | |
| 46 | `VERIFY` | Set verify | AL=1/0 | `VERFLG` → used in `DWRITE` → BIOSWRITE AH | |

`INUSE`–`USERCODE` group (24,28-32) are stubs returning 0 (future CP/M compat placeholders). `DISPATCH` alignment: `SHL BX,1` means each entry 2B; far CALL sites use `CS:[BX+DISPATCH]`.

Error paths: `FATERR` → `INT 24h` with `AH=80h`; `HARDERR` → `INT 24h` with `AH` area code. Caller checks `AL=1 retry, 2 abort, else ignore`.

All refs `MSDOS.ASM:277-405,3935-3965,319-347,1278,1453,3034-3060,3189-3629`.
