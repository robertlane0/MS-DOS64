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
 *
 * Base 0 relies on PSP_SIZE (include/psp.inc, PSP64_size) being a
 * multiple of 16: the loader places this image at PSP+PSP_SIZE, and PSP
 * itself is always 16-byte aligned (heap allocator invariant), so
 * PSP+PSP_SIZE is 16-aligned too only if PSP_SIZE is. gcc-compiled C
 * (unlike the hand-written N1/N4B asm samples) freely emits SSE
 * instructions (e.g. MOVAPS) needing a 16-byte-aligned memory operand
 * for constants/statics; a non-multiple-of-16 PSP_SIZE would fault #UD
 * on the first such access (PLAN.md N4A.3/N4A.4 finding). See
 * include/psp.inc for PSP_SIZE itself; this file just documents the
 * dependency since ld forces output sections to their input sections'
 * declared alignment regardless of the `.` origin requested here, so
 * compensating for a misaligned PSP_SIZE from this end is not viable —
 * the fix has to keep PSP_SIZE itself a multiple of 16.
 *
 * -pie link (tools/nasm-dos64/elf2exe64.py, EXE64 output — a *second*,
 * larger-scoped fix from the same PLAN.md item 11 record): a plain
 * .COM image's "no .got/.rela.dyn" check above only proves CODE
 * addressing is position-independent, not static DATA initialized to
 * the address of another static (e.g. a gcc-emitted dispatch table) —
 * that needs real relocation processing, which needs -pie to keep
 * .rela.dyn's R_X86_64_RELATIVE entries instead of letting ld resolve
 * them away assuming load address 0. -pie also pulls in real-
 * dynamic-linker scaffolding this freestanding loader has no use for
 * (.interp/.dynsym/.dynstr/.hash/.gnu.hash/.dynamic) and, more
 * importantly, places .rela.dyn's own (often large — one entry per
 * static-pointer-to-a-static) content ADDRESS-CONTIGUOUS with .rodata/
 * .data: since elf2exe64.py's flat payload extraction (like every
 * other image here, via `objcopy -O binary`) spans every byte from the
 * lowest to the highest loaded address, a .rela.dyn left in that range
 * would be copied into the flat payload as inert bytes *in addition
 * to* being properly parsed into elf2exe64.py's own relocation-table
 * format — doubling that cost for nothing. Keep it out of both
 * PT_LOAD segments (no :text/:data suffix below) so it exists in the
 * ELF for elf2exe64.py to read but contributes nothing to image_size.
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
  /* -pie only: not part of either PT_LOAD segment. :NONE is required,
   * not just omitting a :text/:data suffix — ld's default orphan-
   * section placement otherwise silently continues the PRECEDING
   * section's segment (here, :data, since .rela.dyn follows .bss),
   * putting it right back in the loadable range this rule exists to
   * keep it out of. Confirmed via `readelf -l`: only :NONE actually
   * drops it from the segment-to-section mapping. objcopy's flat
   * extraction (like every other image here, via `objcopy -O binary`)
   * still needs -R .rela.dyn (elf2exe64.py passes this) since objcopy
   * considers any SHF_ALLOC section's VMA for the flat span regardless
   * of PT_LOAD membership; :NONE alone only fixes mem_size (below),
   * not image_size.
   */
  .rela.dyn : { *(.rela.dyn) } :NONE
  /DISCARD/ : {
    *(.eh_frame*) *(.comment*) *(.note*) *(.note.*)
    *(.debug*) *(.init*) *(.fini*) *(.ctors*) *(.dtors*)
    *(.interp) *(.dynsym) *(.dynstr) *(.hash) *(.gnu.hash) *(.dynamic)
  }
}
