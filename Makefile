# MS-DOS64 – 64-bit BIOS boot build (Phase 1 scaffold)
# Requires: nasm >=2.15, ld (binutils), qemu or bochs
BUILD := build
SRC_BOOT := src/boot
SRC_KERNEL := src/kernel

NASM := nasm
NASM_BIN := $(NASM) -f bin
NASM_ELF := $(NASM) -f elf64 -g -F dwarf

all: $(BUILD)/dos64.img

$(BUILD):
	mkdir -p $(BUILD)

# Phase 2 boot images (stubs – Phase 1 only validates structure)
$(BUILD)/mbr.bin: $(SRC_BOOT)/mbr.asm | $(BUILD)
	$(NASM_BIN) $< -o $@
	@test $$(stat -c %s $@) -eq 512 || (echo "MBR must be 512 bytes"; exit 1)
	@tail -c2 $@ | od -An -tx1 | grep -q "55 aa" || (echo "Missing boot signature 55AA"; exit 1)

$(BUILD)/stage2.bin: $(SRC_BOOT)/stage2.asm $(SRC_BOOT)/gdt.asm | $(BUILD)
	$(NASM_BIN) $(SRC_BOOT)/stage2.asm -o $@

$(BUILD)/kernel.bin: $(wildcard $(SRC_KERNEL)/*.asm) | $(BUILD)
	$(NASM_ELF) $(SRC_KERNEL)/main.asm -o $(BUILD)/kernel.o
	ld -T linker.ld -o $(BUILD)/kernel.elf $(BUILD)/kernel.o -nostdlib
	objcopy -O binary $(BUILD)/kernel.elf $@

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
	rm -rf $(BUILD)/*.bin $(BUILD)/*.o $(BUILD)/*.img $(BUILD)/*.elf

.PHONY: all clean run-bochs run-qemu
