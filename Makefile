# MS-DOS64 – 64-bit BIOS boot build (Phase 12 - stack & ABI)
# Phase 12: Stack/ABI hardening (RSP 16B, System V RDI/RSI/RDX/RCX/R8/R9, callee-saved, canary, IST reserve) + all prior phases
# Requires: nasm >=2.15, ld (binutils), qemu or bochs
BUILD := build
SRC_BOOT := src/boot
SRC_KERNEL := src/kernel
SRC_DRIVERS := src/drivers
SRC_LIB := src/lib

# Disk layout — single source of truth for image creation (see also
# tools/mkfat12.py DOS64_* env defaults, include/fs.inc FS_VOL_LBA /
# FS_VOL_TOTSEC consumed by the kernel, and README.md "Disk layout").
# `make check-layout` enforces that all copies agree.
IMG_MB ?= 10
VOL_LBA ?= 512
VOL_SECTORS ?= 2880
KERNEL_LBA ?= 16

NASM := nasm
NASM_BIN := $(NASM) -f bin
NASM_ELF := $(NASM) -f elf64 -g -F dwarf -I.
# Self-test control (docs/05 §7): default full build runs the suite.
#   Full: -DRUN_SELFTEST (default) -> _start runs tests 1..76 then shell.
#   Lean: -DSKIP_SELFTEST -> _start skips suite, minimal init, shell direct.
# Override with `make NASM_DEFS=-DSKIP_SELFTEST` or `make lean`.
NASM_DEFS ?= -DRUN_SELFTEST

# Kernel objects: all kernel, drivers, lib .asm files -> .o
KERNEL_SRCS := $(wildcard $(SRC_KERNEL)/*.asm) $(wildcard $(SRC_DRIVERS)/*.asm) $(wildcard $(SRC_LIB)/*.asm)
KERNEL_OBJS := $(patsubst %.asm,$(BUILD)/%.o,$(KERNEL_SRCS))

# Lean kernel objects (separate dir so full/lean can coexist)
LEAN_BUILD := $(BUILD)/lean
LEAN_OBJS := $(patsubst %.asm,$(LEAN_BUILD)/%.o,$(KERNEL_SRCS))

# Ensure build dirs exist for nested paths
KERNEL_OBJ_DIRS := $(sort $(dir $(KERNEL_OBJS)))
LEAN_OBJ_DIRS := $(sort $(dir $(LEAN_OBJS)))

all: $(BUILD)/dos64.img

lean: $(BUILD)/dos64-lean.img

$(BUILD):
	mkdir -p $(BUILD)

# Helper to create build subdirectories
$(KERNEL_OBJ_DIRS):
	mkdir -p $@

$(LEAN_OBJ_DIRS):
	mkdir -p $@

# Boot images
$(BUILD)/mbr.bin: $(SRC_BOOT)/mbr.asm | $(BUILD)
	$(NASM_BIN) $< -o $@
	@test $$(stat -c %s $@) -eq 512 || (echo "MBR must be 512 bytes"; exit 1)
	@tail -c2 $@ | od -An -tx1 | grep -q "55 aa" || (echo "Missing boot signature 55AA"; exit 1)

$(BUILD)/stage2.bin: $(SRC_BOOT)/stage2.asm $(SRC_BOOT)/gdt.asm | $(BUILD)
	$(NASM_BIN) $< -o $@
	@echo "Stage2 built: $$(stat -c %s $@) bytes"

# Rule for kernel .o from .asm (with include path)
$(BUILD)/%.o: %.asm | $(KERNEL_OBJ_DIRS)
	$(NASM_ELF) $(NASM_DEFS) $< -o $@

$(LEAN_BUILD)/%.o: %.asm | $(LEAN_OBJ_DIRS)
	$(NASM_ELF) -DSKIP_SELFTEST $< -o $@

$(BUILD)/kernel.elf: $(KERNEL_OBJS) linker.ld | $(BUILD)
	ld -T linker.ld -o $@ $(BUILD)/src/kernel/main.o $(filter-out $(BUILD)/src/kernel/main.o,$(KERNEL_OBJS)) -nostdlib -Map=$(BUILD)/kernel.map || (cat $(BUILD)/kernel.map; exit 1)
	@echo "Kernel linked: $$(stat -c %s $@) bytes, objects: $(words $(KERNEL_OBJS))"

$(BUILD)/kernel.bin: $(BUILD)/kernel.elf | $(BUILD)
	objcopy -O binary $< $@
	@echo "Kernel binary: $$(stat -c %s $@) bytes ($$(expr $$(stat -c %s $@) / 512) sectors)"
	@test $$(stat -c %s $@) -le $$(expr 176 \* 512) || (echo "Kernel too large for 176 sectors! Increase KERNEL_SECTORS"; exit 1)

$(BUILD)/dos64.img: $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(BUILD)/kernel.bin | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=$(IMG_MB) status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=512 seek=1 conv=notrunc status=none
	dd if=$(BUILD)/kernel.bin of=$@ bs=512 seek=$(KERNEL_LBA) conv=notrunc status=none
	DOS64_VOL_LBA=$(VOL_LBA) DOS64_VOL_TOTSEC=$(VOL_SECTORS) python3 tools/mkfat12.py $@
	@echo "Created $@ ($$(stat -c %s $@) bytes)"

$(LEAN_BUILD)/kernel.elf: $(LEAN_OBJS) linker.ld | $(BUILD)
	ld -T linker.ld -o $@ $(LEAN_BUILD)/src/kernel/main.o $(filter-out $(LEAN_BUILD)/src/kernel/main.o,$(LEAN_OBJS)) -nostdlib -Map=$(LEAN_BUILD)/kernel.map || (cat $(LEAN_BUILD)/kernel.map; exit 1)
	@echo "Lean kernel linked: $$(stat -c %s $@) bytes, objects: $(words $(LEAN_OBJS))"

$(LEAN_BUILD)/kernel.bin: $(LEAN_BUILD)/kernel.elf | $(BUILD)
	objcopy -O binary $< $@
	@echo "Lean kernel binary: $$(stat -c %s $@) bytes ($$(expr $$(stat -c %s $@) / 512) sectors)"
	@test $$(stat -c %s $@) -le $$(expr 176 \* 512) || (echo "Lean kernel too large for 176 sectors! Increase KERNEL_SECTORS"; exit 1)

$(BUILD)/dos64-lean.img: $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(LEAN_BUILD)/kernel.bin | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=$(IMG_MB) status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=512 seek=1 conv=notrunc status=none
	dd if=$(LEAN_BUILD)/kernel.bin of=$@ bs=512 seek=$(KERNEL_LBA) conv=notrunc status=none
	DOS64_VOL_LBA=$(VOL_LBA) DOS64_VOL_TOTSEC=$(VOL_SECTORS) python3 tools/mkfat12.py $@
	@echo "Created $@ ($$(stat -c %s $@) bytes)"

# Verify the layout constants stay consistent across Makefile, mkfat12.py
# defaults, and include/fs.inc (kernel). Fails the build with a clear message
# instead of producing a silently-corrupt image.
check-layout:
	@test "$(VOL_LBA)" = "$$(grep -E '^%define FS_VOL_LBA' include/fs.inc | awk '{print $$3}')" || (echo "layout drift: Makefile VOL_LBA=$(VOL_LBA) != include/fs.inc FS_VOL_LBA=$$(grep -E '^%define FS_VOL_LBA' include/fs.inc | awk '{print $$3}')"; exit 1)
	@test "$(VOL_SECTORS)" = "$$(grep -E '^%define FS_VOL_TOTSEC' include/fs.inc | awk '{print $$3}')" || (echo "layout drift: Makefile VOL_SECTORS=$(VOL_SECTORS) != include/fs.inc FS_VOL_TOTSEC=$$(grep -E '^%define FS_VOL_TOTSEC' include/fs.inc | awk '{print $$3}')"; exit 1)
	@test "$$(DOS64_VOL_LBA= DOS64_VOL_TOTSEC= python3 -c 'import sys; sys.path.insert(0, "tools"); import mkfat12; print(mkfat12.VOL_LBA)')" = "$(VOL_LBA)" || (echo "layout drift: Makefile VOL_LBA=$(VOL_LBA) != tools/mkfat12.py default"; exit 1)
	@test "$$(DOS64_VOL_LBA= DOS64_VOL_TOTSEC= python3 -c 'import sys; sys.path.insert(0, "tools"); import mkfat12; print(mkfat12.TOTSEC)')" = "$(VOL_SECTORS)" || (echo "layout drift: Makefile VOL_SECTORS=$(VOL_SECTORS) != tools/mkfat12.py default"; exit 1)
	@test $$(( ($(VOL_LBA) + $(VOL_SECTORS)) * 512 )) -le $$(( $(IMG_MB) * 1024 * 1024 )) || (echo "layout drift: volume end LBA $$(( $(VOL_LBA) + $(VOL_SECTORS) )) exceeds IMG_MB=$(IMG_MB) image"; exit 1)
	@echo "Layout OK: img=$(IMG_MB)MiB vol_lba=$(VOL_LBA) vol_sectors=$(VOL_SECTORS) kernel_lba=$(KERNEL_LBA)"

run-bochs: $(BUILD)/dos64.img
	rm -f $(BUILD)/dos64.img.lock bochs.log serial.log
	bochs -f bochsrc.txt -q

run-qemu: $(BUILD)/dos64.img
	qemu-system-x86_64 -drive file=$(BUILD)/dos64.img,format=raw -serial stdio

run-qemu-lean: $(BUILD)/dos64-lean.img
	qemu-system-x86_64 -drive file=$(BUILD)/dos64-lean.img,format=raw -serial stdio

clean:
	rm -rf $(BUILD)/*.bin $(BUILD)/*.o $(BUILD)/*.img $(BUILD)/*.elf $(BUILD)/*.map $(BUILD)/*.lock
	rm -rf $(BUILD)/src $(BUILD)/lean

.PHONY: all lean clean run-bochs run-qemu run-qemu-lean check-layout
