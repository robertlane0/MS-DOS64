# N2 — Real execution + file + argv: design + acceptance tests

Status: **design only — not implemented.** N1 (cross-assemble + run,
`docs/21-nasm-cross.md`) is the last landed tier. This doc is the build
order for the hard prerequisite both assembler tracks need. Land and
stabilize everything below before any N3/N4 work.

Non-goals (stay cooperative like DOS): no timer preemption, no per-process
`CR3` switch (store it in `PSP64`, switch later), no `MZ`/`PE` loading.

## 0. What exists today (do not regress)

- `proc_spawn64` (`src/kernel/proc64.asm:1285`): memory image → PSP (664 B)
  + payload at `PSP+PSP_SIZE` + 2048 B stack + 1024 B env; records 16-slot
  table (`proc_pid/psp/entry/stack/exitcode/memsize/envptr/state`);
  returns `(pid, psp)`. Never enters the image (enter is N2a,
  `proc_enter64`).
- `handler_exec` (`src/kernel/syscall64.asm:2367`): trap wrapper, writes pid
  to the `SPSAVE64`/`STKPTRS64` frame (`include/regs.inc`), stack-slot
  discard (no BSS statics — `make check-debug-symbols` enforces).
- `sh_do_exec` (`src/kernel/shell64.asm:657`): **EXEC-from-path already
  works** — loads `<name>.COM` (≤ 4096 B via `sh_file`) from the FAT12
  volume, stages via `mem_alloc64`, passes the shell tail
  (`sh_tail_len` → `cmd_exec_external64` → `psp_set_cmdtail64`), prints
  `Loaded, pid N`, then terminate+reap. The missing half is enter/return.
- FCB file core is real (`handler_open/close/delete/create/rename`,
  `fs_fcb_*`, `fs_vol_read_file64`, FAT+root write-through, crash ordering
  `include/fs.inc:98-119`). Handle `3Fh`/`40h` exist but only for console
  handles 0/1/2; `3Ch/3Dh/3Eh/42h` are `handler_inuse` stubs.
- `PSP64.fd_table` (`include/psp.inc`: 16×qword at `+0x198`) is reserved —
  N2 defines its semantics (below). No struct change needed.

## 1. Enter/return (`proc_enter64`, N2a — first)

New leaf in `proc64.asm` (`proc_enter64`, landed N2a). The `AH=4Bh` trap
and `sh_do_exec` stay spawn-only until N2d — no run-flag wiring yet;
tests call the leaf directly. `sh_do_exec` flips to enter once tests
84–86 are green:

```text
In:  RDI = pid (or psp — pick psp, it is unambiguous), documented at call sites
Out: RAX = child exit code, CF 0/1
```

1. Find the slot by `psp` (`proc_psp[]` + `PROC_RUNNING`; never dereference
   the pointer, so garbage fails clean) and fetch `entry` + `stack_top`.
   `stack_top` is aligned *down* (`and ~15`): `psp+total` inherits the
   arbitrary payload size, so alignment is enforced, not assumed.
2. Save the caller on the **current (kernel) stack**: `push RBX RBP R12–R15`
   + `pushfq`, record `RSP` into one BSS qword `exec_caller_rsp`
   (functional save slot, cooperative single-threaded — no reentrancy;
   this is not a debug hook, documented next to `check-debug-symbols` so
   the audit stays clean). `exec_prev_current` saves `proc_current`.
   Single-depth: non-zero `exec_caller_rsp` on entry fails honestly.
3. `RSP := stack_top`, `push child_ret_trampoline`, `RDI := psp` (+ zero
   all other GPRs for a deterministic entry state), `jmp entry`. At entry
   `RSP%16==8` with the trampoline as return address — exactly like `call
   entry`, except a bare `RET` from a `.COM` (e.g. `TEST.COM`'s single
   `0xC3`) lands in the trampoline with exit code 0. (`jmp`, not `call`,
   is deliberate: `call` would put our own return address on top of the
   child stack ahead of the trampoline.)
4. Trampoline + `AH=4Ch` path converge: `proc_exit_current64` checks
   `exec_caller_rsp != 0`: if set, terminate (stores code to
   `proc_exitcode[slot]`, frees blocks, marks zombie — touching no child
   memory afterwards), then restore `proc_current`, caller `RSP`/`RFLAGS`/
   regs, clear both slots, and return the code in `RAX` to the enter
   caller — abandoning the INT/stub frames on the freed child stack. The
   `RFLAGS` restore matters: the `0xEE` interrupt gate clears `IF` on the
   `INT 0x21` path, so the caller gets its own saved flags back. If clear
   (child outliving its enter — must not happen), keep today's
   mark-zombie behavior.
5. Caller regs `RBX RBP R12–R15` + `RSP` + `RFLAGS.IF` preserved across the
   round trip (System V AMD64, `stack64.asm` discipline); canary intact
   (`mem_validate64`).

Sequencing (per PLAN §7 risk row): land `proc_enter64` + tests 84–86 with
the shell still spawn-only; flip `sh_do_exec` to enter only after 84–86
are green on QEMU **and** Bochs. No `EXEC_ENTER` ifdef needed if this order
holds — if boot destabilizes, revert the one-line shell flip, not the leaf.

## 2. Handle syscalls (N2b — second)

Per-proc open-file table **is** `PSP64.fd_table` (16 entries, owner = PSP,
freed with the proc block): `fd` = index; 0/1/2 reserved
stdin/stdout/stderr (today's console behavior, unchanged); 3..15 files.
Entry: `(state, firstclus, size, pos, mode)`. All metadata writes reuse the
FCB write-through paths (`fs_fcb_create64/open/close`, `fs_vol_flush_fat64/
flush_root64`) and the crash orderings (`include/fs.inc`: extend =
data→FAT→root; truncate/shrink = root→FAT; delete = root→FAT; mirrors
FAT1-then-FAT2, mount heals).

- `3Dh` OPEN: `RDX` → NUL-terminated 8.3 name (flat root only, no subdirs;
  strip any `X:` drive prefix, reject `\` paths). Read-only and read/write
  modes. Slice 1 ships read-only + `3Eh`.
- `3Eh` CLOSE: flush (if dirty + writable), free slot. Double-close → CF=1.
- **Slice 1 (smallest useful end-to-end, PLAN §8.4): table + `3Dh`-ro +
  `3Eh` + test 87 (open/close round-trip, zero writes) — landed in N2b.**
- `3Ch` CREATE: `RDX` → name; truncate-if-exists (root→FAT order) else
  alloc entry; returns writable fd. Reuses `SCRATCH.TXT`-namespace tests.
- `42h` LSEEK: `BX`=fd, `CX:DX`/`RCX`=offset, `AL`=origin (0 set / 1 cur /
  2 end); clamp `0..size` (no sparse extends); CF=1 out of range.
- Extend `3Fh`/`40h` beyond console handles: `BX` ≥ 3 → table lookup;
  `3Fh` short-reads at EOF (CF=0, `RAX` < count — same contract as stdin);
  `40h` at `pos == size` extends alloc-on-write (FAT+root write-through);
  record-granular writes stay (matching FCB semantics).
- No new test-namespace names: handle file tests reuse `SCRATCH.TXT`
  (pre-clean recovery + `check_volume_clean.py` already cover it).

## 3. Argv/env convention (pins the N0 open item)

- N2a: `RDI = PSP` on entry (also derivable as `entry - PSP_SIZE` =
  `entry - 664` for `.COM`, which `samples/echo.asm` does — both hold).
  Raw tail stays the DOS-compatible fallback (`PSP+0xA0` len, `+0xA1`
  127 B, set at spawn).
- N2b (with `libc64`): shell tokenizes the tail into a NUL-joined argv
  block above the child stack; `ECX = argc`, `RDX = argv` (pointer to
  pointer-array), block freed with the proc. `ENV` (1024 B, owner = PSP,
  `PATH=.` / `COMSPEC=COMMAND64` defaults via `env_init64`/`env_set64`)
  is copied to the child, never aliased.
- `MZ64` contract (`docs/20-nasm-gaps.md` §4) unchanged, plus `RDI = PSP`.

## 4. Exit codes + `ERRORLEVEL`

Child code travels `AL`/`RDI` (at `RET` trampoline or `AH=4Ch`) →
`proc_exitcode[slot]` → `reap` returns it → `sh_do_exec` prints
`Loaded, pid N` today; after the N2a flip it additionally prints
`Exit <code>` on return (non-zero codes especially — batch use).
Batch `%ERRORLEVEL%` query rides the `%1`–`%9` machinery
(`src/kernel/cmd64.asm`) — N2b, after codes are stable. `ECHO.COM`
becomes the argv round-trip test the moment enter lands (it is staged
but builtin-shadowed today — `docs/21-…md` §3).

## 5. Acceptance tests (84+, in `src/kernel/selftest64.asm`)

| # | Test | Mode |
|---|---|---|
| 84 | spawn→enter→return round-trip: in-memory `RET` image, expect code 0; caller `RBX RBP R12–R15`/`RSP`-align/canary preserved | PURE (smoke-safe) |
| 85 | exit-code propagation: `mov al,0x2A` + `AH=4Ch` image → reap returns `0x2A` | PURE |
| 86 | argv echo: spawn with tail `HI`, enter tail-reader image copying to a harness buffer (address patched into the image), parent `memcmp` | PURE (memory image + BSS buffer, no device writes) |
| 87 | slice-1 handle cycle (N2b, landed): `3Dh`-ro open + `3Eh` close of `README.TXT` direct + trap paths, negatives, 13-fd bound, scrub/mirror/orphan invariance | READ-ONLY |
| 88 | full handle cycle (N2c): `3Ch` create + `40h` write + `42h` seek + `3Fh` read + `3Eh` close on `SCRATCH.TXT`, content verified | DESTRUCTIVE (`SELFTEST_DESTRUCTIVE`, SKIP-counted in smoke like 71/83) |
| 89 | volume-clean invariance after 84–88: scrub 0, mirrors match, `check_volume_clean.py` pre/post clean | READ-ONLY + destructive-half |

Acceptance (PLAN N2): a hand-written 10-instruction `.COM` loaded **from
the volume by name** with args runs, writes a file via `3Dh/40h/3Eh`,
exits with a code the shell prints; `make` + `make full` green on QEMU
and Bochs; `make lean` unaffected. Smoke stays non-destructive
(`85+2`-pattern extended, never volume writes outside scratch LBAs);
`make check-serial`/`check-kbc` patterns hold (child error paths use
bounded `serial_try_putc64` only, never spin).
