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
| `dos64-*.patch` | (N4A.2) Future source patches, one concern per file, applied with `patch -p1` to the build copy only. None yet — N4A.1 needs none. |

## Policy (PLAN §7: no fork)

- No file under `nasm/` is ever written by this tree's build.
- Upstream drift is absorbed by re-pinning the submodule + re-running
  `make nasm-trim-check`, not by carrying a fork.
- Anything that cannot be expressed as flags + `dos64-config.h` + a
  `dos64-*.patch` is a port bug to be fixed here, not in the submodule.
