/* ASM64 tool link (N4B.3c): flat .COM payload, base 0.
 *
 * asm64_main.o MUST come first on the ld command line so _start lands at
 * file offset 0 (the COM entry = PSP+PSP_SIZE = image base; the loader does
 * NO relocation, so the image must be slide-safe).
 *
 * Slide-safety is VERIFIED, not arranged, by this script: a .got with
 * content or dynamic relocs in the linked ELF means absolute addressing
 * slipped in and the image would break at any nonzero load address. Keep
 * .got visible here (never /DISCARD/ it) so the acceptance check fails
 * loudly instead of silently (same bar as N3.5 userland.ld).
 *
 * BSS is NOBITS: objcopy -O binary TRUNCATES trailing NOBITS, so the
 * Makefile pads the image with truncate-to-BSS-end (zeros), which both
 * backs the core's ~18 KB of tables inside the proc block AND satisfies
 * the zeroed-BSS invariant on load (no runtime zeroing needed).
 */
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)
PHDRS {
  text PT_LOAD FLAGS(5);          /* R+E: code + rodata (no RWX segment) */
  data PT_LOAD FLAGS(6);          /* RW: data + bss */
}
SECTIONS {
  . = 0x0;
  .text : { *(.text*) } :text
  .rodata : { *(.rodata*) } :text
  .data : { *(.data*) } :data
  /* BSS is NOBITS (see header comment): the Makefile pads the flat image
   * to _bss_end with zeros. Keep these two symbols. */
  .bss : {
    _bss_start = .;
    *(.bss*) *(COMMON)
    _bss_end = .;
  } :data
  /* No .got rule: any GOT reference keeps the orphan .got section visible
   * in the output, so the readelf acceptance below fails loudly (same bar
   * as N3.5 userland.ld — never /DISCARD/ it). */
  /DISCARD/ : {
    *(.eh_frame*) *(.comment*) *(.note*) *(.note.*)
    *(.debug*) *(.init*) *(.fini*) *(.ctors*) *(.dtors*)
  }
}
