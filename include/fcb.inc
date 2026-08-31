; 64-bit FCB — expands MSDOS.ASM FCBLOCK (MSDOS.ASM:78)
%ifndef FCB64_INC
%define FCB64_INC

struc FCB64
    .drive      resb 1
    .name       resb 8
    .ext        resb 3
    .extent     resw 1
    .pad0       resw 1
    .recsiz     resd 1
    .filsiz     resq 1
    .drvbp      resq 1
    .fdate      resw 1
    .ftime      resw 1
    .devid      resb 1
    .pad1       resb 7
    .firclus    resd 1
    .lstclus    resd 1
    .cluspos    resd 1
    .pad2       resb 4
    .nr         resb 1
    .rr         resq 1    ; 64-bit random record
endstruc
%define FCBSIZ64 FCB64_size

%endif
