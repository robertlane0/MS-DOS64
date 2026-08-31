; 64-bit MCB (Memory Control Block) — replaces paragraph-based MCB from DOS 2+
; DOS 1.25 had NO MCB; Phase 6 introduces MCB64 per AGENTS.md §Phase 6.
; Used by src/kernel/mem64.asm for flat 64-bit allocation.

%ifndef MCB64_INC
%define MCB64_INC

; On-disk/in-memory header preceding each allocated block.
; Total header 32 bytes, followed by user data.
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

%endif
