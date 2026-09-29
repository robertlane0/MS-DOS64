; 64-bit MCB (Memory Control Block) — replaces paragraph-based MCB from DOS 2+
; DOS 1.25 had NO MCB; Phase 6 introduces MCB64 per AGENTS.md §Phase 6.
; Used by src/kernel/mem64.asm for flat 64-bit allocation.

%ifndef MCB64_INC
%define MCB64_INC

; On-disk/in-memory header preceding each allocated block.
; Total header 40 bytes, followed by user data.
struc MCB64
    .type       resb 1    ; 'M' = more blocks, 'Z' = last block
    .pad0       resb 7    ; alignment
    .owner      resq 1    ; owning PSP linear address (0 = free), was 16-bit PSP segment
    .size       resq 1    ; size of user data area in bytes (was paragraphs*16)
    .name       resb 8    ; 8-char owner name (e.g., "COMMAND ", "KERNEL  ")
    .pad1       resb 8    ; reserved / future (checksum, flags)
endstruc
%define MCBSIZ64 MCB64_size  ; 32 bytes

; Convenience: offset of user data after MCB = MCBSIZ64

; Allocation strategy constants
%define MCB_TYPE_M  0x4D  ; 'M'
%define MCB_TYPE_Z  0x5A  ; 'Z'
%define MCB_FREE    0     ; owner = 0 means free

; For verification: MCB chain starts at a known physical address.
; Recommended in docs/03: first free after kernel. Example 0x200000 (2 MiB).
%define MCB_CHAIN_START  0x200000

; Heap extent. The chain runs from MCB_CHAIN_START to MEM_END and the identity
; map covers the same range, so the two are stated together here: the map has
; to reach as far as the chain, and a chain that ends past the last mapped page
; lets an allocation near its top write to an address with no page behind it.
; The chain was 0x200000-0x800000 (6 MiB) under a four-entry map until it was
; extended to 0x200000-0xE00000 (12 MiB) under a seven-entry map.
%define MEM_START  MCB_CHAIN_START  ; 0x200000 (2 MiB)
%define MEM_END    0xE00000         ; 14 MiB (identity map covers 0-14M)
%define MEM_SIZE   (MEM_END - MEM_START)

; Number of 2MiB page-directory entries that cover the identity map, derived
; so a wider heap widens the map with it. Every helper that indexes a PD entry
; must bound its index by this, not by a literal: a bound left at the old
; four-entry count reports an address in the upper heap as unmapped when it is
; mapped, which turns a page-protection request into a failure.
%define PD_PAGESIZE  0x200000
%define PD_ENTRIES   ((MEM_END + PD_PAGESIZE - 1) / PD_PAGESIZE)

%endif
