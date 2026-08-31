; 64-bit DPB (Drive Parameter Block) — replaces MSDOS.ASM DPBLOCK 20B (MSDOS.ASM:128)
; Phase 2 will use this include instead of 16-bit struc
%ifndef DPB64_INC
%define DPB64_INC

struc DPB64
    .devnum     resb 1
    .drvnum     resb 1
    .pad1       resb 6
    .secsiz     resd 1    ; 128-1024 -> 32-bit
    .clusmsk    resb 1
    .clusshft   resb 1
    .pad2       resb 2
    .firfat     resd 1    ; LBA
    .fatcnt     resb 1
    .pad3       resb 3
    .maxent     resd 1
    .firrec     resd 1
    .maxclus    resd 1
    .fatsiz     resd 1
    .firdir     resd 1
    .fat        resq 1    ; 64-bit linear ptr to FAT copy
endstruc
%define DPBSIZ64 DPB64_size

%endif
