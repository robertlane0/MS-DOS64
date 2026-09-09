# N1 — Cross-assemble + run: host NASM → DOS64 `.COM`

Tier 1 of `PLAN.md`: write assembly on a host, assemble with NASM syntax,
copy onto the FAT12 volume, `EXEC` from the `COMMAND64` shell. This is the
only tier that works today, and it already works — this doc smooths it.

Submodule pin: `nasm/` @ `fbdc88565` (`nasm-3.02-50-gfbdc88565`); port
baseline NASM 3.02 (see `docs/20-nasm-gaps.md`). Sample binaries are
assembled with a NASM built from that exact source (`make nasm-samples`
builds `build/nasm-sub/src/nasm` once and caches it under `build/`,
which is gitignored). Verified byte-identical to system NASM 3.02 for
the samples (`cmp` clean).

## 1. Constraints for DOS64 `.COM` programs

```nasm
bits 64
default rel
; NO `org`: a .COM loads at PSP+PSP_SIZE (664) with entry = PSP+PSP_SIZE
; (proc_load_image64), not DOS CS:0x100. `org` only affects absolute
; addresses, and rule 2 forbids those — so omit it, not `org 0x100`.
```

1. **`bits 64`, flat, position-independent.** RIP-relative addressing
   only (`lea rdx, [rel msg]`, `default rel`). No segment overrides
   (CS/DS/ES/SS are inert in long mode), no far calls/jumps, near
   `CALL/RET` only, 16-byte `RSP` alignment per System V AMD64.
2. **No absolute addresses.** The load address varies per spawn (heap
   `0x200000+`, first-fit); anything link-time-absolute is wrong.
3. **Only real `INT 21h` handlers** (full table: `docs/06-`,
   `src/kernel/syscall64.asm:319-396`). Safe subset for samples:
   | AH | Use | Args |
   |---|---|---|
   | `02h` | char out | `DL`=char |
   | `06h–0Ch` | console in/out/status | see G1 table |
   | `09h` | print `'$'`-string | `RDX` → string (flat pointer; the old `DS:DX` is just `RSI`/`RDX` now) |
   | `3Fh` | read | `BX`=0 (stdin only), `CX`=count (low 16), `RDX`=buffer → `RAX`=count, 0 = no more data |
   | `40h` | write | `BX`=1/2 (stdout/stderr), `CX`, `RDX` |
   | `4Ch` / `INT 20h` | exit | `AL`=code |
   | `0Fh–17h/21h–24h/27h–29h` | FCB file/dir ops | read-only data access works; writes are record-granular |
   | `48h/49h/4Ah` | alloc/free/resize | byte-based heap |
   Explicitly **absent** (stubs, `handler_inuse`): `3Ch` CREATE, `3Dh`
   OPEN, `3Eh` CLOSE, `42h` LSEEK — handle file output needs N2.
   Design around them: read via FCB/`3Fh`, write to console via `40h`.
4. **Exit, don't return.** End with `AH=4Ch` (or `INT 20h`). There is no
   return address to the shell.
5. **Small.** The shell stages the whole file into a 4 KiB buffer
   (`sh_file`) before spawn, and the command tail caps at 127 bytes
   (`PSP64.cmd_tail`). Keep images < 4096 bytes; keep CLI args tiny.
6. **8.3 uppercase names.** `FOO.COM`, `HELLO.COM` — the FCB parser
   (`fs_make_fcb64`) uppercases and matches 11-byte names.

Minimal example (`samples/hello.asm`, 37 bytes assembled):

```nasm
bits 64
default rel
start:
    mov ah, 0x09
    lea rdx, [rel msg]
    int 0x21
    mov eax, 0x4C00
    int 0x21
msg: db 'Hello from DOS64', 13, 10, '$'
```

```bash
nasm -f bin samples/hello.asm -o HELLO.COM
```

PSP-tail example (`samples/echo.asm`): the shell stores the command tail
at `PSP+0xA0` (len) / `PSP+0xA1` (127 B). A `.COM` loads at `PSP+PSP_SIZE`
(664), so `PSP = entry - 664`, derived from RIP (`lea rax, [rel start]` /
`sub rax, PSP_SIZE`) — N2a additionally guarantees `RDI = PSP` on entry.

Stdin→stdout example (`samples/cat.asm`): loop `3Fh`/`40h` in 128-byte
chunks, exit on a zero-length read. Named-file args need `3Dh` (N2 gap),
so this is a console-pipe demo, not `cat file`.

## 2. `MZ64` header recipe (> 64 KiB or entry-offset programs)

Raw `.COM` (any non-`MZ64` image) enters at `PSP+PSP_SIZE`. For anything
bigger or with a non-zero entry offset, prepend the 32-byte `MZ64`
header (`proc_verify_image64` / `proc_load_image64`):

| Off | Size | Value |
|---|---|---|
| +0 | 4 | magic `0x34365A4D` (`'MZ64'`, bytes `4D 5A 36 34`) |
| +4 | 4 | `hdr_size` = 32 |
| +8 | 8 | `image_size` (payload bytes after header; `> 0`, `<= filesize-32`) |
| +16 | 4 | `entry_off` (`< image_size`; entry = `PSP+PSP_SIZE+entry_off`) |
| +20 | 4 | `stack_size` (`0..65536`, advisory) |
| +24 | 8 | zero |

```bash
nasm -f bin payload.asm -o payload.bin
python3 -c "
import struct,sys
pay = open('payload.bin','rb').read()
hdr = struct.pack('<IIQIIQ', 0x34365A4D, 32, len(pay), 0, 0, 0)
open('BIG.COM','wb').write(hdr + pay)"
```

Payload rules are the same as §1 (bits 64, RIP-relative, real handlers
only). Spawn budget still applies: `PSP + payload + 2048 < 6 MiB`.

## 3. Getting programs onto the volume

```bash
make nasm-samples      # assemble samples/*.asm with the submodule NASM,
                       # stage HELLO/ECHO/CAT/WRITE .COM onto build/dos64-nasm.img
make run-qemu-nasm     # boot it (serial in your terminal)
```

What `make nasm-samples` does: builds `build/nasm-sub/src/nasm` from the
`nasm/` submodule on first use (cached; `build/` is gitignored),
assembles `samples/*.asm` with `-f bin` into `build/nasm-samples/`,
copies the smoke `mbr`/`stage2`/`kernel` artifacts, and stamps the FAT12
volume with `tools/mkfat12.py --extra-file HELLO.COM=… --extra-file
ECHO.COM=… --extra-file CAT.COM=… --extra-file WRITE.COM=…` (client-file
support lives in the stamper, not in the default `make` path — the
default image keeps only `HELLO.TXT/README.TXT/TEST.COM/DATA.BIN`).
`tools/check_volume_clean.py` allow-lists the four sample names:
permitted but never required, and when present they must be chain-valid
and ≤ 4096 bytes.

Demo (serial-driven, QEMU) — since N2d the shell ENTERS programs:

```bash
printf '\rDIR\rHELLO\rWRITE hello\rTYPE OUT.TXT\rDEL OUT.TXT\rEXIT\r' \
  | timeout 25 qemu-system-x86_64 \
  -drive file=build/dos64-nasm.img,format=raw -serial stdio -display none
```

Expect the four `.COM` names in the `DIR` listing, `Loaded, pid N`
followed by `Exit <code>` after each external name, `hello` from `TYPE
OUT.TXT` (the file `WRITE.COM` created via `3Ch`/`40h`/`3Eh`), and a
clean volume afterwards (`DEL` removes it; child console printing is
VGA-only — serial shows the shell lines). This is the N2 acceptance demo
(PLAN.md Phase N2): volume-loaded `.COM` with args runs, writes a file
through the handle layer, exits with a code the shell prints.
Note: type `HELLO` or `CAT`, not `ECHO`, to run a sample — `ECHO`
resolves to the shell's `ECHO` builtin (builtins win over externals in
`sh_exec_line`), so `ECHO hi` prints `hi` without touching `ECHO.COM`.
`ECHO.COM` rides along as a spawn/verify target; `WRITE.COM` is the argv
round-trip test (its exit code IS the tail length).

## 4. Honest EXEC limits (read before filing bugs)

Since N2d the shell ENTERS programs (`sh_do_exec` → `proc_enter64`,
cooperative like DOS): `<name>.COM` loads from the volume (≤ 4096 bytes),
spawns, runs on its own stack with `RDI=PSP`, and returns via `RET`
(exit 0) or `AH=4Ch`/`INT 20h` — the shell prints `Loaded, pid N` then
`Exit <code>` and reaps. Remaining limits:

- Child `INT 21h` console output (`AH=02h/09h`) goes to VGA text only;
  shell lines (`Loaded`/`Exit`/builtins) go to VGA+serial. Drive the
  serial demo via exit codes and files, not child printing.
- No `argc/argv` beyond the 127 B `cmd_tail` (`RDI=PSP` + raw tail;
  tokenized argv is N3 `crt0` work), no redirection or pipes (use `-o`
  flags later), no timer preemption (cooperative only, by design).
- Batch `%ERRORLEVEL%` expands (uppercase only); `ECHO`-style builtins
  still shadow same-named `.COM`s.
- `TYPE` shows the first 4 KiB; serial RX is 1 byte deep (paste bursts
  can overrun); serial TX is bounded best-effort (dropped, never hangs).
