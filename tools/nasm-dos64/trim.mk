# tools/nasm-dos64/trim.mk — canonical N4A trim flags (included by Makefile).
#
# Output-format trim uses NASM's own OF_* ladder (output/outform.h):
#   OF_ONLY + OF_BIN (+ OF_ELF iff MZ64 output is wanted) while compiling
#   nasm.c/outform.c. Defining them globally is harmless: no other TU
#   consults OF_*.
#
# Measured 2026-09-12 on the pinned submodule (nasm-3.02-50-gfbdc88565),
# host gcc -O2 -g (see docs/25-n4a1-trim.md §2):
#   full          : text 1188559  data 1166048  bss 24040  (file 4665888)
#   OF_ONLY+OF_BIN: text 1041200  data 1159784  bss  4456  (file 3649480)
#   OF_ONLY+OF_BIN+OF_ELF: text 1041352 (delta +152 B — keep ELF for MZ64)
#   stripped bin-only binary: 2214976 bytes on disk.
# Conclusion: the trim saves ~150 KB text (all backends are small); the
# ~1.16 MB .data.rel.ro pointer tables are the floor. The binary does NOT
# fit the 1.44 MB FAT12 volume as-is — N4A.3 must land before delivery.
NASM_TRIM_PPFLAGS := -DOF_ONLY -DOF_BIN -DOF_ELF
# Backends compiled OUT by the trim (kept for the record; OF_ONLY drops
# everything not listed above): outmacho/outcoff/outobj/outas86/outieee/
# outaout/outdbg/codeview/dwarf, debug formats. outelf stays IFF the MZ64
# output path wants it (cost: 152 B text — keep).
# NDISASM is a separate binary and is explicitly deferred (PLAN §5 N4A).
NASM_TRIM_CUTS := outmacho outcoff outobj outas86 outieee outaout dwarf codeview
# Source files dropped from the DOS64 build list (N4A.2):
# nasmlib/mmap.c KEPT (compiles to the NULL stub under dos64-config.h),
# nasmlib/realpath.c + nasmlib/rlimit.c DROPPED (replaced by
# dos64-nasm-shim.c: nasm_realpath/nasm_get_stack_size_limit),
# asm/uncompress.c DROPPED (stdmac decompressed host-side instead),
# nasmlib/asprintf.c DROPPED (reimplemented verbatim in
# dos64-nasm-shim.c over stdio64 vsnprintf, tracking
# _nasm_last_string_size like upstream), stdlib/vsnprintf.c DROPPED
# (HAVE_VSNPRINTF is defined; the symbol comes from stdio64 instead),
# nasm/zlib/ DROPPED whole.
NASM_DOS64_DROP := nasmlib/realpath.c nasmlib/rlimit.c asm/uncompress.c nasmlib/asprintf.c stdlib/vsnprintf.c
# DOS64 cross-compile flags (N4A.2d): freestanding x86-64, PIE codegen for
# the slide-safe flat link (same bar as CHELLO.COM: no relocs, no GOT, no
# syscall, entry 0), unknown-compiler branch (no HAVE_CONFIG_H) tuned by
# dos64-config.h, OF trim, GNU89 inline semantics (extern_inline emits no
# out-of-line copies except ilog2.c's ILOG2_C ones), no fortify (would
# reference __*_chk), -Wno-comment (generated macros.c nests comments).
# NOTE: keep -Wall but NOT -Werror here: upstream warnings (if any) must
# not block the port; correctness is proven by byte-identity runs.
NASM_XCFLAGS := -ffreestanding -nostdlib -m64 -fPIE -mno-red-zone -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -Os -Wall -Wno-comment -UHAVE_CONFIG_H -DOF_ONLY -DOF_BIN -DOF_ELF -U_FORTIFY_SOURCE -fgnu89-inline -include tools/nasm-dos64/dos64-config.h
