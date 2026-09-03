# MS-DOS64 – 64-bit BIOS boot build (Phase 6 - memory management overhaul)
# Phase 6: MCB64 coalesce/resize/validate/protect, para/page helpers, AH=48h/49h/4Ah
# Requires: nasm >=2.15, ld (binutils), qemu or bochs
BUILD := build
SRC_BOOT := src/boot
SRC_KERNEL := src/kernel
SRC_DRIVERS := src/drivers
SRC_LIB := src/lib

NASM := nasm
NASM_BIN := $(NASM) -f bin
NASM_ELF := $(NASM) -f elf64 -g -F dwarf -I.

# Kernel objects: all kernel, drivers, lib .asm files -> .o
KERNEL_SRCS := $(wildcard $(SRC_KERNEL)/*.asm) $(wildcard $(SRC_DRIVERS)/*.asm) $(wildcard $(SRC_LIB)/*.asm)
KERNEL_OBJS := $(patsubst %.asm,$(BUILD)/%.o,$(KERNEL_SRCS))

# Ensure build dirs exist for nested paths
KERNEL_OBJ_DIRS := $(sort $(dir $(KERNEL_OBJS)))

all: $(BUILD)/dos64.img

$(BUILD):
	mkdir -p $(BUILD)

# Helper to create build subdirectories
$(KERNEL_OBJ_DIRS):
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
	$(NASM_ELF) $< -o $@

$(BUILD)/kernel.elf: $(KERNEL_OBJS) linker.ld | $(BUILD)
	ld -T linker.ld -o $@ $(BUILD)/src/kernel/main.o $(filter-out $(BUILD)/src/kernel/main.o,$(KERNEL_OBJS)) -nostdlib -Map=$(BUILD)/kernel.map || (cat $(BUILD)/kernel.map; exit 1)
	@echo "Kernel linked: $$(stat -c %s $@) bytes, objects: $(words $(KERNEL_OBJS))"

$(BUILD)/kernel.bin: $(BUILD)/kernel.elf | $(BUILD)
	objcopy -O binary $< $@
	@echo "Kernel binary: $$(stat -c %s $@) bytes ($$(expr $$(stat -c %s $@) / 512) sectors)"
	@test $$(stat -c %s $@) -le $$(expr 64 \* 512) || (echo "Kernel too large for 64 sectors! Increase KERNEL_SECTORS"; exit 1)

$(BUILD)/dos64.img: $(BUILD)/mbr.bin $(BUILD)/stage2.bin $(BUILD)/kernel.bin | $(BUILD)
	dd if=/dev/zero of=$@ bs=1M count=10 status=none
	dd if=$(BUILD)/mbr.bin of=$@ conv=notrunc status=none
	dd if=$(BUILD)/stage2.bin of=$@ bs=512 seek=1 conv=notrunc status=none
	dd if=$(BUILD)/kernel.bin of=$@ bs=512 seek=16 conv=notrunc status=none
	@echo "Created $@ ($$(stat -c %s $@) bytes)"

run-bochs: $(BUILD)/dos64.img
	bochs -f bochsrc.txt -q

run-qemu: $(BUILD)/dos64.img
	qemu-system-x86_64 -drive file=$(BUILD)/dos64.img,format=raw -serial stdio

clean:
	rm -rf $(BUILD)/*.bin $(BUILD)/*.o $(BUILD)/*.img $(BUILD)/*.elf $(BUILD)/*.map
	rm -rf $(BUILD)/src

.PHONY: all clean run-bochs run-qemu
