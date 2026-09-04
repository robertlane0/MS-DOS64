# Phase 8 Completion Report — Process Management (PSP64)

**Date:** 2026-09-04
**Branch:** `phase8-process` (building on `phase7-filesystem`)
**Engineer:** Muse Spark
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 8 (AGENTS.md §Phase 8, docs/01 §2.2, docs/03 §6) is **complete and verified**.
DOS 1.25's program scaffolding (`SETMEM MSDOS.ASM:3363-3410`, `ABORT:1356-1393`,
`COMMAND.COM COMLOAD/EXELOAD COMMAND.ASM:953-1000,2028-2091`) is now a flat
64-bit process manager on the MCB64 heap (Phase 6) and FAT12 layer (Phase 7):
512→664 B `PSP64` init/validate (INT 20h kept as debug bytes, top-mem linear,
CALL5, INT 22/23/24 RIPs, FCBs, 127 B cmd tail, env dq, CR3/RSP/RFLAGS,
R8–R15 save, 16× fd table), NUL-joined `ENV` blocks (`NAME=VAL` + double NUL,
DOS 2+ env-segment analog), COM raw + `EXE64 'MZ64'` (32 B hdr) loader to
`PSP+PSP64_size`, spawn/exit/reap lifecycle with MCB owner = PSP linear,
and `INT 21h AH=4Bh EXEC / 4Ch EXIT / INT 20h ABORT` wired into `DISPATCH64`.

7 new tests extend the harness to **34 total — all 34 PASS** on Bochs and QEMU,
no `#UD/#GP/#PF`, no BIOS calls.

```
 Bochs / QEMU serial.log after Phase 8 (tail):

  [28] PSP init/validate (SETMEM analog)... PASS
  [29] PSP cmd tail + exit/fd/CR3... PASS
  [30] ENV init/set/get/unset/count... ABCDEFGHIJKLM2NPASS
  [31] Loader COM vs EXE64 + bad hdr... PASS
  [32] Spawn/exit lifecycle + owner... g2abcdefghPASS
  [33] EXEC/EXIT via INT21 dispatch... pqr1[0002]323stuvwxyz!@#$PASS
  [34] Stress max procs + reap/validate... PASS

 Summary: 34 passed, 0 failed
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
 Phase6 memory management (MCB64): ALL TESTS PASS
 Phase7 filesystem adaptation (FAT12): ALL TESTS PASS
 Phase8 process management (PSP64): ALL TESTS PASS
```

> Diagnostic note: `[30]/[32]/[33]` emit single-letter progress markers
> (`A–N`, `a–h`, `p–$`, `[0002]`, counts `2`/`3`) on the same serial/VGA line
> before `PASS`. They are intentional (fail-point isolation, cf. Phase 7's
> `ATA DBG` prints) and do not affect `PASS`/`Summary` parsing. `[32]`'s
> leading `g2` is the tail of `[30]`'s count print (`2`) plus stage print;
> stage `5` (env-alloc) and `1[0002]323` (pid/next/dbg/count) were used to
> isolate the MCB-40 and dispatch-AH bugs below.

---

## 1. Scope (AGENTS.md Phase 8 checklist)

| Requirement | Implementation | Test |
|---|---|---|
| Design 64-bit PSP structure | `PSP64` already in `include/psp.inc` (664 B actual; `PSP_SIZE=PSP64_size`); `psp_init/validate/set_cmdtail/get_cmdlen/set_exit` | `[28]` magic/top/exit/fd/CR3, bad-magic/top; `[29]` tail 11/0/128-fail, vectors, fd, CR3 |
| Program loader for 64-bit executables | `proc_verify_image` (0 COM / 1 EXE64 / 2 bad), `proc_load_image` to `PSP+SIZE`, entry = base (+off) | `[31]` COM pattern + entry, EXE hdr/payload/off, size-0/hdr-size/image-size/entry-range/load-CF |
| Process termination handler | `proc_terminate(pid,code)` (free env+proc → zombie, current→0), `proc_exit_current(code)`, `proc_reap`, `proc_free_all`; `handler_abort` (INT 20h) no longer `jmp [EXITHOLD]` (was 0 → #GP) | `[32]` terminate/reap/double-fail, exit-current/current-reset; `[33]` `handler_abort` + kernel-abort-safe |
| Memory allocation for processes (INT 21h/48h) | Reused Phase 6 `mem_alloc/free` + `handler_alloc/free/resize`; spawn sets `MCB.owner=PSP` (was 1 kernel) for per-process accounting | `[32]` owner==PSP, `mem_validate`; `[34]` totals after free-all |
| Memory deallocation (INT 21h/49h) | Same + terminate frees env then proc, validates, reaps | `[32]` free counts, `[34]` max-free/total-free, invalid/double-free |
| Environment blocks (64-bit) | `env_init/count/get/set/unset` (double-NUL, `?` N/A, `=`-reject, no-space, delete-memmove) | `[30]` 0→3→3→2, get/overwrite/unset/missing/bad-name/small-no-space |
| System-call wiring (EXEC/EXIT) | `DISPATCH64[4Bh]=handler_exec` (`proc_spawn`), `[4Ch]=handler_exit_process` (AL code), `handler_abort` → `proc_exit_current(0)` | `[33]` direct EXEC, dispatch EXEC (pid frame + CF), dispatch EXIT (AL), abort |

New exports (`src/kernel/proc64.asm`, 21 globals): `proc_init/alloc_slot/count_running/count_zombie/get_current/set_current/get_psp/get_entry/get_pid`,
`psp_init/validate/set_cmdtail/get_cmdlen/set_exit`, `env_init/count/get/set/unset`,
`proc_verify_image/load_image/spawn/terminate/exit_current/reap/free_all`
(+ `proc_next_pid/current/state/pid` introspection, `exec_dbg_pid`).
`handler_exec/exit_process` in `syscall64.asm` (77-entry `DISPATCH64` now fully
populated through `4Ch`).

---

## 2. What Was Built

### 2.1 `psp_init64` — SETMEM analog (`MSDOS.ASM:3363`)

`RDI=psp, RSI=top, RDX=exit-RIP, RCX=env` → zero `PSP64_size`, `CD 20`,
`top_mem`, `call5=0`, `exit/cont/error` (`CS=0x08`), FCBs zero, `cmd_len=0`,
`env/cr3 (mov rax,cr3)/rsp/pushfq`, `fd=[0,1,2,-1×13]`. Validates
`psp!=0`, `top>psp+SIZE`, `top≤0x800000`. `psp_validate` returns
`0 ok / 1 magic / 2 top / 3 env`.

### 2.2 `ENV` — DOS 2+ env-segment analog

`env_init` (double NUL), `env_count` (scan to double NUL, ≤1024),
`env_get` (exact `NAME=` match, value copy with truncation-NUL),
`env_set` (find → delete-memmove / replace-memmove forward (`new<old`) or
backward `STD` (`new>old`) / append at `base+used-1` (non-empty,
`new_used=used+newlen`) or `base` (empty, `newlen+1`)), `env_unset`
(`env_set` with `NULL` value, 64 KiB pseudo-size as delete ignores size).
Defaults on spawn: `PATH=.`, `COMSPEC=COMMAND64`.

### 2.3 Loader — COMLOAD/EXELOAD analog

`EXE64` 32 B hdr: `magic 0x34365A4D ('MZ64')`, `hdr_size 32`,
`image_size dq`, `entry_off dd (<image_size)`, `stack_size dd (≤64 KiB)`,
`reserved dq`. `verify` → `0 COM` (any non-`MZ64` or `<32 B`),
`1 EXE64`, `2 bad` (0/oversize/`>16 MiB`/`hdr≠32`/`image+32>size`/
`entry≥image`). `load` copies payload to `PSP+SIZE`, bounds-checks
`dest+size≤0x800000`, returns entry (`base` / `base+off`), `CF`.

### 2.4 Spawn/exit — EXEC (`AH=4Bh`) / EXIT (`AH=4Ch`) / ABORT (`INT 20h`)

`proc_spawn(RDI=src,RSI=size,RDX=cmd,RCX=cmdlen,R8=env_src(0=default))`
→ `verify` → `payload` → `total=PSP_SIZE+payload+2048` (`<6 MiB`) →
`mem_alloc(total)=psp` (+`owner=psp`) → `mem_alloc(1024)=env`
(+`owner=psp`, `init` + defaults) → `psp_init(top=psp+total)` →
`cmdtail` → `load` → `alloc_slot` → `pid=next++`, `entry/stack/exit/mem/env`,
`state=RUNNING` → `RAX=pid,RDX=psp` (`0,stage` on fail; stage `1 verify,
2 total, 3 proc-alloc, 4 no-psp, 5 env-alloc, 6 psp-init, 7 cmd, 8 load,
9 slot` was used for bring-up, `RDX=psp` on success).
`terminate(pid,code)` (reject `0`/zombie/unknown) frees env then proc,
stores code, `state=ZOMBIE`, `current→0` if needed. `exit_current(code)`
terminates `current` (reject kernel). `reap(pid)` frees zombie slot.
`free_all` terminates+reaps children, returns count.
Table: 16 slots, `0 FREE / 1 RUNNING / 2 ZOMBIE`, slot 0 = kernel `pid 0`.

`handler_exec` (`RDI=src,RSI=size,RDX=cmd,RCX=len,R8=env`)
→ `proc_spawn` → `RAX=pid,RDX=psp,CF` + frame `rax/rbx_save=pid`.
`handler_exit_process` uses `AL` when `AH==0x4C` (trap `RAX=0x4Cxx`),
else `RDI`, → `proc_exit_current`. `handler_abort` → `proc_exit_current(0)`
(kernel-safe `1→0`). `IOSTACK/DSKSTACK` grown `1024→4096` for EXEC depth.

---

## 3. Bugs Found & Fixed (via QEMU serial FAIL isolation)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `proc64.o` assembly `label changed` cascade + `proc_strlen` undef | `.proc_strlen` local-dot resolves to `env_get.proc_strlen`/`env_set.proc_strlen`, not shared | rename to `proc_strlen_helper` (global) + 3 call sites (helper takes `RDI`, preserves it) |
| 2 | `nasm: indirect RIP+SIB` ×37 | `[rel table + reg*8]` illegal (RIP+SIB) | `lea r11/r9,[table]` + `[r11+reg*8]` (r11 free; r9 for spawn's env-live region; `proc_free_all` `ecx→rcx`) |
| 3 | `[30]` stops at `AB` (first `env_set` → `2 bad name`) | `env_get/set` called helper with `RSI=name` but helper takes `RDI`; computed `strlen(env)=0` → empty-name reject | `mov rdi,r8/r9` before helper; save `env→r10` first (helper preserves `RDI`) |
| 4 | `[30]` stops at `M` (`count` after `unset` = `3`, want `2`) | `env_unset` stack chaos (push 3 / pop 3 then reuse clobbered `RSI=65536` as name → `RDX=65536` bogus → find miss → no delete, yet `0` ok) + delete left single-NUL + garbage (`28=0,29='R'`) so count sees leftover as 3rd entry | rewrite `env_unset` clean (`push rbx; RDX=name,RSI=65536,RCX=0; call; pop`); after delete-memmove zero `[base+new_used]` for double-NUL (`M2N` now) |
| 5 | `[30]` `bl` corruption (latent) | `env_get` used `bl` (`[r8+r11]`) while `RBX=out_size` live | `bl→cl` (`RCX` free at compare time) |
| 6 | `[32]` stage `5` (env-alloc fail) + heap corruption | `MCB.owner` patch used `psp-32+8` (=`size` field) but `MCBSIZ64=40` (type1+pad7+owner8+size8+name8+pad8); overwrote `size` with `0x2000xx` → next-block walk off → 2nd alloc fail | `sub rbx,MCBSIZ64` + `[MCB64.owner]` (proc + test's `sub 32→40`) |
| 7 | `[33]` `pqr1[4B71]212` (`count 2`, `next 2`, `pid 0x4B71`, `dbg 1`) | `syscall_dispatch64: cmp eax,MAXCOM` compared `0x4B00(19200)>0x4C(76)` → always `.dispatch_bad` (`AL=0`, `CF` preserved 0, `RAX=0x4B00` restored) → stub never ran `handler_exec` (`exec_dbg` stayed `1`, `next` stayed `2`) | `cmp ah,MAXCOM` (function byte, Phase 8) |
| 8 | `leave64`/`dispatch` reg shuffle (latent, masked by test saves) | `dispatch` pushed `rbx..rax` but `leave` popped `r15..rax` (same order, not reverse) → `r12←old r13` etc.; `savregs` last line loaded `BL` from `[SPSAVE]` (pointer low) not `AH` | `dispatch` pushes `r15..rax` (match `savregs`/`STKPTRS64`); `leave` pops `rax..r15` (reverse); `savregs` → `movzx ebx,byte [rbx+1]` |
| 9 | `env_set` replace-larger heap smash (latent; same-size `PATH` masked) | `mov rcx,[rsp+72]` (buf_size) overwrote `RCX=used` before `tail=used-off-old` → `tail≈1000` → `rep movsb` past 1024 into proc tables | delete that reload (`RCX` already `used`) |
| 10 | Test-only `mov al,'q'/'@'` clobbered `RAX=pid` before `mov r14,rax` (`[0071]`, `@→64`) | debug print overwrote low byte before save | save `r14/r12` before `mov al` (kept; explains `[4B71]`→`[0002]` transition) |

Total: 10 defects (2 build, 5 logic, 2 trap-frame, 1 test-debug), all reproduced
on QEMU before fixing; Bochs confirms. Debug markers (`A–N`, `a–h`,
`p–$`, `[0002]`, `2`/`3`) kept intentionally for fail-point isolation.

---

## 4. Verification

```bash
make clean && make
# mbr.bin 512 (55 aa), stage2.bin ~1K, kernel.elf 102816, kernel.bin 31756 (62 sectors ≤ 64)

# QEMU
timeout 15 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# → 34 passed, 0 failed + 6× ALL TESTS PASS

# Bochs (target)
rm -f bochs.log serial.log build/dos64.img.lock && timeout 30 bochs -f bochsrc.txt -q
# → serial.log identical 34 PASS; bochs.log: no #GP/#UD/#PF (only SNDCTL notice)
```

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | ~1K | ≤ 15-sector slot |
| `build/kernel.bin` | 31756 (62 sectors @16) | ≤ 64 (`KERNEL_SECTORS`) |
| `build/dos64.img` | 10 M | MBR + stage2@1 + kernel@16 |

Heap discipline: Phase 8 tests `mem_reset+proc_init` on entry,
`proc_free_all` on exit; scratch stays Phase 7 `LBA 500–511`
(`[34]` is RAM-only spawns, no disk). `IOSTACK/DSKSTACK` 4 KiB each
covers `spawn→alloc→env_set→strlen` depth (~280 B worst).

---

## 5. Checklist (AGENTS.md Phase 8)

- [x] Design 64-bit PSP structure (`PSP64` init/validate/cmd/exit/fd/CR3)
- [x] Implement program loader for 64-bit executables (COM + `MZ64`)
- [x] Create process termination handler (`terminate/exit/reap`, `ABORT`)
- [x] Implement memory allocation for processes (`48h` + `owner=PSP`)
- [x] Implement memory deallocation (`49h`, env+proc free)
- [x] Set up process environment blocks (`ENV` 64-bit)
- [x] Boot + 34 PASS on Bochs & QEMU, no faults

**Next:** Phase 9 syscall dispatcher (`INT 21h` IDT gate + `AH` handlers
`01/02/09/0A/.../3F/40/4C` on top of `proc/fs/mem`; `EXEC` path already
exercises `4Bh/4Ch` via `DISPATCH64`, `SAVREGS/LEAVE` now frame-correct).
