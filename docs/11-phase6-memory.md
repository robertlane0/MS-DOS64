# Phase 6 Completion Report — Memory Management Overhaul (MCB64)

**Date:** 2026-09-03
**Branch:** `phase6-memory` (building on `phase5-native-drivers`)
**Engineer:** Muse Spark
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 6 (AGENTS.md §Phase 6, docs/03 §5) is **complete and verified**.
DOS 1.25 had **no MCB allocator** (only `SETMEM` + `MEMSCAN` paragraph scan,
`MSDOS.ASM:3363,3900`); the Phase-3 `mem64.asm` stub is now a full 64-bit
memory manager: byte-based (paragraph `SHL 4` → bytes, `SHL 12` pages),
flat 64-bit owners/pointers, first-fit split, **bidirectional coalesce**,
in-place resize (`INT 21h AH=4Ah` analog), aligned/page allocation,
chain validation + statistics, and page-table protection (2 MiB PS `RW/NX`).

5 new tests extend the harness to **21 total — all 21 PASS** on Bochs and QEMU,
no `#UD/#GP/#PF`, no BIOS calls.

```
 Bochs / QEMU serial.log after Phase 6 (tail):

  [17] Para/page conv (para*16, pages*4K)... PASS
  [18] MCB coalesce (split, prev+next merge)... PASS
  [19] Resize SETBLK (shrink/grow via AH=4Ah)... PASS
  [20] Page protection (2MiB PS RW/NX)... PASS
  [21] Stress/validate (totals, double-free)... PASS

 Summary: 21 passed, 0 failed
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
 Phase6 memory management (MCB64): ALL TESTS PASS
```

---

## 1. Scope (AGENTS.md Phase 6 checklist)

| Requirement | Implementation | Test |
|---|---|---|
| Paragraph → byte sizing | `mem_para_to_bytes` (`SHL 4`), `mem_bytes_to_para` (`+15/SHR 4`), `mem_bytes_to_pages`/`mem_pages_to_bytes`/`mem_para_to_pages`/`mem_pages_to_para` (`SHL/SHR 12`) | `[17]` vectors `1→16`, `0x100→0x1000`, `17→2`, `4096→1`, `4097→2`, `256 para→1 page`, `1 page→256 para` |
| 16-bit segments → 64-bit linear owners | `MCB64.owner dq` (was 16-bit PSP seg), all walks flat `[rsi+MCB64.*]` + `[rel]`, `R8–R15` temps | `[18]` + GDB heap dumps |
| First-fit allocation update | `mem_alloc64` first-fit, 16-align, split iff remainder ≥ `MCBSIZ64+16` else whole-block | `[18]` reuse `400 in 512 slot @ same addr` |
| 64-bit MCB chain mgmt | `mem_init64`/`mem_reset64` single-`Z` chain `0x200000–0x800000` (6 MiB, identity-mapped) | `[18]` `count==1`, `max≈6M` after free-all |
| Page-table protection | `mem_enable_nxe64` (`EFER.NXE`), `mem_get_pd_entry64`, `mem_set_rw64`, `mem_set_nx64`, `mem_protect_range64`, `mem_flush_tlb64` (`CR3` reload), `mem_invlpg64` over stage2 `PD@0x3000` (4×2 MiB PS) | `[20]` RO→RW→NX→X transitions read back from PD |
| `INT 21h` memory calls | `handler_alloc_mem` (`AH=48h`, BX para→bytes), `handler_free_mem` (`AH=49h`), `handler_resize_mem` (`AH=4Ah`); `DISPATCH64` grown `47→77` entries (`MAXCOM 46→0x4C`); `syscall_dispatch64` now extracts **AH** from saved frame (DOS convention) with balanced 15-push/15-pop `leave64` | `[21]` full `AH=48h` dispatch round-trip; `[7]` badcall `AH=0xFF→AL=0` |

New exports (`src/kernel/mem64.asm:25`, 24 globals): `mem_reset64`,
`mem_validate64`, `mem_alloc_aligned64`, `mem_alloc_pages64`, `mem_resize64`,
`mem_total_free64`, `mem_total_used64`, `mem_count_blocks64`,
`mem_bytes_to_para/pages`, `mem_pages_to_bytes`, `mem_para_to_pages`,
`mem_pages_to_para`, `mem_get_pd_entry64`, `mem_set_rw64/nx`,
`mem_enable_nxe64`, `mem_flush_tlb64`, `mem_invlpg64`, `mem_protect_range64`.

---

## 2. What Was Built

### 2.1 `mem_free64` — bidirectional coalesce (+ validation)

Frees by user pointer (`MCB = ptr-MCBSIZ64`), rejects bad type / out-of-range /
double-free (`CF=1`), merges with **next** free, then scans from `MEM_START`
for the **predecessor** and merges backward. Fixes the Phase-3
forward-only merge (leaked interleaved frees; `[18]` free-all now collapses to
one `Z`).

### 2.2 `mem_resize64` — SETBLK analog (`AH=4Ah`)

16-aligned shrink (splits suffix, coalesces forward) and grow (absorbs next
free, splits remainder). Same-size is a no-op; impossible grows fail with
`CF=1` (test: `10 MiB` grow fails, chain still validates).

### 2.3 `mem_alloc_aligned64` / `mem_alloc_pages64`

Power-of-two aligned allocation by over-allocating and carving prefix
(`padding-MCBSIZ64`) + suffix blocks; pages delegate (`pages*4096`,
`align 4096`). Test: `4096/4096 → 0x201000`, `& 0xFFF == 0`.

### 2.4 Validation + statistics

`mem_validate64` (`0` ok / `1` bad type / `2` overrun / `4` accounting),
`mem_total_free64/used64`, `mem_count_blocks64`, `mem_dump64` walk.

### 2.5 `syscall64.asm` — memory handlers + dispatch repair

`DISPATCH64` extended with `AH=48h/49h/4Ah` at indices `72/73/74`
(`MAXCOM=0x4C`). `syscall_dispatch64` repaired: pushes `RAX` (15 pushes now
balance `leave64`'s 15 pops — previously 14 vs 15 corrupted `RSP`/`RIP`) and
indexes by **AH from the saved frame** (DOS convention; previously indexed by
`SS`). `handler_alloc_mem` reports `AH=8` + max-paragraphs in the trap frame
on failure (DOS insufficient-memory semantics) without clobbering the
returned pointer (`CLC`, `RAX` intact).

---

## 3. Bugs Found & Fixed (via QEMU `-d int` + GDB `gdbstub`)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `[18]` validate code `02` on fresh heap | `bl` (type) clobbered by `mov rbx, ...` (next-addr) in 5 chain walkers (`validate/max/total×2/count`) | type in `r8b` (`push r8`), `file: mem64.asm` |
| 2 | `[19]` triple fault (`#UD` at heap RIP) | `mem_resize64` 10 pushes / 9 pops (missing `pop rdx`); same in `mem_alloc_aligned64` (13/12) → `ret` to saved-reg garbage | added missing `pop rdx` both |
| 3 | `[19]` validate `01` after shrink (header +16) | `mov al,[type]` clobbered live size-diff in `RAX` (`128→0x4D→suffix 37`, merge into zeros) — same pattern in aligned small-pad split | shrink uses `r11b`; aligned recomputes `rax=rcx-r9-40` after the load |
| 4 | `[19]` validate `04` after grow (chain −40 B) | grow-split stored `S-E-40`: double-counted the recycled header (grow moves, not adds, a header) | store `S-E`; split iff `S-E ≥ 16` |
| 5 | `[21]` page alloc `0x200027` unaligned | `r15 = ~align` instead of `~(align-1)` (`mov r15,r12` vs `r14`): mask cleared bit 12, padding `-1` | `mov r15,r14` before `not` |
| 6 | `[21]` `#UD` at `RIP=0x17` after `AH=48h` dispatch | dispatch indexed by `SS` (not `AH`) + 14-push/15-pop imbalance → `leave64 ret` to garbage | index by saved-frame `AH`, `push rax` (15/15); test uses `RAX=0x4800`, `RBX=16 para`; `[7]` badcall probe `99→0xFF00` |

Total: 6 defects (3 clobber-class, 2 accounting, 1 convention), all reproduced
under GDB (`target remote :1234`, `x/` heap dumps, `info reg` at
`shrink_r2`/prefix/dispatch) before fixing.

---

## 4. Verification

```bash
make clean && make
# mbr.bin 512 (55 aa), stage2.bin ~1K, kernel.elf 65784, kernel.bin 16860 (32 sectors ≤ 64)

# QEMU
timeout 10 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial stdio -display none
# → 21 passed, 0 failed + 4× ALL TESTS PASS

# Bochs (target)
rm -f bochs.log serial.log build/dos64.img.lock && timeout 25 bochs -f bochsrc.txt -q
# → serial.log identical 21 PASS; bochs.log: no #GP/#UD/#PF (only SNDCTL wave-device notice)
```

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | ~1K | ≤ 15-sector slot |
| `build/kernel.bin` | 16860 (32 sectors @16) | ≤ 64 (`KERNEL_SECTORS`) |
| `build/dos64.img` | 10 M | MBR + stage2@1 + kernel@16 |

Heap layout: `0x200000–0x800000` MCB64 chain (40-B headers `'M'/'Z'`,
`owner dq`, `size dq` bytes, `name[8]`); kernel `@0x100000`, stack `@0x90000`,
page tables `@0x1000/0x2000/0x3000` untouched by the allocator.

---

## 5. Checklist (AGENTS.md Phase 6)

- [x] Convert paragraph sizing to byte-based (`SHL 4` / `SHR 4`, pages `SHL 12`)
- [x] Expand pointers 16-bit segments → 64-bit linear (`owner dq`, flat walks)
- [x] Update allocation algorithms (first-fit + split + full coalesce + resize)
- [x] Page-table protection (`RW/NX` on 2 MiB PS pages, `NXE`, TLB flush)
- [x] `INT 21h AH=48h/49h/4Ah` handlers + `DISPATCH64` + balanced `leave64`
- [x] Boot + 21 PASS on Bochs & QEMU, no faults

**Next:** Phase 7 FAT12-on-LBA (CH
...[truncated 615 chars]