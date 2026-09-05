# Phase 11 Completion Report — Interrupt Descriptor Table (IVT replacement)

**Date:** 2026-09-05
**Branch:** `main` (building on Phase 10 `50 PASS`)
**Target:** Bochs 3.0 (ryzen) + QEMU 11.1.1, BIOS boot, 64-bit long mode

---

## Executive Summary

Phase 11 (AGENTS.md §Phase 11) is **complete and verified**.
DOS 1.25's real-mode IVT at `0000:0000` (256 far ptrs, `SETVECT MSDOS.ASM:3342`,
`DISPATCH:349`, `INT 20h/21h`, hardware `INT 08h/09h/0Eh`) is now a full flat
64-bit long-mode **IDT**: 256 entries × 16 B (`IDT_ENTRY`: low/sel/IST/type/mid/
high/reserved), per-vector exception stubs 0–31 with diagnostics
(vector+error+RIP, per-vector counts), PIC remapped master `0x20` / slave `0x28`
(standard, fixes Phase 9 `INT 8`/`#DF` overlap), IRQ0 timer `@0x20` (tick+EOI),
IRQ14 disk `@0x2E` (count+EOI slave+master), DOS `INT 0x21` preserved as DPL3
`0xEE` gate, IRQ1 keyboard handler provided but **not** installed at `0x21`
(master+1 collision; IRQ1 stays masked, polling driver Phase 5 suffices).

8 new tests extend the harness to **58 total — all 58 PASS** on Bochs and QEMU,
no `#UD/#GP/#PF/#DF`, no BIOS calls, no triple faults.

```
 Bochs / QEMU serial.log after Phase 11 (tail):

  [51] Full IDT 0-31/0x20/0x21/0x2E + IMR... PASS
  [52] Exceptions 0/3/4 diag + preserve... PASS
  [53] PIC remap 0x20/0x28 + mask/unmask... PASS
  [54] Timer IRQ0 @0x20 tick + EOI... PASS
  [55] Kbd IRQ1 via spare 0x2F (DOS safe)... PASS
  [56] Disk IRQ14 @0x2E count + EOI... PASS
  [57] IRQ SETVECT/GETVECT + DOS kept... PASS
  [58] IDT stress + DOS after remap... PASS

 Summary: 58 passed, 0 failed
 Phase3 register conversion: ALL TESTS PASS
 Phase4 addressing transformation: ALL TESTS PASS
 Phase5 BIOS replacement (Option C): ALL TESTS PASS
 Phase6 memory management (MCB64): ALL TESTS PASS
 Phase7 filesystem adaptation (FAT12): ALL TESTS PASS
 Phase8 process management (PSP64): ALL TESTS PASS
 Phase9 syscall interface (INT 21h): ALL TESTS PASS
 Phase10 command interpreter (COMMAND64): ALL TESTS PASS
 Phase11 IDT full (remap+IRQ+exc): ALL TESTS PASS
```

> Diagnostic note: `[30]/[32]/[33]` still emit single-letter progress markers
> (`A–N`, `a–h`, `p–$`) before `PASS` (fail-point isolation, cf. Phase 8).
> Phase 11 tests emit no markers on pass (clean `... PASS`).

---

## 1. Scope (AGENTS.md Phase 11 checklist)

| Requirement | Implementation | Test |
|---|---|---|
| IDT entry 16 B struct | `idt_set_entry_raw` (low/sel `0x08`/IST 0/type/mid/high/reserved 0), `IDT_CODE_SEL 0x08`, `0x8E` kernel / `0xEE` user | `[51]` SIDT limit 4095 + base, type/selector checks |
| Exception handlers #DE/#GP/#PF etc. 0–31 | 32 per-vector stubs (`push 0+vec` or `push vec` for err 8/10/11/12/13/14/17/21) → `exc_common` (15-push save, record vector/error/RIP + `fault_count` + `exc_counts[vec]`, restore, `add rsp,16`, `iretq`) | `[52]` `int 0/3/4` count/vector/error/RIP/preserve; `[51]` 0≠1 distinct, err vectors via IDT read |
| DOS INT 0x21 handler | Kept Phase 9 `int21_entry` (`0xEE` DPL3, `SPSAVE` + `IOSTACK/DSKSTACK` + `DISPATCH64[AH]` + CF to IRETQ) | `[51]/[53]/[57]/[58]` `0x21==int21` + `int 0x21 AH=19/02/09` after remap |
| Timer IRQ0 (INT 08h) | PIC master `0x20` → vector `0x20` `irq0_timer_handler` (15-save, `tick++`, EOI `0x20`, restore, `iretq`) | `[54]` `int 0x20` tick 1→2, regs preserved, no fault |
| Keyboard IRQ1 (INT 09h) | `irq1_kbd_handler` (OBF `0x64:0x01` → `0x60` → `kbd_queue_push`, EOI) provided but **masked/not installed** (master+1=`0x21` collides with DOS; polling kept); tested via spare `0x2F` | `[55]` install at `0x2F`, `int 0x2F` no crash/preserve, `0x21` still DOS, restore |
| Disk IRQ14 (INT 0Eh) | Slave `0x28`+6 → vector `0x2E` `irq14_disk_handler` (`irq14++`, EOI slave+master cascade, `iretq`) | `[56]` `int 0x2E` count 1→2, preserve, no fault |
| PIC remap + masks | `pic_remap64` (ICW1 `0x11`, ICW2 `0x20/0x28`, ICW3 `0x04/0x02`, ICW4 `0x01`, mask `0xFF/0xFF`), `pic_get/set_mask64`, `pic_mask/unmask_irq64`; `idt_load64` now remaps then masks + `lidt` + `sti` | `[53]` remap→`0xFFFF`, unmask/mask IRQ0, bad 16 fails, DOS after remap |
| SETVECT/GETVECT for IRQs | Existing `AH=25h/35h` via `idt_set/get_vector64` work for `0x20/0x2E` (USER gates on set) | `[57]` `0x20` dummy set/get/restore + timer still ticks |

New exports (`idt64.asm`, 17 globals): `pic_remap/get_mask/set_mask/mask_irq/
unmask_irq`, `irq0/irq1/irq14_handler`, `exc_common`, `idt_get_tick/irq14/fault/
last_vector/last_error/last_rip/exc_count`, `idt_reset_stats64`, plus BSS
`tick/irq14/fault/last_vector/last_error/last_rip/exc_counts[32]`.

---

## 2. What Was Built

### 2.1 `idt64.asm` — IVT → full IDT + PIC

- **Remap rationale:** Phase 9 masked PIC without remap (timer would fire as `INT 8`,
  whose `#DF` err stub does `add rsp,8` with no CPU error → stack corrupt →
  `check_cs(0x0246)`). Phase 11 remaps to `0x20/0x28` (standard PC) so mask is safe
  and future unmask delivers to `0x20+` (no CPU 0–31 overlap). `0x80` POST delay.
- **Collision:** master offset `0x20` + IRQ1 = `0x21` = DOS syscall. Resolved by
  keeping IRQ1 masked (polling `kbd_poll/queue` Phase 5 needs no IRQ) and keeping
  `0x21` as pure DOS gate. `irq1` handler exists for future DOS-relocation to
  `0x80` (Phase 12). Documented in header + this report (spec lists real-mode
  `INT 09h` without noting protected-mode collision).
- **Common handler offsets:** after 15 pushes, `[rsp+120]=vector`, `+128=error`,
  `+136=RIP`, `+144=CS`, `+152=RFLAGS`. `inc` side effects harmless (`iretq`
  restores RFLAGS). Dummy `0` for non-error unifies layout.
- **IRQ preservation:** all 15 GPRs saved/restored (async-safe on `0x90000` stack);
  gates are `0x8E` (IF=0 in handler, no `sti`, no reentrancy in tests).
- **Compat:** `idt_default_handler[_err]`, `idt_test_vectors` (0=DPL0, `0x21`=DPL3)
  unchanged → Phase 9 `[35]` still passes. `idt_init64` still `RAX 0`, builds IDTR.

### 2.2 `main.asm` — 50 → 58 tests

`hello_phase11`, `msg_test51–58`, `msg_phase11_ok/fail`; 8 blocks mirroring prior
style (`vga_print` + `serial_print64`, `R12` pass / `R13` fail); summary now
includes `msg_phase11_*`; `print_num` already handles 58. Test funcs
`test_idt_full/exc_diag/pic_remap/timer_irq/kbd_irq/disk_irq/irq_vectors/
idt_stress` preserve `RBX` etc., use `int` (proper IRETQ frames), never `int`
error vectors (would corrupt: no CPU error on software `int`).

### 2.3 Capacity — still 128 sectors

Kernel `45932→50124 B` (89→97 sectors). `stage2.asm KERNEL_SECTORS 128` (64 KiB,
`0x100000–0x110000` ⊂ 0–8 MiB map) and `Makefile` 128-sector check unchanged.
Image layout unchanged (`MBR@0`, `stage2@1`, `kernel@16`; scratch `200`/`500+`).

---

## 3. Bugs Found & Fixed

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | `nasm` 6× `warning: attempt to initialize memory in BSS` | Second `align 8` in `.bss` tries to pad with zeros (init in BSS) | `align 8` → `alignb 8` (BSS align, no init) |
| 2 | `test_idt_full` SIDT base mismatch / `#GP` risk | Read `[rsp+2]` **after** `call idt_get_base64` (call pushes ret addr, shifts `[rsp]`; SIDT buffer moved) + redundant double-call | Copy `limit→CX`, `base→RSI` before any call, `add rsp,16` immediately, then compare |
| 3 | Dead port reads in `pic_get_mask64` | First 3 `in`s overwritten by clean reconstruct (harmless double-read, ugly + `RCX` clobber without save) | Single clean read, `push rcx`/`pop rcx` (callee preserves) |

Total: 3 defects (1 build warning, 1 stack-frame, 1 hygiene), all caught before
emulator run via code review; QEMU first boot already 58 PASS.

---

## 4. Verification

```bash
make clean && make
# mbr.bin 512 (55 aa), stage2.bin ~1K, kernel.elf 157128, kernel.bin 50124 (97 sectors ≤ 128)

# QEMU (fresh)
timeout 15 qemu-system-x86_64 -drive file=build/dos64.img,format=raw -serial file:/tmp/q.log -display none
# → 58 passed, 0 failed + 9× ALL TESTS PASS

# Bochs (target, fresh)
rm -f bochs.log serial.log build/dos64.img.lock && timeout 30 bochs -f bochsrc.txt -q
# → serial.log identical 58 PASS; bochs.log: no #GP/#UD/#PF/#DF/check_cs (only SND panic, cf. Phase 10)
```

| File | Size | Check |
|------|------|-------|
| `build/mbr.bin` | 512 | `55 aa` |
| `build/stage2.bin` | ~1K | ≤ 15-sector slot |
| `build/kernel.bin` | 50124 (97 sectors @16) | ≤ 128 (`KERNEL_SECTORS`) |
| `build/dos64.img` | 10 M | MBR + stage2@1 + kernel@16 |

Heap discipline: Phase 11 tests are IDT/PIC/RAM-only (no `mem_alloc`; `mem_validate64`
in `[58]`); scratch stays `200` (ATA) + `500–511` (FS); masks restored to `0xFFFF`
after `[53]` for determinism.

---

## 5. Checklist (AGENTS.md Phase 11)

- [x] 16 B `IDT_ENTRY` struct (low/sel/IST/type/mid/high/reserved, `0x08`, `0x8E/0xEE`)
- [x] Exception handlers 0–31 with diagnostics (vector/error/RIP/counts, error-aware)
- [x] DOS `INT 0x21` gate preserved (DPL3, dispatch, CF)
- [x] Timer IRQ0 (`0x20`, tick+EOI)
- [x] Keyboard IRQ1 (handler + masked-collision doc, spare-vector test)
- [x] Disk IRQ14 (`0x2E`, count+EOI slave+master)
- [x] PIC remap `0x20/0x28` + mask API + `lidt/sti`
- [x] Boot + 58 PASS on Bochs & QEMU, no faults

**Next:** Phase 12 stack/ABI hardening (`RSP` 16 B, System V `RDI/RSI/RDX/RCX/R8/R9`,
callee-saved `RBX/RBP/R12–R15`, `IST` stacks, `SYSCALL` extension) on top of the full IDT.

**Update (closure):** see `docs/19-closure-g1-g6.md` for what changed after this report.
