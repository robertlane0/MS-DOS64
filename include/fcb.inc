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

; Layout drift guard: selftests/shell reference FCB64 fields symbolically,
; but a silent re-layout would corrupt on-disk behavior. Fail the build
; if any critical offset moves. NOTE: the RENAME second 11-byte name
; (DOS FCB+16 semantics) overlaps recsiz; rename sites use FCB64.recsiz
; with an overlap comment so they stay symbolic yet drift-checked.
%if FCB64.name != 1
%error "FCB64.name drifted (want 1)"
%endif
%if FCB64.ext != 9
%error "FCB64.ext drifted (want 9)"
%endif
%if FCB64.extent != 12
%error "FCB64.extent drifted (want 12)"
%endif
%if FCB64.recsiz != 16
%error "FCB64.recsiz drifted (want 16)"
%endif
%if FCB64.filsiz != 20
%error "FCB64.filsiz drifted (want 20)"
%endif
%if FCB64.firclus != 48
%error "FCB64.firclus drifted (want 48)"
%endif
%if FCB64.nr != 64
%error "FCB64.nr drifted (want 64)"
%endif
%if FCB64.rr != 65
%error "FCB64.rr drifted (want 65)"
%endif

%endif
