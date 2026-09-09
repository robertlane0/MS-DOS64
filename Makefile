# MS-DOS64 – 64-bit BIOS boot build (83-test selftest + COMMAND64 shell; smoke/full/lean images)
# Stack/ABI hardening (RSP 16B, System V RDI/RSI/RDX/RCX/R8/R9, callee-saved, canary, IST reserve) + all prior phases + G1-G6 closure (77-entry INT 21h, real FAT12 volume, REPL, PIC 0x28/0x30)
# Requires: nasm >=2.15, ld (binutils), qemu
BUILD := build
SRC_BOOT := src/boot
SRC_KERNEL := src/kernel
SRC_DRIVERS := src/drivers
SRC_LIB := src/lib

# Disk layout — SINGLE SOURCE OF TRUTH (fixed values, not overridable).
# Canonical numbers live ONLY in this block. The build generates
# $(BUILD)/include/layout.inc (NASM %defines) which src/boot/stage2.asm and
# include/fs.inc %include, and passes the same values explicitly to
# tools/mkfat12.py on every stamp (no script-side defaults).
# `make check-layout` is a prerequisite of both disk images, so it runs on
# every `make all` with no separate invocation; it validates the generated
# file, the source %includes, the explicit stamper args, and the arithmetic
# invariants (kernel extent ends at/before VOL_LBA; volume end fits IMG_MB).
# Command-line overrides (e.g. `make VOL_LBA=600`) are rejected below: with
# per-layer duplicates gone, a relocated build would need a new canonical
# block, not a half-applied flag. To change the layout, edit this block and
# rebuild from clean.
IMG_MB := 10
IMG_SECTOR_SIZE := 512
VOL_LBA := 512
VOL_SECTORS := 2880
KERNEL_LBA := 16
# 184 (was 176): N2b handle layer (~1.5 KiB) overflowed the 176-sector slot
# with N2c/d still to come. Extent [16,200) stays clear of ATA scratch 200
# (adjacent, half-open: legal), FS scratch 500-511, and volume 512+.
# 184 is the max before scratch LBA 200; beyond N2, revisit via scratch
# relocation, not silent slot pressure (see PLAN.md N4A.3).
KERNEL_SECTORS := 184
LAYOUT_INC := $(BUILD)/include/layout.inc

# Reject unsupported layout overrides. (Environment values are already
# ignored by the := assignments above; command-line assignments still win
# in GNU make, so fail fast instead of building a split-brain image.)
ifeq ($(origin IMG_MB),command line)
$(error layout override rejected: IMG_MB is single-sourced in the Makefile disk-layout block)
endif
ifeq ($(origin IMG_SECTOR_SIZE),command line)
$(error layout override rejected: IMG_SECTOR_SIZE is single-sourced in the Makefile disk-layout block)
endif
ifeq ($(origin VOL_LBA),command line)
$(error layout override rejected: VOL_LBA is single-sourced in the Makefile disk-layout block (got '$(VOL_LBA)'))
endif
ifeq ($(origin VOL_SECTORS),command line)
$(error layout override rejected: VOL_SECTORS is single-sourced in the Makefile disk-layout block (got '$(VOL_SECTORS)'))
endif
ifeq ($(origin KERNEL_LBA),command line)
$(error layout override rejected: KERNEL_LBA is single-sourced in the Makefile disk-layout block (got '$(KERNEL_LBA)'))
endif
ifeq ($(origin KERNEL_SECTORS),command line)
$(error layout override rejected: KERNEL_SECTORS is single-sourced in the Makefile disk-layout block (got '$(KERNEL_SECTORS)'))
endif

NASM := nasm
# -Wall enables all assembler warnings; -Werror promotes them to errors so
# build warnings fail the build instead of scrolling past. Explicit silences
# below cover relocations that are benign by design (linker-resolved or
# intended absolute addresses) and would otherwise make -Wall unusable:
#   -Wno-reloc-abs-word: 16-bit absolute addressing in the ORG'd boot code
#     (intended [boot_drive]/DAP/msg references at 0x7C00/0x7E00).
#   -Wno-reloc-abs-dword/-qword (BIN): GDT descriptors and page-table setup
#     use intentional absolute addresses in the flat binary.
#   -Wno-reloc-rel-dword/-abs-qword (ELF): cross-section calls/jmps and
#     64-bit absolute symbol loads in kernel objects; resolved by ld.
# (--warn-section-align stays omitted for ld: the flat-binary linker script
# intentionally shifts section starts.)
NASM_BIN := $(NASM) -f bin -Wall -Werror -Wno-reloc-abs-word -Wno-reloc-abs-dword -Wno-reloc-abs-qword
NASM_ELF := $(NASM) -f elf64 -g -F dwarf -Wall -Werror -Wno-reloc-abs-word -Wno-reloc-rel-dword -Wno-reloc-abs-qword -I.
# Self-test control (docs/05 §7): default smoke suite is non-destructive.
#   Smoke (default): -DRUN_SELFTEST -> _start runs PURE + SCRATCH-DEVICE +
#     REAL-VOLUME READ-ONLY (85 tests); destructive 71/83/88/89 print SKIP
#     and leave the volume untouched. NOTE: even smoke performs bounded
#     device writes (scratch-LBA patterns at 200/500-511, zeroed after;
#     FAT2 heal on a diverged mount). Only SKIP_SELFTEST performs zero
#     device writes.
#   Full (destructive): -DRUN_SELFTEST -DSELFTEST_DESTRUCTIVE -> all 89 tests
#     including 71 (SCRATCH/RENAMED) + 83 (CRASH) + 88 (handle cycle) + 89
#     (truncate/delete) in the reserved namespace with pre-clean recovery +
#     post-run preservation checks (`make full`).
#   Lean: -DSKIP_SELFTEST -> _start skips suite, minimal init, shell direct.
#   Debug hooks (exec_dbg_pid/stack_dbg_char/cmd_dbg_putc fail-point markers):
#     gated behind -DDEBUG_SELFTEST (same pattern as SELFTEST_DESTRUCTIVE);
#     default/smoke/full/lean builds omit it so release objects stay
#     symbol-clean (`make check-debug-symbols`). Opt in explicitly, e.g.
#     `make NASM_DEFS="-DRUN_SELFTEST -DDEBUG_SELFTEST"`.
# Override with `make NASM_DEFS=-DSKIP_SELFTEST` or `make lean` / `make full`.
NASM_DEFS ?= -DRUN_SELFTEST
FULL_DEFS := -DRUN_SELFTEST -DSELFTEST_DESTRUCTIVE

# Kernel objects: all kernel, drivers, lib .asm files -> .o
KERNEL_SRCS := $(wildcard $(SRC_KERNEL)/*.asm) $(wildcard $(SRC_DRIVERS)/*.asm) $(wildcard $(SRC_LIB)/*.asm)
KERNEL_OBJS := $(patsubst %.asm,$(BUILD)/%.o,$(KERNEL_SRCS))

# Lean kernel objects (separate dir so full/lean can coexist)
LEAN_BUILD := $(BUILD)/lean
LEAN_OBJS := $(patsubst %.asm,$(LEAN_BUILD)/%.o,$(KERNEL_SRCS))

# Full (destructive) kernel objects (separate dir so smoke/full/lean coexist)
FULL_BUILD := $(BUILD)/full
FULL_OBJS := $(patsubst %.asm,$(FULL_BUILD)/%.o,$(KERNEL_SRCS))

# Ensure build dirs exist for nested paths
KERNEL_OBJ_DIRS := $(sort $(dir $(KERNEL_OBJS)))
LEAN_OBJ_DIRS := $(sort $(dir $(LEAN_OBJS)))
FULL_OBJ_DIRS := $(sort $(dir $(FULL_OBJS)))

all: $(BUILD)/dos64.img

lean: $(BUILD)/dos64-lean.img

full: $(BUILD)/dos64-full.img

$(BUILD):
	mkdir -p $(BUILD)

# Generated disk-layout include: the ONLY artifact carrying layout numbers
# into NASM sources (repo-root-relative %include "build/include/layout.inc"
# from src/boot/stage2.asm and include/fs.inc). Regenerated whenever this
# Makefile changes; consumers rebuild via the prerequisites below.
$(LAYOUT_INC): Makefile | $(BUILD)
	@mkdir -p $(dir $@)
	@{ \
		echo '; Generated by Makefile - do not edit. Canonical disk layout'; \
		echo '; (single source of truth: Makefile disk-layout block).'; \
		echo '%ifndef LAYOUT_INC'; \
		echo '%define LAYOUT_INC'; \
		echo '%define IMG_MB $(IMG_MB)'; \
		echo '%define IMG_SECTOR_SIZE $(IMG_SECTOR_SIZE)'; \
		echo '%define KERNEL_LBA $(KERNEL_LBA)'; \
		echo '%define KERNEL_SECTORS $(KERNEL_SECTORS)'; \
		echo '%define VOL_LBA $(VOL_LBA)'; \
		echo '%define VOL_SECTORS $(VOL_SECTORS)'; \
		echo '%define FS_VOL_LBA $(VOL_LBA)'; \
		echo '%define FS_VOL_TOTSEC $(VOL_SECTORS)'; \
		echo '%endif'; \
	} > $@.tmp
	@mv $@.tmp $@
	@echo "Generated $@"

# Helper to create build subdirectories
$(KERNEL_OBJ_DIRS):
	mkdir -p $@

$(LEAN_OBJ_DIRS):
	mkdir -p $@

$(FULL_OBJ_DIRS):
	mkdir -p $@

# Boot images
$(BUILD)/mbr.bin: $(SRC_BOOT)/mbr.asm | $(BUILD)
	$(NASM_BIN) $< -o $@
	@test $$(stat -c %s $@) -eq 512 || (echo "MBR must be 512 bytes"; exit 1)
	@tail -c2 $@ | od -An -tx1 | grep -q "55 aa" || (echo "Missing boot signature 55AA"; exit 1)

$(BUILD)/stage2.bin: $(SRC_BOOT)/stage2.asm $(SRC_BOOT)/gdt.asm $(LAYOUT_INC) | $(BUILD)
	$(NASM_BIN) $< -o $@
	@echo "Stage2 built: $$(stat -c %s $@) bytes"

# Rule for kernel .o from .asm (with include path)
$(BUILD)/%.o: %.asm $(LAYOUT_INC) | $(KERNEL_OBJ_DIRS)
	$(NASM_ELF) $(NASM_DEFS) $< -o $@

$(LEAN_BUILD)/%.o: %.asm $(LAYOUT_INC) | $(LEAN_OBJ_DIRS)
	$(NASM_ELF) -DSKIP_SELFTEST $< -o $@

$(FULL_BUILD)/%.o: %.asm $(LAYOUT_INC) | $(FULL_OBJ_DIRS)
	$(NASM_ELF) $(FULL_DEFS) $< -o $@

$(BUILD)/kernel.elf: $(KERNEL_OBJS) linker.ld | $(BUILD)
	ld -T linker.ld -o $@ $(BUILD)/src/kernel/main.o $(filter-out $(BUILD)/src/kernel/main.o,$(KERNEL_OBJS)) -nostdlib --fatal-warnings -Map=$(BUILD)/kernel.map || (cat $(BUILD)/kernel.map; exit 1)
	@echo "Kernel linked: $$(stat -c %s $@) bytes, objects: $(words $(KERNEL_OBJS))"

$(BUILD)/kernel.bin: $(BUILD)/kernel.elf | $(BUILD)
	objcopy -O binary $< $@
	@echo "Kernel binary: $$(stat -c %s $@) bytes ($$(expr $$(stat -c %s $@) / 512) sectors)"
	@test $$(stat -c %s $@) -le $$(expr $(KERNEL_SECTORS) \* $(IMG_SECTOR_SIZE)) || (echo "Kernel too large for $(KERNEL_SECTORS) sectors! Increase KERNEL_SECTORS in the Makefile disk-layout block"; rm -f $@; exit 1)

$(BUILD)/dos64.img: $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(BUILD)/kernel.bin check-layout check-kbc check-serial check-selftest-modes check-debug-symbols | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=$(IMG_MB) status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=1 conv=notrunc status=none
	dd if=$(BUILD)/kernel.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=$(KERNEL_LBA) conv=notrunc status=none
	python3 -W error tools/mkfat12.py --vol-lba $(VOL_LBA) --vol-totsec $(VOL_SECTORS) --sector-size $(IMG_SECTOR_SIZE) --kernel-lba $(KERNEL_LBA) --kernel-sectors $(KERNEL_SECTORS) $@
	@echo "Created $@ ($$(stat -c %s $@) bytes)"

$(LEAN_BUILD)/kernel.elf: $(LEAN_OBJS) linker.ld | $(BUILD)
	ld -T linker.ld -o $@ $(LEAN_BUILD)/src/kernel/main.o $(filter-out $(LEAN_BUILD)/src/kernel/main.o,$(LEAN_OBJS)) -nostdlib --fatal-warnings -Map=$(LEAN_BUILD)/kernel.map || (cat $(LEAN_BUILD)/kernel.map; exit 1)
	@echo "Lean kernel linked: $$(stat -c %s $@) bytes, objects: $(words $(LEAN_OBJS))"

$(LEAN_BUILD)/kernel.bin: $(LEAN_BUILD)/kernel.elf | $(BUILD)
	objcopy -O binary $< $@
	@echo "Lean kernel binary: $$(stat -c %s $@) bytes ($$(expr $$(stat -c %s $@) / 512) sectors)"
	@test $$(stat -c %s $@) -le $$(expr $(KERNEL_SECTORS) \* $(IMG_SECTOR_SIZE)) || (echo "Lean kernel too large for $(KERNEL_SECTORS) sectors! Increase KERNEL_SECTORS in the Makefile disk-layout block"; rm -f $@; exit 1)

$(BUILD)/dos64-lean.img: $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(LEAN_BUILD)/kernel.bin check-layout check-kbc check-serial check-selftest-modes check-debug-symbols | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=$(IMG_MB) status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=1 conv=notrunc status=none
	dd if=$(LEAN_BUILD)/kernel.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=$(KERNEL_LBA) conv=notrunc status=none
	python3 -W error tools/mkfat12.py --vol-lba $(VOL_LBA) --vol-totsec $(VOL_SECTORS) --sector-size $(IMG_SECTOR_SIZE) --kernel-lba $(KERNEL_LBA) --kernel-sectors $(KERNEL_SECTORS) $@
	@echo "Created $@ ($$(stat -c %s $@) bytes)"

$(FULL_BUILD)/kernel.elf: $(FULL_OBJS) linker.ld | $(BUILD)
	ld -T linker.ld -o $@ $(FULL_BUILD)/src/kernel/main.o $(filter-out $(FULL_BUILD)/src/kernel/main.o,$(FULL_OBJS)) -nostdlib --fatal-warnings -Map=$(FULL_BUILD)/kernel.map || (cat $(FULL_BUILD)/kernel.map; exit 1)
	@echo "Full kernel linked: $$(stat -c %s $@) bytes, objects: $(words $(FULL_OBJS))"

$(FULL_BUILD)/kernel.bin: $(FULL_BUILD)/kernel.elf | $(BUILD)
	objcopy -O binary $< $@
	@echo "Full kernel binary: $$(stat -c %s $@) bytes ($$(expr $$(stat -c %s $@) / 512) sectors)"
	@test $$(stat -c %s $@) -le $$(expr $(KERNEL_SECTORS) \* $(IMG_SECTOR_SIZE)) || (echo "Full kernel too large for $(KERNEL_SECTORS) sectors! Increase KERNEL_SECTORS in the Makefile disk-layout block"; rm -f $@; exit 1)

$(BUILD)/dos64-full.img: $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(FULL_BUILD)/kernel.bin check-layout check-kbc check-serial check-selftest-modes check-debug-symbols | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=$(IMG_MB) status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=1 conv=notrunc status=none
	dd if=$(FULL_BUILD)/kernel.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=$(KERNEL_LBA) conv=notrunc status=none
	python3 -W error tools/mkfat12.py --vol-lba $(VOL_LBA) --vol-totsec $(VOL_SECTORS) --sector-size $(IMG_SECTOR_SIZE) --kernel-lba $(KERNEL_LBA) --kernel-sectors $(KERNEL_SECTORS) $@
	@echo "Created $@ ($$(stat -c %s $@) bytes)"

# Verify the single-sourced layout before any image bytes are written.
# Prerequisite of both disk images, so every `make all` runs this first.
# Fails the build with a clear message instead of producing a
# silently-corrupt image. Checks:
#   1. build/include/layout.inc carries the canonical Makefile values
#      (bootloader/kernel constants and stamper args cannot drift apart).
#   2. stage2.asm / include/fs.inc consume the generated file and no longer
#      hardcode layout numbers.
#   3. tools/mkfat12.py accepts every layout value explicitly and both image
#      recipes pass the canonical values.
#   4. Kernel extent [KERNEL_LBA, +KERNEL_SECTORS) ends at/before VOL_LBA.
#   5. Volume end fits inside the IMG_MB image.
check-layout: $(LAYOUT_INC)
	@test "$$(grep -E '^%define IMG_SECTOR_SIZE' $(LAYOUT_INC) | awk '{print $$3}')" = "$(IMG_SECTOR_SIZE)" || (echo "layout drift: Makefile IMG_SECTOR_SIZE=$(IMG_SECTOR_SIZE) != $(LAYOUT_INC)"; exit 1)
	@test "$$(grep -E '^%define KERNEL_LBA' $(LAYOUT_INC) | awk '{print $$3}')" = "$(KERNEL_LBA)" || (echo "layout drift: Makefile KERNEL_LBA=$(KERNEL_LBA) != $(LAYOUT_INC)"; exit 1)
	@test "$$(grep -E '^%define KERNEL_SECTORS' $(LAYOUT_INC) | awk '{print $$3}')" = "$(KERNEL_SECTORS)" || (echo "layout drift: Makefile KERNEL_SECTORS=$(KERNEL_SECTORS) != $(LAYOUT_INC)"; exit 1)
	@test "$$(grep -E '^%define VOL_LBA' $(LAYOUT_INC) | awk '{print $$3}')" = "$(VOL_LBA)" || (echo "layout drift: Makefile VOL_LBA=$(VOL_LBA) != $(LAYOUT_INC)"; exit 1)
	@test "$$(grep -E '^%define VOL_SECTORS' $(LAYOUT_INC) | awk '{print $$3}')" = "$(VOL_SECTORS)" || (echo "layout drift: Makefile VOL_SECTORS=$(VOL_SECTORS) != $(LAYOUT_INC)"; exit 1)
	@test "$$(grep -E '^%define FS_VOL_LBA' $(LAYOUT_INC) | awk '{print $$3}')" = "$(VOL_LBA)" || (echo "layout drift: $(LAYOUT_INC) FS_VOL_LBA alias != VOL_LBA=$(VOL_LBA)"; exit 1)
	@test "$$(grep -E '^%define FS_VOL_TOTSEC' $(LAYOUT_INC) | awk '{print $$3}')" = "$(VOL_SECTORS)" || (echo "layout drift: $(LAYOUT_INC) FS_VOL_TOTSEC alias != VOL_SECTORS=$(VOL_SECTORS)"; exit 1)
	@grep -q 'build/include/layout.inc' $(SRC_BOOT)/stage2.asm || (echo "layout drift: $(SRC_BOOT)/stage2.asm must %include build/include/layout.inc"; exit 1)
	@grep -q 'build/include/layout.inc' include/fs.inc || (echo "layout drift: include/fs.inc must %include build/include/layout.inc"; exit 1)
	@! grep -Eq '^[[:space:]]*KERNEL_LBA[[:space:]]+equ' $(SRC_BOOT)/stage2.asm || (echo "layout drift: $(SRC_BOOT)/stage2.asm hardcodes KERNEL_LBA; use build/include/layout.inc"; exit 1)
	@! grep -Eq '^[[:space:]]*KERNEL_SECTORS[[:space:]]+equ' $(SRC_BOOT)/stage2.asm || (echo "layout drift: $(SRC_BOOT)/stage2.asm hardcodes KERNEL_SECTORS; use build/include/layout.inc"; exit 1)
	@! grep -Eq '^%define[[:space:]]+FS_VOL_LBA' include/fs.inc || (echo "layout drift: include/fs.inc hardcodes FS_VOL_LBA; use build/include/layout.inc"; exit 1)
	@! grep -Eq '^%define[[:space:]]+FS_VOL_TOTSEC' include/fs.inc || (echo "layout drift: include/fs.inc hardcodes FS_VOL_TOTSEC; use build/include/layout.inc"; exit 1)
	@grep -q -- '--vol-lba' tools/mkfat12.py || (echo "layout drift: tools/mkfat12.py must accept --vol-lba explicitly"; exit 1)
	@grep -q -- '--vol-totsec' tools/mkfat12.py || (echo "layout drift: tools/mkfat12.py must accept --vol-totsec explicitly"; exit 1)
	@grep -q -- '--sector-size' tools/mkfat12.py || (echo "layout drift: tools/mkfat12.py must accept --sector-size explicitly"; exit 1)
	@grep -q -- '--kernel-lba' tools/mkfat12.py || (echo "layout drift: tools/mkfat12.py must accept --kernel-lba explicitly"; exit 1)
	@grep -q -- '--kernel-sectors' tools/mkfat12.py || (echo "layout drift: tools/mkfat12.py must accept --kernel-sectors explicitly"; exit 1)
	@grep -q -- '--vol-lba $$(VOL_LBA)' Makefile || (echo "layout drift: dos64.img recipe must pass --vol-lba $(VOL_LBA) explicitly"; exit 1)
	@test $$(( $(KERNEL_LBA) + $(KERNEL_SECTORS) )) -le $(VOL_LBA) || (echo "layout overlap: kernel extent LBA $(KERNEL_LBA)+$(KERNEL_SECTORS) overlaps volume LBA $(VOL_LBA)"; exit 1)
	@test $$(( ($(VOL_LBA) + $(VOL_SECTORS)) * $(IMG_SECTOR_SIZE) )) -le $$(( $(IMG_MB) * 1024 * 1024 )) || (echo "layout drift: volume end LBA $$(( $(VOL_LBA) + $(VOL_SECTORS) )) exceeds IMG_MB=$(IMG_MB) image"; exit 1)
	@echo "Layout OK: img=$(IMG_MB)MiB secsiz=$(IMG_SECTOR_SIZE) vol_lba=$(VOL_LBA) vol_sectors=$(VOL_SECTORS) kernel_lba=$(KERNEL_LBA) kernel_sectors=$(KERNEL_SECTORS)"

# Negative layout checks — same paths `make all` uses, but with bad inputs
# that must be rejected. Deterministic, no emulator, no timing.
# Verifies: (1) command-line layout overrides are rejected by the
# single-source guard (same error path a relocated `make VOL_LBA=...`
# would hit); (2) the stamper (tools/mkfat12.py, same explicit flags the
# image recipes pass) rejects an overlapping kernel/volume extent and a
# non-512 sector size instead of stamping a corrupt image.
# Run manually (`make check-layout-neg`); `make all` already runs the
# positive `check-layout` on every build, and test 82 locks the same
# arithmetic (kernel_end<=VOL_LBA, volume fits IMG_MB) at runtime.
check-layout-neg: $(BUILD)/mbr.bin
	@echo "Layout negative checks (same paths as make all)..."
	@! $(MAKE) --no-print-directory VOL_LBA=600 check-layout >/dev/null 2>&1 || (echo "layout-neg FAIL: VOL_LBA override not rejected"; exit 1)
	@echo "  override rejection OK"
	@rm -f $(BUILD)/.layout-neg.img
	@dd if=/dev/zero of=$(BUILD)/.layout-neg.img bs=1M count=$(IMG_MB) status=none
	@! python3 -W error tools/mkfat12.py --vol-lba $(VOL_LBA) --vol-totsec $(VOL_SECTORS) --sector-size $(IMG_SECTOR_SIZE) --kernel-lba $(VOL_LBA) --kernel-sectors $(KERNEL_SECTORS) $(BUILD)/.layout-neg.img >/dev/null 2>&1 || (echo "layout-neg FAIL: overlapping kernel/volume not rejected by stamper"; exit 1)
	@echo "  stamper overlap rejection OK"
	@! python3 -W error tools/mkfat12.py --vol-lba $(VOL_LBA) --vol-totsec $(VOL_SECTORS) --sector-size 1024 --kernel-lba $(KERNEL_LBA) --kernel-sectors $(KERNEL_SECTORS) $(BUILD)/.layout-neg.img >/dev/null 2>&1 || (echo "layout-neg FAIL: sector-size 1024 not rejected by stamper"; exit 1)
	@echo "  stamper sector-size rejection OK"
	@rm -f $(BUILD)/.layout-neg.img
	@echo "Layout negative checks OK"

# Bounded-KBC regression check — source-level assertion that the boot
# keyboard-controller waits cannot spin forever. Deterministic, host-side,
# no emulator: greps the same NASM sources `make all` assembles.
# For each of mbr.asm / stage2.asm it verifies:
#   1. a `kbc_wait_timeout:` helper exists (the bounded helper);
#   2. the helper loads a finite counter from a KBC_TIMEOUT* bound
#      (`mov cx, KBC_TIMEOUT...`) and decrements it (`dec cx`);
#   3. the helper has an explicit failure branch returning CF=1 (`stc`)
#      alongside the success branch (`clc`);
#   4. every KBC command/status wait checks the return (`jc ...` after
#      each `call kbc_wait_timeout` — 3 sites per stage);
#   5. no unbounded wait remains (`jnz` directly to a kbc_wait* label).
# A timeout is a FALLBACK condition (fast-A20 via port 0x92 is primary),
# not boot-fatal: callers skip the remaining KBC outs, re-assert fast A20,
# print a diagnostic, and continue boot. Prerequisite of both disk images,
# so every `make all` runs this with no separate invocation.
check-kbc:
	@for f in $(SRC_BOOT)/mbr.asm $(SRC_BOOT)/stage2.asm; do \
		grep -q 'kbc_wait_timeout:' $$f || (echo "kbc FAIL: $$f missing kbc_wait_timeout helper"; exit 1); \
		grep -q 'KBC_TIMEOUT' $$f || (echo "kbc FAIL: $$f missing KBC_TIMEOUT bound"; exit 1); \
		grep -Eq 'mov[[:space:]]+cx,[[:space:]]*KBC_TIMEOUT' $$f || (echo "kbc FAIL: $$f helper does not load finite CX counter"; exit 1); \
		grep -Eq 'dec[[:space:]]+cx' $$f || (echo "kbc FAIL: $$f helper has no decrementing counter"; exit 1); \
		grep -q '[[:space:]]stc' $$f || (echo "kbc FAIL: $$f helper has no explicit failure branch (stc/CF=1)"; exit 1); \
		grep -q '[[:space:]]clc' $$f || (echo "kbc FAIL: $$f helper has no success branch (clc/CF=0)"; exit 1); \
		test $$(grep -c 'call kbc_wait_timeout' $$f) -eq 3 || (echo "kbc FAIL: $$f must check 3 KBC waits (found $$(grep -c 'call kbc_wait_timeout' $$f))"; exit 1); \
		test $$(grep -c 'jc .kbc_skip' $$f) -eq 3 || (echo "kbc FAIL: $$f must branch on timeout after each wait (found $$(grep -c 'jc .kbc_skip' $$f) jc)"; exit 1); \
		! grep -Eq 'jnz[[:space:]]+kbc_wait' $$f || (echo "kbc FAIL: $$f still contains unbounded jnz to kbc_wait*"; exit 1); \
	done
	@echo "KBC wait OK: bounded kbc_wait_timeout (CX counter + CF=1 timeout) with fallback in mbr + stage2"

# Bounded-serial regression check — source-level assertion that no serial
# transmit path can spin forever on UART readiness. Deterministic,
# host-side, no emulator: greps the same NASM sources `make all` assembles.
# Serial is optional best-effort diagnostic I/O (VGA is authoritative): every
# TX site must use a bounded helper that drops the character on timeout
# (CF=1) instead of hanging boot, the suite, or the shell.
# Verifies:
#   1. Boot (mbr/stage2): a `serial_try_putc*` helper exists with a finite
#      `SERIAL_TIMEOUT*` counter (`mov cx, ...`, `dec cx`) and explicit
#      drop (`stc`/CF=1) + success (`clc`/CF=0) branches; the print path
#      calls it; the old unbounded `jz .wait_ser*` spin is gone.
#   2. Kernel: `main.asm` provides the single reusable `serial_try_putc64`
#      (finite `mov ecx, SERIAL_TIMEOUT` + `dec ecx`, `stc`/`clc`), and
#      `serial_print64` calls it (CF ignored: drop and continue).
#   3. All other kernel TX sites (shell/cmd/selftest/stack) call the shared
#      helper and perform no direct `mov dx, 0x3FD` UART poll of their own.
#   4. The AUX backend (`syscall64.asm com1_write_char`) stays bounded too
#      (`dec rcx` budget + `stc` timeout); the RX poll (`com1_read_char`)
#      is single-shot non-blocking by design.
# Normal QEMU output is unchanged: the timeout budget covers 16550
# baud per-byte delay, and a missing UART reads LSR=0xFF (THRE set) so the
# first poll succeeds. Prerequisite of both disk images, so every
# `make all` runs this with no separate invocation.
check-serial:
	@for f in $(SRC_BOOT)/mbr.asm $(SRC_BOOT)/stage2.asm; do \
		grep -q 'serial_try_putc' $$f || (echo "serial FAIL: $$f missing serial_try_putc helper"; exit 1); \
		grep -q 'SERIAL_TIMEOUT' $$f || (echo "serial FAIL: $$f missing SERIAL_TIMEOUT bound"; exit 1); \
		grep -Eq 'mov[[:space:]]+cx,[[:space:]]*SERIAL_TIMEOUT' $$f || (echo "serial FAIL: $$f helper does not load finite CX counter"; exit 1); \
		grep -Eq 'dec[[:space:]]+cx' $$f || (echo "serial FAIL: $$f helper has no decrementing counter"; exit 1); \
		grep -q '[[:space:]]stc' $$f || (echo "serial FAIL: $$f helper has no drop branch (stc/CF=1)"; exit 1); \
		grep -q '[[:space:]]clc' $$f || (echo "serial FAIL: $$f helper has no success branch (clc/CF=0)"; exit 1); \
		grep -q 'call serial_try_putc' $$f || (echo "serial FAIL: $$f print path does not use bounded helper"; exit 1); \
		! grep -Eq 'jz[[:space:]]+\.wait_ser' $$f || (echo "serial FAIL: $$f still contains unbounded jz to .wait_ser*"; exit 1); \
	done
	@grep -q 'global serial_try_putc64' $(SRC_KERNEL)/main.asm || (echo "serial FAIL: main.asm missing shared serial_try_putc64"; exit 1)
	@grep -q 'SERIAL_TIMEOUT equ' $(SRC_KERNEL)/main.asm || (echo "serial FAIL: main.asm missing SERIAL_TIMEOUT bound"; exit 1)
	@grep -Eq 'mov[[:space:]]+ecx,[[:space:]]*SERIAL_TIMEOUT' $(SRC_KERNEL)/main.asm || (echo "serial FAIL: serial_try_putc64 does not load finite ECX counter"; exit 1)
	@grep -Eq 'dec[[:space:]]+ecx' $(SRC_KERNEL)/main.asm || (echo "serial FAIL: serial_try_putc64 has no decrementing counter"; exit 1)
	@grep -q 'call serial_try_putc64' $(SRC_KERNEL)/main.asm || (echo "serial FAIL: serial_print64 does not use bounded helper"; exit 1)
	@for f in $(SRC_KERNEL)/shell64.asm $(SRC_KERNEL)/cmd64.asm $(SRC_KERNEL)/selftest64.asm $(SRC_KERNEL)/stack64.asm; do \
		grep -q 'call serial_try_putc64' $$f || (echo "serial FAIL: $$f does not use shared serial_try_putc64"; exit 1); \
		! grep -q 'mov dx, 0x3FD' $$f || (echo "serial FAIL: $$f still polls UART directly (must go through serial_try_putc64)"; exit 1); \
	done
	@grep -Eq 'dec[[:space:]]+rcx' $(SRC_KERNEL)/syscall64.asm || (echo "serial FAIL: syscall64.asm com1_write_char lost its bounded counter"; exit 1)
	@echo "Serial TX OK: bounded serial_try_putc (boot) + serial_try_putc64 (kernel, drop on timeout) in mbr + stage2 + main/shell/cmd/selftest/stack"

# Self-test mode check — source-level assertion that the destructive
# filesystem tests are isolated from the default boot smoke suite.
# Deterministic, host-side, no emulator: greps the same NASM sources
# `make all` assembles. Verifies:
#   1. selftest64.asm classifies PURE / SCRATCH-DEVICE / READ-ONLY /
#      DESTRUCTIVE and documents that RUN_SELFTEST performs writes.
#   2. Tests 71/83/88/89 dispatch is gated on SELFTEST_DESTRUCTIVE with a
#      SKIP path (smoke leaves the volume untouched); the msg_skip +
#      skipped summary strings exist and R14 counts skips.
#   3. FULL_DEFS carries -DSELFTEST_DESTRUCTIVE and the full image recipe
#      exists (`make full` -> dos64-full.img); default NASM_DEFS does NOT
#      (plain `make` stays smoke).
#   4. include/fs.inc reserves SCRATCH/RENAMED/CRASH and smoke never creates
#      them (test 71 pre-clean deletes both, test 83 deletes CRASH).
check-selftest-modes:
	@grep -q 'SELFTEST_DESTRUCTIVE' $(SRC_KERNEL)/selftest64.asm || (echo "selftest-modes FAIL: selftest64.asm missing SELFTEST_DESTRUCTIVE gate"; exit 1)
	@grep -q 'SCRATCH-DEVICE' $(SRC_KERNEL)/selftest64.asm || (echo "selftest-modes FAIL: missing classification header"; exit 1)
	@grep -q 'msg_skip' $(SRC_KERNEL)/selftest64.asm || (echo "selftest-modes FAIL: missing msg_skip"; exit 1)
	@grep -q 'Skipped (destructive)' $(SRC_KERNEL)/selftest64.asm || (echo "selftest-modes FAIL: missing skipped summary"; exit 1)
	@test $$(grep -c 'ifdef SELFTEST_DESTRUCTIVE' $(SRC_KERNEL)/selftest64.asm) -ge 3 || (echo "selftest-modes FAIL: expected >=3 ifdef SELFTEST_DESTRUCTIVE (71+83+69+88+89)"; exit 1)
	@grep -q 'FULL_DEFS := -DRUN_SELFTEST -DSELFTEST_DESTRUCTIVE' Makefile || (echo "selftest-modes FAIL: Makefile missing FULL_DEFS"; exit 1)
	@grep -q 'dos64-full.img' Makefile || (echo "selftest-modes FAIL: Makefile missing full image recipe"; exit 1)
	@! grep -Eq '^NASM_DEFS \?= .*SELFTEST_DESTRUCTIVE' Makefile || (echo "selftest-modes FAIL: default NASM_DEFS must stay smoke (no SELFTEST_DESTRUCTIVE)"; exit 1)
	@grep -q 'SCRATCH.TXT' include/fs.inc || (echo "selftest-modes FAIL: include/fs.inc missing reserved namespace"; exit 1)
	@grep -q 'check_volume_clean' include/fs.inc || (echo "selftest-modes FAIL: include/fs.inc must reference check_volume_clean"; exit 1)
	@echo "Selftest modes OK: smoke (86 + 4 SKIP) default, full (90) via make full"

# Debug-hook check — source-level assertion that test/fail-point markers
# stay out of release objects (same pattern as SELFTEST_DESTRUCTIVE).
# Deterministic, host-side, no emulator: greps the same NASM sources
# `make all` assembles. (Source-level only, like check-kbc/check-serial:
# it never inspects built ELFs, so stale variant builds cannot false-fail
# a single-image rebuild. After building, validate artifacts manually:
#   nm build/kernel.elf | grep -E 'exec_dbg|stack_dbg|cmd_dbg|exec_ret'
#   nm build/lean/kernel.elf | grep -i dbg
# both must print nothing.)
# Verifies:
#   1. syscall64.asm gates exec_dbg_pid (global + BSS + handler_exec store)
#      behind DEBUG_SELFTEST and defines/uses no exec_ret BSS statics
#      (handler_exec preserves pid/psp via a stack-slot discard — `add rsp,8`
#      over the saved orig-RDX slot — not via statics).
#   2. stack64.asm gates stack_dbg_char and cmd64.asm gates cmd_dbg_putc
#      behind DEBUG_SELFTEST; selftest64.asm gates its extern/use likewise.
#   3. Default builds never define DEBUG_SELFTEST (NASM_DEFS/FULL_DEFS omit
#      it; lean uses -DSKIP_SELFTEST), so smoke/full/lean all stay clean.
# Debug builds opt in explicitly, e.g.
#   make NASM_DEFS="-DRUN_SELFTEST -DDEBUG_SELFTEST"
# Prerequisite of all disk images, so every `make` runs this with no
# separate invocation.
check-debug-symbols:
	@grep -q 'ifdef DEBUG_SELFTEST' $(SRC_KERNEL)/syscall64.asm || (echo "debug-symbols FAIL: syscall64.asm missing DEBUG_SELFTEST gate"; exit 1)
	@grep -q 'global exec_dbg_pid' $(SRC_KERNEL)/syscall64.asm || (echo "debug-symbols FAIL: syscall64.asm missing gated exec_dbg_pid"; exit 1)
	@! grep -Eq 'exec_ret_(pid|psp):' $(SRC_KERNEL)/syscall64.asm || (echo "debug-symbols FAIL: syscall64.asm still defines exec_ret BSS static (use stack discard)"; exit 1)
	@! grep -Eq '\[rel exec_ret_(pid|psp)\]' $(SRC_KERNEL)/syscall64.asm || (echo "debug-symbols FAIL: syscall64.asm still uses exec_ret static (use stack discard)"; exit 1)
	@grep -q 'ifdef DEBUG_SELFTEST' $(SRC_KERNEL)/stack64.asm || (echo "debug-symbols FAIL: stack64.asm missing DEBUG_SELFTEST gate"; exit 1)
	@grep -q 'stack_dbg_char' $(SRC_KERNEL)/stack64.asm || (echo "debug-symbols FAIL: stack64.asm missing gated stack_dbg_char"; exit 1)
	@grep -q 'ifdef DEBUG_SELFTEST' $(SRC_KERNEL)/cmd64.asm || (echo "debug-symbols FAIL: cmd64.asm missing DEBUG_SELFTEST gate"; exit 1)
	@grep -q 'cmd_dbg_putc' $(SRC_KERNEL)/cmd64.asm || (echo "debug-symbols FAIL: cmd64.asm missing gated cmd_dbg_putc"; exit 1)
	@grep -q 'ifdef DEBUG_SELFTEST' $(SRC_KERNEL)/selftest64.asm || (echo "debug-symbols FAIL: selftest64.asm missing DEBUG_SELFTEST gate"; exit 1)
	@! grep -Eq '^NASM_DEFS \?= .*DEBUG_SELFTEST' Makefile || (echo "debug-symbols FAIL: default NASM_DEFS must omit DEBUG_SELFTEST (release symbol-clean)"; exit 1)
	@! grep -Eq '^FULL_DEFS := .*DEBUG_SELFTEST' Makefile || (echo "debug-symbols FAIL: FULL_DEFS must omit DEBUG_SELFTEST (full stays symbol-clean)"; exit 1)
	@echo "Debug symbols OK: hooks gated behind -DDEBUG_SELFTEST (release symbol-clean; nm validation: no exec_dbg/stack_dbg/cmd_dbg/exec_ret)"

# QEMU run targets (only supported emulator; `-serial stdio` carries the
# suite transcript and the COMMAND64 REPL).
run-qemu: $(BUILD)/dos64.img
	qemu-system-x86_64 -drive file=$(BUILD)/dos64.img,format=raw -serial stdio

run-qemu-lean: $(BUILD)/dos64-lean.img
	qemu-system-x86_64 -drive file=$(BUILD)/dos64-lean.img,format=raw -serial stdio

run-qemu-full: $(BUILD)/dos64-full.img
	qemu-system-x86_64 -drive file=$(BUILD)/dos64-full.img,format=raw -serial stdio

# N1 cross-assemble samples (PLAN.md tier 1; docs/21-nasm-cross.md).
# Samples are assembled with a NASM built from the vendored nasm/
# submodule (exact pin, not whatever the host ships) and staged onto a
# separate dos64-nasm.img variant. The default smoke/full/lean images are
# untouched (still only HELLO.TXT/README.TXT/TEST.COM/DATA.BIN).
# The submodule build is cached under build/nasm-sub (gitignored); it
# rebuilds only when missing. `make nasm-clean` drops that cache.
NASM_SUB_SRC := nasm
NASM_SUB_BUILD := $(BUILD)/nasm-sub/src
NASM_SUB_BIN := $(NASM_SUB_BUILD)/nasm
SAMPLE_OUTDIR := $(BUILD)/nasm-samples
SAMPLE_OUTS := $(SAMPLE_OUTDIR)/HELLO.COM $(SAMPLE_OUTDIR)/ECHO.COM $(SAMPLE_OUTDIR)/CAT.COM $(SAMPLE_OUTDIR)/WRITE.COM
NASM_IMG := $(BUILD)/dos64-nasm.img

$(NASM_SUB_BIN):
	mkdir -p $(BUILD)/nasm-sub
	cp -a $(NASM_SUB_SRC)/. $(NASM_SUB_BUILD)/
	cd $(NASM_SUB_BUILD) && ./autogen.sh
	cd $(NASM_SUB_BUILD) && ./configure --disable-lto --disable-debug
	$(MAKE) -C $(NASM_SUB_BUILD) -j nasm

$(SAMPLE_OUTDIR)/HELLO.COM: samples/hello.asm $(NASM_SUB_BIN) | $(BUILD)
	mkdir -p $(SAMPLE_OUTDIR)
	$(NASM_SUB_BIN) -f bin $< -o $@
	@test $$(stat -c %s $@) -le 4096 || (echo "sample $@ exceeds 4096B shell staging"; exit 1)

$(SAMPLE_OUTDIR)/ECHO.COM: samples/echo.asm $(NASM_SUB_BIN) | $(BUILD)
	mkdir -p $(SAMPLE_OUTDIR)
	$(NASM_SUB_BIN) -f bin $< -o $@
	@test $$(stat -c %s $@) -le 4096 || (echo "sample $@ exceeds 4096B shell staging"; exit 1)

$(SAMPLE_OUTDIR)/CAT.COM: samples/cat.asm $(NASM_SUB_BIN) | $(BUILD)
	mkdir -p $(SAMPLE_OUTDIR)
	$(NASM_SUB_BIN) -f bin $< -o $@
	@test $$(stat -c %s $@) -le 4096 || (echo "sample $@ exceeds 4096B shell staging"; exit 1)

$(SAMPLE_OUTDIR)/WRITE.COM: samples/write.asm $(NASM_SUB_BIN) | $(BUILD)
	mkdir -p $(SAMPLE_OUTDIR)
	$(NASM_SUB_BIN) -f bin $< -o $@
	@test $$(stat -c %s $@) -le 4096 || (echo "sample $@ exceeds 4096B shell staging"; exit 1)

$(NASM_IMG): $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(BUILD)/kernel.bin $(SAMPLE_OUTS) check-layout check-kbc check-serial check-selftest-modes check-debug-symbols | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=$(IMG_MB) status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=1 conv=notrunc status=none
	dd if=$(BUILD)/kernel.bin of=$@ bs=$(IMG_SECTOR_SIZE) seek=$(KERNEL_LBA) conv=notrunc status=none
	python3 -W error tools/mkfat12.py --vol-lba $(VOL_LBA) --vol-totsec $(VOL_SECTORS) --sector-size $(IMG_SECTOR_SIZE) --kernel-lba $(KERNEL_LBA) --kernel-sectors $(KERNEL_SECTORS) --extra-file HELLO.COM=$(SAMPLE_OUTDIR)/HELLO.COM --extra-file ECHO.COM=$(SAMPLE_OUTDIR)/ECHO.COM --extra-file CAT.COM=$(SAMPLE_OUTDIR)/CAT.COM --extra-file WRITE.COM=$(SAMPLE_OUTDIR)/WRITE.COM $@
	@echo "Created $@ ($$(stat -c %s $@) bytes, with N1+N2d samples)"

nasm-samples: $(NASM_IMG)

run-qemu-nasm: $(NASM_IMG)
	qemu-system-x86_64 -drive file=$(NASM_IMG),format=raw -serial stdio

nasm-clean:
	rm -rf $(BUILD)/nasm-sub $(SAMPLE_OUTDIR) $(NASM_IMG) $(NASM_IMG).lock

clean:
	rm -rf $(BUILD)/*.bin $(BUILD)/*.o $(BUILD)/*.img $(BUILD)/*.elf $(BUILD)/*.map $(BUILD)/*.lock
	rm -rf $(BUILD)/src $(BUILD)/lean $(BUILD)/full $(BUILD)/include

.PHONY: all lean full clean run-qemu run-qemu-lean run-qemu-full check-layout check-layout-neg check-kbc check-serial check-selftest-modes check-debug-symbols nasm-samples run-qemu-nasm nasm-clean
