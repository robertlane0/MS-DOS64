# `tools/nasm-dos64/` — full-NASM port scaffolding (PLAN N4A)

Home for the Tier-3 port work **outside** the `nasm/` submodule.
The submodule is a pinned host build tool — never modified, never forked.
Port adaptations live here as a patch/config stack applied to throwaway
copies (same pattern as `make nasm-samples`: `cp -a nasm/. build/...`).

## Files

| File | Role |
|---|---|
| `dos64-config.h` | Force-include (`-include`) feature config for the DOS64 cross-target. Selects the graceful-degradation paths NASM already ships (pure-stdio `file.c`, NULL-`mmap`, `fseek`-as-`fseeko`, vendored `stdlib/` fallbacks). Each block names the fallback it selects and the libc64 symbol it needs. |
| `trim.mk` | Canonical trim flags (`OF_ONLY`/`OF_BIN`/`OF_ELF`) + the backend-cut list. Included by the top `Makefile` (`nasm-trim-check`); the numbers it quotes are measured in `docs/25-n4a1-trim.md`. |
| `stdmac-raw.pl` | Raw-`macros.c` codegen driver (N4A.2c): neutralizes zlib so every blob has `dsize == zsize` (`make nasm-stdmac-raw`). Reads the submodule read-only. |
| `dos64-nasm-shim.c` | NASM-specific C shims for the cross-target (N4A.2d): `nasm_vasprintf/asprintf/vaxprintf/axprintf` (over `vfprintf`), `uncompress_stdmac` (raw-blob copy), `nasm_realpath`, `nasm_get_stack_size_limit`, `abs` (here — `abs` is a NASM keyword and cannot be an asm label). Shared by the NASM and NDISASM links. |
| `dos64-*.patch` | Source patches, one concern per file, applied with `patch -p1` to the build copy only. None needed to date (N4A.2 landed patch-free — config + mechanism fixes sufficed). |

## Policy (PLAN §7: no fork)

- No file under `nasm/` is ever written by this tree's build.
- Upstream drift is absorbed by re-pinning the submodule + re-running
  `make nasm-trim-check`, not by carrying a fork.
- Anything that cannot be expressed as flags + `dos64-config.h` + a
  `dos64-*.patch` is a port bug to be fixed here, not in the submodule.

## NDISASM (docs/25-n4a1-trim.md §11)

Same pattern, smaller link: `make ndisasm-cross` compiles the 5
`disasm/*.c` sources with `NASM_XCFLAGS` and links them against
`NDISASM_KEEP` (`trim.mk` — the NASMLIB-subset from upstream's
`ndisasm = NDISASM + LIBOBJ_DIS + NASMLIB` link) instead of the full
assembler pool. `make ndisasm-check` is the on-device acceptance
(`-v` + `-b 64` byte-identity vs host ndisasm).
