# N4B.1 — `ASM64` mini-assembler spec (native `.COM`, two-pass subset)

First self-hosted assembler milestone (PLAN item 10, first half).
`ASM64.COM` assembles a NASM-`-f bin` subset well enough to rebuild the
N1 samples byte-identically on-device, validating the N2 handle-I/O
primitives Track A needs at ~1/10th the cost. Full NASM stays Track A.

## What it is

- `src/tools/asm64_core.asm`: pure assemble-buffer function (no traps,
  no I/O — host-testable like the libc parsers, dual-built: `-f bin`
  for the tool, `elf64` for the in-suite test).
- `src/tools/asm64_main.asm`: `-f bin` I/O wrapper (tail args, handle
  file I/O, `AH=09h` errors, `AH=4Ch` exit codes) → `ASM64.COM`.
- Usage: `ASM64 HELLO.ASM -o HELLO.COM [-l HELLO.LST]`.
- The corpus contract: `samples/{hello,echo,cat,write}.asm` assemble to
  **byte-identical** output vs host NASM 3.02 `-f bin` (mechanical proof
  host-side for all four; in-suite test 93 embeds hello only — 7 KB for
  all four exceeds the kernel-slot budget, see N4B.3).

## Language subset (v1 — everything else is an honest error)

Statements: `[label:] [times N] mnemonic operands...` / `label: ...` /
directive. Separators: space/tab/comma. `;` comments to EOL. Blank lines
ok. Mnemonics/registers/directives case-insensitive; **symbols
case-sensitive** (NASM default). Line ≤ 255 chars (else error).

Labels: `name:` and flat `.local:` (**no scoped dedup**: two `.foo`
under different globals collide — honest error; the corpus has none).
`label: <statement>` on one line required (`fname db ...`).

Directives: `bits 64` (only 64 accepted), `default rel` (accepted;
bare `[sym]` also means `[rel sym]`), `name equ expr`, `times expr`
(prefix, repeats the rest of the line; 0 = emit nothing, negative =
error), `db/dw/dd/dq` (below), `%define NAME replacement...` (whole-word
textual, replacement NOT rescanned — documented cut vs NASM recursion).
Unsupported (`org`, `section`, `global`, `extern`, `resb`, `cpu`,
`incbin`, `struc`, macros, `%if`, jump-size keywords) → clear error.

Data: `db` items = `number-expr` (must fit int8, else error) or string
(`'...'`/`"..."`, `''` doubling escape). `dw/dd/dq` items = numbers
(fit int16/int32/any-64) or strings packed LE, zero-padded to the unit
(strings in `dw` with odd length pad — corpus has no `dw/dq` at all;
only even/number cases are tested). `times N db 0` is the BSS idiom
(cat.asm precedent — `-f bin` has no BSS section).

Numbers: decimal, `0x` hex, `'x'` char literal. NO `..h` suffix, NO
`..b` binary, NO `$` (unknown-symbol error — honest cut; none in the
corpus, which uses only `0x`/decimal/chars).

Expressions (in `equ`, `times`, immediates, displacements, `db`):
`term ((+|-) term)*`, `term := factor ((*|/) factor)*`, `factor :=
number | symbol | ( expr )` with unary `+-`. Division by zero = error.
Forward refs allowed in `equ` and code (resolved by the fixpoint loop);
`times` count must be known-nonnegative when its line emits (else
"unresolved" error — `times` of a forward label is rejected, NASM
agrees it cannot size it... actually NASM errors too. Good.)

Instructions (64-bit only; shortest-form selection throughout):

| Mnemonic | Forms |
|---|---|
| `mov` | r8←imm8, r32←imm32, r64←imm64 (`B8`, or `C7` if fits int32), r8←m8, r32←r32, r64←r64, r32←m8 via `movzx` only (below) |
| `movzx` | r32←m8, r32←r8 |
| `lea` | r64←`[rel sym±off]`, r64←`[reg]`, r64←`[reg+disp8/32]` |
| `add/sub/cmp` | r,r and r,imm8/imm32 (no memory ALU — honest error) |
| `test` | r,r and r,imm |
| `inc/dec` | r64/r32/r16/r8 (FF /0 /1) |
| `jmp` | rel8/rel32 (fixpoint, below); bare only (`short`/`near` rejected) |
| `jcc` | all 16 conditions + `jc/jnc` aliases, rel8/rel32 fixpoint |
| `call` | rel32; `ret` (`C3`); `int ib`; `syscall` (`0F 05`); `nop` (`90`) |

Registers: `rax..rdi`, `r8..r15`, `eax..edi`, `r8d..r15d`,
`ax..di`, `r8w..r15w`, `al..dil` (`sil/dil` + `r8b..r15b`; classic
`ah/bh/ch/dh` too). NO segment regs, NO `[base+index*scale] SIB`
(honest error — none in the corpus), NO segment overrides, NO
address-size override, NO `m←r`/`m←imm` stores (loads only, per corpus).

Memory operands: `[rel sym±off]`, `[reg]`, `[reg±disp]`. Bare `[sym]`
= `[rel sym]`. REX.W/R/B emitted as needed; ModRM/SIB for the covered
shapes; disp8 whenever `-128..127` else disp32 (NASM's rule).

Jumps: optimistic-short + monotonic-growth fixpoint (bounded 16
passes, else "unstable" error — practically converges in 2–3):
backward targets encode exact on first sight; forward-unknown starts
short (disp 0); any pass where a displacement overflows grows that
jump to near and repeats. Matches NASM whenever NASM picks short or
forced-near (the corpus is all-short and converges pass 2).

## Interface

```
; asm64_assemble(RDI=src, RSI=srclen, RDX=out, RCX=outcap,
;                R8=list, R9=listcap, [RSP+8]=err, [RSP+16]=errcap)
;   -> RAX = output bytes, or -1 (errbuf = "LINE: msg" C-string, first
;   error only — documented v1 cut; main prepends "FILE:").
;   list/listcap NULL/0 = no listing. Pure: no traps, no statics beyond
;   its tables (re-entrant across calls after reset? NO — single-shot
;   per call; tables rebuilt each call from scratch).
```

Limits (v1, sized: corpus totals 5922 B source; N0's synthetic 138912 B
stress is explicitly out of scope; `TYPE`'s 4 KiB window is the
small-files consistency note): source ≤ 65535 B, output ≤ 65535 B,
symbols (labels+equs) ≤ 256, name ≤ 32 chars, `%define`s ≤ 32
(name ≤ 32, value ≤ 96), line ≤ 255, args ≤ 8. All excess → clean
error, never silent truncation.

Listing (`-l`, our format — no NASM parity claimed):
`XXXXXXXX  BB BB ...  source` — 8-hex offset, up to 8 bytes as hex
pairs space-separated, two spaces, the source line (truncated to 64).

CLI: `ASM64 IN.ASM [-o OUT.COM] [-l OUT.LST]` (any flag order; first
bare arg = input). Default output = input basename + `.COM`
(`HELLO.ASM` → `HELLO.COM`); no listing unless `-l`. Unknown flag /
missing input → usage error. Exit codes: `0` ok, `1` assembly errors,
`2` file/usage/limit errors (batch `%ERRORLEVEL%`-safe).

Diagnostics: `FILE:LINE: message$` via `AH=09h` (console/VGA; serial
shows shell prints only — same as all child output). Message texts are
ours (only the `file:line:` shape is NASM-compatible).

I/O: source `3Dh`/`3Fh`-loop/`3Eh` (read-until-short, 32K chunks — no
`42h` dependency); output `3Ch` + `40h`-chunked + `3Eh` (WRITE-proven).
BSS zeroed at entry (N3.5 lesson — flat `.COM` has no BSS content).

## N4B.3 acceptance (how each half is proven)

- Host `make asm64-check`: C harness links `asm64_core` (`elf64`) and
  assembles all four samples → `memcmp` vs host-`nasm -f bin` outputs.
  Mechanical 4/4 byte-identity, runs on the dev machine.
- In-suite PURE test 93 (smoke-safe): embedded `hello.asm` source
  (`incbin`, 844 B, checked-in) + expected output (build-generated
  `build/hello93.ref` via system `nasm -f bin`, `incbin`, ~37 B) →
  `asm64_assemble` → `memcmp`. Guards regressions on-device.
- Shell demo on `dos64-nasm.img` (ships `ASM64.COM` + `HELLO.ASM`):
  `ASM64 HELLO.ASM -o HELLO.COM` then run it; transcript is the
  evidence. Full-corpus `ECHO`/`CAT`/`WRITE` likewise (covered
  mechanically host-side).
