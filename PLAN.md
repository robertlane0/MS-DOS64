# NASM support in MS-DOS64 — Plan

## 1. Goal

Let users write assembly on a host, assemble it with NASM syntax, and run
the result on MS-DOS64 — and, eventually, assemble **on** MS-DOS64 itself
(self-hosted development from the `COMMAND64` prompt).

Recommended scope, in order:

1. **Cross-assemble + run (no OS change).** Document and smooth the flow
   that already works: host-side `nasm` → raw `.COM` / `MZ64` → copy onto
   the FAT12 volume → `EXEC` from the shell. This is the only tier that
   works today.
2. **Native mini-assembler (short term).** A small DOS64-hosted assembler
   covering a useful NASM subset (`-f bin` only), shipped as a `.COM`
   program. No C toolchain required.
3. **Full NASM port (long term).** The vendored `nasm/` submodule (currently
   `nasm-3.02-50-gfbdc88565`) running as a DOS64 process. Requires a libc
   shim, new syscalls, and real process execution. Large; do it last.

`PLAN.md` success = tier 1 done + tier 2 designed with acceptance tests;
tier 3 broken into fundable milestones, not attempted in one jump.

## 2. Current state (what exists today)

| Area | State | Reference |
|---|---|---|
| Host build | Uses host `nasm >= 2.15` (`-f bin` boot, `-f elf64` + `ld -T linker.ld` kernel) | `Makefile:53-67`, `AGENTS.md` Phase 2 |
| NASM source | Vendored as git submodule at `nasm/`, v3.02, **host build tool only**, not shipped on the image | `.gitmodules`, `nasm/version` |
| Executable loading | Raw `.COM` (any non-`MZ64` image) + `MZ64` (32 B hdr: magic `0x34365A4D`, `hdr_size 32`, `image_size`, `entry_off`, `stack_size ≤ 64 KiB`) via `proc_spawn64` | `src/kernel/proc64.asm:1277-1428`, `docs/13-phase8-process.md §2.3` |
| `EXEC` semantics | **Spawns but does not context-switch.** `proc_spawn64` allocates PSP+payload+stack, inits PSP64/env, copies image, records pid/entry — it never `call`/`jmp` the entry, and the shell never transfers control | `AGENTS.md` Phase 10 (“EXEC spawns but does not context-switch”), `src/kernel/cmd64.asm:1459-1475` (`cmd_exec_external64` returns pid/psp only) |
| Syscalls | 77-entry `DISPATCH64` (`AH=00h–4Ch`), DPL3 `INT 0x21` gate. Consoles, FCB files, drives, DMA, `48h/49h/4Ah` alloc, `4Bh/4Ch` EXEC/EXIT real; DOS-reserved slots stubbed | `src/kernel/syscall64.asm:319-396`, `docs/19-closure-g1-g6.md` G1 table |
| Handle I/O gap | `3Fh` READ / `40h` WRITE exist, but **`3Ch` CREATE, `3Dh` OPEN, `3Eh` CLOSE, `42h` LSEEK are stubs** (`handler_inuse`). Assembler file output needs these | `src/kernel/syscall64.asm:381-389` (`41–47` all `handler_inuse`) |
| Memory | Flat 64-bit, heap `0x200000+` (`MCB64` 40 B, first-fit), identity map 0–8 MiB (PML4 @`0x1000` → PDPT @`0x2000` → PD @`0x3000`, 4×2 MiB), spawn `total = PSP + payload + 2048 < 6 MiB`, 16 proc slots | `AGENTS.md` Memory map, `src/kernel/proc64.asm:1320-1326` |
| Filesystem | Real FAT12 volume LBA 512–3391 (2880 sectors, 1.44 M geometry, stamped by `tools/mkfat12.py`), FCB record I/O core + `3F/40` handles; `TYPE` shows first 4 KiB; reserved test namespace `SCRATCH.TXT` / `RENAMED.TXT` / `CRASH.TXT` | `Makefile:23-28` layout block, `include/fs.inc` |
| Disk budget | Kernel ≤ 176 sectors (~86 KiB today); volume holds `HELLO.TXT`, `README.TXT`, `TEST.COM`, `DATA.BIN`. A full NASM binary (~1 MB Linux build) **does not fit** alongside the kernel growth headroom without layout changes | `Makefile:174,181`, `README.md` |
| Shell | `COMMAND64` REPL (`src/kernel/shell64.asm` + `src/kernel/cmd64.asm`): builtins, batch `%1`–`%9` + `%%`, `*.COM` via `proc_spawn64`; single address space, no argv beyond 127 B PSP tail, no redirection/pipes | `AGENTS.md` Phase 10 |
| ABI | System V AMD64, 16 B `RSP` alignment, near `CALL/RET` only, no TSS/IST yet | `AGENTS.md` Driver/ABI specifics |

Bottom line: **no C program can run on MS-DOS64 today** — there is no libc,
no handle-based file create/open/close/seek, no way to pass `argc/argv` or
files to a child, and no way to actually enter the child image.

## 3. Gap analysis for a NASM port

NASM upstream (`nasm/asm`, `nasm/output`, `nasm/nasmlib`, `nasm/x86`,
`nasm/common`, `nasm/disasm`) is ~44 kLOC of hosted C (measured via
`wc -l nasm/*/*.c`). Porting it needs, at minimum:

1. **Execution (`P0`, blocks everything).** `proc_spawn64` + `handler_exec`
   + shell must grow from “allocate and record” to “load, enter, return
   with exit code”. Today there is no `call entry`, no child stack switch,
   no `RET`-to-parent, and `handler_exit_process` only marks zombie state.
   Without this, neither a mini-assembler nor NASM can be *run*.
2. **Program arguments and environment (`P0`).** NASM needs
   `nasm [-f bin] [-o out] in.asm`. Today: 127 B PSP tail only, set at
   spawn; shell does not tokenize into `argv`, and `ENV` defaults to
   `PATH=.` / `COMSPEC=COMMAND64`. Need a documented `argc/argv` + env
   convention on top of `PSP64.cmd_tail` / `env_ptr` (`include/psp.inc`).
3. **Handle file syscalls (`P0`).** NASM reads source/includes/macros and
   writes object/listings. Missing: `3Ch/3Dh/3Eh/42h`
   (create/open/close/seek). FCB paths (`0Fh–17h/21h–24h/27h–29h`) exist
   but are the wrong interface for a C `stdio` shim; extending the `3F/40`
   handle layer is the correct target.
4. **Libc shim (`P1`).** NASM calls `malloc/realloc/free`, `fopen/fread/
   fwrite/fseek/fclose`, `mmap` (`nasm/nasmlib/mmap.c` uses Unix `mmap`),
   `string/ctype`, `exit`, and generated-table code (`insns.dat`,
   `pptok.dat`, `tokens.dat` via Perl at build time). Need a freestanding
   `libc64` mapped onto `mem_alloc64` (`AH=48h/49h/4Ah`), handle I/O, and
   `AH=4Ch` exit. `mmap` must be replaced with read-into-heap; `realpath`,
   `rlimit`, `mmap`, `dwarf/macho/coff` backends are cut candidates.
5. **Output-format trimming (`P1`).** DOS64 needs `-f bin` (flat `.COM`)
   and possibly `-f elf64`-subset for `MZ64` payloads. The `outmacho/
   outcoff/outobj/outas86/outieee/codeview/dwarf` backends can be dropped
   for the first port; keep `outbin.c` (+ `outelf.c` iff `MZ64` output is
   wanted). This is a build-system task in the submodule, not a fork.
6. **Image size and delivery (`P1`).** Even trimmed, a NASM binary is
   hundreds of KiB. The 1.44 M FAT12 volume + 176-sector kernel slot leave
   little room. Options: grow `VOL_SECTORS`/`IMG_MB` (layout-block change +
   `make check-layout` update), ship NASM outside the base image as an
   optional second image, or accept the mini-assembler (KiB-scale) as the
   on-image tool.
7. **C toolchain target (`P2`, tier-3 only).** There is no `x86_64-dos64`
   target: no linker script, no crt0, no relocation story for `MZ64`.
   Building NASM *for* DOS64 first requires defining that target on the
   host (cross `gcc -ffreestanding -nostdlib` + `MZ64` emitter or ELF64→
   `MZ64` converter). This is a project in itself — do not conflate it
   with the OS-side syscall work.
8. **Shell ergonomics (`P1`).** `NASM file.asm -o file.com` needs PATH
   search, `>%` redirection or at least `-o` handling, and error output
   that survives the 1-byte-deep serial RX / 80×25 VGA limits. `TYPE`’s
   4 KiB cap matters for listing review.

## 4. Options considered

| Option | What | Pros | Cons | Verdict |
|---|---|---|---|---|
| A. Full NASM C port | Build `nasm/` for DOS64 against a new `libc64` + new syscalls | Full syntax/macros/formats; self-hosting | Needs P0+P1+P2 (exec, 4 syscalls, libc, C target, size); months | **Long-term target** |
| B. Native mini-assembler | Hand-written `-f bin`-subset assembler in NASM asm, as `.COM` (labels, `db/dw/dq`, `mov/add/sub/jmp/call/ret/int/syscall`, `times/equ/%define`-subset, 64-bit regs) | Runs with only P0; KiB-scale; fits volume; dogfoods `MZ64`/EXEC work | Not full NASM; two syntaxes to maintain | **Short-term deliverable** |
| C. Cross-dev flow | Docs + examples + host tooling only | Zero OS risk; unblocks users now | Not “NASM on DOS64” | **Do first, keep anyway** |

Recommendation: **C, then B, then A.** Each tier reuses the previous
tier’s EXEC/argv/file work; B validates the OS primitives A will need at
1/10th the cost.

## 5. Phased plan

### Phase N0 — Scope freeze + measurements (no code, ~days)

- [x] Pin submodule: record `nasm/` commit in this file + `AGENTS.md`
      (today `nasm-3.02-50-gfbdc88565`); decide “NASM 3.02” as port baseline.
      (Done: pin recorded in `docs/20-nasm-gaps.md` §1; baseline NASM 3.02.)
- [x] Inventory exact syscall surface NASM needs: `strace -e file,mmap,
      process,signal host-nasm -f bin hello.asm` on Linux; map each call
      to `DISPATCH64` handler or gap. Publish table in `docs/20-nasm-gaps.md`.
- [x] Measure: trimmed `outbin`-only host NASM size (`size nasm`), heap
      high-water (`massif`/`getrusage`), and worst-case source size that
      fits the 6 MiB spawn budget. Decides volume-growth question in N4.
      (Done: `docs/20-nasm-gaps.md` §3 — `size` + `getrusage ru_maxrss`;
      no `massif` on host, `getrusage` suffices for the order of magnitude.)
- [x] Define `MZ64` toolchain contract in `docs/`: entry ABI (regs on
      entry, stack layout, exit-code path via `AH=4Ch`/`INT 20h`), argv
      encoding in `PSP64.cmd_tail`, env pointer ownership.
      (Done: `docs/20-nasm-gaps.md` §4; argv register pinned by N2a.)

Acceptance: `docs/20-nasm-gaps.md` exists with strace→`INT 21h` map and
size numbers; N1–N3 estimates updated.

### Phase N1 — Cross-assemble + run (docs + host tooling, no kernel change)

- [x] `docs/21-nasm-cross.md`: host `nasm -f bin prog.asm -o PROG.COM`
      constraints for DOS64 (org/origin expectations, flat addresses,
      allowed `INT 21h` subset with examples, `MZ64` header recipe for
      >64 KiB or entry-offset programs).
- [x] Ship 2–3 sample programs (`TEST.COM` pattern): `HELLO.COM`
      (`AH=09h` print + `AH=4Ch` exit), `ECHO.COM` (PSP tail echo),
      `CAT.COM` (`3Fh/40h` copy). Assemble host-side, add to volume via
      `tools/mkfat12.py` client-file support, run under `make run-qemu`.
      (Done: `samples/*.asm` + `build/dos64-nasm.img` via `--extra-file`;
      `ECHO.COM` is builtin-shadowed in the shell — documented in
      `docs/21-nasm-cross.md` §3, becomes the N2 argv test.)
- [x] `make nasm-samples`: host-assembles samples with the submodule
      `nasm/` binary and stages them into the image; `check_volume_clean.py`
      extended to allow-list them.
      (Done: `make nasm-samples` builds `build/nasm-sub/src/nasm` from the
      pinned submodule once, assembles with `-f bin`, stages onto
      `build/dos64-nasm.img`; default smoke/full/lean images unchanged.)
- [x] Shell: document current EXEC limits honestly (“spawns but does not
      context-switch” → samples return via кооператив? or shell `TEST`
      path only). File follow-up issues for N2 instead of papering over.
      (Done: `docs/21-nasm-cross.md` §4; N2 follow-ups in
      `docs/22-n2-exec-design.md`.)

Acceptance: `printf 'HELLO\rEXIT\r' | make run-qemu`-style demo runs a
host-assembled `.COM` from the volume; docs merged.

### Phase N2 — Real execution + file + argv (kernel, the hard prerequisite)

All items below are required by *both* options A and B. Land and stabilize
before any assembler work. **Design + acceptance tests (84+) are done in
`docs/22-n2-exec-design.md`; implementation not started.**

- [ ] **Enter/return.** Extend `proc_spawn64` (`src/kernel/proc64.asm`) +
      `handler_exec` (`src/kernel/syscall64.asm:2367`) with a `run` step:
      switch `RSP` to child stack top, `call`/`jmp` child entry with
      documented regs, catch return → `proc_exit_current(code)`. Preserve
      caller `RBX RBP R12–R15` + 16 B `RSP` alignment per ABI. Decide
      cooperative (child `RET`/`AH=4Ch` returns to shell) vs preemptive
      (timer IRQ0 preemption — explicitly **out of scope**; stay
      cooperative like DOS). (Slice N2a; shell flip in N2d.)
- [ ] **Load from disk, not just memory.** Today the `AH=4Bh` trap takes a
      memory image (`RDI=src`). Add `EXEC-from-path`: resolve via FAT12,
      load clusters into the proc block, then spawn. Without this NASM
      cannot assemble named files. (Half done: `sh_do_exec` already
      resolves `<name>.COM` via FAT12 and stages it — the shell path
      frontend exists. Remaining N2a decision: whether `AH=4Bh` grows a
      path form or the shell stays the path frontend and the trap keeps
      the memory-image form.)
- [ ] **Handle syscalls.** Implement `3Ch` CREATE, `3Dh` OPEN, `3Eh`
      CLOSE, `42h` LSEEK on top of `fs64/fat64` (mirror FCB semantics:
      alloc-on-write, FAT+root write-through, record-granular writes).
      Keep behavior smoke-safe: new tests default to scratch-namespace
      files; extend `include/fs.inc` reserved namespace if needed.
      (Slices N2b–N2c, `3Eh`-first; reuse `SCRATCH.TXT` — no new
      namespace names needed.)
- [ ] **Argv/env convention.** Shell tokenizes command tail → `argv`
      accessible to child (e.g., NUL-joined block + `argc` register +
      pointer in PSP extension or above-stack); `ENV` inheritance from
      parent with `PATH`/`COMSPEC` defaults preserved. (Convention pinned
      in `docs/22-n2-exec-design.md` §3: N2a `RDI=PSP` + raw tail; shell
      side lands in N2d.)
- [ ] **Exit codes.** Propagate child `AL`/`RDI` code through zombie →
      `reap` → shell `ERRORLEVEL` analogue + `%ERRORLEVEL%`-style batch
      query (batch `%1`–`%9` machinery in `src/kernel/cmd64.asm` is the
      model). (N2a: code path into `proc_exitcode`; N2d: shell print +
      `ERRORLEVEL`.)
- [ ] **Tests.** Extend `src/kernel/selftest64.asm` (tests 84+):
      spawn→enter→return round-trip, exit-code propagation, argv echo,
      create/write/seek/read/close handle cycle in scratch namespace,
      volume-clean pre/post via `tools/check_volume_clean.py`. Smoke must
      stay non-destructive (`make` 81+2 pattern); destructive parts gated
      behind `SELFTEST_DESTRUCTIVE` like tests 71/83. (84–86 in N2a, 87a
      in N2b, 87b–88 in N2c.)

Acceptance: a hand-written 10-instruction `.COM` loaded **from the volume
by name** with args runs, writes a file via `3Dh/40h/3Eh`, exits with a
code the shell can print; `make` + `make full` green on QEMU and Bochs.

**Build order — N2a → N2d (the next steps; do in order, keep `make` /
`make full` / `make lean` + the Bochs trio green after each slice):**

- **N2a — enter/return, no I/O, no volume risk (do first).**
  `src/kernel/proc64.asm`: new `proc_enter64` + `exec_caller_rsp` save
  slot; `RET`-trampoline so bare-`RET` images (`TEST.COM`) exit 0;
  `AH=4Ch` converges to the same restore path. No trap/shell wiring yet
  (`AH=4Bh` + shell stay spawn-only until N2d — smaller blast radius).
  `src/kernel/selftest64.asm`: tests 84 (round-trip + preservation),
  85 (code `0x2A` via real `INT 0x21`), 86 (tail echo into a harness
  buffer + `memcmp`) — all PURE. Also update the suite-count strings
  (`81 + 2` in `Makefile`/`README.md`/`AGENTS.md` /`docs/`) to the new
  totals. Acceptance: smoke green on QEMU + Bochs with zero new device
  writes; `check_volume_clean.py` CLEAN.
- **N2b — handle table + `3Dh`-ro + `3Eh` (smallest useful file slice).**
  Define `PSP64.fd_table` semantics (fds 0–2 console, 3–15 files) on top
  of `fs_fcb_open64`/`fs_fcb_close64`; test 87a (`3Dh`-ro open + `3Eh`
  close of `README.TXT`, zero writes, READ-ONLY). Acceptance: smoke
  green, volume CLEAN.
- **N2c — `3Ch` + file `3Fh`/`40h` + `42h`.** CREATE (truncate/create,
  root→FAT order), extend `3Fh`/`40h` to fds ≥ 3 (short-read at EOF,
  alloc-on-write at `pos == size`), LSEEK clamped to `0..size`; tests
  87b (`SCRATCH.TXT` cycle, destructive-gated) + 88 (scrub/mirror
  invariance). Acceptance: `make full` green on QEMU + Bochs,
  `check_volume_clean.py` pre/post CLEAN.
- **N2d — shell flip + exit codes (N2 acceptance).** `sh_do_exec` enters
  and prints `Exit <code>`; `%ERRORLEVEL%` batch query; `ECHO.COM`
  becomes the argv round-trip test (unblocks the N1 shadowing note).
  Acceptance: the N2 acceptance paragraph above, demonstrated via
  `printf '\rHELLO\rECHO hi\rEXIT\r' | make run-qemu-nasm`-style run.

### Phase N3 — `libc64` shim (enables C programs generally, NASM specifically)

**Entry: N2d green. Milestone breakdown: `docs/23-nasm-port-milestones.md`
(N3.1–N3.5). `hello.c` is the first C program running on DOS64.**

- [ ] New `src/lib/libc64.asm` (System V ABI, 16 B alignment, callee-saved
      discipline per `src/kernel/stack64.asm`): `memcpy/memset/strcmp/
      strlen`, `nasm_malloc/realloc/free` over `AH=48h/49h/4Ah`
      (`mem_alloc64` first-fit/split/coalesce), minimal `printf`-subset
      over `AH=02h/09h/40h`, `exit` over `AH=4Ch`.
- [ ] `stdio64` over new handle syscalls: `fopen/fclose/fread/fwrite/
      fseek/ftell` with a small static `FILE` table (no `mmap`; read fully
      into heap — matches N0-measured sizes). Stub `isatty` honestly.
- [ ] `crt0`: `_start` builds `argc/argv/envp` from the N2 convention and
      calls `main`; returns code via `AH=4Ch`.
- [ ] Host cross-target: `gcc -ffreestanding -nostdlib -m64` + linker
      script emitting flat payload convertible to `.COM`/`MZ64`
      (`objcopy -O binary` path mirrors `Makefile:171-174`); document
      exact flags. No kernel change here — pure `tools/` work validated
      by a `hello.c` → `HELLO.COM` demo.

Acceptance: `hello.c` (puts/fopen/fwrite/malloc) cross-built on host runs
on DOS64 under QEMU; no Linux syscalls in the binary (`objdump` check).

### Phase N4 — Assembler delivery (two tracks)

**Tier-3 milestone breakdown (fundable, not attempted in one jump):
`docs/23-nasm-port-milestones.md` (N3.1–N3.5, N4B.1–N4B.3, N4A.1–N4A.4,
N5.1–N5.4).**

**Track B (first): native mini-assembler `ASM64.COM`. Entry: N2d green
(handle I/O + `ERRORLEVEL`); needs N2 only, so it can overlap N3. This is
the first self-hosted assembler milestone — do not skip it even if
full-port funding arrives early.**

- [ ] Spec `docs/22-asm64-spec.md`: supported directives/instructions,
      error format (`file:line: error`), `-o`/`-l` flags, limits (source
      ≤ X KiB, symbols ≤ N — sized from N0 + `TYPE` 4 KiB note).
- [ ] Implement in `src/tools/` (new dir, NASM asm, `-f bin`): two-pass
      (parse → fixup → emit), 8.3 source/output via handle I/O, error
      messages via `AH=09h`, exit codes for batch `ERRORLEVEL` use.
- [ ] Ship on volume; shell `ASM64 HELLO.ASM -o HELLO.COM` demo;
      self-tests assemble the N1 samples and `memcmp` against
      host-`nasm` output (byte-identical for the subset).

**Track A (after B is stable): full NASM port. Entry: N3.5 + N4B.3
green; take the N4A.3 size decision (grow volume vs `dos64-tools.img`)
first — never squeeze the 176-sector kernel slot.**

- [ ] Submodule build variant: `nasm/configure` with `--disable-*`,
      keep `asm/parser/preproc`, `nasmlib` (minus `mmap/realpath/rlimit`),
      `output/outbin.c` (+ `outelf.c` iff needed), `x86` tables
      (pre-generate `*.ph` host-side — do not run Perl on DOS64).
- [ ] Replace `nasm/nasmlib/mmap.c`, `file.c`/`fileio.c` backends with
      `stdio64` calls; stub `getopt`-long subset or vendor it.
- [ ] Solve size: if N0 shows overflow, grow image (`IMG_MB` /
      `VOL_SECTORS` in `Makefile:23-28` + `check-layout` + `bochsrc`
      CHS) **or** ship `NASM.COM` on a second optional image
      (`dos64-tools.img`). Never silently squeeze the kernel slot.
- [ ] `NDISASM` port explicitly deferred (needs no new syscalls; file it
      as follow-up).

Acceptance (B): on-image `ASM64` assembles `HELLO.ASM` → working
`HELLO.COM` with no host involvement. Acceptance (A): on-image `NASM -f
bin` assembles the same corpus as host NASM 3.02 byte-identically.

### Phase N5 — Integration + hardening

- [ ] Shell: `NASM`/`ASM64` in `HELP`, PATH search, batch-friendly
      `ERRORLEVEL`, `make run-qemu` pipe-driven demo
      (`printf 'ASM64 HELLO.ASM\rHELLO\rEXIT\r'`).
- [ ] Self-test: assembler round-trip tests in the harness (smoke-safe:
      assemble in memory/scratch; destructive volume writes stay behind
      `SELFTEST_DESTRUCTIVE`); `check-serial`/`check-kbc` patterns hold
      (bounded UART/KBC waits — assembler errors must never spin).
- [ ] Docs: update `README.md` (Using the shell), `AGENTS.md` (status +
      memory/disk deltas), `docs/06-syscall-reference.md` (new `3Ch/3Dh/
      3Eh/42h` rows), close G1–G6-style audit for new surface.
- [ ] Regression: `make`, `make full`, `make lean` + Bochs trio
      (`run-bochs*`) all green; `check_volume_clean.py` pre/post clean.

## 6. What is explicitly out of scope

- Preemptive multitasking / timer preemption / per-process `CR3` paging
  (store `CR3` in `PSP64` today, switch later — assemblers don’t need it).
- `MZ`/`PE` loading, relocations, shared libraries.
- Long filenames, subdirectories-as-namespaces beyond FAT12 reality,
  pipes/redirection operators (use `-o` flags instead).
- Running the Linux-built `nasm` ELF binary directly (no ELF loader, no
  Linux syscall emulation — the port recompiles from source).
- Perl/Python on DOS64 (codegen stays host-side).

## 7. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| EXEC-enter destabilizes kernel (stack/IDT/`RSP` bugs) | Boots break, all tests red | N2 lands behind a `DEBUG_SELFTEST`-style gate first; cooperative-only; reuse `IOSTACK`/`DSKSTACK` 4 KiB split pattern |
| Handle-syscall FAT corruption | Volume corruption, `make full` red | Reuse FCB write-through paths; scratch-namespace tests; `check_volume_clean.py` pre/post on every run |
| NASM too big / too malloc-hungry for 6 MiB spawn + 1.44 M volume | Tier 3 infeasible as specced | N0 measures first; Track B guarantees value even if A is cut to a floppy-external image |
| Submodule drift (upstream NASM moves) | Port bit-rots | Pin commit here + in build; port patches as `nasm/dos64-*.patch` stack, not a fork |
| Serial/VGA debug loss during assembler errors | Un-debuggable failures | Assembler uses bounded `serial_try_putc64` path only (`make check-serial` already enforces) |

## 8. Next actions (concrete, in order)

Done:

- [x] 1. Plan merged (this file); tracking lives here + `docs/20–23`.
- [x] 2. N0: `docs/20-nasm-gaps.md` (strace map + sizes).
- [x] 3. N1: `docs/21-nasm-cross.md` + `samples/` + `make nasm-samples`
      (no kernel change; `build/dos64-nasm.img` demo green).

Next — N2 implementation, one slice at a time (design + tests 84+ spec:
`docs/22-n2-exec-design.md`; each slice keeps `make` / `make full` /
`make lean` + the Bochs trio green):

- [x] 4. **N2a** enter/return (`proc_enter64`, `RET`-trampoline, `AH=4Ch`
      convergence) + tests 84–86 (PURE) + suite-count string updates.
      (Done: smoke 84+2 / full 86 green on QEMU + Bochs, volumes CLEAN.
      Test 86 caught a real drift — loader uses `PSP+PSP_SIZE` (664), not
      the `PSP+512` of stale comments; fixed across code/samples/docs.)
- [ ] 5. **N2b** handle table + `3Dh`-ro + `3Eh` + test 87a (zero writes).
- [ ] 6. **N2c** `3Ch` + file `3Fh`/`40h` + `42h` + tests 87b (destructive,
      `SCRATCH.TXT`) and 88 (scrub/mirror invariance).
- [ ] 7. **N2d** shell flip (`sh_do_exec` enters, `Exit <code>`,
      `%ERRORLEVEL%`); N2 acceptance demo on `dos64-nasm.img`.

Then, towards NASM running on DOS64 (breakdown: `docs/23-…`):

- [ ] 8. **N3** `libc64` (N3.1–N3.5): heap over `48h/49h/4Ah`, `stdio64`
      over N2 handles, `crt0`, cross-target `hello.c` demo. Entry: N2d.
- [ ] 9. **N4B** mini-assembler `ASM64.COM` (N4B.1–N4B.3): spec, two-pass
      `-f bin` subset in `src/tools/`, on-volume
      `ASM64 HELLO.ASM -o HELLO.COM` demo, byte-identical round-trips.
      Needs N2 only — may overlap N3.
- [ ] 10. **N4A** full NASM port (N4A.1–N4A.4): submodule build variant,
      `stdio64` backend swap, size decision first, byte-identical corpus.
      Entry: N3.5 + N4B.3.
- [ ] 11. **N5** integration + hardening (HELP/PATH/`ERRORLEVEL`, harness
      round-trips, README/AGENTS/syscall-ref updates, G1–G6-style audit,
      full regression trio).
- [ ] 12. Re-estimate whatever remains from N2 actuals after each slice;
      confirm Track B scope vs full-port funding at N2d.

---
*Baseline refs: `Makefile` layout block (`IMG_MB=10, VOL_LBA=512,
VOL_SECTORS=2880, KERNEL_LBA=16, KERNEL_SECTORS=176`), `src/kernel/
proc64.asm:1277`, `src/kernel/syscall64.asm:319`, `include/psp.inc`
(664 B `PSP64`), `include/mcb.inc` (40 B `MCB64`), `nasm/` @ 3.02.*
