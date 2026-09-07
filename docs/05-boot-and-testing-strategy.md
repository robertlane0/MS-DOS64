# Phase 1 – Boot & Testing Strategy for 64-bit Conversion

> **As built (2026-09-07):** this strategy is implemented — MBR → stage2 →
> kernel at `0x100000` boots smoke 84 + 2 SKIP (`make`) or full 86 PASS
> (`make full`, destructive 71/83 in the reserved namespace with recovery)
> + `COMMAND64` REPL on QEMU (primary) and Bochs. Concrete sizes/layout
> below reflect the code; the step rationale is unchanged. See `README.md`
> + `docs/19-closure-g1-g6.md` for the final state (chunked loads,
> `KERNEL_SECTORS 176`, FAT12 volume at LBA 512+, PIC master `0x28`/slave
> `0x30`). `make lean` builds a shell-only `build/dos64-lean.img`
> (`SKIP_SELFTEST`, §7.1); tests 73–76 (§7.2) lock in negative-path
> handling, tests 77–82 (§7.3) lock in cross-layer malformed-input
> invariants (BPB table + sentinels, pure ATA table, FAT-chain bounds,
> allocator arithmetic, queue interleave, layout), and test 83 (§7.4)
> locks FAT12 crash-ordering (FAT-first commit, mirror heal, scrub/reclaim
> with fault-injected remounts).

## 1. Why New Boot Chain Is Needed

Original DOS had no MBR in repo — SCP boot loaded `IO.SYS` + `MSDOS.SYS` via unknown loader (likely absolute sectors). `IO.ASM:INIT` assumes it is already at `BIOSSEG:0` with DOS at `DOSSEG`. For BIOS Bochs we must supply MBR + stage2 that reproduces `real → protected → long` and places kernel at `0x100000`.

## 2. Target Memory Layout (AGENTS.md recommendation, adapted)

```
0x00000000  IVT (preserved for compatibility, but IDT will shadow it)
0x00000400  BDA
0x00000500–0x7BFF free conventional
0x00001000  PML4 (4 KiB) → 0x2000 PDPT → 0x3000 PD (4×2 MiB PS pages, identity 0–8 MiB)
0x00007C00  MBR (512B) loaded by BIOS — stage1
0x00007E00  Stage2 (~1 KiB, performs mode switch, chunked kernel loads)
0x00070000  Kernel staging buffer (BIOS loads here, copied to 0x100000 in long mode)
0x00090000  Initial RSP top (grows down, 16-aligned; IOSTACK/DSKSTACK are separate 4 KiB BSS stacks)
0x00100000  Kernel entry (flat binary, 64-bit, `KERNEL_SECTORS 176` = 88 KiB max, ~172 sectors used)
0x00200000+ Heap (MCB64 chain, first-fit)
0x00A0000–0x00BFFFF Video (B8000 text, will be driven by VGA driver)
0x0C0000–0xFFFFF ROM
```

`DOSINIT` old free-para scan is kept but updated to page granularity (4KiB).

## 3. Stage 1 – MBR (512B, BIOS entry `bits 16; org 0x7C00`)

Responsibilities:

1. `cli; xor ax,ax; mov ds,ax; mov es,ax; mov ss,ax; mov sp,0x7C00`
2. Preserve `DL` (BIOS boot drive).
3. Enable A20 via Fast A20 (port 0x92 bit1) with keyboard fallback (port 0x64) – verify with `int 15h AH=2401`?
4. Load Stage2: use BIOS `INT 13h AH=42h` LBA extended read if available, else CHS (`AH=02h`). Stage2 at 0x7E00 (fits the 15-sector LBA 1–15 slot; ~1 KiB as built). Verify signature 0xAA55.
5. `jmp 0:0x7E00`.

Stage2 loads the kernel in chunks (≤16 sectors/LBA packet; CHS fallback
advances ES across 64 KiB boundaries) to staging `0x70000`, then copies to
`0x100000` in long mode (`rep movsq`, `KERNEL_SECTORS 176`).

Build: `nasm -f bin src/boot/mbr.asm -o build/mbr.bin` – check `stat -c %s =512` and last two bytes `55 AA`.

## 4. Stage 2 – Protected → Long Switch (at 0x7E00)

Steps (AGENTS.md Phase 2 snippet):

```nasm
bits 16
stage2:
  lgdt [gdt32_ptr]
  mov eax, cr0
  or eax, 1
  mov cr0, eax          ; protected
  jmp 0x08:pmode

bits 32
pmode:
  mov ax, 0x10
  mov ds, ax
  mov es, ax
  mov ss, ax
  ; EFER: check CPUID 0x80000001 EDX:29 LM, else halt print
  ; enable PAE: or cr4, 1<<5
  ; build paging: PML4[0]=PDPT, PDPT[0]=PD, PD[0]= PT with 0x83 2MiB? or PT level for fine grained
  mov eax, 0x1000        ; PML4
  mov cr3, eax
  ; EFER MSR 0xC0000080: rdmsr, or 1<<8, wrmsr
  ; cr0 PG: or eax, 1<<31
  lgdt [gdt64_ptr]
  jmp 0x08:long_entry
bits 64
long_entry:
  mov ax, 0x10
  mov ds, ax
  ; jmp to kernel at 0x100000
  jmp 0x08:0x100000
```

**Page-table details:** use `dq` entries with flags `P|RW` (0x3). As built: PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000` with 4×2 MiB PS pages (`0x83`), identity 0–8 MiB — covers stage2, staging `0x70000`, stack `0x90000`, and kernel at `0x100000`.

**GDTs:**

```nasm
; GDT32: null, code 0x08 (base 0, limit 0FFFFFh, 0xCF9A), data 0x10 (0xCF92)
; GDT64: null, code 0x08 (0xAF9A long), data 0x10 (0xCF92)
```

## 5. Kernel Entry (`src/kernel/main.asm : _start`)

* `bits 64; default rel; org 0x100000`
* `mov rsp, 0x90000` (or end of identity-mapped conventional) aligned 16.
* Clear `.bss`, call `kinit` (C or asm) that sets `DRVTAB`, `BUFFER` as 64-bit pointers via `prot_ata_init`, `vga_init`.
* Install IDT (256 entries ×16B, see AGENTS.md):

```nasm
struc IDT_ENTRY
 .off_lo  resw 1
 .sel     resw 1
 .ist     resb 1
 .attr    resb 1
 .off_mid resw 1
 .off_hi  resd 1
 .res     resd 1
endstruc
lidt [idt_ptr]
```
Needed handlers: #DE(0), #GP(13), #PF(14) → fault print to VGA then hlt; IDT gate 0x21 for DOS syscall (DPL3), PIC master `0x28`/slave `0x30` (timer IRQ0@`0x28`, keyboard IRQ1@`0x29` installed, disk IRQ14@`0x36`).

## 6. Driver Replacement Order (per AGENTS.md Priority)

1. **VGA text** – memory-mapped `0xB8000`, ports 0x3D4/0x3D5 cursor. Implements `CONOUT`, `OUTCH`, `CRLF`. Verify by printing "Hello 64-bit DOS!" on `qemu/bochs`.
2. **Keyboard** – port 0x60 data, 0x64 status (OBF 1, IBF 2); translate scancode set 1 to ASCII; circular queue 128B (`KBD_QUEUE_SIZE`, power-of-two mask). Verify echo.
3. **Disk** – ATA PIO LBA28: poll `BSY=0x80` via `0x1F7`, write 0x1F2 sect cnt, 0x1F3-0x1F6 LBA, 0x1F7 cmd 0x20 read / 0x30 write. Alternatively AHCI. Verify read of boot sector 0 and check 0xAA55.

Time/BIOSGETTIME replaced later via CMOS `PORT 0x70/0x71`.

## 7. Incremental Testing (AGENTS.md §Testing Procedure)

Each stage has Bochs run:

*Stage 1 – Boot + mode.* Build mbr only, `dd if=mbr.bin of=dos64.img conv=notrunc; bochs -f bochsrc.txt -q` → check `r` shows `CR0 PE=1`, `EFER LME=1`, `CS long`. Halt with magic `0xEBFE`.

*Stage 2 – VGA.* Add `call dbg_print` → see text.

*Stage 3 – Kbd.* Poll `in al,0x64; test al,1`.

*Stage 4 – Disk.* Read LBA 0 to `0x9000` buffer, compare signature.

*Stage 5 – FS.* `tools/mkfat12.py` stamps a real 1.44M FAT12 volume at LBA 512–3391 during `make`; the kernel mounts it via `fs_mount_volume64` (`firfat/firdir/firrec` DPB + in-RAM FAT copy) and serves FCB/dir handlers from it. Scratch stays `200`/`500–511`.

*Stage 6 – Syscalls.* Exercise `INT 21h` gate for `AH=09` print string.

*Stage 7 – Shell.* `src/kernel/shell64.asm` REPL after the self-test suite: prompt loop over PS/2 + COM1 RX, `cmd_parse_line64` → builtins against the mounted volume + `*.COM` EXEC. QEMU `-serial stdio` drives it from a pipe.

### 7.1 Build flag: smoke (default) vs full (destructive) vs lean (shell-only)

The suite is no longer inseparable from the boot path, and destructive
filesystem tests are no longer coupled to every normal boot.
`src/kernel/main.asm` wraps the test-calling block in `_start` with build
flags (classification: PURE / SCRATCH-DEVICE / REAL-VOLUME READ-ONLY /
REAL-VOLUME DESTRUCTIVE — see `src/kernel/selftest64.asm` header):

```nasm
; Smoke (default): nasm -DRUN_SELFTEST -> 84 + 2 SKIP, then shell_repl64
; Full:  nasm -DRUN_SELFTEST -DSELFTEST_DESTRUCTIVE -> 86, then shell
; Lean:  nasm -DSKIP_SELFTEST -> skip suite, minimal init, shell direct
%ifdef SKIP_SELFTEST
%undef RUN_SELFTEST
%undef SELFTEST_DESTRUCTIVE
%else
%ifndef RUN_SELFTEST
%define RUN_SELFTEST
%endif
%endif
```

`Makefile` exposes all three (objects are kept separate so the images can coexist):

```bash
make                    # smoke: build/dos64.img (RUN_SELFTEST, 84 + 2 SKIP + shell)
make full               # full: build/dos64-full.img (RUN_SELFTEST+SELFTEST_DESTRUCTIVE, 86 + shell)
make lean               # lean: build/dos64-lean.img (SKIP_SELFTEST, shell direct)
make run-qemu           # boot smoke image, expect "Summary: 84 passed, 0" + "Skipped (destructive): 2"
make run-qemu-full      # boot full image, expect "Summary: 86 passed, 0"
make run-qemu-lean      # boot lean image, expect "Lean boot ... entering COMMAND64..."
```

Smoke keeps PURE + bounded SCRATCH-DEVICE (LBA 200/500–511, zeroed after)
+ REAL-VOLUME READ-ONLY (67/70/72/76); tests 71 (`SCRATCH`/`RENAMED`) and
83 (`CRASH`) print `SKIP (destructive, needs SELFTEST_DESTRUCTIVE)` and
leave the volume untouched. Full runs all 83 in the reserved namespace
(`include/fs.inc`: only 71/83 may write the volume, only those three names)
with mount-time recovery (Test 70 `recover_test_namespace_if_dirty` +
71/83 pre-clean delete + discard/remount + reclaim + heal + scrub) and
post-run non-test preservation checks (`HELLO`/`README` intact, scrub
clean, mirrors match), so an interrupted run is recovered idempotently by
the next boot and can never destroy non-test files. `tools/check_volume_clean.py`
proves pre/post cleanliness from the host side (directory metadata + FAT
allocations, including deliberately dirtied runs).

NOTE: `RUN_SELFTEST` (even smoke) performs bounded device writes
(scratch-LBA patterns, optional FAT2 heal on a diverged mount). Only
`SKIP_SELFTEST` performs zero device writes.

The lean path (`_start:.lean_boot`) still performs the essential init the
suite would otherwise have done — `mem_init64`, `proc_init64`,
`syscall_init`, `kbd_init`, `idt_init64`/`idt_load64`, `pic_remap64`,
`fs_mount_volume64` (retried inside the shell) — prints `msg_lean`, then
calls `shell_repl64`. This isolates the "does the shell alone still work"
path and saves boot time (measurable via QEMU `-serial stdio` timestamp
deltas); the full build still reports `N passed, 0` with the higher N.

### 7.2 Negative-path coverage (tests 73–76)

Positive-path coverage (all 77 `INT 21h` slots exercised) is now paired
with systematic failure-mode checks, following the existing
`msg_testN` / `inc r12` / `inc r13` pattern:

* `[73] Loader negative` (`test_neg_verify`): `proc_verify_image64` with
  `image_size` larger than the file (1000 vs 160, and 160 vs 160-32),
  `entry_offset >= image_size`, `stack_size > 64K`, bad `hdr_size`,
  zero size, NULL src, size > 16M → all `RAX=2`; valid COM → 0 and valid
  EXE64 → 1 still hold; `proc_load_image64` on the bad header returns
  `CF=1` before any copy.
* `[74] ATA negative` (`test_ata_neg`): `ata_read/write_lba28` with LBA
  `0x10000000`/`0x10000001` (≥ 2^28) fail fast with `RAX=1` (pure range
  check, no hardware wait); `ata_wait_not_busy`/`ata_wait_ready` return
  ready on the idle drive; `ata_wait_drq` with no command times out
  (`CF=1`) rather than hanging; a normal LBA0 read (`0xAA55`) still works
  afterwards (no state damage).
* `[75] Syscall bounds` (`test_syscall_bounds`): `AH=0x4C` (MAXCOM) via
  `syscall_dispatch64` and via CPU `int 0x21` dispatches (kernel EXIT
  fails `CF=1`, proving it is *not* the bad path); `AH=0x4D`
  (MAXCOM+1) and `AH=0xFF` return `AL=0`/`CF=0` via both paths without
  faulting.
* `[76] FAT12 negative` (`test_fs_neg`, read-only): `fs_vol_read_file64`
  with NULL dest and with a missing name fails (`CF=1`);
  `fs_bpb_parse64` on a corrupt (bytes/sector 123) and on a zeroed boot
  sector fails into a scratch DPB in `p8_file_buf+512` (never the mounted
  volume's real DPB), while the valid boot sector still parses;
  `fs_cluster_to_lba64`/`fs_get_cluster64` reject clusters 0/1/huge and
  accept cluster 2.

### 7.3 Cross-layer malformed-input invariants (tests 77–82)

Table-driven where boundaries must stay obvious; all deterministic, no
emulator timing, no disk I/O except the already-mounted volume for
read-only sampling. Each leaves its subsystem clean for the shell.

* `[77] BPB table + sentinels` (`test_bpb_table`): 14 single-field
  mutations from a valid 1.44M baseline — `FATSz=10` (FAT > `fs_vol_fat`),
  `Root=225` (root > `fs_vol_root`), `Spc=128` (cluster > `fs_vol_iobuf`,
  parse fail) vs `Spc=64` boundary still ok (32 KiB == iobuf), `1024B`
  sectors (parse ok, `GEOM_ERR` under the 512B cache), `Tot=4112`
  (`maxclus` 4080 beyond FAT bytes) — plus stale-`Tot=100` data-end and a
  `Spc=128` defense-in-depth branch. Guards (`bpb77_pre/post`,
  `bpb77_dpb_post` + `fs_vol_fat/root/iobuf` samples) prove the validator
  is read-only and never overflows the fixed cache.
* `[78] ATA pure table` (`test_ata_table`): 16 `ata_validate_range64`
  cases (helper only, no port I/O) — `0x0FFFFFFF+1` ok vs `+2` overflow,
  exact-fit `0x0FFFFFC0+64` ok vs `0x0FFFFFC1+64` past-max, count
  `0/65/256/high-bits` rejected, `LBA>=2^28`/huge rejected, endpoint
  inclusive `0x0FFFFFFE+2` ok vs `+3` fail — plus `R8-R11`/`RSI`/`RDX`
  preservation (the endpoint/count contract from ISSUE-02).
* `[79] FAT chain bounds` (`test_chain_bounds`): `maxclus=10` synthetic
  FAT with guards — empty ok, valid `2->3->EOF` ok + cleared, exact-fit
  `2..10->EOF` (9 hops) ok, overlong cycle `2..10->2` corrupt (hops ≥
  `maxclus`), dangling `2->0` / `2->11(>maxclus)` terminate ok, `NULL`
  `RSI`/`RBP` corrupt, `maxclus<2` corrupt, self-loop with `maxclus=2`
  corrupt, all best-effort cleared and bounded, valid-again (no sticky).
* `[80] Alloc table` (`test_alloc_table`): 10 `mem_alloc64` sizes from an
  empty heap — `0` fail, `1/16` ok, `6M-48` ok (max fitting, header 40),
  `6M/100M/UINT64_MAX/MAX-14(wraps size+15)/MAX-15/2^63-1` fail with the
  chain intact (validate 0, single `Z`) — then aligned (`4096` ok +
  aligned, huge/`4G`-align fail), pages (`1` ok, `MAX`/`2^52` fail),
  resize (`512` ok, `MAX`/`MAX-14`/`10M` fail with `CF`, chain intact).
* `[81] Queue interleave` (`test_queue_interleave`): empty pop fails,
  single round-trip, `500x` alternating push/pop at empty, `127`-fill +
  `100x` push/pop at full with exact FIFO order + drain of the remaining
  `127`, wraparound `100x0x55` + `50x0x80+i` past `127`, `IF`
  preservation (`push`/`pop`/`flush` leave `IF` as found) and nested `cli`
  (inner calls keep `IF=0`, restore to found). Ends flushed.
* `[82] Layout invariants` (`test_layout`): canonical values
  (`IMG 10M`, `secsiz 512`, kernel `16+176`, volume `512+2880`, `FAT 4608`
  / `root 7168` / `iobuf 32768`) plus the same predicates `make
  check-layout` enforces — `kernel_end<=VOL_LBA`, `volume_end<=IMG_MB`,
  `FS_VOL_*` aliases, scratch `200/500/501/510/511` clear of kernel and
  volume, `FAT 9sec` / `root 14sec <=64` (ATA `1..64` contract for the
  mount reads) — plus negative tables proving off-by-one overlaps
  (`191`, `500`-extents) and oversize volumes (`1M` image, `20000`
  sectors) are rejected. `make check-layout-neg` covers the same paths
  from the host side (override + stamper overlap/sector-size rejection).

### 7.4 FAT12 crash-ordering (test 83)

FAT12 has no journal, so consistency is write ordering + mount healing
(see `include/fs.inc` for the model: extend `data → FAT → root`,
truncate `root → FAT`, delete `root(0xE5) → FAT`, mirrors `FAT1 → FAT2`
healed `FAT1`-wins; first-flush failure skips the second, second-flush
failure reports `CF=1` with an orphan leak). `test_fs_crash` drives the
real volume with a `CRASH.TXT` scratch file (idempotent pre-clean:
delete + reclaim + heal, so an aborted run cannot poison the next boot)
through: baseline create+write (scrub clean, mirrors match); a
data-written/FAT-old window with injected `FAT1` failure (old size kept,
scrub clean); a FAT-new/root-old window with FAT flushed and root
skipped (reachable slack, no `DANGLING` — the fix for the old
root-then-FAT window); a `FAT2` copy1-new/copy2-old divergence (check
reports mismatch, remount heals, exactly 1 orphan, reclaim frees it); a
data-only write to a free cluster (harmless, orphans 0); and a delete
with `FAT` failure (name gone, 1 orphan, reclaim frees it). Final state
is clean (gone, orphans 0, mirrors match) for the shell. Faults use the
sticky `fs_fault_inject` mask (`FS_FAULT_FAT1/FAT2/ROOT`); `fs_vol_discard64`
drops RAM caches so each remount behaves like a reboot. Power-loss
consistency here is ordering + healing, NOT transactional (torn
multi-sector writes stay deterministic via `FAT1`-wins).

## 8. Bochs Config (AGENTS.md template)

```
megs: 256
romimage: file=$BXSHARE/BIOS-bochs-latest
vgaromimage: file=$BXSHARE/VGABIOS-lgpl-latest.bin
ata0-master: type=disk, path="build/dos64.img", mode=flat, cylinders=20, heads=16, spt=63
boot: disk
log: bochs.log
cpu: model=ryzen, count=1, ips=50000000, reset_on_triple_fault=1, ignore_bad_msrs=1
panic: action=report
magic_break: enabled=1
com1: enabled=1, mode=file, dev=serial.log
display_library: nogui
```

(QEMU `qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none` is the primary proof path.)

Build scripts (see `Makefile`):

```bash
nasm -f bin src/boot/mbr.asm -o build/mbr.bin
nasm -f bin src/boot/stage2.asm -o build/stage2.bin
nasm -f elf64 src/kernel/*.asm src/drivers/*.asm src/lib/*.asm -o build/src/.../*.o
ld -T linker.ld -o build/kernel.elf build/src/kernel/main.o ... -nostdlib  # linker places .text.start (_start) at 0x100000
objcopy -O binary build/kernel.elf build/kernel.bin  # must fit KERNEL_SECTORS 176
dd if=/dev/zero of=build/dos64.img bs=1M count=10
dd if=build/mbr.bin of=build/dos64.img conv=notrunc
dd if=build/stage2.bin of=build/dos64.img bs=512 seek=1 conv=notrunc
dd if=build/kernel.bin of=build/dos64.img bs=512 seek=16 conv=notrunc  # or via stage2 LBA loader
python3 tools/mkfat12.py --vol-lba 512 --vol-totsec 2880 --sector-size 512 --kernel-lba 16 --kernel-sectors 176 build/dos64.img  # stamps FAT12 volume (canonical values: Makefile disk-layout block)
make run-qemu   # or: bochs -f bochsrc.txt -q
```

## 9. Debugging Tools

* Bochs internal debugger: `b 0x7C00`, `c`, `r`, `x /10xb 0x7C00`, `s`, `creg`.
* Serial port logging: `mov dx,0x3F8; out dx,al` fallback.
* VGA dump: `mov rax,0xB8000; mov word [rax],0x0F44` (white-on-black 'D').
* Triple-fault: `ips` and `reset_on_triple_fault=1` will reset; check `bochs.log` for `exception` lines.

## 10. Success Criteria (Phase 1 → Phase 12)

Refer to Validation section. Phase 1 success is **documentation + scaffold** complete and reviewed, no code crashes because no boot yet.

## 11. Next Steps (Phase 2 Kickoff)

1. Implement `src/boot/mbr.asm` + `stage2.asm` + `gdt.asm`
2. Create `linker.ld` and `Makefile`
3. Smoke-test mode switch in Bochs with debugger.

*Memory map follows AGENTS.md §Memory Layout Recommendations; all addresses verified against IO.ASM:0F0h ports and MSDOS.ASM mem arithmetic.*
