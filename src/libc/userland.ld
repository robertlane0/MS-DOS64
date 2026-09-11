/* MS-DOS64 userland link (N3.5): flat .COM payload, base 0.
 *
 * crt0.o MUST come first on the ld command line so _start lands at file
 * offset 0 (the COM entry = PSP+PSP_SIZE = image base; the loader does NO
 * relocation, so the image must be slide-safe).
 *
 * Slide-safety is VERIFIED, not arranged, by this script: a .got with
 * content or a .rela.dyn in the linked ELF means the C flags produced
 * absolute addressing and the image would break at any nonzero load
 * address. Keep .got visible here (never /DISCARD/ it) so the readelf
 * check in the N3.5 acceptance fails loudly instead of silently.
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
  /* BSS is NOBITS: objcopy -O binary TRUNCATES trailing NOBITS (the data
   * LOAD has FileSiz 0), so the loader copies stale bytes there. The
   * startup code zeroes [start,end) itself (bare-metal contract) —
   * libc statics (e.g. the stdio FILE table) are read-before-written
   * and break on garbage (N3.5 Exit-2 lesson). Keep these two symbols. */
  .bss : {
    _bss_start = .;
    *(.bss*) *(COMMON)
    _bss_end = .;
  } :data
  /DISCARD/ : {
    *(.eh_frame*) *(.comment*) *(.note*) *(.note.*)
    *(.debug*) *(.init*) *(.fini*) *(.ctors*) *(.dtors*)
  }
}
