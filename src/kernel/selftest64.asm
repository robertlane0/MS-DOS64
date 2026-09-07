; MS-DOS64 self-test suite — extracted from main.asm so main stays boot glue.
; Provides selftest_run64: runs tests 1..83, prints PASS/FAIL + summary + phase lines.
; Returns RAX = failed count (0 = all pass). Called by _start in full builds.
; Lean builds (SKIP_SELFTEST): stub returns 0; test code excluded via RUN_SELFTEST.
;
; Self-test classes (see Implementation steps: pure vs scratch vs real-volume):
;   PURE (no disk I/O, no persistent state): 1-12 (regs/strings/BCD/FAT-pack/
;     mem-para/DMA/dispatch/addressing), 17-21 (para/coalesce/resize/protect/
;     stress), 28-34 (PSP/env/loader/spawn), 35-42 subset (IDT/console/vectors
;     without disk), 43-50 (cmd parser/builtins, RAM buffers only), 51-66
;     (IDT/PIC/stacks, bounded port I/O, no volume writes), 73-82 (negative
;     paths + pure tables, read-only volume sampling only).
;   SCRATCH-DEVICE (bounded ATA writes to reserved LBAs outside the volume,
;     cleaned up): 14 (LBA 200 pattern + zero restore), 25 (FS_SCRATCH 500/502
;     + zero), 26 (FS_FILE_LBA_BASE 510 file-data scratch). Safe every boot.
;   REAL-VOLUME READ-ONLY (mount + reads, no FAT/root/data writes): 67 (mount +
;     HELLO/README reads), 70 (FCB open/rndread/search/close), 72 (shell DIR/
;     TYPE/TEST dispatch), 76 (negative reads into scratch DPB). Mount may
;     heal FAT2 from FAT1 best-effort if mirrors already diverged (recovery,
;     not a test write on clean images).
;   REAL-VOLUME DESTRUCTIVE (FAT/root/data-cluster writes on the live volume,
;     reserved namespace SCRATCH.TXT/RENAMED.TXT/CRASH.TXT): 71 (FCB create/
;     write/rename/delete round-trip) and 83 (crash-ordering with fault
;     injection + reclaim). Gated behind SELFTEST_DESTRUCTIVE (see below).
;     Test 69 performs one net-zero root flush (SETATTRIB same value back);
;     it is skipped when the value already matches so the smoke suite stays
;     read-only in steady state.
;
; Boot modes (NASM defines, see Makefile):
;   -DRUN_SELFTEST alone (default `make`): smoke suite — PURE + SCRATCH-DEVICE
;     + REAL-VOLUME READ-ONLY. Tests 71/83 print SKIP and leave the volume
;     untouched (only mount reads + scratch-LBA I/O occur).
;   -DRUN_SELFTEST -DSELFTEST_DESTRUCTIVE (`make full`): full suite — all 83
;     tests including 71/83 in the reserved namespace with mount-time recovery
;     (pre-clean delete + discard/remount + reclaim + heal + scrub) and
;     post-run non-test preservation checks (HELLO/README intact, scrub clean,
;     mirrors match). An interrupted destructive run is recovered idempotently
;     by the next boot's pre-clean.
;   -DSKIP_SELFTEST (`make lean`): no suite, straight to shell.
; NOTE: RUN_SELFTEST (even smoke) performs bounded device writes: scratch-LBA
;   patterns (200/500-511, zeroed after) and optional FAT2 heal on a diverged
;   mount. Only SKIP_SELFTEST performs zero device writes. Full destructive
;   mode additionally creates/writes/deletes reserved files on the volume.
bits 64
default rel

%include "include/regs.inc"
%include "include/mcb.inc"
%include "include/dpb.inc"
%include "include/fcb.inc"
%include "include/psp.inc"
%include "include/fs.inc"

%ifdef SKIP_SELFTEST
%undef RUN_SELFTEST
%undef SELFTEST_DESTRUCTIVE
%else
%ifndef RUN_SELFTEST
%define RUN_SELFTEST
%endif
%endif

section .text
global selftest_run64

extern vga_init
extern vga_clear
extern vga_print
extern vga_putc
extern vga_set_cursor
extern memcpy64
extern memset64
extern strlen64
extern strcmp64
extern strupper64
extern loop_replacement_demo
extern xlat_replacement_demo
extern bcd_aam_replacement
extern bcd_aad_replacement_final
extern rtc_bcd_to_bin
extern rtc_bin_to_bcd
extern rtc_bcd_to_bin_v2
extern cbw_cwde_cdqe_demo
extern mul_div_64_demo
extern shl_rcl_demo
extern fat_unpack64
extern fat_pack64
extern fat_test_pack_unpack
extern dma_get_linear
extern dma_set_linear
extern mem_init64
extern mem_reset64
extern mem_validate64
extern mem_alloc64
extern mem_alloc_aligned64
extern mem_alloc_pages64
extern mem_free64
extern mem_resize64
extern mem_max_free64
extern mem_total_free64
extern mem_total_used64
extern mem_count_blocks64
extern mem_para_to_bytes
extern mem_bytes_to_para
extern mem_bytes_to_pages
extern mem_pages_to_bytes
extern mem_para_to_pages
extern mem_pages_to_para
extern mem_para_to_bytes_checked64
extern mem_bytes_to_para_checked64
extern mem_bytes_to_pages_checked64
extern mem_pages_to_bytes_checked64
extern mem_para_to_pages_checked64
extern mem_pages_to_para_checked64
extern mem_get_pd_entry64
extern mem_set_rw64
extern mem_set_nx64
extern mem_enable_nxe64
extern mem_flush_tlb64
extern mem_invlpg64
extern syscall_init
extern syscall_dispatch64
extern handler_conout
extern handler_conin
extern handler_in
extern handler_rawio
extern handler_rawinp
extern handler_prtbuf
extern handler_bufin
extern handler_constat
extern handler_flushkb
extern handler_dskreset
extern handler_seldsk
extern handler_getdrv
extern handler_setvect
extern handler_getvect
extern handler_read_file
extern handler_write_file
extern handler_alloc_mem
extern handler_free_mem
extern handler_resize_mem
extern idt_init64
extern idt_load64
extern idt_set_vector64
extern idt_get_vector64
extern idt_get_base64
extern idt_test_vectors
extern int21_entry
extern pic_remap64
extern pic_get_mask64
extern pic_set_mask64
extern pic_mask_irq64
extern pic_unmask_irq64
extern irq0_timer_handler
extern irq1_kbd_handler
extern irq14_disk_handler
extern idt_get_tick64
extern idt_get_irq14_count64
extern idt_get_fault_count64
extern idt_get_last_vector64
extern idt_get_last_error64
extern idt_get_last_rip64
extern idt_get_exc_count64
extern idt_reset_stats64
extern kbd_queue_push
extern kbd_queue_pop
extern kbd_flush
extern seg_off_to_linear
extern addr_test_all
extern addr_test_seg_off
extern addr_test_rip
extern addr_test_far_near
extern addr_test_buffer
extern addr_test_canonical
extern ata_init
extern ata_init_clean
extern ata_wait_not_busy
extern ata_wait_ready
extern ata_wait_drq
extern ata_read_lba28
extern ata_write_lba28
extern ata_validate_range64
extern ata_test_mbr_read
extern ata_test_write_readback
extern ata_test_chs_conversion
extern chs_to_lba
extern lba_to_chs_demo
extern ata_test_buf
extern ata_debug_status
extern ata_debug_error
extern kbd_init
extern kbd_has_data
extern kbd_poll
extern kbd_test_status
extern kbd_test_translation
extern kbd_test_queue
extern kbd_test_queue_stress
extern kbd_test_queue_if
extern fs_test_bpb
extern fs_test_chain
extern fs_test_dir
extern fs_test_lba_io
extern fs_test_file_read
extern fs_test_fcb
extern fs_test_geom
extern fs_mount_volume64
extern fs_vol_read_file64
extern fs_bpb_parse64
extern fs_vol_validate64
extern fs_cluster_to_lba64
extern fs_get_cluster64
extern fs_set_cluster64
extern fs_chain_free_mem64
extern fs_vol_boot
extern fs_vol_dpb
extern fs_vol_fat
extern fs_vol_root
extern fs_vol_iobuf
extern fs_fcb_create64
extern fs_fcb_delete64
extern fs_fcb_open64
extern fs_fcb_io64
extern fs_make_fcb64
extern fs_dir_find64
extern fs_vol_flush_fat64
extern fs_vol_flush_root64
extern fs_file_write_cluster64
extern fs_vol_check_mirrors64
extern fs_vol_heal_mirrors64
extern fs_vol_scrub64
extern fs_vol_reclaim_orphans64
extern fs_vol_discard64
extern fs_fault_inject
extern handler_getdate
extern handler_setdate
extern handler_gettime
extern handler_settime
extern handler_reader
extern handler_punch
extern handler_list
extern handler_verify
extern handler_newbase
extern handler_getfatpt
extern handler_getfatptdl
extern handler_getrdonly
extern handler_setattrib
extern handler_getdskpt
extern handler_open
extern handler_close
extern handler_srchfrst
extern handler_srchnxt
extern handler_delete
extern handler_seqrd
extern handler_seqwrt
extern handler_create
extern handler_rename
extern handler_rndrd
extern handler_rndwrt
extern handler_filesize
extern handler_setrndrec
extern handler_blkrd
extern handler_blkwrt
extern handler_makefcb
extern handler_setdma
extern shell_repl64
extern sh_exec_line
extern proc_init64
extern proc_alloc_slot64
extern proc_count_running64
extern proc_count_zombie64
extern proc_get_current64
extern proc_set_current64
extern proc_get_psp64
extern proc_get_entry64
extern proc_next_pid
extern proc_state
extern proc_pid
extern exec_dbg_pid
extern psp_init64
extern psp_validate64
extern psp_set_cmdtail64
extern psp_get_cmdlen64
extern psp_set_exit64
extern env_init64
extern env_count64
extern env_get64
extern env_set64
extern env_unset64
extern proc_verify_image64
extern proc_load_image64
extern proc_spawn64
extern proc_terminate64
extern proc_exit_current64
extern proc_reap64
extern proc_free_all64
extern handler_exec
extern handler_exit_process
extern handler_abort
extern cmd_test_parser
extern cmd_test_dir_type
extern cmd_test_fileops
extern cmd_test_shellcfg
extern cmd_test_datetime
extern cmd_test_exec
extern cmd_test_batch
extern cmd_test_dispatch
extern stack_test_align
extern stack_test_callee
extern stack_test_args
extern stack_test_depth
extern stack_test_irq
extern stack_test_push
extern stack_test_canary
extern stack_test_stress
extern serial_print64
extern serial_try_putc64

%ifdef RUN_SELFTEST

selftest_run64:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    xor r12, r12          ; passed count in R12 (callee-saved, demonstrates R8-R15)
    xor r13, r13          ; failed count in R13
    xor r14, r14          ; skipped count in R14 (destructive 71/83 in smoke mode)

    ; ---- Test 1: Register mapping — 64-bit RAX etc. and R8-R15 ----
    mov rsi, msg_test1
    call vga_print
    call serial_print64
    call test_registers
    test rax, rax
    jz .t1_pass
    inc r13
    mov rsi, msg_fail
    jmp .t1_done
.t1_pass:
    inc r12
    mov rsi, msg_pass
.t1_done:
    call vga_print
    call serial_print64

    ; ---- Test 2: String ops — REP MOVSB/MOVSQ, SCASB, CMPSB, LODSB/STOSB ----
    mov rsi, msg_test2
    call vga_print
    call serial_print64
    call test_string_ops
    test rax, rax
    jz .t2_pass
    inc r13
    mov rsi, msg_fail
    jmp .t2_done
.t2_pass:
    inc r12
    mov rsi, msg_pass
.t2_done:
    call vga_print
    call serial_print64

    ; ---- Test 3: BCD — AAM/AAD replacement ----
    mov rsi, msg_test3
    call vga_print
    call serial_print64
    call test_bcd
    test rax, rax
    jz .t3_pass
    inc r13
    mov rsi, msg_fail
    jmp .t3_done
.t3_pass:
    inc r12
    mov rsi, msg_pass
.t3_done:
    call vga_print
    call serial_print64

    ; ---- Test 4: FAT12 pack/unpack ----
    mov rsi, msg_test4
    call vga_print
    call serial_print64
    call fat_test_pack_unpack
    test rax, rax
    jz .t4_pass
    inc r13
    mov rsi, msg_fail
    jmp .t4_done
.t4_pass:
    inc r12
    mov rsi, msg_pass
.t4_done:
    call vga_print
    call serial_print64

    ; ---- Test 5: Memory — MCB64, paragraph->byte, alloc/free ----
    mov rsi, msg_test5
    call vga_print
    call serial_print64
    call test_memory
    test rax, rax
    jz .t5_pass
    inc r13
    mov rsi, msg_fail
    jmp .t5_done
.t5_pass:
    inc r12
    mov rsi, msg_pass
.t5_done:
    call vga_print
    call serial_print64

    ; ---- Test 6: DMA flat pointer (LES/LDS elimination) ----
    mov rsi, msg_test6
    call vga_print
    call serial_print64
    call test_dma
    test rax, rax
    jz .t6_pass
    inc r13
    mov rsi, msg_fail
    jmp .t6_done
.t6_pass:
    inc r12
    mov rsi, msg_pass
.t6_done:
    call vga_print
    call serial_print64

    ; ---- Test 7: Syscall dispatch and CBW etc. ----
    mov rsi, msg_test7
    call vga_print
    call serial_print64
    call test_syscall
    test rax, rax
    jz .t7_pass
    inc r13
    mov rsi, msg_fail
    jmp .t7_done
.t7_pass:
    inc r12
    mov rsi, msg_pass
.t7_done:
    call vga_print
    call serial_print64

    ; ---- Test 8: Addressing seg:off -> linear (seg<<4+off, DMA split, para) ----
    mov rsi, msg_test8
    call vga_print
    call serial_print64
    call addr_test_seg_off
    test rax, rax
    jz .t8_pass
    inc r13
    mov rsi, msg_fail
    jmp .t8_done
.t8_pass:
    inc r12
    mov rsi, msg_pass
.t8_done:
    call vga_print
    call serial_print64

    ; ---- Test 9: RIP-relative / OFFSET DOSGROUP -> rel ----
    mov rsi, msg_test9
    call vga_print
    call serial_print64
    call addr_test_rip
    test rax, rax
    jz .t9_pass
    inc r13
    mov rsi, msg_fail
    jmp .t9_done
.t9_pass:
    inc r12
    mov rsi, msg_pass
.t9_done:
    call vga_print
    call serial_print64

    ; ---- Test 10: FAR PTR BIOS jump table -> near dispatch ----
    mov rsi, msg_test10
    call vga_print
    call serial_print64
    call addr_test_far_near
    test rax, rax
    jz .t10_pass
    inc r13
    mov rsi, msg_fail
    jmp .t10_done
.t10_pass:
    inc r12
    mov rsi, msg_pass
.t10_done:
    call vga_print
    call serial_print64

    ; ---- Test 11: Flat buffers DIRBUF/BUFFER dq, segment override elimination ----
    mov rsi, msg_test11
    call vga_print
    call serial_print64
    call addr_test_buffer
    test rax, rax
    jz .t11_pass
    inc r13
    mov rsi, msg_fail
    jmp .t11_done
.t11_pass:
    inc r12
    mov rsi, msg_pass
.t11_done:
    call vga_print
    call serial_print64

    ; ---- Test 12: Canonical addresses & flat stack ----
    mov rsi, msg_test12
    call vga_print
    call serial_print64
    call addr_test_canonical
    test rax, rax
    jz .t12_pass
    inc r13
    mov rsi, msg_fail
    jmp .t12_done
.t12_pass:
    inc r12
    mov rsi, msg_pass
.t12_done:
    call vga_print
    call serial_print64

    ; ---- Test 13: ATA PIO driver — MBR read + CHS->LBA (INT13h replacement) ----
    mov rsi, msg_test13
    call vga_print
    call serial_print64
    call test_ata_mbr
    test rax, rax
    jz .t13_pass
    inc r13
    mov rsi, msg_fail
    jmp .t13_done
.t13_pass:
    inc r12
    mov rsi, msg_pass
.t13_done:
    call vga_print
    call serial_print64

    ; ---- Test 14: ATA write/readback verification ----
    mov rsi, msg_test14
    call vga_print
    call serial_print64
    call test_ata_write
    test rax, rax
    jz .t14_pass
    inc r13
    mov rsi, msg_fail
    jmp .t14_done
.t14_pass:
    inc r12
    mov rsi, msg_pass
.t14_done:
    call vga_print
    call serial_print64

    ; ---- Test 15: Keyboard driver — status port + queue (INT16h replacement) ----
    mov rsi, msg_test15
    call vga_print
    call serial_print64
    call test_kbd_status
    test rax, rax
    jz .t15_pass
    inc r13
    mov rsi, msg_fail
    jmp .t15_done
.t15_pass:
    inc r12
    mov rsi, msg_pass
.t15_done:
    call vga_print
    call serial_print64

    ; ---- Test 16: Keyboard translation + VGA native (INT10h/16h combined) ----
    mov rsi, msg_test16
    call vga_print
    call serial_print64
    call test_kbd_translation
    test rax, rax
    jz .t16_pass
    inc r13
    mov rsi, msg_fail
    jmp .t16_done
.t16_pass:
    inc r12
    mov rsi, msg_pass
.t16_done:
    call vga_print
    call serial_print64

    ; ---- Test 17: Para/page conversion — byte-based sizing (Phase6) ----
    mov rsi, msg_test17
    call vga_print
    call serial_print64
    call test_para_page
    test rax, rax
    jz .t17_pass
    inc r13
    mov rsi, msg_fail
    jmp .t17_done
.t17_pass:
    inc r12
    mov rsi, msg_pass
.t17_done:
    call vga_print
    call serial_print64

    ; ---- Test 18: MCB coalesce — first-fit split + prev+next merge ----
    mov rsi, msg_test18
    call vga_print
    call serial_print64
    call test_coalesce
    test rax, rax
    jz .t18_pass
    inc r13
    mov rsi, msg_fail
    jmp .t18_done
.t18_pass:
    inc r12
    mov rsi, msg_pass
.t18_done:
    call vga_print
    call serial_print64

    ; ---- Test 19: Resize (INT21 AH=4Ah SETBLK analog) — shrink/grow ----
    mov rsi, msg_test19
    call vga_print
    call serial_print64
    call test_resize
    test rax, rax
    jz .t19_pass
    inc r13
    mov rsi, msg_fail
    jmp .t19_done
.t19_pass:
    inc r12
    mov rsi, msg_pass
.t19_done:
    call vga_print
    call serial_print64

    ; ---- Test 20: Page-table protection — RW/NX on 2MiB PS pages ----
    mov rsi, msg_test20
    call vga_print
    call serial_print64
    call test_protection
    test rax, rax
    jz .t20_pass
    inc r13
    mov rsi, msg_fail
    jmp .t20_done
.t20_pass:
    inc r12
    mov rsi, msg_pass
.t20_done:
    call vga_print
    call serial_print64

    ; ---- Test 21: Stress + validation — total free, double-free, caps ----
    mov rsi, msg_test21
    call vga_print
    call serial_print64
    call test_stress
    test rax, rax
    jz .t21_pass
    inc r13
    mov rsi, msg_fail
    jmp .t21_done
.t21_pass:
    inc r12
    mov rsi, msg_pass
.t21_done:
    call vga_print
    call serial_print64

    ; ---- Test 22: BPB->DPB + cluster->LBA + FAT sector (Phase7) ----
    mov rsi, msg_test22
    call vga_print
    call serial_print64
    call fs_test_bpb
    test rax, rax
    jz .t22_pass
    inc r13
    mov rsi, msg_fail
    jmp .t22_done
.t22_pass:
    inc r12
    mov rsi, msg_pass
.t22_done:
    call vga_print
    call serial_print64

    ; ---- Test 23: FAT12 chain pack/unpack + EOF/free (Phase7) ----
    mov rsi, msg_test23
    call vga_print
    call serial_print64
    call fs_test_chain
    test rax, rax
    jz .t23_pass
    inc r13
    mov rsi, msg_fail
    jmp .t23_done
.t23_pass:
    inc r12
    mov rsi, msg_pass
.t23_done:
    call vga_print
    call serial_print64

    ; ---- Test 24: Root-dir find/delete/end/wildcard (Phase7) ----
    mov rsi, msg_test24
    call vga_print
    call serial_print64
    call fs_test_dir
    test rax, rax
    jz .t24_pass
    inc r13
    mov rsi, msg_fail
    jmp .t24_done
.t24_pass:
    inc r12
    mov rsi, msg_pass
.t24_done:
    call vga_print
    call serial_print64

    ; ---- Test 25: ATA-backed DREAD/DWRITE + DIRREAD (Phase7) ----
    mov rsi, msg_test25
    call vga_print
    call serial_print64
    call fs_test_lba_io
    test rax, rax
    jz .t25_pass
    inc r13
    mov rsi, msg_fail
    jmp .t25_done
.t25_pass:
    inc r12
    mov rsi, msg_pass
.t25_done:
    call vga_print
    call serial_print64

    ; ---- Test 26: Multi-cluster file read via chain (Phase7) ----
    mov rsi, msg_test26
    call vga_print
    call serial_print64
    call fs_test_file_read
    test rax, rax
    jz .t26_pass
    inc r13
    mov rsi, msg_fail
    jmp .t26_done
.t26_pass:
    inc r12
    mov rsi, msg_pass
.t26_done:
    call vga_print
    call serial_print64

    ; ---- Test 27: FCB64 open + 64-bit filsiz/rr/DMA (Phase7) ----
    mov rsi, msg_test27
    call vga_print
    call serial_print64
    call fs_test_fcb
    test rax, rax
    jz .t27_pass
    inc r13
    mov rsi, msg_fail
    jmp .t27_done
.t27_pass:
    inc r12
    mov rsi, msg_pass
.t27_done:
    call vga_print
    call serial_print64

    ; ---- Test 28: PSP init/validate (SETMEM analog, Phase8) ----
    mov rsi, msg_test28
    call vga_print
    call serial_print64
    call test_psp_init
    test rax, rax
    jz .t28_pass
    inc r13
    mov rsi, msg_fail
    jmp .t28_done
.t28_pass:
    inc r12
    mov rsi, msg_pass
.t28_done:
    call vga_print
    call serial_print64

    ; ---- Test 29: PSP cmd tail + exit vectors + fd/CR3 (Phase8) ----
    mov rsi, msg_test29
    call vga_print
    call serial_print64
    call test_psp_cmd
    test rax, rax
    jz .t29_pass
    inc r13
    mov rsi, msg_fail
    jmp .t29_done
.t29_pass:
    inc r12
    mov rsi, msg_pass
.t29_done:
    call vga_print
    call serial_print64

    ; ---- Test 30: ENV blocks (Phase8) ----
    mov rsi, msg_test30
    call vga_print
    call serial_print64
    call test_env
    test rax, rax
    jz .t30_pass
    inc r13
    mov rsi, msg_fail
    jmp .t30_done
.t30_pass:
    inc r12
    mov rsi, msg_pass
.t30_done:
    call vga_print
    call serial_print64

    ; ---- Test 31: Loader COM vs EXE64 (Phase8) ----
    mov rsi, msg_test31
    call vga_print
    call serial_print64
    call test_loader
    test rax, rax
    jz .t31_pass
    inc r13
    mov rsi, msg_fail
    jmp .t31_done
.t31_pass:
    inc r12
    mov rsi, msg_pass
.t31_done:
    call vga_print
    call serial_print64

    ; ---- Test 32: Spawn/exit lifecycle + owner (Phase8) ----
    mov rsi, msg_test32
    call vga_print
    call serial_print64
    call test_spawn
    test rax, rax
    jz .t32_pass
    inc r13
    mov rsi, msg_fail
    jmp .t32_done
.t32_pass:
    inc r12
    mov rsi, msg_pass
.t32_done:
    call vga_print
    call serial_print64

    ; ---- Test 33: EXEC/EXIT via INT21 dispatch (Phase8) ----
    mov rsi, msg_test33
    call vga_print
    call serial_print64
    call test_exec_dispatch
    test rax, rax
    jz .t33_pass
    inc r13
    mov rsi, msg_fail
    jmp .t33_done
.t33_pass:
    inc r12
    mov rsi, msg_pass
.t33_done:
    call vga_print
    call serial_print64

    ; ---- Test 34: Stress max procs + reap + validate (Phase8) ----
    mov rsi, msg_test34
    call vga_print
    call serial_print64
    call test_proc_stress
    test rax, rax
    jz .t34_pass
    inc r13
    mov rsi, msg_fail
    jmp .t34_done
.t34_pass:
    inc r12
    mov rsi, msg_pass
.t34_done:
    call vga_print
    call serial_print64

    ; ---- Test 35: IDT init/load + INT 0x21 gate (Phase9 Option B) ----
    mov rsi, msg_test35
    call vga_print
    call serial_print64
    call test_idt_gate
    test rax, rax
    jz .t35_pass
    inc r13
    mov rsi, msg_fail
    jmp .t35_done
.t35_pass:
    inc r12
    mov rsi, msg_pass
.t35_done:
    call vga_print
    call serial_print64

    ; ---- Test 36: Console input 01/08/0B/0C (Phase9) ----
    mov rsi, msg_test36
    call vga_print
    call serial_print64
    call test_console_in
    test rax, rax
    jz .t36_pass
    inc r13
    mov rsi, msg_fail
    jmp .t36_done
.t36_pass:
    inc r12
    mov rsi, msg_pass
.t36_done:
    call vga_print
    call serial_print64

    ; ---- Test 37: Buffered input 0A line editing (Phase9) ----
    mov rsi, msg_test37
    call vga_print
    call serial_print64
    call test_bufin
    test rax, rax
    jz .t37_pass
    inc r13
    mov rsi, msg_fail
    jmp .t37_done
.t37_pass:
    inc r12
    mov rsi, msg_pass
.t37_done:
    call vga_print
    call serial_print64

    ; ---- Test 38: Drive select/get + reset 0E/19/0D (Phase9) ----
    mov rsi, msg_test38
    call vga_print
    call serial_print64
    call test_drive
    test rax, rax
    jz .t38_pass
    inc r13
    mov rsi, msg_fail
    jmp .t38_done
.t38_pass:
    inc r12
    mov rsi, msg_pass
.t38_done:
    call vga_print
    call serial_print64

    ; ---- Test 39: Vectors 25/35 via IDT (Phase9) ----
    mov rsi, msg_test39
    call vga_print
    call serial_print64
    call test_vectors
    test rax, rax
    jz .t39_pass
    inc r13
    mov rsi, msg_fail
    jmp .t39_done
.t39_pass:
    inc r12
    mov rsi, msg_pass
.t39_done:
    call vga_print
    call serial_print64

    ; ---- Test 40: Read 3F stdin handle 0 (Phase9) ----
    mov rsi, msg_test40
    call vga_print
    call serial_print64
    call test_read_file
    test rax, rax
    jz .t40_pass
    inc r13
    mov rsi, msg_fail
    jmp .t40_done
.t40_pass:
    inc r12
    mov rsi, msg_pass
.t40_done:
    call vga_print
    call serial_print64

    ; ---- Test 41: Write 40 stdout handles 1/2 (Phase9) ----
    mov rsi, msg_test41
    call vga_print
    call serial_print64
    call test_write_file
    test rax, rax
    jz .t41_pass
    inc r13
    mov rsi, msg_fail
    jmp .t41_done
.t41_pass:
    inc r12
    mov rsi, msg_pass
.t41_done:
    call vga_print
    call serial_print64

    ; ---- Test 42: Full INT 0x21 round-trip via CPU INT (Phase9) ----
    mov rsi, msg_test42
    call vga_print
    call serial_print64
    call test_int21_roundtrip
    test rax, rax
    jz .t42_pass
    inc r13
    mov rsi, msg_fail
    jmp .t42_done
.t42_pass:
    inc r12
    mov rsi, msg_pass
.t42_done:
    call vga_print
    call serial_print64

    ; ---- Test 43: Parser SCANOFF/DELIM/SWITCH/drive/upper (Phase10) ----
    mov rsi, msg_test43
    call vga_print
    call serial_print64
    call cmd_test_parser
    test rax, rax
    jz .t43_pass
    inc r13
    mov rsi, msg_fail
    jmp .t43_done
.t43_pass:
    inc r12
    mov rsi, msg_pass
.t43_done:
    call vga_print
    call serial_print64

    ; ---- Test 44: DIR format + TYPE ^Z (Phase10) ----
    mov rsi, msg_test44
    call vga_print
    call serial_print64
    call cmd_test_dir_type
    test rax, rax
    jz .t44_pass
    inc r13
    mov rsi, msg_fail
    jmp .t44_done
.t44_pass:
    inc r12
    mov rsi, msg_pass
.t44_done:
    call vga_print
    call serial_print64

    ; ---- Test 45: COPY/DEL/REN fileops (Phase10) ----
    mov rsi, msg_test45
    call vga_print
    call serial_print64
    call cmd_test_fileops
    test rax, rax
    jz .t45_pass
    inc r13
    mov rsi, msg_fail
    jmp .t45_done
.t45_pass:
    inc r12
    mov rsi, msg_pass
.t45_done:
    call vga_print
    call serial_print64

    ; ---- Test 46: CLS/VER/PROMPT/PATH/REM/PAUSE (Phase10) ----
    mov rsi, msg_test46
    call vga_print
    call serial_print64
    call cmd_test_shellcfg
    test rax, rax
    jz .t46_pass
    inc r13
    mov rsi, msg_fail
    jmp .t46_done
.t46_pass:
    inc r12
    mov rsi, msg_pass
.t46_done:
    call vga_print
    call serial_print64

    ; ---- Test 47: DATE/TIME get/set/parse (Phase10) ----
    mov rsi, msg_test47
    call vga_print
    call serial_print64
    call cmd_test_datetime
    test rax, rax
    jz .t47_pass
    inc r13
    mov rsi, msg_fail
    jmp .t47_done
.t47_pass:
    inc r12
    mov rsi, msg_pass
.t47_done:
    call vga_print
    call serial_print64

    ; ---- Test 48: External EXEC via spawn (Phase10) ----
    mov rsi, msg_test48
    call vga_print
    call serial_print64
    call cmd_test_exec
    test rax, rax
    jz .t48_pass
    inc r13
    mov rsi, msg_fail
    jmp .t48_done
.t48_pass:
    inc r12
    mov rsi, msg_pass
.t48_done:
    call vga_print
    call serial_print64

    ; ---- Test 49: Batch open/next/expand (Phase10) ----
    mov rsi, msg_test49
    call vga_print
    call serial_print64
    call cmd_test_batch
    test rax, rax
    jz .t49_pass
    inc r13
    mov rsi, msg_fail
    jmp .t49_done
.t49_pass:
    inc r12
    mov rsi, msg_pass
.t49_done:
    call vga_print
    call serial_print64

    ; ---- Test 50: Dispatch + stress (Phase10) ----
    mov rsi, msg_test50
    call vga_print
    call serial_print64
    call cmd_test_dispatch
    test rax, rax
    jz .t50_pass
    inc r13
    mov rsi, msg_fail
    jmp .t50_done
.t50_pass:
    inc r12
    mov rsi, msg_pass
.t50_done:
    call vga_print
    call serial_print64

    ; ---- Test 51: Full IDT structure 0-31/0x20/0x21/0x2E + IMR (Phase11) ----
    mov rsi, msg_test51
    call vga_print
    call serial_print64
    call test_idt_full
    test rax, rax
    jz .t51_pass
    inc r13
    mov rsi, msg_fail
    jmp .t51_done
.t51_pass:
    inc r12
    mov rsi, msg_pass
.t51_done:
    call vga_print
    call serial_print64

    ; ---- Test 52: Exception diagnostics via INT 0/3/4 (Phase11) ----
    mov rsi, msg_test52
    call vga_print
    call serial_print64
    call test_exc_diag
    test rax, rax
    jz .t52_pass
    inc r13
    mov rsi, msg_fail
    jmp .t52_done
.t52_pass:
    inc r12
    mov rsi, msg_pass
.t52_done:
    call vga_print
    call serial_print64

    ; ---- Test 53: PIC remap 0x20/0x28 + mask/unmask (Phase11) ----
    mov rsi, msg_test53
    call vga_print
    call serial_print64
    call test_pic_remap
    test rax, rax
    jz .t53_pass
    inc r13
    mov rsi, msg_fail
    jmp .t53_done
.t53_pass:
    inc r12
    mov rsi, msg_pass
.t53_done:
    call vga_print
    call serial_print64

    ; ---- Test 54: Timer IRQ0 @0x20 tick + EOI (Phase11) ----
    mov rsi, msg_test54
    call vga_print
    call serial_print64
    call test_timer_irq
    test rax, rax
    jz .t54_pass
    inc r13
    mov rsi, msg_fail
    jmp .t54_done
.t54_pass:
    inc r12
    mov rsi, msg_pass
.t54_done:
    call vga_print
    call serial_print64

    ; ---- Test 55: Keyboard IRQ1 handler via spare vector (Phase11) ----
    mov rsi, msg_test55
    call vga_print
    call serial_print64
    call test_kbd_irq
    test rax, rax
    jz .t55_pass
    inc r13
    mov rsi, msg_fail
    jmp .t55_done
.t55_pass:
    inc r12
    mov rsi, msg_pass
.t55_done:
    call vga_print
    call serial_print64

    ; ---- Test 56: Disk IRQ14 @0x2E count + EOI (Phase11) ----
    mov rsi, msg_test56
    call vga_print
    call serial_print64
    call test_disk_irq
    test rax, rax
    jz .t56_pass
    inc r13
    mov rsi, msg_fail
    jmp .t56_done
.t56_pass:
    inc r12
    mov rsi, msg_pass
.t56_done:
    call vga_print
    call serial_print64

    ; ---- Test 57: IRQ vectors SETVECT/GETVECT + DOS preserved (Phase11) ----
    mov rsi, msg_test57
    call vga_print
    call serial_print64
    call test_irq_vectors
    test rax, rax
    jz .t57_pass
    inc r13
    mov rsi, msg_fail
    jmp .t57_done
.t57_pass:
    inc r12
    mov rsi, msg_pass
.t57_done:
    call vga_print
    call serial_print64

    ; ---- Test 58: IDT stress + DOS round-trip after remap (Phase11) ----
    mov rsi, msg_test58
    call vga_print
    call serial_print64
    call test_idt_stress
    test rax, rax
    jz .t58_pass
    inc r13
    mov rsi, msg_fail
    jmp .t58_done
.t58_pass:
    inc r12
    mov rsi, msg_pass
.t58_done:
    call vga_print
    call serial_print64

    ; ---- Test 59: RSP 16B alignment + I/O/IST stacks (Phase12) ----
    mov rsi, msg_test59
    call vga_print
    call serial_print64
    call stack_test_align
    test rax, rax
    jz .t59_pass
    inc r13
    mov rsi, msg_fail
    jmp .t59_done
.t59_pass:
    inc r12
    mov rsi, msg_pass
.t59_done:
    call vga_print
    call serial_print64

    ; ---- Test 60: Callee-saved RBX/RBP/R12-R15 + caller clobber (Phase12) ----
    mov rsi, msg_test60
    call vga_print
    call serial_print64
    call stack_test_callee
    test rax, rax
    jz .t60_pass
    inc r13
    mov rsi, msg_fail
    jmp .t60_done
.t60_pass:
    inc r12
    mov rsi, msg_pass
.t60_done:
    call vga_print
    call serial_print64

    ; ---- Test 61: System V args 6-reg + 2-stack + return (Phase12) ----
    mov rsi, msg_test61
    call vga_print
    call serial_print64
    call stack_test_args
    test rax, rax
    jz .t61_pass
    inc r13
    mov rsi, msg_fail
    jmp .t61_done
.t61_pass:
    inc r12
    mov rsi, msg_pass
.t61_done:
    call vga_print
    call serial_print64

    ; ---- Test 62: Nested-call depth 32 + RSP restore (Phase12) ----
    mov rsi, msg_test62
    call vga_print
    call serial_print64
    call stack_test_depth
    test rax, rax
    jz .t62_pass
    inc r13
    mov rsi, msg_fail
    jmp .t62_done
.t62_pass:
    inc r12
    mov rsi, msg_pass
.t62_done:
    call vga_print
    call serial_print64

    ; ---- Test 63: IRQ/exc stacks IST==0 + timer preserve (Phase12) ----
    mov rsi, msg_test63
    call vga_print
    call serial_print64
    call stack_test_irq
    test rax, rax
    jz .t63_pass
    inc r13
    mov rsi, msg_fail
    jmp .t63_done
.t63_pass:
    inc r12
    mov rsi, msg_pass
.t63_done:
    call vga_print
    call serial_print64

    ; ---- Test 64: PUSH/POP 64-bit + near CALL/RET + DF=0 (Phase12) ----
    mov rsi, msg_test64
    call vga_print
    call serial_print64
    call stack_test_push
    test rax, rax
    jz .t64_pass
    inc r13
    mov rsi, msg_fail
    jmp .t64_done
.t64_pass:
    inc r12
    mov rsi, msg_pass
.t64_done:
    call vga_print
    call serial_print64

    ; ---- Test 65: Canary init/intact/detect + depth stress (Phase12) ----
    mov rsi, msg_test65
    call vga_print
    call serial_print64
    call stack_test_canary
    test rax, rax
    jz .t65_pass
    inc r13
    mov rsi, msg_fail
    jmp .t65_done
.t65_pass:
    inc r12
    mov rsi, msg_pass
.t65_done:
    call vga_print
    call serial_print64

    ; ---- Test 66: ABI stress + DOS round-trip after hardening (Phase12) ----
    mov rsi, msg_test66
    call vga_print
    call serial_print64
    call stack_test_stress
    test rax, rax
    jz .t66_pass
    inc r13
    mov rsi, msg_fail
    jmp .t66_done
.t66_pass:
    inc r12
    mov rsi, msg_pass
.t66_done:
    call vga_print
    call serial_print64

    ; ---- Test 67: Real FAT12 volume mount + on-disk file read (G2) ----
    mov rsi, msg_test67
    call vga_print
    call serial_print64
    call test_vol_mount
    test rax, rax
    jz .t67_pass
    inc r13
    mov rsi, msg_fail
    jmp .t67_done
.t67_pass:
    inc r12
    mov rsi, msg_pass
.t67_done:
    call vga_print
    call serial_print64

    ; ---- Test 68: RTC date/time get/set via INT21 2A-2D (G1) ----
    mov rsi, msg_test68
    call vga_print
    call serial_print64
    call test_rtc_datetime
    test rax, rax
    jz .t68_pass
    inc r13
    mov rsi, msg_fail
    jmp .t68_done
.t68_pass:
    inc r12
    mov rsi, msg_pass
.t68_done:
    call vga_print
    call serial_print64

    ; ---- Test 69: AUX/COM/LIST + VERIFY/NEWBASE/disk ptrs (G1) ----
    mov rsi, msg_test69
    call vga_print
    call serial_print64
    call test_aux_misc
    test rax, rax
    jz .t69_pass
    inc r13
    mov rsi, msg_fail
    jmp .t69_done
.t69_pass:
    inc r12
    mov rsi, msg_pass
.t69_done:
    call vga_print
    call serial_print64

    ; ---- Test 70: FCB open/rndread/search/makefcb (G1, read-only) ----
    mov rsi, msg_test70
    call vga_print
    call serial_print64
    call test_fcb_file
    test rax, rax
    jz .t70_pass
    inc r13
    mov rsi, msg_fail
    jmp .t70_done
.t70_pass:
    inc r12
    mov rsi, msg_pass
.t70_done:
    call vga_print
    call serial_print64

    ; ---- Test 71: FCB create/write/read/rename/delete round-trip ----
    ; DESTRUCTIVE (real-volume writes in reserved namespace SCRATCH/RENAMED).
    ; Smoke (no SELFTEST_DESTRUCTIVE): SKIP without touching the volume.
    mov rsi, msg_test71
    call vga_print
    call serial_print64
%ifdef SELFTEST_DESTRUCTIVE
    call test_fcb_write
    test rax, rax
    jz .t71_pass
    inc r13
    mov rsi, msg_fail
    jmp .t71_done
.t71_pass:
    inc r12
    mov rsi, msg_pass
.t71_done:
%else
    inc r14
    mov rsi, msg_skip
%endif
    call vga_print
    call serial_print64

    ; ---- Test 72: Shell line dispatch (G3, non-interactive) ----
    mov rsi, msg_test72
    call vga_print
    call serial_print64
    call test_shell_exec
    test rax, rax
    jz .t72_pass
    inc r13
    mov rsi, msg_fail
    jmp .t72_done
.t72_pass:
    inc r12
    mov rsi, msg_pass
.t72_done:
    call vga_print
    call serial_print64

    ; ---- Test 73: Loader negative paths (image_size/entry/stack/bad hdr) ----
    mov rsi, msg_test73
    call vga_print
    call serial_print64
    call test_neg_verify
    test rax, rax
    jz .t73_pass
    inc r13
    mov rsi, msg_fail
    jmp .t73_done
.t73_pass:
    inc r12
    mov rsi, msg_pass
.t73_done:
    call vga_print
    call serial_print64

    ; ---- Test 74: ATA negative paths (range reject, no-hang waits) ----
    mov rsi, msg_test74
    call vga_print
    call serial_print64
    call test_ata_neg
    test rax, rax
    jz .t74_pass
    inc r13
    mov rsi, msg_fail
    jmp .t74_done
.t74_pass:
    inc r12
    mov rsi, msg_pass
.t74_done:
    call vga_print
    call serial_print64

    ; ---- Test 75: Syscall bounds (MAXCOM/MAXCOM+1/FF via dispatch+INT) ----
    mov rsi, msg_test75
    call vga_print
    call serial_print64
    call test_syscall_bounds
    test rax, rax
    jz .t75_pass
    inc r13
    mov rsi, msg_fail
    jmp .t75_done
.t75_pass:
    inc r12
    mov rsi, msg_pass
.t75_done:
    call vga_print
    call serial_print64

    ; ---- Test 76: FAT12/file negative paths (BPB/cluster/NULL/missing) ----
    mov rsi, msg_test76
    call vga_print
    call serial_print64
    call test_fs_neg
    test rax, rax
    jz .t76_pass
    inc r13
    mov rsi, msg_fail
    jmp .t76_done
.t76_pass:
    inc r12
    mov rsi, msg_pass
.t76_done:
    call vga_print
    call serial_print64

    ; ---- Test 77: BPB table + sentinels (FAT/root/cluster/tot/maxclus) ----
    mov rsi, msg_test77
    call vga_print
    call serial_print64
    call test_bpb_table
    test rax, rax
    jz .t77_pass
    inc r13
    mov rsi, msg_fail
    jmp .t77_done
.t77_pass:
    inc r12
    mov rsi, msg_pass
.t77_done:
    call vga_print
    call serial_print64

    ; ---- Test 78: ATA pure table (endpoint/count, no hardware) ----
    mov rsi, msg_test78
    call vga_print
    call serial_print64
    call test_ata_table
    test rax, rax
    jz .t78_pass
    inc r13
    mov rsi, msg_fail
    jmp .t78_done
.t78_pass:
    inc r12
    mov rsi, msg_pass
.t78_done:
    call vga_print
    call serial_print64

    ; ---- Test 79: FAT chain bounds (cycle/iteration, best-effort clear) ----
    mov rsi, msg_test79
    call vga_print
    call serial_print64
    call test_chain_bounds
    test rax, rax
    jz .t79_pass
    inc r13
    mov rsi, msg_fail
    jmp .t79_done
.t79_pass:
    inc r12
    mov rsi, msg_pass
.t79_done:
    call vga_print
    call serial_print64

    ; ---- Test 80: Allocator arithmetic table (near-UINT64_MAX) ----
    mov rsi, msg_test80
    call vga_print
    call serial_print64
    call test_alloc_table
    test rax, rax
    jz .t80_pass
    inc r13
    mov rsi, msg_fail
    jmp .t80_done
.t80_pass:
    inc r12
    mov rsi, msg_pass
.t80_done:
    call vga_print
    call serial_print64

    ; ---- Test 81: Queue interleave (empty/full/wrap + IF preserve) ----
    mov rsi, msg_test81
    call vga_print
    call serial_print64
    call test_queue_interleave
    test rax, rax
    jz .t81_pass
    inc r13
    mov rsi, msg_fail
    jmp .t81_done
.t81_pass:
    inc r12
    mov rsi, msg_pass
.t81_done:
    call vga_print
    call serial_print64

    ; ---- Test 82: Layout invariants (same arithmetic as make check-layout) ----
    mov rsi, msg_test82
    call vga_print
    call serial_print64
    call test_layout
    test rax, rax
    jz .t82_pass
    inc r13
    mov rsi, msg_fail
    jmp .t82_done
.t82_pass:
    inc r12
    mov rsi, msg_pass
.t82_done:
    call vga_print
    call serial_print64

    ; ---- Test 83: FAT12 crash-consistency (order + mirrors + scrub/reclaim) ----
    ; DESTRUCTIVE (real-volume writes in reserved namespace CRASH.TXT).
    ; Smoke (no SELFTEST_DESTRUCTIVE): SKIP without touching the volume.
    mov rsi, msg_test83
    call vga_print
    call serial_print64
%ifdef SELFTEST_DESTRUCTIVE
    call test_fs_crash
    test rax, rax
    jz .t83_pass
    inc r13
    mov rsi, msg_fail
    jmp .t83_done
.t83_pass:
    inc r12
    mov rsi, msg_pass
.t83_done:
%else
    inc r14
    mov rsi, msg_skip
%endif
    call vga_print
    call serial_print64

    ; ---- Summary ----
    mov rsi, msg_summary
    call vga_print
    call serial_print64
    movzx rax, r12w
    call print_num_vga_serial
    mov rsi, msg_summary2
    call vga_print
    call serial_print64
    movzx rax, r13w
    call print_num_vga_serial
    mov rsi, msg_summary3
    call vga_print
    call serial_print64
    ; Skipped count (destructive tests in smoke mode). Zero in full mode.
    movzx rax, r14w
    test rax, rax
    jz .st_no_skip
    mov rsi, msg_summary4
    call vga_print
    call serial_print64
    movzx rax, r14w
    call print_num_vga_serial
    mov rsi, msg_summary5
    call vga_print
    call serial_print64
.st_no_skip:

    cmp r13, 0
    je .st_all_pass
    mov rsi, msg_phase3_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase4_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase5_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase6_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase7_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase8_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase9_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase10_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase11_fail
    call vga_print
    call serial_print64
    mov rsi, msg_phase12_fail
    call vga_print
    call serial_print64
    jmp .st_done
.st_all_pass:
    mov rsi, msg_phase3_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase4_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase5_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase6_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase7_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase8_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase9_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase10_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase11_ok
    call vga_print
    call serial_print64
    mov rsi, msg_phase12_ok
    call vga_print
    call serial_print64
.st_done:
    mov rax, r13
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

print_char_vga_serial:
    push rax
    push rdx
    push r8
    mov r8b, al
    movzx edi, r8b
    mov al, r8b
    call vga_putc
    ; serial: bounded best-effort (drop on timeout, never hang the suite)
    mov al, r8b
    call serial_try_putc64      ; CF ignored
    pop r8
    pop rdx
    pop rax
    ret

; Helper: print RAX 0-99 as decimal to VGA+serial
print_num_vga_serial:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    mov rcx, 10
    xor rdx, rdx
    div rcx              ; RAX = tens, RDX = ones
    test rax, rax
    jz .ones_only
    ; print tens
    add al, '0'
    push rdx
    mov r8b, al
    movzx edi, r8b
    mov al, r8b
    call vga_putc
    mov al, r8b
    call serial_try_putc64      ; CF ignored: drop and continue
    pop rdx
.ones_only:
    mov al, dl
    add al, '0'
    mov r8b, al
    movzx edi, r8b
    mov al, r8b
    call vga_putc
    mov al, r8b
    call serial_try_putc64      ; CF ignored: drop and continue
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Helper: print AL as two hex digits to VGA+serial
print_hex8:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    mov bl, al
    shr al, 4
    and al, 0x0F
    cmp al, 10
    jb .h1_low
    add al, 'A'-10
    jmp .h1_out
.h1_low:
    add al, '0'
.h1_out:
    mov r8b, al
    movzx edi, r8b
    push rax
    mov al, r8b
    call vga_putc
    pop rax
    mov al, r8b
    call serial_try_putc64      ; CF ignored: drop and continue
    mov al, bl
    and al, 0x0F
    cmp al, 10
    jb .h2_low
    add al, 'A'-10
    jmp .h2_out
.h2_low:
    add al, '0'
.h2_out:
    mov r8b, al
    movzx edi, r8b
    push rax
    mov al, r8b
    call vga_putc
    pop rax
    mov al, r8b
    call serial_try_putc64      ; CF ignored: drop and continue
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Helper: print AX as 4 hex digits
print_hex16:
    push rax
    mov al, ah
    call print_hex8
    pop rax
    push rax
    call print_hex8
    pop rax
    ret

; ------------------------------------------------------------
; Test 1: Register mapping and R8-R15
; ------------------------------------------------------------
test_registers:
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    ; Test 64-bit register widths: AL->AX->EAX->RAX zero extend
    mov rax, 0x11223344
    shl rax, 32
    or rax, 0x55667788
    mov al, 0x99
    cmp al, 0x99
    jne .fail
    ; Test R8-R15 availability — use 32-bit values to avoid truncation
    mov r8d, 0x11111111
    mov r9d, 0x22222222
    mov r10d, 0x33333333
    mov r11d, 0x44444444
    add r8, r9
    cmp r8d, 0x33333333
    jne .fail
    ; Test RBX/RBP/RSP mapping (BX->RBX etc.)
    mov rbx, 0x1234
    mov rcx, 0x5678
    mov rdx, rbx
    add rdx, rcx
    cmp rdx, 0x68AC
    jne .fail
    ; Test RSI/RDI flat
    lea rsi, [rel str_hello]
    lea rdi, [rel str_hello]
    cmp rsi, rdi
    jne .fail
    xor rax, rax
    jmp .done
.fail:
    mov rax, 1
.done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 2: String ops
; ------------------------------------------------------------

section .bss
test_buf_src: resb 128
test_buf_dst: resb 128
vol_read_buf: resb 1024
aux_fcb: resb FCBSIZ64

section .text
test_string_ops:
    push rsi
    push rdi
    push rcx
    push rbx

    ; Prepare source: "Hello64"
    lea rsi, [rel str_hello]
    lea rdi, [rel test_buf_src]
    mov rcx, 8
    call memcpy64          ; REP MOVSB with RCX

    ; Verify via strlen
    lea rdi, [rel test_buf_src]
    call strlen64
    cmp rax, 7
    jne .fail2

    ; Test memset: fill dst with 'A'
    lea rdi, [rel test_buf_dst]
    mov al, 'A'
    mov rcx, 16
    call memset64
    cmp byte [rel test_buf_dst], 'A'
    jne .fail2
    cmp byte [rel test_buf_dst+15], 'A'
    jne .fail2

    ; Test strcmp: src vs dst should differ
    lea rsi, [rel test_buf_src]
    lea rdi, [rel test_buf_dst]
    mov rcx, 8
    call strcmp64
    test rax, rax
    jz .fail2              ; should not be equal

    ; Test strupper
    lea rsi, [rel str_lower]
    lea rdi, [rel test_buf_dst]
    mov rcx, 5
    call strupper64
    cmp byte [rel test_buf_dst], 'H'
    jne .fail2             ; 'hello' -> 'HELLO'
    cmp byte [rel test_buf_dst+1], 'E'
    jne .fail2

    ; Test loop_replacement_demo (should not hang)
    mov rcx, 5
    mov r8, 0
    call loop_replacement_demo
    cmp r8, 5
    jne .fail2

    ; Test xlat replacement
    lea rbx, [rel xlat_table]
    mov al, 2
    call xlat_replacement_demo
    cmp al, 0x22
    jne .fail2

    xor rax, rax
    jmp .done2
.fail2:
    mov rax, 1
.done2:
    pop rbx
    pop rcx
    pop rdi
    pop rsi
    ret

; ------------------------------------------------------------
; Test 3: BCD
; ------------------------------------------------------------
test_bcd:
    push rbx
    ; Test rtc_bcd_to_bin: 0x59 -> 59
    mov al, 0x59
    call rtc_bcd_to_bin_v2
    cmp al, 59
    jne .fail3

    ; Test rtc_bin_to_bcd: 59 -> 0x59
    mov al, 59
    call rtc_bin_to_bcd
    cmp al, 0x59
    jne .fail3

    ; Test 0x00, 0x99 edges
    mov al, 0x00
    call rtc_bcd_to_bin_v2
    cmp al, 0
    jne .fail3
    mov al, 0x99
    call rtc_bcd_to_bin_v2
    cmp al, 99
    jne .fail3

    ; Test cbw demo doesn't fault
    call cbw_cwde_cdqe_demo
    call mul_div_64_demo
    call shl_rcl_demo

    xor rax, rax
    jmp .done3
.fail3:
    mov rax, 1
.done3:
    pop rbx
    ret

; ------------------------------------------------------------
; Test 5: Memory
; ------------------------------------------------------------
test_memory:
    call mem_init64
    ; Test para->bytes: 1 para =16 bytes
    mov rax, 1
    call mem_para_to_bytes
    cmp rax, 16
    jne .fail5
    mov rax, 0x100
    call mem_para_to_bytes
    cmp rax, 0x1000
    jne .fail5

    ; Alloc test
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail5
    mov rbx, rax           ; save
    mov rdi, 512
    call mem_alloc64
    test rax, rax
    jz .fail5
    mov rcx, rax
    ; Free first
    mov rdi, rbx
    call mem_free64
    jc .fail5
    ; Alloc again should reuse
    mov rdi, 128
    call mem_alloc64
    test rax, rax
    jz .fail5

    ; Max free should be >0
    call mem_max_free64
    test rax, rax
    jz .fail5

    xor rax, rax
    jmp .done5
.fail5:
    mov rax, 1
.done5:
    ret

; ------------------------------------------------------------
; Test 6: DMA flat
; ------------------------------------------------------------
test_dma:
    mov rdi, 0x12345678
    call dma_set_linear
    call dma_get_linear
    cmp rdi, 0x12345678
    jne .fail6
    mov rdi, 0x80000
    call dma_set_linear
    call dma_get_linear
    cmp rdi, 0x80000
    jne .fail6
    xor rax, rax
    ret
.fail6:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Test 7: Syscall/Dispatch
; ------------------------------------------------------------
test_syscall:
    call syscall_init
    mov rax, 2
    mov dl, 'X'
    call handler_conout
    mov rdx, demo_dollar2
    call handler_prtbuf
    mov rax, 0xFF00     ; AH=0xFF > MAXCOM -> bad function (DOS AH convention)
    call syscall_dispatch64
    cmp al, 0
    jne .fail7
    xor rax, rax
    ret
.fail7:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Test 13: ATA MBR + CHS conversion (INT13h replacement)
; ------------------------------------------------------------
test_ata_mbr:
    push rbx
    push rcx
    push rdx
    push rsi
    call ata_init
    call ata_test_mbr_read
    mov rcx, rax  ; save result: 0=pass, 1=timeout, 2=sig mismatch
    test rcx, rcx
    jnz .debug13
    ; Inline CHS test with verbose debug
    ; Vector1: C1 H0 S1 -> 1008
    mov eax, 1
    mov bl, 0
    mov cl, 1
    mov edx, 16
    mov esi, 63
    call chs_to_lba
    cmp eax, 1008
    je .chs1_ok
    push rax
    mov rsi, ata_chs_dbg1
    call vga_print
    call serial_print64
    pop rax
    call print_hex16
    mov rsi, ata_chs_exp
    call vga_print
    call serial_print64
    mov ax, 1008
    call print_hex16
    mov rsi, msg_nl2
    call vga_print
    call serial_print64
    jmp .fail13b
.chs1_ok:
    ; Vector2: LBA1008 -> C1 H0 S1
    mov eax, 1008
    mov edx, 16
    mov esi, 63
    call lba_to_chs_demo
    cmp eax, 1
    jne .chs2_fail
    cmp bl, 0
    jne .chs2_fail
    cmp cl, 1
    jne .chs2_fail
    jmp .chs2_ok
.chs2_fail:
    push rax
    push rbx
    push rcx
    mov rsi, ata_chs_dbg2
    call vga_print
    call serial_print64
    pop rcx
    pop rbx
    pop rax
    ; Print C/H/S
    push rax
    call print_hex16
    mov rsi, ata_dbg_msg3
    call vga_print
    call serial_print64
    mov al, bl
    call print_hex8
    mov rsi, ata_dbg_msg3
    call vga_print
    call serial_print64
    mov al, cl
    call print_hex8
    mov rsi, msg_nl2
    call vga_print
    call serial_print64
    pop rax
    jmp .fail13b
.chs2_ok:
    ; Vector3: LBA0 -> C0 H0 S1
    mov eax, 0
    mov edx, 16
    mov esi, 63
    call lba_to_chs_demo
    cmp eax, 0
    jne .chs3_fail
    cmp bl, 0
    jne .chs3_fail
    cmp cl, 1
    jne .chs3_fail
    jmp .chs3_ok
.chs3_fail:
    push rax
    mov rsi, ata_chs_dbg3
    call vga_print
    call serial_print64
    pop rax
    call print_hex16
    mov rsi, msg_nl2
    call vga_print
    call serial_print64
    jmp .fail13b
.chs3_ok:
    xor rax, rax
    jmp .done13
.debug13:
    ; Print debug: " ATA DBG status="
    push rcx
    mov rsi, ata_dbg_msg
    call vga_print
    call serial_print64
    mov al, [rel ata_debug_status]
    call print_hex8
    mov rsi, ata_dbg_msg2
    call vga_print
    call serial_print64
    mov al, [rel ata_debug_error]
    call print_hex8
    mov rsi, ata_dbg_msg3
    call vga_print
    call serial_print64
    ; Also print word at 510
    mov rsi, ata_dbg_msg4
    call vga_print
    call serial_print64
    lea rsi, [rel ata_test_buf]
    mov ax, [rsi+510]
    call print_hex16
    mov rsi, msg_nl2
    call vga_print
    call serial_print64
    pop rcx
    cmp rcx, 2
    je .fail_sig13
    jmp .fail13
.fail_sig13:
    mov rsi, ata_sig_fail_msg
    call vga_print
    call serial_print64
    jmp .fail13
.fail13b:
    mov rsi, ata_chs_fail_msg
    call vga_print
    call serial_print64
.fail13:
    mov rax, 1
    jmp .done13b
.done13:
    ; success path
.done13b:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 14: ATA write/readback
; ------------------------------------------------------------
test_ata_write:
    call ata_test_write_readback
    test rax, rax
    jnz .fail14
    xor rax, rax
    ret
.fail14:
    mov rax, 1
    ret

; ------------------------------------------------------------
; Test 15: Keyboard status + queue (INT16h replacement)
; ------------------------------------------------------------
test_kbd_status:
    push rbx
    call kbd_init
    ; kbd_init should return 0; if 1 still continue but test status port
    call kbd_test_status
    test rax, rax
    jnz .fail15
    call kbd_test_queue
    test rax, rax
    jnz .fail15
    ; IRQ-safe queue stress at empty/full boundaries (runs with caller IF;
    ; safe before the IDT is loaded — no sti/cli, push/pop preserve IF).
    ; Explicit IF=1/0 preservation (kbd_test_queue_if, uses sti) runs in
    ; test 55 after the IDT is up.
    call kbd_test_queue_stress
    test rax, rax
    jnz .fail15
    ; Also verify has_data doesn't fault and poll returns no data (CF)
    call kbd_has_data
    ; 0 or 1 both valid, just check not crashing and within range
    cmp rax, 1
    ja .fail15
    ; Poll should indicate no data (CF=1) when idle, or if data, handle
    call kbd_poll
    ; Either CF=0 (data) or CF=1 (no data) both ok, just check not hanging
    ; Test queue push/pop via driver already
    xor rax, rax
    jmp .done15
.fail15:
    mov rax, 1
.done15:
    pop rbx
    ret

; ------------------------------------------------------------
; Test 16: Keyboard translation + VGA native combined
; ------------------------------------------------------------
test_kbd_translation:
    push rbx
    call kbd_test_translation
    test rax, rax
    jnz .fail16
    ; VGA additional test: init (clears and resets cursor) and print
    call vga_init
    mov rsi, vga_test_str
    call vga_print
    ; Check VGA memory at 0xB8000 contains first char 'V'?
    mov rbx, 0xB8000
    cmp byte [rbx], 'V'
    jne .fail16
    cmp byte [rbx+1], 0x0F
    jne .fail16
    ; Also test scroll and cursor positioning via vga driver (INT10h replacement)
    mov al, 13
    call vga_putc  ; CR
    mov al, 10
    call vga_putc  ; LF -> should move to next line
    ; Verify cursor moved (row should be 1 after printing VGA + CRLF)
    xor rax, rax
    jmp .done16
.fail16:
    mov rax, 1
.done16:
    pop rbx
    ret

; ------------------------------------------------------------
; Test 17: Paragraph/page conversions (Phase6 byte-based)
;   Fast helpers on small values plus checked adapters on the
;   UINT64_MAX>>4 / >>12 boundaries (just below/at/overflow-by-one/many).
; ------------------------------------------------------------
test_para_page:
    push rbx
    push rcx
    ; para->bytes 1->16
    mov rax, 1
    call mem_para_to_bytes
    cmp rax, 16
    jne .fail17
    mov rax, 0x100
    call mem_para_to_bytes
    cmp rax, 0x1000
    jne .fail17
    ; bytes->para 16->1, 17->2 (rounded)
    mov rax, 16
    call mem_bytes_to_para
    cmp rax, 1
    jne .fail17
    mov rax, 17
    call mem_bytes_to_para
    cmp rax, 2
    jne .fail17
    mov rax, 0x1000
    call mem_bytes_to_para
    cmp rax, 0x100
    jne .fail17
    ; bytes->pages 4096->1, 4097->2, 0->0
    mov rax, 4096
    call mem_bytes_to_pages
    cmp rax, 1
    jne .fail17
    mov rax, 4097
    call mem_bytes_to_pages
    cmp rax, 2
    jne .fail17
    xor rax, rax
    call mem_bytes_to_pages
    cmp rax, 0
    jne .fail17
    ; pages->bytes 1->4096
    mov rax, 1
    call mem_pages_to_bytes
    cmp rax, 4096
    jne .fail17
    mov rax, 2
    call mem_pages_to_bytes
    cmp rax, 8192
    jne .fail17
    ; para->pages: 256 para = 4096 bytes =1 page
    mov rax, 256
    call mem_para_to_pages
    cmp rax, 1
    jne .fail17
    mov rax, 257
    call mem_para_to_pages
    cmp rax, 2
    jne .fail17
    ; pages->para 1 page =256 para
    mov rax, 1
    call mem_pages_to_para
    cmp rax, 256
    jne .fail17
    ; ---- checked adapters: boundary just below/at UINT64_MAX>>4, overflow ----
    ; para->bytes checked: 1->16 ok
    mov rax, 1
    call mem_para_to_bytes_checked64
    jc .fail17
    cmp rax, 16
    jne .fail17
    ; just below max convertible (MAX>>4 -1) -> 0xFFFFFFFFFFFFFFE0 ok
    mov rax, 0x0FFFFFFFFFFFFFFE
    call mem_para_to_bytes_checked64
    jc .fail17
    mov rbx, 0xFFFFFFFFFFFFFFE0
    cmp rax, rbx
    jne .fail17
    ; at max convertible (MAX>>4) -> 0xFFFFFFFFFFFFFFF0 ok
    mov rax, 0x0FFFFFFFFFFFFFFF
    call mem_para_to_bytes_checked64
    jc .fail17
    mov rbx, 0xFFFFFFFFFFFFFFF0
    cmp rax, rbx
    jne .fail17
    ; overflow by one bit (MAX>>4 +1) must fail with RAX=0
    mov rax, 0x1000000000000000
    call mem_para_to_bytes_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    ; overflow by many bits (all ones) must fail
    mov rax, -1
    call mem_para_to_bytes_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    ; bytes->para checked: max ok (MAX-15) converts, MAX-14 wraps->fail
    mov rax, 0xFFFFFFFFFFFFFFF0
    call mem_bytes_to_para_checked64
    jc .fail17
    mov rbx, 0x0FFFFFFFFFFFFFFF
    cmp rax, rbx
    jne .fail17
    mov rax, 0xFFFFFFFFFFFFFFF1
    call mem_bytes_to_para_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    ; pages->bytes checked: max pages (MAX>>12) ok, 2^52 overflows by one
    mov rax, 0xFFFFFFFFFFFFF
    call mem_pages_to_bytes_checked64
    jc .fail17
    mov rbx, 0xFFFFFFFFFFFFF000
    cmp rax, rbx
    jne .fail17
    mov rax, 0x10000000000000
    call mem_pages_to_bytes_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    ; bytes->pages checked: max ok (MAX-4095), MAX fails
    mov rax, 0xFFFFFFFFFFFFF000
    call mem_bytes_to_pages_checked64
    jc .fail17
    mov rbx, 0xFFFFFFFFFFFFF
    cmp rax, rbx
    jne .fail17
    mov rax, -1
    call mem_bytes_to_pages_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    ; para->pages checked: 256->1 ok, max para fails second-stage (+4095 wraps)
    mov rax, 256
    call mem_para_to_pages_checked64
    jc .fail17
    cmp rax, 1
    jne .fail17
    mov rax, 0x0FFFFFFFFFFFFFFF
    call mem_para_to_pages_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    ; pages->para checked: 1->256 ok, 2^52 fails
    mov rax, 1
    call mem_pages_to_para_checked64
    jc .fail17
    cmp rax, 256
    jne .fail17
    mov rax, 0x10000000000000
    call mem_pages_to_para_checked64
    jnc .fail17
    test rax, rax
    jnz .fail17
    xor rax, rax
    jmp .done17
.fail17:
    mov rax, 1
.done17:
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 18: Coalesce — split and prev+next merge, validation
; ------------------------------------------------------------
test_coalesce:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail18
    ; Alloc A 256, B 512, C 256
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail18
    mov r8, rax
    mov rdi, 512
    call mem_alloc64
    test rax, rax
    jz .fail18
    mov r9, rax
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail18
    mov r10, rax
    ; Free middle B
    mov rdi, r9
    call mem_free64
    jc .fail18
    call mem_validate64
    test rax, rax
    jnz .fail18
    ; Allocate D 400 should reuse B (first-fit, B was 512)
    mov rdi, 400
    call mem_alloc64
    test rax, rax
    jz .fail18
    cmp rax, 0x200000
    jb .fail18
    cmp rax, 0x800000
    jae .fail18
    mov r9, rax
    ; Free A,C,D in order to test coalesce both directions
    mov rdi, r8
    call mem_free64
    jc .fail18
    mov rdi, r10
    call mem_free64
    jc .fail18
    mov rdi, r9
    call mem_free64
    jc .fail18
    call mem_validate64
    test rax, rax
    jnz .fail18
    ; After all frees, should be single Z block
    call mem_count_blocks64
    cmp rax, 1
    jne .fail18
    call mem_max_free64
    cmp rax, 6*1024*1024 - 1024
    jb .fail18
    ; Also test double-free detection
    mov rdi, r8
    call mem_free64
    jnc .fail18          ; should fail (already free)
    ; Test via direct alloc (bypass handler AL corruption)
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail18
    mov r8, rax
    mov rdi, r8
    call mem_free64
    jc .fail18
    xor rax, rax
    jmp .done18
.fail18:
    mov rax, 1
.done18:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 19: Resize — shrink and grow (SETBLK)
; ------------------------------------------------------------
test_resize:
    push rbx
    push rcx
    push rdi
    push rsi
    call mem_reset64
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail19
    mov rbx, rax
    ; Shrink to 128
    mov rdi, rbx
    mov rsi, 128
    call mem_resize64
    test rax, rax
    jnz .fail19
    call mem_validate64
    test rax, rax
    jnz .fail19
    ; Verify new size via reading MCB? Instead check that max free increased
    ; Grow to 512 — need next free to coalesce (should succeed as next is free)
    mov rdi, rbx
    mov rsi, 512
    call mem_resize64
    test rax, rax
    jnz .fail19
    call mem_validate64
    test rax, rax
    jnz .fail19
    ; Grow too large should fail (needs 10M > heap)
    mov rdi, rbx
    mov rsi, 10*1024*1024
    call mem_resize64
    test rax, rax
    jz .fail19           ; should fail
    call mem_validate64
    test rax, rax
    jnz .fail19
    ; Near-overflow resizes must fail with CF and leave chain intact
    ; NOTE: check CF immediately — TEST clears CF.
    mov rdi, rbx
    mov rsi, -1             ; UINT64_MAX
    call mem_resize64
    jnc .fail19             ; CF must be set on failure
    test rax, rax
    jz .fail19
    call mem_validate64
    test rax, rax
    jnz .fail19
    mov rdi, rbx
    mov rsi, -15            ; UINT64_MAX-14 (wraps size+15 to 0)
    call mem_resize64
    jnc .fail19
    test rax, rax
    jz .fail19
    call mem_validate64
    test rax, rax
    jnz .fail19
    mov rdi, rbx
    mov rsi, -16            ; UINT64_MAX-15 (rounds to huge, exceeds heap)
    call mem_resize64
    jnc .fail19
    test rax, rax
    jz .fail19
    call mem_validate64
    test rax, rax
    jnz .fail19
    ; Also test resize via direct call
    mov rdi, rbx
    mov rsi, 256
    call mem_resize64
    test rax, rax
    jnz .fail19
    mov rdi, rbx
    call mem_free64
    jc .fail19
    xor rax, rax
    jmp .done19
.fail19:
    mov rax, 1
.done19:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 20: Page protection — RW/NX via PD 2MiB pages
; ------------------------------------------------------------
test_protection:
    push rbx
    push rcx
    push rdi
    push rsi
    call mem_enable_nxe64
    ; Get PD entry for heap start 0x200000 (should be PD[1])
    mov rdi, 0x200000
    call mem_get_pd_entry64
    test rax, rax
    jz .fail20
    mov rbx, rax
    and rbx, 2
    cmp rbx, 2
    jne .fail20          ; should be RW initially
    ; Set to RO
    mov rdi, 0x200000
    xor rsi, rsi         ; 0 = RO
    call mem_set_rw64
    test rax, rax
    jnz .fail20
    mov rdi, 0x200000
    call mem_get_pd_entry64
    and rax, 2
    cmp rax, 0
    jne .fail20
    ; Restore RW
    mov rdi, 0x200000
    mov rsi, 1
    call mem_set_rw64
    test rax, rax
    jnz .fail20
    mov rdi, 0x200000
    call mem_get_pd_entry64
    and rax, 2
    cmp rax, 2
    jne .fail20
    ; Test NX set
    mov rdi, 0x200000
    mov rsi, 1
    call mem_set_nx64
    test rax, rax
    jnz .fail20
    mov rdi, 0x200000
    call mem_get_pd_entry64
    mov rcx, 1
    shl rcx, 63
    and rax, rcx
    cmp rax, rcx
    jne .fail20
    ; Clear NX
    mov rdi, 0x200000
    xor rsi, rsi
    call mem_set_nx64
    test rax, rax
    jnz .fail20
    mov rdi, 0x200000
    call mem_get_pd_entry64
    mov rcx, 1
    shl rcx, 63
    and rax, rcx
    cmp rax, 0
    jne .fail20
    ; Flush
    call mem_flush_tlb64
    xor rax, rax
    jmp .done20
.fail20:
    mov rax, 1
.done20:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 21: Stress + validation — totals, double-free, alloc caps
; ------------------------------------------------------------
test_stress:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail21
    call mem_total_free64
    mov r10, rax         ; initial free
    call mem_total_used64
    test rax, rax
    jnz .fail21          ; should be 0 used
    ; Allocate many small blocks until fail
    xor r11, r11         ; count
    mov r8, 0x210000     ; start storing pointers at unused heap area? Use stack buffer
    ; Use heap itself for pointer array? Use BSS 4K buffer at 0x90000-? But that's stack. Use temporary buffer in .bss we allocate via static?
    ; Simpler: allocate 64-byte blocks and keep count, free via scanning? We'll just loop alloc 64 bytes
.alloc_loop21:
    cmp r11, 64
    jae .alloc_done21
    mov rdi, 64
    call mem_alloc64
    test rax, rax
    jz .alloc_done21
    inc r11
    jmp .alloc_loop21
.alloc_done21:
    cmp r11, 0
    je .fail21
    call mem_total_used64
    cmp rax, 0
    je .fail21
    call mem_max_free64
    test rax, rax
    jz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Free all via reset (for simplicity) and validate single block
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail21
    call mem_count_blocks64
    cmp rax, 1
    jne .fail21
    ; Test invalid free (not MCB aligned)
    mov rdi, 0x200001
    call mem_free64
    jnc .fail21          ; must reject unaligned pointer
    ; Test zero-size alloc fails
    xor rdi, rdi
    call mem_alloc64
    test rax, rax
    jnz .fail21          ; must fail
    ; Test huge alloc fails
    mov rdi, 100*1024*1024
    call mem_alloc64
    test rax, rax
    jnz .fail21          ; must fail
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Overflow hardening: near-UINT64_MAX sizes must fail without MCB change
    mov rdi, -1             ; UINT64_MAX
    call mem_alloc64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, -15            ; UINT64_MAX-14 (size+15 wraps to 0)
    call mem_alloc64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, -16            ; UINT64_MAX-15 (rounds to huge > heap)
    call mem_alloc64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Aligned near-overflow: large valid alignment + huge size must fail
    mov rdi, -16
    mov rsi, 4096
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, -4096          ; UINT64_MAX-4095, 4096-aligned huge
    mov rsi, 4096
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, 16
    mov rsi, 1
    shl rsi, 32             ; align = 2^32, valid power of two
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail21             ; 4 GiB alignment cannot fit 6 MiB heap
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, -16
    mov rsi, 1
    shl rsi, 32
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Pages overflow: page count whose byte size wraps must fail
    mov rdi, -1             ; UINT64_MAX pages
    call mem_alloc_pages64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, 1
    shl rdi, 52             ; 2^52 pages * 4096 = 2^64 -> wraps to 0
    call mem_alloc_pages64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Resize near-overflow must fail with CF, chain intact
    ; NOTE: check CF immediately — TEST clears CF.
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail21
    mov rbx, rax
    mov rdi, rax
    mov rsi, -1
    call mem_resize64
    jnc .fail21
    test rax, rax
    jz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, rbx
    mov rsi, -16
    call mem_resize64
    jnc .fail21
    test rax, rax
    jz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, rbx
    call mem_free64
    jc .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Normal max-heap alloc still governed by capacity, not wrap:
    ; Largest 16-aligned request fitting the empty heap succeeds.
    mov rdi, 6*1024*1024 - 48
    call mem_alloc64
    test rax, rax
    jz .fail21
    mov rbx, rax
    call mem_validate64
    test rax, rax
    jnz .fail21
    mov rdi, rbx
    call mem_free64
    jc .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; MEM_SIZE (header + data exceeds heap) must fail via capacity.
    mov rdi, 6*1024*1024
    call mem_alloc64
    test rax, rax
    jnz .fail21
    call mem_validate64
    test rax, rax
    jnz .fail21
    ; Test page-aligned alloc (4096) returns 4096-aligned
    mov rdi, 4096
    mov rsi, 4096
    call mem_alloc_aligned64
    test rax, rax
    jz .fail21
    test rax, 0xFFF
    jnz .fail21          ; must be 4096-aligned
    mov rdi, rax
    call mem_free64
    jc .fail21
    ; Exercise INT 21h AH=48h ALLOC via full dispatch: AH=function (DOS
    ; convention), RBX=paragraphs. Handler converts para->bytes (SHL 4).
    ; Result intentionally ignored (leaks 256B); must return without fault.
    mov rbx, 16          ; 16 paragraphs = 256 bytes
    xor rdi, rdi         ; force paragraph path in handler
    mov rax, 0x4800      ; AH=0x48 ALLOC
    call syscall_dispatch64
    xor rax, rax
    jmp .done21
.fail21:
    mov rax, 1
.done21:
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 67: Real FAT12 volume mount + on-disk file read (G2)
;   Mounts LBA FS_VOL_LBA (tools/mkfat12.py), reads HELLO.TXT
;   (1 cluster) and README.TXT (2 clusters, 1000B chain) via ATA,
;   checks content prefix + size, verifies missing file fails.
; ------------------------------------------------------------
test_vol_mount:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call fs_mount_volume64
    test rax, rax
    jnz .fail67
    ; Idempotent second mount must also succeed.
    call fs_mount_volume64
    test rax, rax
    jnz .fail67
    ; HELLO.TXT: expect >32 bytes starting with "Hello".
    lea rdi, [rel vol_name_hello]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail67
    cmp rax, 32
    jb .fail67
    lea rsi, [rel vol_read_buf]
    cmp dword [rsi], 'Hell'     ; "Hell" LE
    jne .fail67
    cmp byte [rsi+4], 'o'
    jne .fail67
    ; README.TXT: exactly 1000 bytes across a 2-cluster chain, "MS-D".
    lea rdi, [rel vol_name_readme]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail67
    cmp rax, 1000
    jne .fail67
    cmp dword [rsi], 'MS-D'      ; "MS-D" LE
    jne .fail67
    ; Small buffer truncates (min(size, bufsize)).
    lea rdi, [rel vol_name_readme]
    lea rsi, [rel vol_read_buf]
    mov rdx, 100
    call fs_vol_read_file64
    jc .fail67
    cmp rax, 100
    jne .fail67
    ; Missing file must fail with CF.
    lea rdi, [rel vol_name_missing]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jnc .fail67
    xor eax, eax
    jmp .done67
.fail67:
    mov rax, 1
.done67:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 68: RTC date/time (INT21 AH=2Ah-2Dh).
;   GETDATE/GETTIME sane ranges, SET round-trip with restore,
;   invalid SET rejected, one INT 0x21 trap routing check.
; ------------------------------------------------------------
test_rtc_datetime:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; GETDATE direct: RCX=year RDX=(mon<<8)|day AL=wday
    call handler_getdate
    jc .fail68
    mov r8b, al           ; save wday before RAX is reused for mon/day
    cmp rcx, 1980
    jb .fail68
    cmp rcx, 2099
    ja .fail68
    mov rax, rdx
    shr rax, 8
    and rax, 0xFF
    cmp rax, 1
    jb .fail68
    cmp rax, 12
    ja .fail68
    mov rax, rdx
    and rax, 0xFF
    cmp rax, 1
    jb .fail68
    cmp rax, 31
    ja .fail68
    cmp r8b, 6
    ja .fail68
    mov r10, rcx          ; save year
    mov r11, rdx          ; save mon/day
    ; GETTIME direct: RCX=(hr<<8)|min RDX=(sec<<8)
    call handler_gettime
    jc .fail68b
    mov rax, rcx
    shr rax, 8
    cmp rax, 24
    jae .fail68b
    mov rax, rcx
    and rax, 0xFF
    cmp rax, 60
    jae .fail68b
    mov rax, rdx
    shr rax, 8
    cmp rax, 60
    jae .fail68b
    push r10
    push r11
    mov r8, rcx           ; save time
    push r8
    mov r9, rdx
    push r9
    ; SETDATE 2001-02-28 then verify
    mov rcx, 2001
    mov rdx, 0x021C       ; mon=2 day=28
    call handler_setdate
    jc .fail68c
    test al, al
    jnz .fail68c
    call handler_getdate
    jc .fail68c
    cmp rcx, 2001
    jne .fail68c
    cmp rdx, 0x021C
    jne .fail68c
    ; SETTIME 12:34:56 then verify
    mov rcx, 0x0C22       ; hr=12 min=34
    mov rdx, 0x3800       ; sec=56
    call handler_settime
    jc .fail68c
    call handler_gettime
    jc .fail68c
    cmp rcx, 0x0C22
    jne .fail68c
    cmp rdx, 0x3800
    jne .fail68c
    ; Restore original date/time
    pop r9
    mov rdx, r9
    pop r8
    mov rcx, r8
    call handler_settime
    jc .fail68c
    pop r11
    mov rdx, r11
    pop r10
    mov rcx, r10
    call handler_setdate
    jc .fail68c
    ; Invalid SETDATE (month 13) rejected
    mov rcx, 2001
    mov rdx, 0x0D01
    call handler_setdate
    jnc .fail68
    cmp al, 0xFF
    jne .fail68
    ; Invalid SETTIME (hour 25) rejected
    mov rcx, 0x1900
    mov rdx, 0
    call handler_settime
    jnc .fail68
    ; Trap routing: AH=2Ch via CPU INT 0x21
    mov rax, 0x2C00
    int 0x21
    mov rax, rcx
    shr rax, 8
    cmp rax, 24
    jae .fail68
    ; Trap routing: AH=2Ah via dispatch
    mov rax, 0x2A00
    call syscall_dispatch64
    jc .fail68
    cmp rcx, 1980
    jb .fail68
    xor eax, eax
    jmp .done68
.fail68c:
    add rsp, 32           ; drop 4 saved qwords (r9/r8/r11/r10)
.fail68b:
.fail68:
    mov rax, 1
.done68:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 69: AUX/COM/LIST + VERIFY/NEWBASE/disk pointers.
; ------------------------------------------------------------
test_aux_misc:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; PUNCH 'Z' -> COM1, AL=0 CF=0
    mov dl, 'Z'
    call handler_punch
    jc .fail69
    test al, al
    jnz .fail69
    ; LIST 'L' -> COM1 capture
    mov dl, 'L'
    call handler_list
    jc .fail69
    ; READER is non-blocking: must return either way (no hang possible)
    call handler_reader
    ; carry either way is legal; AL must be 0 when CF=1
    jc .reader_empty_ok
    jmp .reader_done
.reader_empty_ok:
    test al, al
    jnz .fail69
.reader_done:
    ; VERIFY set/get/reject
    mov al, 1
    call handler_verify
    jc .fail69
    mov al, 0
    call handler_verify
    jc .fail69
    mov al, 2
    call handler_verify
    jnc .fail69
    ; NEWBASE -> paragraphs > 0
    call handler_newbase
    jc .fail69
    test rax, rax
    jz .fail69
    ; GETFATPT -> RBX != 0, AL == 9 (volume fatsiz)
    call handler_getfatpt
    jc .fail69
    test rbx, rbx
    jz .fail69
    cmp al, 9
    jne .fail69
    ; GETFATPTDL drive 0 ok, drive 9 rejected
    mov dl, 0
    call handler_getfatptdl
    jc .fail69
    mov dl, 9
    call handler_getfatptdl
    jnc .fail69
    ; GETDSKPT -> RBX != 0
    call handler_getdskpt
    jc .fail69
    test rbx, rbx
    jz .fail69
    ; GETRDONLY -> media 0xF0
    call handler_getrdonly
    jc .fail69
    cmp al, 0xF0
    jne .fail69
    ; SETATTRIB get on HELLO.TXT (build FCB in aux_fcb)
    lea rdi, [rel aux_fcb]
    mov rcx, 80
    xor al, al
.clear_fcb69:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .clear_fcb69
    lea rdi, [rel aux_fcb]
    mov byte [rdi], 1
    mov dword [rdi+1], 'HELL'
    mov dword [rdi+5], 'O   '
    mov byte [rdi+9], 'T'
    mov byte [rdi+10], 'X'
    mov byte [rdi+11], 'T'
    xor al, al            ; get
    lea rdx, [rel aux_fcb]
    call handler_setattrib
    jc .fail69
    cmp cl, 0x20          ; mkfat12 writes archive attr
    jne .fail69
%ifdef SELFTEST_DESTRUCTIVE
    ; Full mode only: exercise the SET write+flush path with a different
    ; value then restore (net-zero overall). Smoke skips this so the
    ; default suite stays read-only on the volume in steady state.
    mov al, 1
    mov cl, 0x21
    lea rdx, [rel aux_fcb]
    call handler_setattrib
    jc .fail69_restore
    xor al, al
    lea rdx, [rel aux_fcb]
    call handler_setattrib
    jc .fail69_restore
    cmp cl, 0x21
    jne .fail69_restore
    mov al, 1
    mov cl, 0x20
    lea rdx, [rel aux_fcb]
    call handler_setattrib
    jc .fail69
    jmp .after_set69
.fail69_restore:
    ; Best-effort restore to 0x20 so a failed SET round-trip cannot leave
    ; HELLO.TXT with a dirty attr for the next boot's strict GET check.
    push rax
    push rcx
    mov al, 1
    mov cl, 0x20
    lea rdx, [rel aux_fcb]
    call handler_setattrib
    pop rcx
    pop rax
    jmp .fail69
.after_set69:
%else
    ; Smoke: skip the SET write entirely (no root-sector write every boot).
    ; The SET path is still covered by destructive tests 71/83 (which flush
    ; root on create/rename/delete) and by the interactive shell.
%endif
    ; dispatch path: AH=05 LIST via syscall_dispatch64
    mov dl, 'Q'
    mov rax, 0x0500
    call syscall_dispatch64
    jc .fail69
    xor eax, eax
    jmp .done69
.fail69:
    mov rax, 1
.done69:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; recover_test_namespace_if_dirty — mount-time recovery check (smoke+full).
; Verifies the reserved test namespace (SCRATCH/RENAMED/CRASH) during mount:
; read-only scrub + mirror + live-name checks; writes (delete + reclaim +
; heal) ONLY when dirty (interrupted destructive run). This is why Test 70
; (read-only enumeration expecting exactly HELLO+README .TXT) stays stable
; even when a previous boot died mid-71/83: the next boot heals before
; enumerating. On a clean image this performs zero device writes (mount
; heal is a no-op when mirrors already match).
; Out: RAX 0 clean/recovered, 1 unrecoverable. Preserves all except RAX.
; ------------------------------------------------------------
recover_test_namespace_if_dirty:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov dword [rel fs_fault_inject], 0
    call fs_mount_volume64
    test rax, rax
    jnz .rec_fail
    xor r12d, r12d                ; dirty flag 0 clean
    ; SCRATCH live? (make+open CF=0 found => dirty)
    lea rsi, [rel fcb_str_scratch]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    cmp al, 0xFF
    je .rec_fail
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .rec_dirty               ; found => dirty
    ; RENAMED live?
    lea rsi, [rel fcb_str_renamed]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    cmp al, 0xFF
    je .rec_fail
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .rec_dirty
    ; CRASH live?
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    cmp al, 0xFF
    je .rec_fail
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .rec_dirty
    jmp .rec_check_meta
.rec_dirty:
    mov r12d, 1
.rec_check_meta:
    ; scrub bits (RAX) must be 0; orphans (RCX) >0 => dirty (leak, recoverable)
    call fs_vol_scrub64
    test rax, rax
    jnz .rec_fail                 ; DANGLING/XLINK/MIRROR bits: not recoverable here
    jc .rec_fail
    test rcx, rcx
    jnz .rec_is_dirty2
    call fs_vol_check_mirrors64
    cmp rax, 0
    je .rec_maybe_clean
.rec_is_dirty2:
    mov r12d, 1
.rec_maybe_clean:
    test r12d, r12d
    jz .rec_ok                    ; clean: zero writes performed
    ; ---- dirty: delete both+all test names (ignore missing) ----
    lea rsi, [rel fcb_str_scratch]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    lea rdi, [rel aux_fcb]
    call fs_fcb_delete64          ; ignore
    lea rsi, [rel fcb_str_renamed]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    lea rdi, [rel aux_fcb]
    call fs_fcb_delete64          ; ignore
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    lea rdi, [rel aux_fcb]
    call fs_fcb_delete64          ; ignore
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .rec_fail
    call fs_vol_reclaim_orphans64
    jc .rec_fail
    call fs_vol_heal_mirrors64
    test rax, rax
    jnz .rec_fail
    call fs_vol_scrub64
    test rax, rax
    jnz .rec_fail
    test rcx, rcx
    jnz .rec_fail
    jc .rec_fail
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .rec_fail
    ; verify no test names live after recovery
    lea rsi, [rel fcb_str_scratch]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .rec_fail
    lea rsi, [rel fcb_str_renamed]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .rec_fail
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .rec_fail
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .rec_fail
.rec_ok:
    xor eax, eax
    jmp .rec_done
.rec_fail:
    mov rax, 1
.rec_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 70: FCB file ops, read-only, on the real volume.
;   MAKEFCB/OPEN/FILESIZE/RNDRD/BLKRD/SRCHFRST/SRCHNXT/CLOSE + dispatch.
;   Starts with mount-time recovery (see above) so an interrupted 71/83
;   cannot break the "*.TXT == HELLO+README only" enumeration: dirty test
;   files are reclaimed before counting. On a clean image the recovery is
;   read-only (no writes).
; ------------------------------------------------------------
test_fcb_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    call recover_test_namespace_if_dirty
    test rax, rax
    jnz .fail70
    ; MAKEFCB "HELLO.TXT" (mode 0, no wildcards -> AL=0)
    lea rsi, [rel fcb_str_hello]
    lea rdi, [rel aux_fcb]
    xor al, al
    call handler_makefcb
    cmp al, 0
    jne .fail70
    cmp byte [rsi], 0
    jne .fail70
    ; OPEN
    lea rdx, [rel aux_fcb]
    call handler_open
    jc .fail70
    test al, al
    jnz .fail70
    cmp dword [rel aux_fcb + FCB64.recsiz], 128   ; recsiz defaulted
    jne .fail70
    ; SETDMA to vol_read_buf
    lea rdx, [rel vol_read_buf]
    call handler_setdma
    ; FILESIZE -> RR = ceil(filsiz/128); cross-check against filsiz
    lea rdx, [rel aux_fcb]
    call handler_filesize
    jc .fail70
    mov rcx, [rel aux_fcb + FCB64.filsiz]         ; filsiz
    mov rax, [rel aux_fcb + FCB64.rr]             ; RR
    test rax, rax
    jz .fail70
    mov r9, rax
    shl r9, 7                         ; rr*128 >= filsiz?
    cmp r9, rcx
    jb .fail70
    sub r9, 128                       ; (rr-1)*128 < filsiz?
    cmp r9, rcx
    jae .fail70
    ; RNDRD record 0 -> "Hello"
    mov qword [rel aux_fcb + FCB64.rr], 0
    lea rdx, [rel aux_fcb]
    call handler_rndrd
    jc .fail70
    test al, al
    jnz .fail70
    cmp dword [rel vol_read_buf], 'Hell'
    jne .fail70
    ; BLKRD 2 records at RR=0 (HELLO is 2 records of 128)
    mov qword [rel aux_fcb + FCB64.rr], 0
    mov rcx, 2
    lea rdx, [rel aux_fcb]
    call handler_blkrd
    jc .fail70
    cmp rcx, 2
    jne .fail70
    ; SRCHFRST "*.TXT" (wild -> AL=1 from MAKEFCB)
    lea rsi, [rel fcb_str_wild]
    lea rdi, [rel aux_fcb]
    xor al, al
    call handler_makefcb
    cmp al, 1
    jne .fail70
    lea rdx, [rel aux_fcb]
    call handler_srchfrst
    jc .fail70
    cmp dword [rel vol_read_buf], 'HELL'   ; first .TXT = HELLO
    jne .fail70
    lea rdx, [rel aux_fcb]
    call handler_srchnxt
    jc .fail70
    cmp dword [rel vol_read_buf], 'READ'   ; second .TXT = README
    jne .fail70
    lea rdx, [rel aux_fcb]
    call handler_srchnxt
    jnc .fail70                        ; no third .TXT
    ; CLOSE (HELLO still open in this FCB? FCB now holds wild pattern;
    ; rebuild + reopen + close for a clean CLOSE test)
    lea rsi, [rel fcb_str_hello]
    lea rdi, [rel aux_fcb]
    xor al, al
    call handler_makefcb
    lea rdx, [rel aux_fcb]
    call handler_open
    jc .fail70
    lea rdx, [rel aux_fcb]
    call handler_close
    jc .fail70
    ; Dispatch path: AH=0Fh OPEN via syscall_dispatch64
    lea rdx, [rel aux_fcb]
    mov rax, 0x0F00
    call syscall_dispatch64
    jc .fail70
    ; Dispatch path: AH=29h MAKEFCB via int 0x21 (AL=mode in live AL)
    lea rsi, [rel fcb_str_hello]
    lea rdi, [rel aux_fcb]
    mov rax, 0x2900
    int 0x21
    cmp al, 0
    jne .fail70
    xor eax, eax
    jmp .done70
.fail70:
    mov rax, 1
.done70:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 71: FCB create/write/read/rename/delete round-trip on SCRATCH.
;   DESTRUCTIVE: real-volume writes in the reserved test namespace
;   (SCRATCH.TXT + RENAMED.TXT, see include/fs.inc). Only runs under
;   SELFTEST_DESTRUCTIVE; smoke prints SKIP instead (see dispatch above).
;   Recovery is mount-time + idempotent: pre-clean deletes both names,
;   discards RAM (like a reboot), reclaims orphans, heals mirrors and
;   scrubs, so an interrupted run (torn FAT/root/data windows) cannot
;   poison the next boot. Pre- and post- phases verify non-test files
;   (HELLO.TXT + README.TXT) are intact and the volume is scrub-clean
;   with mirrors matching, so a failed/interrupted cycle cannot destroy
;   non-test files. Final state is clean (both names gone, orphans 0)
;   for the shell.
; ------------------------------------------------------------
test_fcb_write:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    ; ---- Reserved-namespace recovery (idempotent after interrupt) ----
    mov dword [rel fs_fault_inject], 0
    call fs_mount_volume64
    test rax, rax
    jnz .fail71
    ; clearing deletes first (ignore results: gone already is fine).
    lea rsi, [rel fcb_str_scratch]
    lea rdi, [rel aux_fcb]
    mov al, 1                          ; skip leading seps (none here)
    call handler_makefcb
    lea rdx, [rel aux_fcb]
    call handler_delete                ; ignore
    lea rsi, [rel fcb_str_renamed]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call handler_makefcb
    lea rdx, [rel aux_fcb]
    call handler_delete                ; ignore
    ; discard + remount: drop RAM caches like a reboot (heals FAT2).
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .fail71
    ; reclaim orphans leaked by a torn extend/delete (must not fail).
    call fs_vol_reclaim_orphans64
    jc .fail71
    call fs_vol_heal_mirrors64
    test rax, rax
    jnz .fail71
    ; scrub must be clean with 0 orphans after reclaim.
    call fs_vol_scrub64
    test rax, rax
    jnz .fail71
    test rcx, rcx
    jnz .fail71
    jc .fail71
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail71
    ; non-test preservation: HELLO + README still readable after recovery.
    lea rdi, [rel vol_name_hello]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail71
    cmp rax, 32
    jb .fail71
    lea rdi, [rel vol_name_readme]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail71
    cmp rax, 1000
    jne .fail71
    ; Rebuild SCRATCH FCB (pre-clean left RENAMED in aux_fcb).
    lea rsi, [rel fcb_str_scratch]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call handler_makefcb
    ; CREATE
    lea rdx, [rel aux_fcb]
    call handler_create
    jc .fail71
    test al, al
    jnz .fail71
    cmp dword [rel aux_fcb + FCB64.filsiz], 0      ; filsiz 0
    jne .fail71
    ; Fill DMA half 2 (vol_read_buf+512) with 512B pattern 'A'+i%26
    ; (4 records of 128). NOTE: SEQ ops transfer exactly one record at
    ; the current DMA (DOS semantics); only block ops stride DMA.
    lea rdi, [rel vol_read_buf+512]
    mov rcx, 512
    mov al, 'A'
    mov r8, rdi
.pat71:
    mov [r8], al
    inc r8
    inc al
    cmp al, 'Z'+1
    jne .nowrap71
    mov al, 'A'
.nowrap71:
    dec rcx
    jnz .pat71
    ; BLKWRT 3 records at RR=0 from DMA half 2.
    lea rdx, [rel vol_read_buf+512]
    call handler_setdma
    mov qword [rel aux_fcb + FCB64.rr], 0      ; RR=0
    mov rcx, 3
    lea rdx, [rel aux_fcb]
    call handler_blkwrt
    jc .fail71
    cmp rcx, 3
    jne .fail71
    cmp qword [rel aux_fcb + FCB64.rr], 3     ; RR advanced by block count
    jne .fail71
    cmp dword [rel aux_fcb + FCB64.filsiz], 384   ; filsiz grew
    jne .fail71
    ; SEQWRT 1 record at P=3 (extent=0,nr=3) from DMA buf+896.
    lea rdx, [rel vol_read_buf+896]
    call handler_setdma
    mov word [rel aux_fcb + FCB64.extent], 0      ; extent
    mov byte [rel aux_fcb + FCB64.nr], 3          ; nr
    lea rdx, [rel aux_fcb]
    call handler_seqwrt
    jc .fail71
    test al, al
    jnz .fail71
    cmp dword [rel aux_fcb + FCB64.filsiz], 512   ; filsiz grew to 4 records
    jne .fail71
    ; Read back via BLKRD into half 1 (zeroed first).
    lea rdi, [rel vol_read_buf]
    mov rcx, 512
    xor al, al
.zero71:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .zero71
    lea rdx, [rel vol_read_buf]
    call handler_setdma
    mov qword [rel aux_fcb + FCB64.rr], 0
    mov rcx, 4
    lea rdx, [rel aux_fcb]
    call handler_blkrd
    jc .fail71
    cmp rcx, 4
    jne .fail71
    cmp qword [rel aux_fcb + FCB64.rr], 4     ; RR advanced by block count
    jne .fail71
    ; Verify 512 bytes against the pattern.
    lea rsi, [rel vol_read_buf]
    mov rcx, 512
    mov al, 'A'
    mov r8, rsi
.vfy71:
    cmp [r8], al
    jne .fail71
    inc r8
    inc al
    cmp al, 'Z'+1
    jne .nowrap71b
    mov al, 'A'
.nowrap71b:
    dec rcx
    jnz .vfy71
    ; SETRNDREC: extent=0,nr=2 -> RR=2; RNDRD RR=2 gives 3rd record.
    mov word [rel aux_fcb + FCB64.extent], 0      ; extent
    mov byte [rel aux_fcb + FCB64.nr], 2          ; nr
    lea rdx, [rel aux_fcb]
    call handler_setrndrec
    jc .fail71
    cmp qword [rel aux_fcb + FCB64.rr], 2
    jne .fail71
    lea rdx, [rel aux_fcb]
    call handler_rndrd
    jc .fail71
    ; 3rd record starts at pattern offset 256: 256 % 26 = 22 -> 'W'.
    cmp byte [rel vol_read_buf], 'W'
    jne .fail71
    ; CLOSE (syncs size), then RENAME to RENAMED TXT.
    lea rdx, [rel aux_fcb]
    call handler_close
    jc .fail71
    lea rsi, [rel fcb_new_renamed]
    lea rdi, [rel aux_fcb + FCB64.recsiz]  ; RENAME 2nd name overlaps recsiz
    mov rcx, 11
    cld
    rep movsb
    lea rdx, [rel aux_fcb]
    call handler_rename
    jc .fail71
    test al, al
    jnz .fail71
    ; Old name gone, new name found.
    lea rsi, [rel fcb_str_scratch]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call handler_makefcb
    lea rdx, [rel aux_fcb]
    call handler_srchfrst
    jnc .fail71
    lea rsi, [rel fcb_str_renamed]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call handler_makefcb
    lea rdx, [rel aux_fcb]
    call handler_srchfrst
    jc .fail71
    ; DELETE renamed; verify gone; double-delete fails.
    lea rdx, [rel aux_fcb]
    call handler_delete
    jc .fail71
    lea rdx, [rel aux_fcb]
    call handler_srchfrst
    jnc .fail71
    lea rdx, [rel aux_fcb]
    call handler_delete
    jnc .fail71
    ; ---- Post-run: reserved namespace clean + non-test intact ----
    ; HELLO + README must survive the destructive cycle unchanged.
    lea rdi, [rel vol_name_hello]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail71
    cmp rax, 32
    jb .fail71
    cmp dword [rel vol_read_buf], 'Hell'
    jne .fail71
    lea rdi, [rel vol_name_readme]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail71
    cmp rax, 1000
    jne .fail71
    cmp dword [rel vol_read_buf], 'MS-D'
    jne .fail71
    ; Volume must be scrub-clean (orphans 0) with mirrors matching.
    call fs_vol_scrub64
    test rax, rax
    jnz .fail71
    test rcx, rcx
    jnz .fail71
    jc .fail71
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail71
    xor eax, eax
    jmp .done71
.fail71:
    mov rax, 1
.done71:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 72: Shell line dispatch (G3) without keyboard.
;   sh_exec_line("DIR")=0, ("TYPE HELLO.TXT")=0, ("TEST")=0 (spawn+reap),
;   ("FOOBAR")=1 (not found, correct handling), ("")=1, ("EXIT")=2.
; ------------------------------------------------------------
test_shell_exec:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [rel shl_dir]
    call sh_exec_line
    test rax, rax
    jnz .fail72
    lea rdi, [rel shl_type]
    call sh_exec_line
    test rax, rax
    jnz .fail72
    lea rdi, [rel shl_test]
    call sh_exec_line
    test rax, rax
    jnz .fail72
    lea rdi, [rel shl_bad]
    call sh_exec_line
    cmp rax, 1
    jne .fail72
    lea rdi, [rel shl_empty]
    call sh_exec_line
    cmp rax, 1
    jne .fail72
    lea rdi, [rel shl_exit]
    call sh_exec_line
    cmp rax, 2
    jne .fail72
    xor eax, eax
    jmp .done72
.fail72:
    mov rax, 1
.done72:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 73: Loader negative paths — proc_verify_image64 must reject
;   corrupt headers gracefully (RAX=2) and proc_load_image64 must
;   refuse them (CF=1), without faulting. Locks in the defensive
;   checks in proc_verify_image64 (image_size, entry, stack, hdr).
; ------------------------------------------------------------
test_neg_verify:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    ; Build a valid EXE64 header + payload size 160 (32 hdr + 128 image)
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+0], 0x34365A4D
    mov dword [rdi+4], 32
    mov qword [rdi+8], 128
    mov dword [rdi+16], 0x10
    mov dword [rdi+20], 1024
    mov qword [rdi+24], 0
    ; Valid EXE64 -> 1
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 1
    jne .fail73
    ; image_size larger than file (1000 > 160) -> 2
    lea rdi, [rel p8_exe_src]
    mov qword [rdi+8], 1000
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; image_size == file size (160 > 160-32 allowed) -> 2
    lea rdi, [rel p8_exe_src]
    mov qword [rdi+8], 160
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; Restore image_size 128
    lea rdi, [rel p8_exe_src]
    mov qword [rdi+8], 128
    ; entry_offset == image_size (128 >= 128) -> 2
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+16], 128
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; entry_offset huge -> 2
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+16], 1000
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; Restore entry 0x10
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+16], 0x10
    ; stack_size > 64K -> 2
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+20], 65537
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; Restore stack 1024
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+20], 1024
    ; bad hdr_size 16 -> 2
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+4], 16
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73b
    ; proc_load_image64 must also refuse the bad header (CF=1), using a
    ; dummy non-zero PSP (fails at verify, before any copy).
    mov rdi, 0x200000
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_load_image64
    jnc .fail73b
    ; Restore hdr_size 32
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+4], 32
    ; zero size -> 2
    lea rsi, [rel p8_exe_src]
    xor edx, edx
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; null src -> 2
    xor esi, esi
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; oversize > 16M -> 2
    lea rsi, [rel p8_exe_src]
    mov rdx, 17*1024*1024
    call proc_verify_image64
    cmp rax, 2
    jne .fail73
    ; valid COM pattern -> 0 (negatives did not break positives)
    lea rdi, [rel p8_com_src]
    mov rcx, 64
    mov al, 0x51
.fill73:
    mov [rdi], al
    inc rdi
    inc al
    dec rcx
    jnz .fill73
    lea rsi, [rel p8_com_src]
    mov rdx, 64
    call proc_verify_image64
    cmp rax, 0
    jne .fail73
    ; valid EXE64 again after restores -> 1
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 1
    jne .fail73
    xor eax, eax
    jmp .done73
.fail73b:
    ; restore hdr_size before failing (leave buffer valid for later)
    push rax
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+4], 32
    pop rax
.fail73:
    mov rax, 1
.done73:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 74: ATA negative paths — out-of-range LBA rejected fast
;   (RAX=1, no hardware wait), strict 1..64 count contract
;   (count 0/65/256/high-bits rejected before any port I/O),
;   pure endpoint validation via ata_validate_range64 (no device I/O),
;   wait helpers terminate (no hang), and a normal MBR read still
;   works afterwards (no state damage).
; ------------------------------------------------------------
test_ata_neg:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; LBA 1<<28 out of range: read must fail fast with RAX=1
    lea rdi, [rel vol_read_buf]
    mov rsi, 0x10000000
    mov rdx, 1
    call ata_read_lba28
    cmp rax, 1
    jne .fail74
    ; Same for write (range check, no media touched)
    lea rdi, [rel vol_read_buf]
    mov rsi, 0x10000000
    mov rdx, 1
    call ata_write_lba28
    cmp rax, 1
    jne .fail74
    ; Max+1 variant also rejected
    lea rdi, [rel vol_read_buf]
    mov rsi, 0x10000001
    mov rdx, 1
    call ata_read_lba28
    cmp rax, 1
    jne .fail74
    ; Strict count contract: 0 rejected (read+write, no I/O issued)
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    xor edx, edx
    call ata_read_lba28
    cmp rax, 1
    jne .fail74
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    xor edx, edx
    call ata_write_lba28
    cmp rax, 1
    jne .fail74
    ; count 65 rejected (read+write)
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 65
    call ata_read_lba28
    cmp rax, 1
    jne .fail74
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 65
    call ata_write_lba28
    cmp rax, 1
    jne .fail74
    ; count 256 rejected (read+write; no 0-means-256 encoding)
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 256
    call ata_read_lba28
    cmp rax, 1
    jne .fail74
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 256
    call ata_write_lba28
    cmp rax, 1
    jne .fail74
    ; high bits of count not discarded: low byte 1 but full RDX > 64
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 0x100000001
    call ata_read_lba28
    cmp rax, 1
    jne .fail74
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 0x101
    call ata_write_lba28
    cmp rax, 1
    jne .fail74
    ; Pure endpoint validation (helper only, no device I/O):
    ; LBA=0x0FFFFFFF,count=1 valid
    mov rsi, 0x0FFFFFFF
    mov rdx, 1
    call ata_validate_range64
    test rax, rax
    jnz .fail74
    ; LBA=0x0FFFFFFF,count=2 wraps past 2^28 -> invalid
    mov rsi, 0x0FFFFFFF
    mov rdx, 2
    call ata_validate_range64
    cmp rax, 1
    jne .fail74
    ; LBA=0x0FFFFFC0,count=64 ends exactly at max -> valid
    mov rsi, 0x0FFFFFC0
    mov rdx, 64
    call ata_validate_range64
    test rax, rax
    jnz .fail74
    ; LBA=0x0FFFFFC1,count=64 ends past max -> invalid
    mov rsi, 0x0FFFFFC1
    mov rdx, 64
    call ata_validate_range64
    cmp rax, 1
    jne .fail74
    ; helper count edges (pure): 0/65/256/high-bits invalid
    xor esi, esi
    xor edx, edx
    call ata_validate_range64
    cmp rax, 1
    jne .fail74
    xor esi, esi
    mov rdx, 65
    call ata_validate_range64
    cmp rax, 1
    jne .fail74
    xor esi, esi
    mov rdx, 256
    call ata_validate_range64
    cmp rax, 1
    jne .fail74
    xor esi, esi
    mov rdx, 0x100000001
    call ata_validate_range64
    cmp rax, 1
    jne .fail74
    ; Wait helpers must return, not hang. Idle drive is not busy/ready.
    call ata_wait_not_busy
    jc .fail74
    call ata_wait_ready
    jc .fail74
    ; DRQ without a command must time out (CF=1) rather than hang.
    ; Reaching the next instruction already proves no-hang; the CF=1
    ; check locks in the timeout path.
    call ata_wait_drq
    jnc .fail74
    ; Normal LBA0 read still works after the rejects (state intact)
    lea rdi, [rel vol_read_buf]
    xor esi, esi
    mov rdx, 1
    call ata_read_lba28
    test rax, rax
    jnz .fail74
    cmp word [rel vol_read_buf+510], 0xAA55
    jne .fail74
    xor eax, eax
    jmp .done74
.fail74:
    mov rax, 1
.done74:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 75: Syscall bounds — AH at/past MAXCOM (0x4C) graceful.
;   0x4C dispatches (kernel EXIT fails CF=1, not bad-path AL=0);
;   0x4D/0xFF return AL=0 CF=0 via dispatch and via CPU INT 0x21.
; ------------------------------------------------------------
test_syscall_bounds:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call syscall_init
    call proc_init64
    ; AH=0x4C (MAXCOM) via dispatch as kernel: dispatched to EXIT which
    ; fails (kernel cannot exit) with CF=1 — proves NOT the bad path.
    clc
    mov rax, 0x4C00
    call syscall_dispatch64
    jnc .fail75
    ; AH=0x4D (MAXCOM+1) via dispatch: bad -> AL=0, CF stays 0
    clc
    mov rax, 0x4D00
    call syscall_dispatch64
    cmp al, 0
    jne .fail75
    jc .fail75
    ; AH=0xFF via dispatch: bad -> AL=0
    clc
    mov rax, 0xFF00
    call syscall_dispatch64
    cmp al, 0
    jne .fail75
    ; AH=0x4D via CPU INT 0x21: bad -> AL=0, no fault
    mov rax, 0x4D00
    int 0x21
    cmp al, 0
    jne .fail75
    ; AH=0xFF via CPU INT 0x21: bad -> AL=0
    mov rax, 0xFF00
    int 0x21
    cmp al, 0
    jne .fail75
    ; AH=0x4C via CPU INT as kernel: dispatched, CF=1 (exit fails)
    mov rax, 0x4C00
    int 0x21
    jnc .fail75
    xor eax, eax
    jmp .done75
.fail75:
    mov rax, 1
.done75:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 76: FAT12/file negative paths — corrupt BPB rejected,
;   bad clusters rejected, NULL/missing reads fail, valid still ok.
;   Geometry boundary (fs_test_geom): FATSz10/Root225/Spc128/1024B/
;   data-end/maxclus rejected with GEOM_ERR before FAT/root reads,
;   valid 1.44M still validates, validator read-only (sentinels intact).
;   All read-only: scratch DPB in p8_file_buf+512, never touches
;   the mounted volume's real DPB/FAT/root.
; ------------------------------------------------------------
test_fs_neg:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    call fs_mount_volume64
    test rax, rax
    jnz .fail76
    ; NULL dest buffer -> CF=1 (no crash)
    lea rdi, [rel vol_name_hello]
    xor esi, esi
    mov rdx, 1024
    call fs_vol_read_file64
    jnc .fail76
    ; Missing file -> CF=1
    lea rdi, [rel vol_name_missing]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jnc .fail76
    ; Corrupt BPB (bytes/sector 123) -> parse fails
    lea rsi, [rel fs_vol_boot]
    lea rdi, [rel p8_file_buf]
    mov rcx, 512
    cld
    rep movsb
    lea rdi, [rel p8_file_buf]
    mov word [rdi+11], 123
    lea rsi, [rel p8_file_buf]
    lea rbp, [rel p8_file_buf+512]
    call fs_bpb_parse64
    cmp rax, 1
    jne .fail76
    ; Zeroed boot sector -> parse fails
    lea rdi, [rel p8_file_buf]
    mov rcx, 512
    xor al, al
    cld
    rep stosb
    lea rsi, [rel p8_file_buf]
    lea rbp, [rel p8_file_buf+512]
    call fs_bpb_parse64
    cmp rax, 1
    jne .fail76
    ; Valid boot sector still parses into scratch DPB (positives intact)
    lea rsi, [rel fs_vol_boot]
    lea rdi, [rel p8_file_buf]
    mov rcx, 512
    cld
    rep movsb
    lea rsi, [rel p8_file_buf]
    lea rbp, [rel p8_file_buf+512]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail76
    ; cluster->LBA rejects 0, 1, huge; accepts 2 (read-only on real DPB)
    lea rbp, [rel fs_vol_dpb]
    xor ebx, ebx
    call fs_cluster_to_lba64
    jnc .fail76
    mov ebx, 1
    call fs_cluster_to_lba64
    jnc .fail76
    mov ebx, 0xFFFFF
    call fs_cluster_to_lba64
    jnc .fail76
    mov ebx, 2
    call fs_cluster_to_lba64
    jc .fail76
    ; FAT get rejects 0, 1; accepts 2
    lea rbp, [rel fs_vol_dpb]
    mov rsi, [rbp+DPB64.fat]
    test rsi, rsi
    jz .fail76
    mov rbx, 0
    call fs_get_cluster64
    jnc .fail76
    mov rbx, 1
    call fs_get_cluster64
    jnc .fail76
    mov rbx, 2
    call fs_get_cluster64
    jc .fail76
    ; Geometry boundary: malformed BPBs rejected before FAT/root reads.
    call fs_test_geom
    test rax, rax
    jnz .fail76
    xor eax, eax
    jmp .done76
.fail76:
    mov rax, 1
.done76:
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 77: BPB table + sentinels — cross-layer malformed-input contracts.
;   Table-driven: each entry mutates one BPB field from a valid 1.44M
;   baseline, then checks parse vs validate expectations:
;     FAT size > fs_vol_fat (FATSz=10 -> GEOM), root > fs_vol_root
;     (Root=225 -> GEOM), cluster bytes > iobuf (Spc=128 -> parse fail,
;     Spc=64 boundary still ok), tot/data-region overflow (stale Tot=100
;     -> GEOM), maxclus beyond FAT bytes (Tot=4112 -> maxclus 4080 -> GEOM).
;   Sentinels: bpb77_pre/post around scratch boot, dpb_post after DPB,
;   plus samples of the real fs_vol_fat/root/iobuf prove the validator
;   never writes to the fixed cache (read-only boundary).
;   Deterministic, no disk I/O, no timing.
; ------------------------------------------------------------
test_bpb_table:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r14
    lea rdi, [rel bpb77_snap]
    mov rax, [rel fs_vol_fat]
    mov [rdi+0], rax
    mov rax, [rel fs_vol_fat+FS_VOL_FAT_BYTES-8]
    mov [rdi+8], rax
    mov rax, [rel fs_vol_root]
    mov [rdi+16], rax
    mov rax, [rel fs_vol_root+FS_VOL_ROOT_BYTES-8]
    mov [rdi+24], rax
    mov rax, [rel fs_vol_iobuf]
    mov [rdi+32], rax
    mov rax, [rel fs_vol_iobuf+FS_VOL_IOBUF_BYTES-8]
    mov [rdi+40], rax
    mov dword [rel bpb77_pre], 0xA5A5A5A5
    mov dword [rel bpb77_pre+4], 0xA5A5A5A5
    mov dword [rel bpb77_pre+8], 0xA5A5A5A5
    mov dword [rel bpb77_pre+12], 0xA5A5A5A5
    mov dword [rel bpb77_post], 0x5A5A5A5A
    mov dword [rel bpb77_post+4], 0x5A5A5A5A
    mov dword [rel bpb77_post+8], 0x5A5A5A5A
    mov dword [rel bpb77_post+12], 0x5A5A5A5A
    mov dword [rel bpb77_dpb_post], 0xA55A5AA5
    mov dword [rel bpb77_dpb_post+4], 0xA55A5AA5
    mov dword [rel bpb77_dpb_post+8], 0xA55A5AA5
    mov dword [rel bpb77_dpb_post+12], 0xA55A5AA5
    lea rdi, [rel bpb77_boot]
    call .bpb77_make_valid
    lea rsi, [rel bpb77_boot]
    lea rbp, [rel bpb77_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail77
    call fs_vol_validate64
    test rax, rax
    jnz .fail77
    lea rbp, [rel bpb77_dpb]
    cmp dword [rbp+DPB64.maxclus], 2848
    jne .fail77
    call .bpb77_check
    test rax, rax
    jnz .fail77
    lea rbx, [rel bpb77_table]
    mov r14, bpb77_count
.loop77:
    test r14, r14
    jz .tabledone77
    lea rdi, [rel bpb77_boot]
    call .bpb77_make_valid
    mov eax, [rbx+0]
    movzx ecx, byte [rbx+4]
    mov edx, [rbx+8]
    cmp ecx, 1
    je .w177
    cmp ecx, 2
    je .w277
    jmp .fail77
.w177:
    lea rdi, [rel bpb77_boot]
    add rdi, rax
    mov [rdi], dl
    jmp .doparse77
.w277:
    lea rdi, [rel bpb77_boot]
    add rdi, rax
    mov [rdi], dx
    jmp .doparse77
.doparse77:
    lea rsi, [rel bpb77_boot]
    lea rbp, [rel bpb77_dpb]
    call fs_bpb_parse64
    movzx ecx, byte [rbx+5]
    cmp ecx, 1
    je .expfail77
    test rax, rax
    jnz .fail77
    call fs_vol_validate64
    movzx ecx, byte [rbx+6]
    cmp ecx, 0
    je .expok77
    cmp ecx, 2
    je .expgeom77
    jmp .fail77
.expfail77:
    test rax, rax
    jz .fail77
    jmp .next77
.expok77:
    test rax, rax
    jnz .fail77
    jmp .next77
.expgeom77:
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .fail77
    jmp .next77
.next77:
    call .bpb77_check
    test rax, rax
    jnz .fail77
    add rbx, 16
    dec r14
    jmp .loop77
.tabledone77:
    lea rdi, [rel bpb77_boot]
    call .bpb77_make_valid
    lea rsi, [rel bpb77_boot]
    lea rbp, [rel bpb77_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail77
    mov word [rel bpb77_boot + BPB_TotSec16], 100
    call fs_vol_validate64
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .fail77
    call .bpb77_check
    test rax, rax
    jnz .fail77
    lea rdi, [rel bpb77_boot]
    call .bpb77_make_valid
    mov byte [rel bpb77_boot + BPB_SecPerClus], 128
    lea rsi, [rel bpb77_boot]
    lea rbp, [rel bpb77_dpb]
    call fs_bpb_parse64
    test rax, rax
    jz .spcparsed77
    jmp .spcok77
.spcparsed77:
    call fs_vol_validate64
    cmp rax, FS_MOUNT_GEOM_ERR
    jne .fail77
.spcok77:
    call .bpb77_check
    test rax, rax
    jnz .fail77
    lea rdi, [rel bpb77_boot]
    call .bpb77_make_valid
    lea rsi, [rel bpb77_boot]
    lea rbp, [rel bpb77_dpb]
    call fs_bpb_parse64
    test rax, rax
    jnz .fail77
    call fs_vol_validate64
    test rax, rax
    jnz .fail77
    call .bpb77_check
    test rax, rax
    jnz .fail77
    xor eax, eax
    jmp .done77
.bpb77_make_valid:
    push rdi
    push rcx
    push rax
    mov rcx, 512
    xor al, al
    cld
    rep stosb
    pop rax
    pop rcx
    pop rdi
    mov word [rdi + BPB_BytsPerSec], 512
    mov byte [rdi + BPB_SecPerClus], 1
    mov word [rdi + BPB_RsvdSecCnt], 1
    mov byte [rdi + BPB_NumFATs], 2
    mov word [rdi + BPB_RootEntCnt], 224
    mov word [rdi + BPB_TotSec16], 2880
    mov byte [rdi + BPB_Media], 0xF0
    mov word [rdi + BPB_FATSz16], 9
    mov word [rdi + BPB_SecPerTrk], 18
    mov word [rdi + BPB_NumHeads], 2
    mov dword [rdi + BPB_HiddSec], 0
    mov dword [rdi + BPB_TotSec32], 0
    mov word [rdi + BPB_BootSig], 0xAA55
    ret
.bpb77_check:
    cmp dword [rel bpb77_pre], 0xA5A5A5A5
    jne .cgfail77
    cmp dword [rel bpb77_pre+4], 0xA5A5A5A5
    jne .cgfail77
    cmp dword [rel bpb77_pre+8], 0xA5A5A5A5
    jne .cgfail77
    cmp dword [rel bpb77_pre+12], 0xA5A5A5A5
    jne .cgfail77
    cmp dword [rel bpb77_post], 0x5A5A5A5A
    jne .cgfail77
    cmp dword [rel bpb77_post+4], 0x5A5A5A5A
    jne .cgfail77
    cmp dword [rel bpb77_post+8], 0x5A5A5A5A
    jne .cgfail77
    cmp dword [rel bpb77_post+12], 0x5A5A5A5A
    jne .cgfail77
    cmp dword [rel bpb77_dpb_post], 0xA55A5AA5
    jne .cgfail77
    cmp dword [rel bpb77_dpb_post+4], 0xA55A5AA5
    jne .cgfail77
    cmp dword [rel bpb77_dpb_post+8], 0xA55A5AA5
    jne .cgfail77
    cmp dword [rel bpb77_dpb_post+12], 0xA55A5AA5
    jne .cgfail77
    lea rdi, [rel bpb77_snap]
    mov rax, [rel fs_vol_fat]
    cmp rax, [rdi+0]
    jne .cgfail77
    mov rax, [rel fs_vol_fat+FS_VOL_FAT_BYTES-8]
    cmp rax, [rdi+8]
    jne .cgfail77
    mov rax, [rel fs_vol_root]
    cmp rax, [rdi+16]
    jne .cgfail77
    mov rax, [rel fs_vol_root+FS_VOL_ROOT_BYTES-8]
    cmp rax, [rdi+24]
    jne .cgfail77
    mov rax, [rel fs_vol_iobuf]
    cmp rax, [rdi+32]
    jne .cgfail77
    mov rax, [rel fs_vol_iobuf+FS_VOL_IOBUF_BYTES-8]
    cmp rax, [rdi+40]
    jne .cgfail77
    xor eax, eax
    ret
.cgfail77:
    mov rax, 1
    ret
.fail77:
    mov rax, 1
.done77:
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 78: ATA pure table — endpoint/count contract without hardware.
;   Table-driven ata_validate_range64: LBA 0..0x0FFFFFFF, count strict
;   1..64, endpoint LBA+count-1 <= 0x0FFFFFFF with no 64-bit wrap.
;   Covers count 0/65/256/high-bits, LBA max/max+1/huge, exact-fit
;   0x0FFFFFC0+64, endpoint inclusive 0x0FFFFFFE+2 vs past-max +3.
;   Also proves the helper preserves all other registers (R8-R11/RSI/RDX
;   patterns survive) and never issues port I/O. Deterministic, no timing.
; ------------------------------------------------------------
test_ata_table:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r14
    lea rbx, [rel ata78_table]
    mov r14, ata78_count
.loop78:
    test r14, r14
    jz .done78ok
    mov rsi, [rbx+0]
    mov rdx, [rbx+8]
    mov r8, 0x1111111111111111
    mov r9, 0x2222222222222222
    mov r10, 0x3333333333333333
    mov r11, 0x4444444444444444
    call ata_validate_range64
    mov rcx, rax
    mov rax, 0x1111111111111111
    cmp r8, rax
    jne .fail78
    mov rax, 0x2222222222222222
    cmp r9, rax
    jne .fail78
    mov rax, 0x3333333333333333
    cmp r10, rax
    jne .fail78
    mov rax, 0x4444444444444444
    cmp r11, rax
    jne .fail78
    mov rax, [rbx+0]
    cmp rsi, rax
    jne .fail78
    mov rax, [rbx+8]
    cmp rdx, rax
    jne .fail78
    mov rax, [rbx+16]
    cmp rcx, rax
    jne .fail78
    add rbx, 24
    dec r14
    jmp .loop78
.done78ok:
    xor eax, eax
    jmp .done78
.fail78:
    mov rax, 1
.done78:
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 79: FAT chain bounds — cycle/iteration limits, best-effort clear.
;   Synthetic FAT in fat79_buf (guards pre/post prove no overflow) with
;   small maxclus=10 (9 distinct data clusters 2..10). Proves:
;   empty/no-op, valid EOF ok + cleared, exact-fit 9-cluster ok,
;   overlong cycle 2..10->2 corrupt (hops>=maxclus), dangling 2->0 and
;   2->11(>maxclus) terminate ok, NULL RSI/RBP corrupt, maxclus<2 corrupt,
;   self-loop corrupt, all bounded (return) with best-effort clears and
;   valid-again (no sticky state). Pure, no disk I/O, no timing.
; ------------------------------------------------------------
test_chain_bounds:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r14
    mov dword [rel fat79_pre], 0xA5A5A5A5
    mov dword [rel fat79_pre+4], 0xA5A5A5A5
    mov dword [rel fat79_pre+8], 0xA5A5A5A5
    mov dword [rel fat79_pre+12], 0xA5A5A5A5
    mov dword [rel fat79_post], 0x5A5A5A5A
    mov dword [rel fat79_post+4], 0x5A5A5A5A
    mov dword [rel fat79_post+8], 0x5A5A5A5A
    mov dword [rel fat79_post+12], 0x5A5A5A5A
    mov dword [rel fat79_dpb_post], 0xA55A5AA5
    mov dword [rel fat79_dpb_post+4], 0xA55A5AA5
    mov dword [rel fat79_dpb_post+8], 0xA55A5AA5
    mov dword [rel fat79_dpb_post+12], 0xA55A5AA5
    lea rdi, [rel fat79_dpb]
    mov rcx, 64
    xor al, al
    cld
    rep stosb
    lea rbp, [rel fat79_dpb]
    mov dword [rbp+DPB64.maxclus], 10
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rdi, 0
    call fs_chain_free_mem64
    test rax, rax
    jnz .fail79
    jc .fail79
    mov rdi, 1
    call fs_chain_free_mem64
    test rax, rax
    jnz .fail79
    jc .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 3
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jc .fail79
    test rax, rax
    jnz .fail79
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    mov rbx, 3
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 3
    mov rdx, 4
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 4
    mov rdx, 5
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 5
    mov rdx, 6
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 6
    mov rdx, 7
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 7
    mov rdx, 8
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 8
    mov rdx, 9
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 9
    mov rdx, 10
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 10
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jc .fail79
    test rax, rax
    jnz .fail79
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    mov rbx, 10
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 3
    mov rdx, 4
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 4
    mov rdx, 5
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 5
    mov rdx, 6
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 6
    mov rdx, 7
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 7
    mov rdx, 8
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 8
    mov rdx, 9
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 9
    mov rdx, 10
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 10
    mov rdx, 2
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jnc .fail79
    cmp rax, 1
    jne .fail79
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    mov rbx, 10
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 0
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jc .fail79
    test rax, rax
    jnz .fail79
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 11
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jc .fail79
    test rax, rax
    jnz .fail79
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    lea rbp, [rel fat79_dpb]
    mov rdi, 2
    xor esi, esi
    call fs_chain_free_mem64
    jnc .fail79
    cmp rax, 1
    jne .fail79
    lea rsi, [rel fat79_buf]
    mov rdi, 2
    xor ebp, ebp
    call fs_chain_free_mem64
    jnc .fail79
    cmp rax, 1
    jne .fail79
    lea rbp, [rel fat79_dpb]
    mov dword [rbp+DPB64.maxclus], 1
    lea rsi, [rel fat79_buf]
    mov rdi, 2
    call fs_chain_free_mem64
    jnc .fail79
    cmp rax, 1
    jne .fail79
    mov dword [rbp+DPB64.maxclus], 10
    call .fat79_check
    test rax, rax
    jnz .fail79
    lea rbp, [rel fat79_dpb]
    mov dword [rbp+DPB64.maxclus], 2
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 2
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jnc .fail79
    cmp rax, 1
    jne .fail79
    mov rbx, 2
    call fs_get_cluster64
    test rax, rax
    jnz .fail79
    test rdi, rdi
    jnz .fail79
    lea rbp, [rel fat79_dpb]
    mov dword [rbp+DPB64.maxclus], 10
    call .fat79_check
    test rax, rax
    jnz .fail79
    call .fat79_zero
    lea rsi, [rel fat79_buf]
    lea rbp, [rel fat79_dpb]
    mov rbx, 2
    mov rdx, 3
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rbx, 3
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail79
    mov rdi, 2
    call fs_chain_free_mem64
    jc .fail79
    test rax, rax
    jnz .fail79
    call .fat79_check
    test rax, rax
    jnz .fail79
    xor eax, eax
    jmp .done79
.fat79_zero:
    push rdi
    push rcx
    push rax
    lea rdi, [rel fat79_buf]
    mov rcx, 128
    xor al, al
    cld
    rep stosb
    pop rax
    pop rcx
    pop rdi
    ret
.fat79_check:
    cmp dword [rel fat79_pre], 0xA5A5A5A5
    jne .fc79fail
    cmp dword [rel fat79_pre+4], 0xA5A5A5A5
    jne .fc79fail
    cmp dword [rel fat79_pre+8], 0xA5A5A5A5
    jne .fc79fail
    cmp dword [rel fat79_pre+12], 0xA5A5A5A5
    jne .fc79fail
    cmp dword [rel fat79_post], 0x5A5A5A5A
    jne .fc79fail
    cmp dword [rel fat79_post+4], 0x5A5A5A5A
    jne .fc79fail
    cmp dword [rel fat79_post+8], 0x5A5A5A5A
    jne .fc79fail
    cmp dword [rel fat79_post+12], 0x5A5A5A5A
    jne .fc79fail
    cmp dword [rel fat79_dpb_post], 0xA55A5AA5
    jne .fc79fail
    cmp dword [rel fat79_dpb_post+4], 0xA55A5AA5
    jne .fc79fail
    cmp dword [rel fat79_dpb_post+8], 0xA55A5AA5
    jne .fc79fail
    cmp dword [rel fat79_dpb_post+12], 0xA55A5AA5
    jne .fc79fail
    xor eax, eax
    ret
.fc79fail:
    mov rax, 1
    ret
.fail79:
    mov rax, 1
.done79:
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 80: Allocator arithmetic table — near-UINT64_MAX boundaries.
;   Table-driven mem_alloc64 sizes (each from an empty heap via
;   mem_reset64, so success is deterministic): 0 fail, 1/16 ok,
;   6M-48 ok (max fitting: header 40 + 16-align), 6M fail (capacity),
;   100M fail, UINT64_MAX / MAX-14 (wraps size+15 to 0) / MAX-15
;   (rounds huge) / 2^63-1 fail via overflow-or-capacity with the chain
;   intact (validate 0, single Z after fails). Then aligned (4096 ok +
;   aligned, huge/4G-align fail), pages (1 ok, MAX/2^52 fail), resize
;   (512 ok, MAX/MAX-14/10M fail with CF, chain intact). Then AH=48h/49h/
;   4Ah compat overflow: checked para->bytes just below/at MAX>>4,
;   overflow by one/many bits, valid large (1M para=16M, MAX>>4) rejected
;   by heap capacity rather than wrap, plus FREE/RESIZE compat overflow
;   (including FREE base-add wrap) — every rejection leaves validate 0
;   and a single Z block where the heap was reset. No timing.
; ------------------------------------------------------------
test_alloc_table:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r14
    lea rbx, [rel alloc80_table]
    mov r14, alloc80_count
.loop80:
    test r14, r14
    jz .tabledone80
    mov r10, [rbx+8]
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, [rbx+0]
    call mem_alloc64
    mov r11, rax
    cmp r10, 0
    je .expfail80
    test r11, r11
    jz .fail80
    cmp r11, 0x200000
    jb .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, r11
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    jmp .next80
.expfail80:
    test r11, r11
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
.next80:
    add rbx, 16
    dec r14
    jmp .loop80
.tabledone80:
    call mem_reset64
    mov rdi, 16
    mov rsi, 4096
    call mem_alloc_aligned64
    test rax, rax
    jz .fail80
    test rax, 0xFFF
    jnz .fail80
    mov rdi, rax
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, -1
    mov rsi, 4096
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, 16
    mov rsi, 1
    shl rsi, 32
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, -16
    mov rsi, 4096
    call mem_alloc_aligned64
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, 1
    call mem_alloc_pages64
    test rax, rax
    jz .fail80
    mov rdi, rax
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, -1
    call mem_alloc_pages64
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, 1
    shl rdi, 52
    call mem_alloc_pages64
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail80
    mov rbx, rax
    mov rdi, rax
    mov rsi, 512
    call mem_resize64
    jc .fail80
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, rbx
    mov rsi, -1
    call mem_resize64
    jnc .fail80
    test rax, rax
    jz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, rbx
    mov rsi, -15
    call mem_resize64
    jnc .fail80
    test rax, rax
    jz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, rbx
    mov rsi, 10*1024*1024
    call mem_resize64
    jnc .fail80
    test rax, rax
    jz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, rbx
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; ---- AH=48h/49h/4Ah compat overflow: checked para->bytes ----
    ; All cases run from a known heap (mem_reset64) and every rejected
    ; operation must leave mem_validate64 == 0 (heap untouched).
    ; Valid large convertible values must fail via heap capacity, while
    ; values above UINT64_MAX>>4 must fail via overflow rejection — in
    ; both cases a clean CF=1 failure, never a wrapped small success.
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; valid small compat ALLOC: 16 para -> 256B succeeds, then free
    xor rdi, rdi
    mov rbx, 16
    call handler_alloc_mem
    jc .fail80
    test rax, rax
    jz .fail80
    cmp rax, 0x200000
    jb .fail80
    mov r10, rax
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, r10
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; valid large convertible but over-capacity: 1M para = 16M bytes
    ; (0x100000<<4 = 0x1000000, no wrap) must fail via capacity
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, 0x100000
    call handler_alloc_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
    ; max convertible para (MAX>>4) -> bytes MAX-15: checked ok, alloc
    ; must fail via capacity (heap 6M), never wrap to a small success
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, 0x0FFFFFFFFFFFFFFF
    call handler_alloc_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
    ; overflow by exactly one (MAX>>4 +1) must fail via overflow rejection
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, 0x1000000000000000
    call handler_alloc_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
    ; overflow by many bits (UINT64_MAX) must fail, heap intact
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, -1
    call handler_alloc_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
    ; wrap-to-small: huge para whose low bits survive must NOT become a
    ; small success (old unchecked SHL 4 wrapped). 2^60+1 -> 0x10 (16B)
    ; and 2^60+16 -> 0x100 (256B) would both succeed unchecked; checked
    ; must reject with heap intact.
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, 0x1000000000000001
    call handler_alloc_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
    xor rdi, rdi
    mov rbx, 0x1000000000000010
    call handler_alloc_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_count_blocks64
    cmp rax, 1
    jne .fail80
    ; FREE compat overflow: RDI=0 forces para path, huge RBX must fail
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, 0x1000000000000000
    call handler_free_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor rdi, rdi
    mov rbx, -1
    call handler_free_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; FREE second-stage: max para shifts ok but +0x200000 base wraps,
    ; must still fail cleanly
    xor rdi, rdi
    mov rbx, 0x0FFFFFFFFFFFFFFF
    call handler_free_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; FREE wrap-to-small: allocate first block (deterministic 0x200028
    ; from empty heap: 0x200000 + 40B MCB64 header), then a huge RBX with
    ; identical low 60 bits wraps to the same low bytes unchecked.
    ; Checked must reject before computing linear and keep it live.
    call mem_reset64
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail80
    mov r10, rax
    cmp r10, 0x200028
    jne .fail80
    xor rdi, rdi
    mov rbx, 0x1000000000000002
    call handler_free_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; block must still be live: direct free succeeds, then double-free fails
    mov rdi, r10
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; RESIZE compat: alloc 256B, then overflowing compat sizes must fail
    call mem_reset64
    mov rdi, 256
    call mem_alloc64
    test rax, rax
    jz .fail80
    mov r10, rax
    mov rdi, r10
    xor rsi, rsi
    mov rbx, 0x1000000000000000
    call handler_resize_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, r10
    xor rsi, rsi
    mov rbx, -1
    call handler_resize_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; RESIZE wrap-to-small: 2^60+1 -> 16B would shrink unchecked; must fail
    mov rdi, r10
    xor rsi, rsi
    mov rbx, 0x1000000000000001
    call handler_resize_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; RESIZE compat large convertible but over-capacity (1M para=16M)
    ; must fail via capacity, heap intact
    mov rdi, r10
    xor rsi, rsi
    mov rbx, 0x100000
    call handler_resize_mem
    jnc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    ; RESIZE compat valid small: 32 para = 512B grows 256->512
    mov rdi, r10
    xor rsi, rsi
    mov rbx, 32
    call handler_resize_mem
    jc .fail80
    test rax, rax
    jnz .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    mov rdi, r10
    call mem_free64
    jc .fail80
    call mem_validate64
    test rax, rax
    jnz .fail80
    call mem_reset64
    call mem_validate64
    test rax, rax
    jnz .fail80
    xor eax, eax
    jmp .done80
.fail80:
    mov rax, 1
.done80:
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 81: Queue interleave — empty/full/wrap state machine + IF preserve.
;   Pure queue logic (no hardware, no timing): empty pop fails, single
;   push/pop round-trip, 500x alternating push/pop at the empty boundary
;   (no drops/reorders/count drift), 127-fill + 100x push/pop at the full
;   boundary with exact FIFO order (V0..V126 then P0..P99), drain of the
;   remaining 127 in order, wraparound 100x0x55 drain + 50x0x80+i wrap
;   past 127, IF preservation (push/pop/flush leave IF as found) and
;   nested cli (outer cli + inner calls keep IF=0, restore to found).
;   Ends flushed (clean for later tests/shell).
; ------------------------------------------------------------
test_queue_interleave:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r14
    call kbd_flush
    call kbd_queue_pop
    jnc .fail81
    mov al, 0x1E
    call kbd_queue_push
    jc .fail81
    call kbd_queue_pop
    jc .fail81
    cmp al, 0x1E
    jne .fail81
    call kbd_queue_pop
    jnc .fail81
    mov ecx, 500
    xor ebx, ebx
.alt81:
    mov al, bl
    call kbd_queue_push
    jc .fail81
    call kbd_queue_pop
    jc .fail81
    cmp al, bl
    jne .fail81
    inc bl
    dec ecx
    jnz .alt81
    call kbd_queue_pop
    jnc .fail81
    call kbd_flush
    mov ecx, 127
    xor ebx, ebx
.fill127_81:
    mov al, bl
    call kbd_queue_push
    jc .fail81
    inc bl
    dec ecx
    jnz .fill127_81
    mov ecx, 100
    xor ebx, ebx
.altfull81:
    mov al, bl
    and al, 0x7F
    or al, 0x80
    mov r8b, bl
    call kbd_queue_push
    jc .fail81
    call kbd_queue_pop
    jc .fail81
    cmp al, r8b
    jne .fail81
    inc bl
    dec ecx
    jnz .altfull81
    mov ecx, 27
    mov ebx, 100
.drain1_81:
    call kbd_queue_pop
    jc .fail81
    cmp al, bl
    jne .fail81
    inc bl
    dec ecx
    jnz .drain1_81
    mov ecx, 100
    xor ebx, ebx
.drain2_81:
    call kbd_queue_pop
    jc .fail81
    mov dl, al
    mov al, bl
    and al, 0x7F
    or al, 0x80
    cmp dl, al
    jne .fail81
    inc bl
    dec ecx
    jnz .drain2_81
    call kbd_queue_pop
    jnc .fail81
    call kbd_flush
    mov ecx, 100
    mov al, 0x55
.adv81:
    call kbd_queue_push
    jc .fail81
    dec ecx
    jnz .adv81
    mov ecx, 100
.advd81:
    call kbd_queue_pop
    jc .fail81
    cmp al, 0x55
    jne .fail81
    dec ecx
    jnz .advd81
    xor ebx, ebx
    mov ecx, 50
.fillw81:
    mov al, bl
    add al, 0x80
    call kbd_queue_push
    jc .fail81
    inc bl
    dec ecx
    jnz .fillw81
    xor ebx, ebx
    mov ecx, 50
.drainw81:
    call kbd_queue_pop
    jc .fail81
    mov dl, al
    mov al, bl
    add al, 0x80
    cmp dl, al
    jne .fail81
    inc bl
    dec ecx
    jnz .drainw81
    pushfq
    pop rax
    and rax, 0x200
    mov r14, rax
    mov al, 0x1E
    call kbd_queue_push
    jc .fail81
    pushfq
    pop rax
    and rax, 0x200
    cmp rax, r14
    jne .fail81
    call kbd_queue_pop
    jc .fail81
    pushfq
    pop rax
    and rax, 0x200
    cmp rax, r14
    jne .fail81
    call kbd_flush
    pushfq
    pop rax
    and rax, 0x200
    cmp rax, r14
    jne .fail81
    pushfq
    cli
    pushfq
    pop rax
    test rax, 0x200
    jnz .fail81outer
    mov al, 0x33
    call kbd_queue_push
    jc .fail81outer
    pushfq
    pop rax
    test rax, 0x200
    jnz .fail81outer
    call kbd_queue_pop
    jc .fail81outer
    cmp al, 0x33
    jne .fail81outer
    pushfq
    pop rax
    test rax, 0x200
    jnz .fail81outer
    popfq
    pushfq
    pop rax
    and rax, 0x200
    cmp rax, r14
    jne .fail81
    call kbd_flush
    xor eax, eax
    jmp .done81
.fail81outer:
    popfq
    jmp .fail81
.fail81:
    mov r11, 1
    jmp .flush81
.done81:
    xor r11d, r11d
.flush81:
    call kbd_flush
    mov rax, r11
.done81ret:
    pop r14
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 82: Layout invariants — same arithmetic as make check-layout.
;   Locks the canonical disk layout ( IMG 10M, secsiz 512, kernel 16+176,
;   volume 512+2880, FAT 4608 / root 7168 / iobuf 32768 ) and proves the
;   build-time predicates at runtime, pure arithmetic, no disk I/O:
;     kernel_end=16+176<=512, volume_end=3392*512<=10M, aliases
;     FS_VOL_LBA==VOL_LBA, scratch 200/500/501/510/511 clear of kernel
;     [16,192) and volume [512,3392), FAT 9sec / root 14sec <=64 (ATA
;     1..64 contract for the mount reads). Negative tables prove the same
;   predicates reject off-by-one overlaps (511, 500+extents) and oversize
;   volumes (1M image, 20000 sectors). Deterministic, no timing.
; ------------------------------------------------------------
test_layout:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r14
    mov eax, IMG_MB
    cmp eax, 10
    jne .fail82
    mov eax, IMG_SECTOR_SIZE
    cmp eax, 512
    jne .fail82
    mov eax, KERNEL_LBA
    cmp eax, 16
    jne .fail82
    mov eax, KERNEL_SECTORS
    cmp eax, 176
    jne .fail82
    mov eax, VOL_LBA
    cmp eax, 512
    jne .fail82
    mov eax, VOL_SECTORS
    cmp eax, 2880
    jne .fail82
    mov eax, FS_VOL_LBA
    cmp eax, 512
    jne .fail82
    mov eax, FS_VOL_TOTSEC
    cmp eax, 2880
    jne .fail82
    mov eax, FS_VOL_FAT_BYTES
    cmp eax, 4608
    jne .fail82
    mov eax, FS_VOL_ROOT_BYTES
    cmp eax, 7168
    jne .fail82
    mov eax, FS_VOL_IOBUF_BYTES
    cmp eax, 32768
    jne .fail82
    mov eax, FS_VOL_BOOT_BYTES
    cmp eax, 512
    jne .fail82
    mov eax, FS_VOL_SECSIZ
    cmp eax, 512
    jne .fail82
    mov eax, KERNEL_LBA
    add eax, KERNEL_SECTORS
    cmp eax, VOL_LBA
    ja .fail82
    mov rax, VOL_LBA
    add rax, VOL_SECTORS
    jc .fail82
    imul rax, 512
    jc .fail82
    mov rbx, IMG_MB
    imul rbx, 1024*1024
    cmp rax, rbx
    ja .fail82
    mov eax, FS_VOL_LBA
    cmp eax, VOL_LBA
    jne .fail82
    mov eax, FS_VOL_TOTSEC
    cmp eax, VOL_SECTORS
    jne .fail82
    mov eax, 200
    cmp eax, KERNEL_LBA
    jb .s200v82
    mov ebx, KERNEL_LBA
    add ebx, KERNEL_SECTORS
    cmp eax, ebx
    jb .fail82
.s200v82:
    cmp eax, VOL_LBA
    jb .s200ok82
    mov ebx, VOL_LBA
    add ebx, VOL_SECTORS
    cmp eax, ebx
    jb .fail82
.s200ok82:
    mov eax, 500
    cmp eax, KERNEL_LBA
    jb .s500v82
    mov ebx, KERNEL_LBA
    add ebx, KERNEL_SECTORS
    cmp eax, ebx
    jb .fail82
.s500v82:
    cmp eax, VOL_LBA
    jb .s500ok82
    mov ebx, VOL_LBA
    add ebx, VOL_SECTORS
    cmp eax, ebx
    jb .fail82
.s500ok82:
    mov eax, 501
    cmp eax, KERNEL_LBA
    jb .s501v82
    mov ebx, KERNEL_LBA
    add ebx, KERNEL_SECTORS
    cmp eax, ebx
    jb .fail82
.s501v82:
    cmp eax, VOL_LBA
    jb .s501ok82
    mov ebx, VOL_LBA
    add ebx, VOL_SECTORS
    cmp eax, ebx
    jb .fail82
.s501ok82:
    mov eax, 510
    cmp eax, KERNEL_LBA
    jb .s510v82
    mov ebx, KERNEL_LBA
    add ebx, KERNEL_SECTORS
    cmp eax, ebx
    jb .fail82
.s510v82:
    cmp eax, VOL_LBA
    jb .s510ok82
    mov ebx, VOL_LBA
    add ebx, VOL_SECTORS
    cmp eax, ebx
    jb .fail82
.s510ok82:
    mov eax, 511
    cmp eax, KERNEL_LBA
    jb .s511v82
    mov ebx, KERNEL_LBA
    add ebx, KERNEL_SECTORS
    cmp eax, ebx
    jb .fail82
.s511v82:
    cmp eax, VOL_LBA
    jb .s511ok82
    mov ebx, VOL_LBA
    add ebx, VOL_SECTORS
    cmp eax, ebx
    jb .fail82
.s511ok82:
    mov eax, FS_VOL_FAT_BYTES
    xor edx, edx
    mov ecx, 512
    div ecx
    test edx, edx
    jnz .fail82
    cmp eax, 64
    ja .fail82
    cmp eax, 9
    jne .fail82
    mov eax, FS_VOL_ROOT_BYTES
    xor edx, edx
    mov ecx, 512
    div ecx
    test edx, edx
    jnz .fail82
    cmp eax, 64
    ja .fail82
    cmp eax, 14
    jne .fail82
    lea rbx, [rel layout82_ext_table]
    mov r14, layout82_ext_count
.loopext82:
    test r14, r14
    jz .extdone82
    mov eax, [rbx+0]
    mov ecx, [rbx+4]
    mov edx, [rbx+8]
    mov esi, [rbx+12]
    add eax, ecx
    jc .extfail82
    cmp eax, edx
    jbe .extpass82
.extfail82:
    cmp esi, 1
    jne .fail82
    jmp .extnext82
.extpass82:
    cmp esi, 0
    jne .fail82
.extnext82:
    add rbx, 16
    dec r14
    jmp .loopext82
.extdone82:
    lea rbx, [rel layout82_fit_table]
    mov r14, layout82_fit_count
.loopfit82:
    test r14, r14
    jz .fitdone82
    mov eax, [rbx+0]
    mov ecx, [rbx+4]
    mov edx, [rbx+8]
    mov esi, [rbx+12]
    mov rax, rax
    mov rcx, rcx
    add rax, rcx
    jc .fitfail82
    imul rax, 512
    jc .fitfail82
    mov rcx, rdx
    imul rcx, 1024*1024
    cmp rax, rcx
    jbe .fitpass82
.fitfail82:
    cmp esi, 1
    jne .fail82
    jmp .fitnext82
.fitpass82:
    cmp esi, 0
    jne .fail82
.fitnext82:
    add rbx, 16
    dec r14
    jmp .loopfit82
.fitdone82:
    xor eax, eax
    jmp .done82
.fail82:
    mov rax, 1
.done82:
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 83: FAT12 crash-consistency — FAT-first order + mirrors + scrub.
;   DESTRUCTIVE: real-volume writes in the reserved test namespace
;   (CRASH.TXT, see include/fs.inc). Only runs under SELFTEST_DESTRUCTIVE;
;   smoke prints SKIP instead (see dispatch above).
;   Covers the write-through windows on the real volume with a SCRATCH-
;   like file CRASH.TXT (idempotent pre-clean: delete+reclaim+heal, so a
;   previous aborted run cannot poison the next boot):
;     A. baseline create+write 1 record (128B): scrub clean, mirrors match.
;     B. FAT1 fault on extend (alloc flush fails, rolled back): io must
;        fail CF=1; after clear+discard+remount the file is still the old
;        size with scrub clean and mirrors match (old state kept, never
;        dangling). This is the data-before-FAT window: nothing reached
;        disk, so nothing needs healing.
;     C. ROOT fault on extend (FAT flushed, root skipped): io must fail;
;        after clear+discard+remount the size is still old, scrub reports
;        no DANGLING (FAT-first leaves the new cluster as reachable slack,
;        never a dir pointer to free), mirrors match. Proves the fix for
;        the old root-then-FAT dangling window.
;     D. FAT2 fault via manual RAM link + flush (copy1 new, copy2 old):
;        flush must fail; check_mirrors must report mismatch (1); after
;        clear+discard+remount the mount heals (check 0), scrub is clean
;        with exactly 1 orphan, reclaim frees 1, scrub orphans 0.
;     E. Data-only window: write a pattern to a free cluster's sectors
;        with no FAT/root change; after discard+remount scrub is clean,
;        orphans 0, baseline file intact (stale data in free space is
;        harmless).
;     F. Delete second-flush failure (FAT1 fault on delete: root deleted
;        on disk, FAT still allocated): delete must fail; after
;        clear+discard+remount the name is gone, scrub is clean with
;        1 orphan, reclaim frees 1. Proves delete's root-first leak-only
;        window.
;   Final state is clean (CRASH gone, orphans 0, mirrors match) for the
;   shell. Power-loss here is ordering+heal, NOT transactional (see
;   include/fs.inc); torn multi-sector writes stay deterministic via
;   FAT1-wins healing.
; ------------------------------------------------------------
test_fs_crash:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    ; ---- fill DMA pattern 512B 'A'+i%26 ----
    lea rdi, [rel vol_read_buf]
    mov rcx, 512
    mov al, 'A'
    mov rbx, rdi
.fill83:
    mov [rbx], al
    inc rbx
    inc al
    cmp al, 'Z'+1
    jne .nowrap83
    mov al, 'A'
.nowrap83:
    dec rcx
    jnz .fill83
    ; ---- pre-clean: fault 0, mount, delete CRASH (ignore), reclaim, heal ----
    mov dword [rel fs_fault_inject], 0
    call fs_mount_volume64
    test rax, rax
    jnz .fail83
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    cmp al, 0xFF
    je .fail83
    lea rdi, [rel aux_fcb]
    call fs_fcb_delete64            ; ignore: gone already is fine
    call fs_vol_reclaim_orphans64
    jc .fail83                      ; reclaim itself must not fail
    call fs_vol_heal_mirrors64
    test rax, rax
    jnz .fail83
    call fs_vol_scrub64
    test rax, rax
    jnz .fail83
    test rcx, rcx
    jnz .fail83                     ; pre-clean must leave orphans 0
    jc .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    ; non-test preservation after recovery: HELLO + README intact.
    ; (Uses vol_read_buf as temp; pattern refilled below.)
    lea rdi, [rel vol_name_hello]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail83
    cmp rax, 32
    jb .fail83
    lea rdi, [rel vol_name_readme]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail83
    cmp rax, 1000
    jne .fail83
    ; refill DMA pattern (preservation check clobbered vol_read_buf).
    lea rdi, [rel vol_read_buf]
    mov rcx, 512
    mov al, 'A'
    mov rbx, rdi
.refill83:
    mov [rbx], al
    inc rbx
    inc al
    cmp al, 'Z'+1
    jne .nowrap83b
    mov al, 'A'
.nowrap83b:
    dec rcx
    jnz .refill83
    ; ---- A. baseline: create + write RR=0 (128B) ----
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    cmp al, 0xFF
    je .fail83
    lea rdi, [rel aux_fcb]
    call fs_fcb_create64
    test rax, rax
    jnz .fail83
    jc .fail83
    lea rdi, [rel aux_fcb]
    xor esi, esi                    ; recno 0
    lea rdx, [rel vol_read_buf]
    mov ecx, 1
    mov r8d, 1
    call fs_fcb_io64
    jc .fail83
    cmp rax, 1
    jne .fail83
    mov r12d, [rel aux_fcb + FCB64.firclus]      ; save baseline firstclus
    test r12d, r12d
    jz .fail83
    cmp qword [rel aux_fcb + FCB64.filsiz], 128
    jne .fail83
    call fs_vol_scrub64
    test rax, rax
    jnz .fail83
    test rcx, rcx
    jnz .fail83
    jc .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    ; ---- B. first-flush-fails => second skipped (old state, never dangling) ----
    ; Manual extend in RAM only: data to free cluster F, link H->F->EOF and
    ; size 256 in RAM (no flush yet). Then FAT flush with FAT1 fault must
    ; fail; the caller (here, the test) SKIPS the root flush per the rule,
    ; so after clear+discard+remount the disk still shows the old size
    ; with scrub clean and mirrors match. This is the data-written/FAT-old
    ; window: the new data sits in a free cluster (harmless stale bytes).
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov ecx, [rbp + DPB64.maxclus]
    mov ebx, 2
.scanB83:
    cmp ebx, ecx
    ja near .fail83
    push rcx
    push rbx
    push rsi
    push rbp
    call fs_get_cluster64
    mov r8d, edi
    mov r9d, eax
    pop rbp
    pop rsi
    pop rbx
    pop rcx
    test r9d, r9d
    jnz .fail83
    test r8d, r8d
    jz .foundB83
    inc ebx
    jmp .scanB83
.foundB83:
    mov r13d, ebx                   ; F = free cluster
    lea rbp, [rel fs_vol_dpb]
    mov rbx, r13
    lea rsi, [rel vol_read_buf]
    call fs_file_write_cluster64    ; data reaches disk, no metadata yet
    test rax, rax
    jnz .fail83
    jc .fail83
    ; link H->F->EOF in RAM
    lea rsi, [rel fs_vol_fat]
    lea rbp, [rel fs_vol_dpb]
    mov rbx, r12
    mov rdx, r13
    call fs_set_cluster64
    test rax, rax
    jnz .fail83
    mov rbx, r13
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail83
    ; size 256 in RAM dir entry
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [rel aux_fcb + FCB64.name]
    call fs_dir_find64
    jc .fail83
    mov dword [rbx+28], 256
    ; FAT flush with fault must fail (failure propagates, root skipped)
    mov dword [rel fs_fault_inject], 1
    call fs_vol_flush_fat64
    cmp rax, 1
    jne .fail83
    mov dword [rel fs_fault_inject], 0
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .fail83
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jc .fail83
    test rax, rax
    jnz .fail83
    cmp qword [rel aux_fcb + FCB64.filsiz], 128 ; still old size
    jne .fail83
    mov eax, [rel aux_fcb + FCB64.firclus]
    cmp eax, r12d                   ; still old chain head
    jne .fail83
    call fs_vol_scrub64
    test rax, rax
    jnz .fail83
    test rcx, rcx
    jnz .fail83
    jc .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    ; ---- C. FAT-new/root-old crash leaves slack, never dangling ----
    ; Same RAM extend as B (data + link + size in RAM), but flush ONLY the
    ; FAT (both mirrors, no fault) and deliberately SKIP the root flush to
    ; simulate a reset between them (FAT-first order). After discard+remount
    ; the size is still old, scrub reports no DANGLING (the new cluster is
    ; reachable slack), orphans 0, mirrors match. This is the fix for the
    ; old root-then-FAT dangling window: with FAT-first only leaks occur.
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov ecx, [rbp + DPB64.maxclus]
    mov ebx, 2
.scanC83:
    cmp ebx, ecx
    ja near .fail83
    push rcx
    push rbx
    push rsi
    push rbp
    call fs_get_cluster64
    mov r8d, edi
    mov r9d, eax
    pop rbp
    pop rsi
    pop rbx
    pop rcx
    test r9d, r9d
    jnz .fail83
    test r8d, r8d
    jz .foundC83
    inc ebx
    jmp .scanC83
.foundC83:
    mov r13d, ebx
    lea rbp, [rel fs_vol_dpb]
    mov rbx, r13
    lea rsi, [rel vol_read_buf]
    call fs_file_write_cluster64
    test rax, rax
    jnz .fail83
    jc .fail83
    lea rsi, [rel fs_vol_fat]
    lea rbp, [rel fs_vol_dpb]
    mov rbx, r12
    mov rdx, r13
    call fs_set_cluster64
    test rax, rax
    jnz .fail83
    mov rbx, r13
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail83
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    lea rdi, [rel aux_fcb + FCB64.name]
    call fs_dir_find64
    jc .fail83
    mov dword [rbx+28], 256
    call fs_vol_flush_fat64         ; FAT reaches disk (both mirrors)
    test rax, rax
    jnz .fail83
    ; SKIP root flush: simulated reset here.
    mov dword [rel fs_fault_inject], 0
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .fail83
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jc .fail83
    cmp qword [rel aux_fcb + FCB64.filsiz], 128 ; root still old size
    jne .fail83
    call fs_vol_scrub64             ; must have NO dangling (slack, not dangling)
    test rax, rax
    jnz .fail83
    jc .fail83
    ; orphans must be 0 here (new cluster is reachable slack, not orphan)
    test rcx, rcx
    jnz .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    ; drop the slack file and rebuild a clean 1-cluster baseline for D
    lea rdi, [rel aux_fcb]
    call fs_fcb_delete64
    test rax, rax
    jnz .fail83
    jc .fail83
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    lea rdi, [rel aux_fcb]
    call fs_fcb_create64
    test rax, rax
    jnz .fail83
    jc .fail83
    lea rdi, [rel aux_fcb]
    xor esi, esi
    lea rdx, [rel vol_read_buf]
    mov ecx, 1
    mov r8d, 1
    call fs_fcb_io64
    jc .fail83
    cmp rax, 1
    jne .fail83
    mov r12d, [rel aux_fcb + FCB64.firclus]
    test r12d, r12d
    jz .fail83
    ; ---- D. FAT2 divergence: manual link + flush copy1 only ----
    ; find a free cluster -> R13D
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov ecx, [rbp + DPB64.maxclus]
    mov ebx, 2
.scanD83:
    cmp ebx, ecx
    ja near .fail83
    push rcx
    push rbx
    push rsi
    push rbp
    call fs_get_cluster64
    mov r8d, edi
    mov r9d, eax
    pop rbp
    pop rsi
    pop rbx
    pop rcx
    test r9d, r9d
    jnz .fail83
    test r8d, r8d
    jz .foundD83
    inc ebx
    jmp .scanD83
.foundD83:
    mov r13d, ebx
    ; link it EOF in RAM (no flush yet)
    lea rsi, [rel fs_vol_fat]
    lea rbp, [rel fs_vol_dpb]
    mov rbx, r13
    mov rdx, 0xFFF
    call fs_set_cluster64
    test rax, rax
    jnz .fail83
    ; flush with FAT2 fault: copy1 written, copy2 skipped -> must fail
    mov dword [rel fs_fault_inject], 2
    call fs_vol_flush_fat64
    cmp rax, 1
    jne .fail83
    ; RAM(new) vs disk copy2(old) must report mismatch
    call fs_vol_check_mirrors64
    cmp rax, 1
    jne .fail83
    ; clear + discard + remount (heals FAT2 from FAT1)
    mov dword [rel fs_fault_inject], 0
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    call fs_vol_scrub64
    test rax, rax                   ; clean bits (orphan is leak, not corruption)
    jnz .fail83
    jc .fail83
    cmp rcx, 1                      ; exactly the 1 leaked cluster
    jne .fail83
    call fs_vol_reclaim_orphans64
    jc .fail83
    cmp rax, 1
    jne .fail83
    call fs_vol_scrub64
    test rax, rax
    jnz .fail83
    test rcx, rcx
    jnz .fail83
    jc .fail83
    ; ---- E. data-only window: pattern to a free cluster, no metadata ----
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_fat]
    mov ecx, [rbp + DPB64.maxclus]
    mov ebx, 2
.scanE83:
    cmp ebx, ecx
    ja near .fail83
    push rcx
    push rbx
    push rsi
    push rbp
    call fs_get_cluster64
    mov r8d, edi
    mov r9d, eax
    pop rbp
    pop rsi
    pop rbx
    pop rcx
    test r9d, r9d
    jnz .fail83
    test r8d, r8d
    jz .foundE83
    inc ebx
    jmp .scanE83
.foundE83:
    mov r14d, ebx
    lea rbp, [rel fs_vol_dpb]
    mov rbx, r14
    lea rsi, [rel vol_read_buf]
    call fs_file_write_cluster64
    test rax, rax
    jnz .fail83
    jc .fail83
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .fail83
    call fs_vol_scrub64
    test rax, rax
    jnz .fail83
    test rcx, rcx
    jnz .fail83
    jc .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    ; baseline CRASH still intact at 128B
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jc .fail83
    cmp qword [rel aux_fcb + FCB64.filsiz], 128
    jne .fail83
    ; ---- F. delete with FAT fault: root gone on disk, clusters leaked ----
    mov dword [rel fs_fault_inject], 1
    lea rdi, [rel aux_fcb]
    call fs_fcb_delete64
    jnc .fail83                     ; must fail
    mov dword [rel fs_fault_inject], 0
    call fs_vol_discard64
    call fs_mount_volume64
    test rax, rax
    jnz .fail83
    ; name must be gone from disk
    lea rsi, [rel fcb_str_crash]
    lea rdi, [rel aux_fcb]
    mov al, 1
    call fs_make_fcb64
    jc .fail83
    lea rdi, [rel aux_fcb]
    lea rbp, [rel fs_vol_dpb]
    lea rsi, [rel fs_vol_root]
    call fs_fcb_open64
    jnc .fail83                     ; must NOT be found
    call fs_vol_scrub64
    test rax, rax                   ; clean bits; leak is orphans, not dangling
    jnz .fail83
    jc .fail83
    cmp rcx, 1
    jne .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    call fs_vol_reclaim_orphans64
    jc .fail83
    cmp rax, 1
    jne .fail83
    ; non-test preservation: destructive cycle must not harm HELLO/README.
    lea rdi, [rel vol_name_hello]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail83
    cmp rax, 32
    jb .fail83
    cmp dword [rel vol_read_buf], 'Hell'
    jne .fail83
    lea rdi, [rel vol_name_readme]
    lea rsi, [rel vol_read_buf]
    mov rdx, 1024
    call fs_vol_read_file64
    jc .fail83
    cmp rax, 1000
    jne .fail83
    ; ---- final: clean (gone, orphans 0, mirrors match) ----
    call fs_vol_scrub64
    test rax, rax
    jnz .fail83
    test rcx, rcx
    jnz .fail83
    jc .fail83
    call fs_vol_check_mirrors64
    cmp rax, 0
    jne .fail83
    mov dword [rel fs_fault_inject], 0
    xor eax, eax
    jmp .done83
.fail83:
    mov dword [rel fs_fault_inject], 0
    mov rax, 1
.done83:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 28: PSP init/validate (SETMEM analog, MSDOS.ASM:3363)
; ------------------------------------------------------------
test_psp_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call mem_reset64
    call proc_init64
    ; alloc 4096
    mov rdi, 4096
    call mem_alloc64
    test rax, rax
    jz .fail28
    mov rbx, rax             ; psp
    mov rcx, rbx
    add rcx, 4096            ; top
    mov rdi, rbx
    mov rsi, rcx
    mov rdx, 0x1234
    xor ecx, ecx             ; env 0
    call psp_init64
    test rax, rax
    jnz .fail28
    mov rdi, rbx
    call psp_validate64
    test rax, rax
    jnz .fail28
    ; magic CD 20
    cmp byte [rbx + PSP64.int20], 0xCD
    jne .fail28
    cmp byte [rbx + PSP64.int20+1], 0x20
    jne .fail28
    ; top
    mov rax, [rbx + PSP64.top_mem]
    mov rcx, rbx
    add rcx, 4096
    cmp rax, rcx
    jne .fail28
    ; exit
    cmp qword [rbx + PSP64.exit_ip], 0x1234
    jne .fail28
    cmp qword [rbx + PSP64.exit_cs], 0x08
    jne .fail28
    ; fd table
    cmp qword [rbx + PSP64.fd_table + 0*8], 0
    jne .fail28
    cmp qword [rbx + PSP64.fd_table + 1*8], 1
    jne .fail28
    cmp qword [rbx + PSP64.fd_table + 2*8], 2
    jne .fail28
    mov rax, [rbx + PSP64.fd_table + 3*8]
    cmp rax, -1
    jne .fail28
    ; cr3 non-zero and matches current
    mov rax, cr3
    test rax, rax
    jz .fail28
    mov rcx, [rbx + PSP64.cr3]
    cmp rcx, rax
    jne .fail28
    ; corrupt magic -> validate 1
    mov al, [rbx + PSP64.int20]
    mov byte [rbx + PSP64.int20], 0x00
    mov rdi, rbx
    call psp_validate64
    cmp rax, 1
    jne .fail28_restore
    mov byte [rbx + PSP64.int20], 0xCD
    ; bad top (==psp) -> validate 2
    mov rax, [rbx + PSP64.top_mem]
    push rax
    mov qword [rbx + PSP64.top_mem], 0
    mov rdi, rbx
    call psp_validate64
    cmp rax, 2
    jne .fail28_restore2
    pop rax
    mov [rbx + PSP64.top_mem], rax
    mov rdi, rbx
    call psp_validate64
    test rax, rax
    jnz .fail28
    call mem_validate64
    test rax, rax
    jnz .fail28
    mov rdi, rbx
    call mem_free64
    jc .fail28
    xor eax, eax
    jmp .done28
.fail28_restore2:
    pop rax
    mov [rbx + PSP64.top_mem], rax
    jmp .fail28
.fail28_restore:
    mov byte [rbx + PSP64.int20], 0xCD
    jmp .fail28
.fail28:
    mov rax, 1
.done28:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 29: PSP cmd tail + exit vectors + fd/CR3
; ------------------------------------------------------------
test_psp_cmd:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call mem_reset64
    call proc_init64
    mov rdi, 4096
    call mem_alloc64
    test rax, rax
    jz .fail29
    mov rbx, rax
    mov rcx, rbx
    add rcx, 4096
    mov rdi, rbx
    mov rsi, rcx
    xor edx, edx
    xor ecx, ecx
    call psp_init64
    test rax, rax
    jnz .fail29
    ; set cmd "HELLO WORLD" len 11
    mov rdi, rbx
    lea rsi, [rel p8_cmd_hello]
    mov rdx, 11
    call psp_set_cmdtail64
    test rax, rax
    jnz .fail29
    mov rdi, rbx
    call psp_get_cmdlen64
    cmp rax, 11
    jne .fail29
    cmp byte [rbx + PSP64.cmd_tail], 'H'
    jne .fail29
    cmp byte [rbx + PSP64.cmd_tail+10], 'D'
    jne .fail29
    ; empty cmd
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call psp_set_cmdtail64
    test rax, rax
    jnz .fail29
    mov rdi, rbx
    call psp_get_cmdlen64
    cmp rax, 0
    jne .fail29
    ; restore hello for later checks
    mov rdi, rbx
    lea rsi, [rel p8_cmd_hello]
    mov rdx, 11
    call psp_set_cmdtail64
    test rax, rax
    jnz .fail29
    ; too long 128 -> fail
    mov rdi, rbx
    lea rsi, [rel p8_cmd_hello]
    mov rdx, 128
    call psp_set_cmdtail64
    test rax, rax
    jz .fail29
    ; set exit vectors
    mov rdi, rbx
    mov rsi, 0xAAAA
    mov rdx, 0xBBBB
    mov rcx, 0xCCCC
    call psp_set_exit64
    test rax, rax
    jnz .fail29
    cmp qword [rbx + PSP64.exit_ip], 0xAAAA
    jne .fail29
    cmp qword [rbx + PSP64.cont_ip], 0xBBBB
    jne .fail29
    cmp qword [rbx + PSP64.error_ip], 0xCCCC
    jne .fail29
    mov rdi, rbx
    call psp_validate64
    test rax, rax
    jnz .fail29
    mov rdi, rbx
    call mem_free64
    jc .fail29
    xor eax, eax
    jmp .done29
.fail29:
    mov rax, 1
.done29:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 30: ENV blocks
; ------------------------------------------------------------
test_env:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea rdi, [rel p8_env_buf]
    mov rsi, 1024
    call env_init64
    test rax, rax
    jnz .fail30
    mov al, 'A'
    call print_char_vga_serial
    lea rdi, [rel p8_env_buf]
    call env_count64
    cmp rax, 0
    jne .fail30
    mov al, 'B'
    call print_char_vga_serial
    ; set PATH=/BIN
    lea rdi, [rel p8_env_buf]
    mov rsi, 1024
    lea rdx, [rel p8_env_path]
    lea rcx, [rel p8_env_path_val]
    call env_set64
    test rax, rax
    jnz .fail30
    mov al, 'C'
    call print_char_vga_serial
    ; set COMSPEC
    lea rdi, [rel p8_env_buf]
    mov rsi, 1024
    lea rdx, [rel p8_env_comspec]
    lea rcx, [rel p8_env_comspec_val]
    call env_set64
    test rax, rax
    jnz .fail30
    mov al, 'D'
    call print_char_vga_serial
    ; set PROMPT
    lea rdi, [rel p8_env_buf]
    mov rsi, 1024
    lea rdx, [rel p8_env_prompt]
    lea rcx, [rel p8_env_prompt_val]
    call env_set64
    test rax, rax
    jnz .fail30
    mov al, 'E'
    call print_char_vga_serial
    lea rdi, [rel p8_env_buf]
    call env_count64
    cmp rax, 3
    jne .fail30
    mov al, 'F'
    call print_char_vga_serial
    ; get PATH
    lea rdi, [rel p8_env_buf]
    lea rsi, [rel p8_env_path]
    lea rdx, [rel p8_outbuf]
    mov rcx, 64
    call env_get64
    test rax, rax
    jnz .fail30
    mov al, 'G'
    call print_char_vga_serial
    cmp byte [rel p8_outbuf], '/'
    jne .fail30
    cmp byte [rel p8_outbuf+1], 'B'
    jne .fail30
    mov al, 'H'
    call print_char_vga_serial
    ; overwrite PATH=/NEW
    lea rdi, [rel p8_env_buf]
    mov rsi, 1024
    lea rdx, [rel p8_env_path]
    lea rcx, [rel p8_env_path_val2]
    call env_set64
    test rax, rax
    jnz .fail30
    mov al, 'I'
    call print_char_vga_serial
    lea rdi, [rel p8_env_buf]
    call env_count64
    cmp rax, 3
    jne .fail30
    mov al, 'J'
    call print_char_vga_serial
    lea rdi, [rel p8_env_buf]
    lea rsi, [rel p8_env_path]
    lea rdx, [rel p8_outbuf]
    mov rcx, 64
    call env_get64
    test rax, rax
    jnz .fail30
    mov al, 'K'
    call print_char_vga_serial
    cmp byte [rel p8_outbuf+1], 'N'
    jne .fail30
    mov al, 'L'
    call print_char_vga_serial
    ; unset PROMPT
    lea rdi, [rel p8_env_buf]
    lea rsi, [rel p8_env_prompt]
    call env_unset64
    test rax, rax
    jnz .fail30
    mov al, 'M'
    call print_char_vga_serial
    lea rdi, [rel p8_env_buf]
    call env_count64
    push rax
    call print_num_vga_serial
    pop rax
    cmp rax, 2
    jne .fail30
    mov al, 'N'
    call print_char_vga_serial
    lea rdi, [rel p8_env_buf]
    lea rsi, [rel p8_env_prompt]
    lea rdx, [rel p8_outbuf]
    mov rcx, 64
    call env_get64
    test rax, rax
    jz .fail30
    ; missing -> fail
    lea rdi, [rel p8_env_buf]
    lea rsi, [rel p8_env_missing]
    lea rdx, [rel p8_outbuf]
    mov rcx, 64
    call env_get64
    test rax, rax
    jz .fail30
    ; bad name with '=' -> 2
    lea rdi, [rel p8_env_buf]
    mov rsi, 1024
    lea rdx, [rel p8_env_bad_eq]
    lea rcx, [rel p8_env_path_val]
    call env_set64
    cmp rax, 2
    jne .fail30
    ; no-space with small buf
    lea rdi, [rel p8_env_small]
    mov rsi, 64
    call env_init64
    test rax, rax
    jnz .fail30
    lea rdi, [rel p8_env_small]
    mov rsi, 64
    lea rdx, [rel p8_env_path]
    lea rcx, [rel p8_env_path_val]
    call env_set64
    test rax, rax
    jnz .fail30
    ; fill small until no space: use long value (200 'A's in file_buf)
    lea rdi, [rel p8_file_buf]
    mov rcx, 200
    mov al, 'A'
.fill_small:
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .fill_small
    lea rdi, [rel p8_file_buf+200]
    mov byte [rdi], 0
    lea rdi, [rel p8_env_small]
    mov rsi, 64
    lea rdx, [rel p8_env_comspec]
    lea rcx, [rel p8_file_buf]
    call env_set64
    cmp rax, 1
    jne .fail30
    xor eax, eax
    jmp .done30
.fail30:
    mov rax, 1
.done30:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 31: Loader COM vs EXE64
; ------------------------------------------------------------
test_loader:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    call mem_reset64
    call proc_init64
    ; build COM pattern 256 bytes in p8_com_src
    lea rdi, [rel p8_com_src]
    mov rcx, 256
    mov al, 0xA0
.fill_com31:
    mov [rdi], al
    inc rdi
    inc al
    dec rcx
    jnz .fill_com31
    ; verify COM
    lea rsi, [rel p8_com_src]
    mov rdx, 256
    call proc_verify_image64
    cmp rax, 0
    jne .fail31
    ; alloc PSP 8192 and init
    mov rdi, 8192
    call mem_alloc64
    test rax, rax
    jz .fail31
    mov r12, rax
    mov r13, rax
    add r13, 8192
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    xor ecx, ecx
    call psp_init64
    test rax, rax
    jnz .fail31
    ; load COM
    mov rdi, r12
    lea rsi, [rel p8_com_src]
    mov rdx, 256
    call proc_load_image64
    jc .fail31
    test rax, rax
    jz .fail31
    mov rbx, r12
    add rbx, PSP64_size
    cmp rax, rbx
    jne .fail31
    ; verify copied
    lea rsi, [rel p8_com_src]
    mov rdi, rbx
    mov rcx, 256
.verify_com31:
    mov al, [rsi]
    cmp al, [rdi]
    jne .fail31
    inc rsi
    inc rdi
    dec rcx
    jnz .verify_com31
    ; build EXE64: header + 128 payload in p8_exe_src
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+0], 0x34365A4D
    mov dword [rdi+4], 32
    mov qword [rdi+8], 128
    mov dword [rdi+16], 0x10
    mov dword [rdi+20], 1024
    mov qword [rdi+24], 0
    lea rbx, [rel p8_exe_src+32]
    mov rcx, 128
    mov al, 0xC0
.fill_exe31:
    mov [rbx], al
    inc rbx
    inc al
    dec rcx
    jnz .fill_exe31
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 1
    jne .fail31
    mov rdi, r12
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_load_image64
    jc .fail31
    mov rbx, r12
    add rbx, PSP64_size
    add rbx, 0x10
    cmp rax, rbx
    jne .fail31
    ; verify payload at psp+SIZE matches src+32
    mov rsi, r12
    add rsi, PSP64_size
    lea rdi, [rel p8_exe_src+32]
    mov rcx, 128
.verify_exe31:
    mov al, [rdi]
    cmp al, [rsi]
    jne .fail31
    inc rdi
    inc rsi
    dec rcx
    jnz .verify_exe31
    ; bad: size 0 -> 2
    lea rsi, [rel p8_com_src]
    xor edx, edx
    call proc_verify_image64
    cmp rax, 2
    jne .fail31
    ; bad hdr_size
    lea rdi, [rel p8_exe_src]
    mov eax, [rdi+4]
    push rax
    mov dword [rdi+4], 16
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail31_restore
    pop rax
    mov [rdi+4], eax
    ; oversize image_size
    mov rax, [rdi+8]
    push rax
    mov qword [rdi+8], 1000
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_verify_image64
    cmp rax, 2
    jne .fail31_restore2
    pop rax
    mov [rdi+8], rax
    ; load with bad should fail (CF)
    mov dword [rdi+4], 16
    mov rdi, r12
    lea rsi, [rel p8_exe_src]
    mov rdx, 160
    call proc_load_image64
    jnc .fail31
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+4], 32
    mov rdi, r12
    call mem_free64
    jc .fail31
    xor eax, eax
    jmp .done31
.fail31_restore2:
    pop rax
    lea rdi, [rel p8_exe_src]
    mov [rdi+8], rax
    jmp .fail31
.fail31_restore:
    pop rax
    lea rdi, [rel p8_exe_src]
    mov [rdi+4], eax
    jmp .fail31
.fail31:
    mov rax, 1
.done31:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 32: Spawn/exit lifecycle + owner
; ------------------------------------------------------------
test_spawn:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call mem_reset64
    call proc_init64
    ; build COM 64B pattern
    lea rdi, [rel p8_com_src]
    mov rcx, 64
    mov al, 0x51
.fill_c32:
    mov [rdi], al
    inc rdi
    inc al
    dec rcx
    jnz .fill_c32
    ; build EXE 32+64
    lea rdi, [rel p8_exe_src]
    mov dword [rdi+0], 0x34365A4D
    mov dword [rdi+4], 32
    mov qword [rdi+8], 64
    mov dword [rdi+16], 0
    mov dword [rdi+20], 512
    mov qword [rdi+24], 0
    lea rbx, [rel p8_exe_src+32]
    mov rcx, 64
    mov al, 0x77
.fill_e32:
    mov [rbx], al
    inc rbx
    inc al
    dec rcx
    jnz .fill_e32
    ; spawn COM with cmd ARG1
    lea rdi, [rel p8_com_src]
    mov rsi, 64
    lea rdx, [rel p8_cmd_arg1]
    mov rcx, 4
    xor r8d, r8d
    call proc_spawn64
    push rdx
    push rax
    mov rax, rdx
    call print_num_vga_serial
    pop rax
    pop rdx
    test rax, rax
    jz .fail32
    test rdx, rdx
    jz .fail32
    mov r12, rax             ; pid1
    mov r13, rdx             ; psp1
    mov al, 'a'
    call print_char_vga_serial
    ; verify get_psp
    mov rdi, r12
    call proc_get_psp64
    cmp rax, r13
    jne .fail32
    mov al, 'b'
    call print_char_vga_serial
    ; entry == psp+SIZE
    mov rdi, r12
    call proc_get_entry64
    mov rbx, r13
    add rbx, PSP64_size
    cmp rax, rbx
    jne .fail32
    mov al, 'c'
    call print_char_vga_serial
    ; count running ==2
    call proc_count_running64
    cmp rax, 2
    jne .fail32
    mov al, 'd'
    call print_char_vga_serial
    ; psp validate
    mov rdi, r13
    call psp_validate64
    test rax, rax
    jnz .fail32
    ; cmd len 4
    mov rdi, r13
    call psp_get_cmdlen64
    cmp rax, 4
    jne .fail32
    mov al, 'e'
    call print_char_vga_serial
    ; env non-zero and has PATH
    mov rax, [r13 + PSP64.env_ptr]
    test rax, rax
    jz .fail32
    mov rdi, rax
    lea rsi, [rel p8_env_path]
    lea rdx, [rel p8_outbuf]
    mov rcx, 64
    call env_get64
    test rax, rax
    jnz .fail32
    mov al, 'f'
    call print_char_vga_serial
    ; owner == psp (MCB at psp-MCBSIZ64, owner at +8)
    mov rbx, r13
    sub rbx, 40
    mov rax, [rbx + 8]
    cmp rax, r13
    jne .fail32
    call mem_validate64
    test rax, rax
    jnz .fail32
    mov al, 'g'
    call print_char_vga_serial
    ; spawn EXE
    lea rdi, [rel p8_exe_src]
    mov rsi, 96
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call proc_spawn64
    test rax, rax
    jz .fail32
    mov r14, rax
    mov r15, rdx
    mov al, 'h'
    call print_char_vga_serial
    cmp r14, r12
    je .fail32
    call proc_count_running64
    cmp rax, 3
    jne .fail32
    ; set current to pid1
    mov rdi, r12
    call proc_set_current64
    test rax, rax
    jnz .fail32
    call proc_get_current64
    cmp rax, r12
    jne .fail32
    ; bad pid set fails
    mov rdi, 9999
    call proc_set_current64
    test rax, rax
    jz .fail32
    ; terminate pid1 code 42
    mov rdi, r12
    mov rsi, 42
    call proc_terminate64
    test rax, rax
    jnz .fail32
    call proc_count_running64
    cmp rax, 2
    jne .fail32
    call proc_count_zombie64
    cmp rax, 1
    jne .fail32
    ; double terminate fails
    mov rdi, r12
    mov rsi, 0
    call proc_terminate64
    test rax, rax
    jz .fail32
    ; reap
    mov rdi, r12
    call proc_reap64
    test rax, rax
    jnz .fail32
    call proc_count_zombie64
    cmp rax, 0
    jne .fail32
    mov rdi, r12
    call proc_get_psp64
    test rax, rax
    jnz .fail32
    ; exit_current pid2
    mov rdi, r14
    call proc_set_current64
    test rax, rax
    jnz .fail32
    mov rdi, 99
    call proc_exit_current64
    test rax, rax
    jnz .fail32
    call proc_get_current64
    cmp rax, 0
    jne .fail32
    mov rdi, r14
    call proc_reap64
    test rax, rax
    jnz .fail32
    call proc_count_running64
    cmp rax, 1
    jne .fail32
    call mem_validate64
    test rax, rax
    jnz .fail32
    ; kernel pid0 terminate fails
    xor edi, edi
    mov rsi, 0
    call proc_terminate64
    test rax, rax
    jz .fail32
    ; exit_current as kernel fails
    mov rdi, 5
    call proc_exit_current64
    test rax, rax
    jz .fail32
    call proc_free_all64
    xor eax, eax
    jmp .done32
.fail32:
    mov rax, 1
.done32:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 33: EXEC/EXIT via INT21 dispatch (AH=4Bh/4Ch) + INT20
; ------------------------------------------------------------
test_exec_dispatch:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call mem_reset64
    call proc_init64
    call syscall_init
    ; build COM 32B
    lea rdi, [rel p8_com_src]
    mov rcx, 32
    mov al, 0x99
.fill_c33:
    mov [rdi], al
    inc rdi
    inc al
    dec rcx
    jnz .fill_c33
    ; direct handler_exec
    lea rdi, [rel p8_com_src]
    mov rsi, 32
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call handler_exec
    jc .fail33
    test rax, rax
    jz .fail33
    test rdx, rdx
    jz .fail33
    mov r12, rax
    mov r13, rdx
    mov al, 'p'
    call print_char_vga_serial
    ; via dispatch AH=4Bh
    lea rdi, [rel p8_com_src]
    mov rsi, 32
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    mov rax, 0x4B00
    call syscall_dispatch64
    jc .fail33
    test rax, rax
    jz .fail33
    mov r14, rax             ; pid via dispatch (save before debug print corrupts AL)
    mov al, 'q'
    call print_char_vga_serial
    cmp r14, r12
    je .fail33
    mov al, 'r'
    call print_char_vga_serial
    push rax
    mov rax, r12
    call print_num_vga_serial
    mov rax, r14
    push rax
    mov al, '['
    call print_char_vga_serial
    pop rax
    push rax
    call print_hex16
    mov al, ']'
    call print_char_vga_serial
    pop rax
    mov rax, [rel proc_next_pid]
    call print_num_vga_serial
    mov rax, [rel exec_dbg_pid]
    call print_num_vga_serial
    pop rax
    call proc_count_running64
    push rax
    call print_num_vga_serial
    pop rax
    cmp rax, 3
    jne .fail33
    mov al, 's'
    call print_char_vga_serial
    ; set current to r12 and EXIT via dispatch AH=4Ch AL=5
    mov rdi, r12
    call proc_set_current64
    test rax, rax
    jnz .fail33
    mov al, 't'
    call print_char_vga_serial
    mov rax, 0x4C05
    call syscall_dispatch64
    jc .fail33
    mov al, 'u'
    call print_char_vga_serial
    call proc_count_running64
    cmp rax, 2
    jne .fail33
    mov al, 'v'
    call print_char_vga_serial
    mov rdi, r12
    call proc_reap64
    test rax, rax
    jnz .fail33
    mov al, 'w'
    call print_char_vga_serial
    ; direct handler_exit_process with AL path: set current to r14, RAX=0x4C07
    mov rdi, r14
    call proc_set_current64
    test rax, rax
    jnz .fail33
    mov al, 'x'
    call print_char_vga_serial
    mov rax, 0x4C07
    ; RDI stale? Set RDI to 0xFFFF to force AL path? Our handler uses AL when AH==4Ch regardless of RDI. Good.
    call handler_exit_process
    jc .fail33
    mov al, 'y'
    call print_char_vga_serial
    call proc_get_current64
    cmp rax, 0
    jne .fail33
    mov al, 'z'
    call print_char_vga_serial
    mov rdi, r14
    call proc_reap64
    test rax, rax
    jnz .fail33
    mov al, '!'
    call print_char_vga_serial
    ; INT20 abort: spawn then abort
    lea rdi, [rel p8_com_src]
    mov rsi, 32
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call handler_exec
    jc .fail33
    mov r14, rax
    mov al, '@'
    call print_char_vga_serial
    mov rdi, r14
    call proc_set_current64
    test rax, rax
    jnz .fail33
    mov al, '#'
    call print_char_vga_serial
    call handler_abort
    mov al, '$'
    call print_char_vga_serial
    call proc_count_running64
    cmp rax, 1
    jne .fail33
    mov rdi, r14
    call proc_reap64
    test rax, rax
    jnz .fail33
    ; abort as kernel (current 0) should just return 0, no crash
    call handler_abort
    call mem_validate64
    test rax, rax
    jnz .fail33
    call proc_free_all64
    xor eax, eax
    jmp .done33
.fail33:
    mov rax, 1
.done33:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Test 34: Stress max procs + reap + validate
; ------------------------------------------------------------
test_proc_stress:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    call mem_reset64
    call proc_init64
    ; build small COM 64B
    lea rdi, [rel p8_com_src]
    mov rcx, 64
    mov al, 0x11
.fill_c34:
    mov [rdi], al
    inc rdi
    inc al
    dec rcx
    jnz .fill_c34
    xor r12, r12             ; spawned count
.spawn_loop34:
    cmp r12, 15
    jae .spawn_done34
    lea rdi, [rel p8_com_src]
    mov rsi, 64
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call proc_spawn64
    test rax, rax
    jz .spawn_done34
    inc r12
    jmp .spawn_loop34
.spawn_done34:
    cmp r12, 15
    jne .fail34
    call proc_count_running64
    cmp rax, 16
    jne .fail34
    call proc_alloc_slot64
    cmp rax, -1
    jne .fail34
    ; next spawn must fail (full)
    lea rdi, [rel p8_com_src]
    mov rsi, 64
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call proc_spawn64
    test rax, rax
    jnz .fail34
    ; oversize spawn fails
    lea rdi, [rel p8_com_src]
    mov rsi, 10*1024*1024
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call proc_spawn64
    test rax, rax
    jnz .fail34
    call mem_validate64
    test rax, rax
    jnz .fail34
    ; invalid pid ops fail
    mov rdi, 9999
    mov rsi, 0
    call proc_terminate64
    test rax, rax
    jz .fail34
    mov rdi, 9999
    call proc_reap64
    test rax, rax
    jz .fail34
    ; free all
    call proc_free_all64
    cmp rax, 15
    jne .fail34
    call proc_count_running64
    cmp rax, 1
    jne .fail34
    call proc_count_zombie64
    cmp rax, 0
    jne .fail34
    call mem_validate64
    test rax, rax
    jnz .fail34
    call mem_count_blocks64
    ; after free_all, heap may have many free blocks coalesced? Should be 1 or few. At least validate 1..16.
    test rax, rax
    jz .fail34
    ; double reap fails (already reaped)
    mov rdi, 1
    call proc_reap64
    test rax, rax
    jz .fail34
    xor eax, eax
    jmp .done34
.fail34:
    mov rax, 1
.done34:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Phase9 tests [35]-[42]: System Call Interface (INT 21h IDT gate)
; ------------------------------------------------------------
; Test 35: IDT init/load + INT 0x21 gate via actual INT instruction
test_idt_gate:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call syscall_init
    call kbd_init
    call idt_init64
    test rax, rax
    jnz .fail35
    call idt_test_vectors
    test rax, rax
    jnz .fail35
    call idt_load64
    test rax, rax
    jnz .fail35
    ; verify vectors again after LIDT (table unchanged)
    call idt_test_vectors
    test rax, rax
    jnz .fail35
    ; actual INT 0x21 AH=02 DL='*' — must not fault, must print
    mov rax, 0x0200
    mov dl, '*'
    int 0x21
    ; actual INT 0x21 AH=09 RDX=$-string
    mov rax, 0x0900
    lea rdx, [rel p9_dollar]
    int 0x21
    ; bad function AH=0xFF via INT must return AL=0 (dispatch_bad)
    mov rax, 0xFF00
    int 0x21
    cmp al, 0
    jne .fail35
    xor eax, eax
    jmp .done35
.fail35:
    mov rax, 1
.done35:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 36: Console input 01/08/0B/0C
test_console_in:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call kbd_flush
    ; constat empty -> AL=0
    call handler_constat
    cmp al, 0
    jne .fail36
    ; push 'a' scancode 0x1E, constat -> FF
    mov al, 0x1E
    call kbd_queue_push
    call handler_constat
    cmp al, 0xFF
    jne .fail36
    ; IN (08) no echo -> 'a', queue drained
    call handler_in
    cmp al, 'a'
    jne .fail36
    ; constat empty again
    call handler_constat
    cmp al, 0
    jne .fail36
    ; CONIN (01) with echo: push 'b' 0x30 -> 'b'
    mov al, 0x30
    call kbd_queue_push
    call handler_conin
    cmp al, 'b'
    jne .fail36
    ; RAWIO DL=FF input: push 'c' 0x2E -> 'c'
    mov al, 0x2E
    call kbd_queue_push
    mov dl, 0xFF
    call handler_rawio
    jc .fail36
    cmp al, 'c'
    jne .fail36
    ; RAWIO DL=FF empty -> CF=1 AL=0
    mov dl, 0xFF
    call handler_rawio
    jnc .fail36
    cmp al, 0
    jne .fail36
    ; RAWIO output DL='Z' (non-FF) -> prints, no fault
    mov dl, 'Z'
    call handler_rawio
    ; RAWINP (07): push 'd' 0x20 -> 'd'
    mov al, 0x20
    call kbd_queue_push
    call handler_rawinp
    cmp al, 'd'
    jne .fail36
    ; FLUSHKB (0C) AL=0 -> flush + AL=0; then constat 0
    mov al, 0x1E
    call kbd_queue_push
    mov rax, 0x0C00
    call handler_flushkb
    cmp al, 0
    jne .fail36
    call handler_constat
    cmp al, 0
    jne .fail36
    ; FLUSHKB + redispatch AL=8 (IN): DOS flushes BEFORE dispatch, so
    ; pre-pushed keys are cleared (MSDOS.ASM:412 PUSH AX/CALL FLUSH/POP).
    ; Non-blocking test-safe impl returns AL=0 empty (DOS would block).
    ; This still proves redispatch calls handler_in without fault.
    mov al, 0x12
    call kbd_queue_push
    mov rax, 0x0C08
    call handler_flushkb
    cmp al, 0
    jne .fail36
    ; dispatch path: AH=01 via syscall_dispatch64 (queue 'f' 0x21)
    mov al, 0x21
    call kbd_queue_push
    mov rax, 0x0100
    call syscall_dispatch64
    cmp al, 'f'
    jne .fail36
    xor eax, eax
    jmp .done36
.fail36:
    mov rax, 1
.done36:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 37: Buffered input 0A
test_bufin:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call kbd_flush
    ; buffer max 16 at p9_bufin
    lea rdi, [rel p9_bufin]
    mov byte [rdi], 16
    mov byte [rdi+1], 0
    ; feed "HI" + CR: H=0x23, I=0x17, CR=0x1C
    mov al, 0x23
    call kbd_queue_push
    mov al, 0x17
    call kbd_queue_push
    mov al, 0x1C
    call kbd_queue_push
    lea rdx, [rel p9_bufin]
    call handler_bufin
    test rax, rax
    jnz .fail37
    cmp byte [rdi+1], 2
    jne .fail37
    cmp byte [rdi+2], 'h'
    jne .fail37
    cmp byte [rdi+3], 'i'
    jne .fail37
    cmp byte [rdi+4], 13
    jne .fail37
    ; backspace test: "AB" BS "C" CR -> "AC": A=0x1E,B=0x30,BS=0x0E,C=0x2E,CR=0x1C
    call kbd_flush
    lea rdi, [rel p9_bufin]
    mov byte [rdi], 16
    mov byte [rdi+1], 0
    mov al, 0x1E
    call kbd_queue_push
    mov al, 0x30
    call kbd_queue_push
    mov al, 0x0E
    call kbd_queue_push
    mov al, 0x2E
    call kbd_queue_push
    mov al, 0x1C
    call kbd_queue_push
    lea rdx, [rel p9_bufin]
    call handler_bufin
    test rax, rax
    jnz .fail37
    cmp byte [rdi+1], 2
    jne .fail37
    cmp byte [rdi+2], 'a'
    jne .fail37
    cmp byte [rdi+3], 'c'
    jne .fail37
    ; empty (no keys) -> count 0
    call kbd_flush
    lea rdi, [rel p9_bufin]
    mov byte [rdi], 16
    mov byte [rdi+1], 0xFF
    lea rdx, [rel p9_bufin]
    call handler_bufin
    test rax, rax
    jnz .fail37
    cmp byte [rdi+1], 0
    jne .fail37
    ; bad buffer (0) -> fail
    xor edx, edx
    call handler_bufin
    test rax, rax
    jz .fail37
    ; dispatch path AH=0A: feed "K"+CR (K=0x25)
    call kbd_flush
    lea rdi, [rel p9_bufin]
    mov byte [rdi], 16
    mov al, 0x25
    call kbd_queue_push
    mov al, 0x1C
    call kbd_queue_push
    lea rdx, [rel p9_bufin]
    mov rax, 0x0A00
    call syscall_dispatch64
    cmp byte [rdi+1], 1
    jne .fail37
    cmp byte [rdi+2], 'k'
    jne .fail37
    xor eax, eax
    jmp .done37
.fail37:
    mov rax, 1
.done37:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 38: Drive 0E/19/0D
test_drive:
    push rbx
    push rcx
    push rdx
    call syscall_init
    ; initial 0
    call handler_getdrv
    cmp al, 0
    jne .fail38
    ; select 1
    mov dl, 1
    call handler_seldsk
    cmp al, 2              ; NUMDRV
    jne .fail38
    call handler_getdrv
    cmp al, 1
    jne .fail38
    ; select 0
    mov dl, 0
    call handler_seldsk
    call handler_getdrv
    cmp al, 0
    jne .fail38
    ; invalid 99 -> stays 0, AL=NUMDRV
    mov dl, 99
    call handler_seldsk
    cmp al, 2
    jne .fail38
    call handler_getdrv
    cmp al, 0
    jne .fail38
    ; reset -> AL=0
    call handler_dskreset
    cmp al, 0
    jne .fail38
    ; dispatch paths: AH=0E DL=1, AH=19, AH=0D
    mov rdx, 1
    mov rax, 0x0E00
    call syscall_dispatch64
    mov rax, 0x1900
    call syscall_dispatch64
    cmp al, 1
    jne .fail38
    mov rax, 0x0D00
    call syscall_dispatch64
    cmp al, 0
    jne .fail38
    ; restore 0 for later tests
    mov dl, 0
    call handler_seldsk
    xor eax, eax
    jmp .done38
.fail38:
    mov rax, 1
.done38:
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 39: Vectors 25/35
test_vectors:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; save current 0x21
    mov al, 0x21
    call handler_getvect
    mov r8, rbx            ; saved handler
    test r8, r8
    jz .fail39
    ; set 0x21 to dummy 0x12345000 (canonical low)
    mov rax, 0x2500
    mov al, 0x21
    mov rdx, 0x12345000
    call handler_setvect
    test rax, rax
    jnz .fail39
    mov al, 0x21
    call handler_getvect
    cmp rbx, 0x12345000
    jne .fail39b
    ; set vector 0x80 to int21_entry, verify
    mov rax, 0x2500
    mov al, 0x80
    lea rdx, [rel int21_entry]
    call handler_setvect
    test rax, rax
    jnz .fail39b
    mov al, 0x80
    call handler_getvect
    lea rcx, [rel int21_entry]
    cmp rbx, rcx
    jne .fail39b
    ; bad: SETVECT RDX=0 -> fail
    mov rax, 0x2500
    mov al, 0x21
    xor edx, edx
    call handler_setvect
    test rax, rax
    jz .fail39b
    ; dispatch path: AH=35h AL=0x80 -> RBX=int21
    mov rax, 0x3580
    call syscall_dispatch64
    lea rcx, [rel int21_entry]
    ; RBX holds handler after dispatch? dispatch restores RBX from frame rbx_save
    ; Our handler_getvect writes frame rbx_save=handler, so after leave RBX=handler
    cmp rbx, rcx
    jne .fail39b
    ; restore 0x21
    mov rax, 0x2500
    mov al, 0x21
    mov rdx, r8
    call handler_setvect
    test rax, rax
    jnz .fail39b
    mov al, 0x21
    call handler_getvect
    cmp rbx, r8
    jne .fail39b
    ; verify INT 0x21 still works after restore (AH=19 GETDRV)
    mov rax, 0x1900
    int 0x21
    ; AL should be 0 (drive restored in test_drive)
    cmp al, 0
    jne .fail39b
    xor eax, eax
    jmp .done39
.fail39b:
    ; try restore before failing
    push rax
    mov rax, 0x2500
    mov al, 0x21
    mov rdx, r8
    call handler_setvect
    pop rax
.fail39:
    mov rax, 1
.done39:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 40: Read 3F
test_read_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call kbd_flush
    ; push 'x' 0x2D, read 1 byte handle 0
    mov al, 0x2D
    call kbd_queue_push
    lea rdx, [rel p9_rwbuf]
    mov rbx, 0
    mov rcx, 1
    call handler_read_file
    jc .fail40
    cmp rax, 1
    jne .fail40
    cmp byte [rel p9_rwbuf], 'x'
    jne .fail40
    ; zero count -> 0
    lea rdx, [rel p9_rwbuf]
    mov rbx, 0
    mov rcx, 0
    call handler_read_file
    jc .fail40
    cmp rax, 0
    jne .fail40
    ; bad handle 5 -> CF + RAX=5
    lea rdx, [rel p9_rwbuf]
    mov rbx, 5
    mov rcx, 1
    call handler_read_file
    jnc .fail40
    ; bad buffer 0 -> fail
    mov rbx, 0
    mov rcx, 1
    xor edx, edx
    call handler_read_file
    jnc .fail40
    ; dispatch path AH=3Fh: push 'y' 0x15 -> 'y'
    call kbd_flush
    mov al, 0x15
    call kbd_queue_push
    lea rdx, [rel p9_rwbuf]
    mov rbx, 0
    mov rcx, 1
    mov rax, 0x3F00
    call syscall_dispatch64
    jc .fail40
    cmp byte [rel p9_rwbuf], 'y'
    jne .fail40
    xor eax, eax
    jmp .done40
.fail40:
    mov rax, 1
.done40:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 41: Write 40
test_write_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    ; write "Hi!" (3) to stdout handle 1
    lea rdx, [rel p9_hello3]
    mov rbx, 1
    mov rcx, 3
    call handler_write_file
    jc .fail41
    cmp rax, 3
    jne .fail41
    ; handle 2 stderr same
    lea rdx, [rel p9_hello3]
    mov rbx, 2
    mov rcx, 3
    call handler_write_file
    jc .fail41
    cmp rax, 3
    jne .fail41
    ; zero count -> 0
    lea rdx, [rel p9_hello3]
    mov rbx, 1
    mov rcx, 0
    call handler_write_file
    jc .fail41
    cmp rax, 0
    jne .fail41
    ; bad handle 5 -> CF
    lea rdx, [rel p9_hello3]
    mov rbx, 5
    mov rcx, 3
    call handler_write_file
    jnc .fail41
    ; dispatch AH=40h handle 1 count 3
    lea rdx, [rel p9_hello3]
    mov rbx, 1
    mov rcx, 3
    mov rax, 0x4000
    call syscall_dispatch64
    jc .fail41
    cmp rax, 3
    jne .fail41
    xor eax, eax
    jmp .done41
.fail41:
    mov rax, 1
.done41:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 42: Full INT 0x21 round-trip via CPU INT
test_int21_roundtrip:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call kbd_flush
    ; AH=02 DL='Q' via INT
    mov rax, 0x0200
    mov dl, 'Q'
    int 0x21
    ; AH=09 $-string via INT
    mov rax, 0x0900
    lea rdx, [rel p9_dollar]
    int 0x21
    ; AH=0E DL=1 / AH=19 via INT
    mov rax, 0x0E00
    mov dl, 1
    int 0x21
    cmp al, 2
    jne .fail42
    mov rax, 0x1900
    int 0x21
    cmp al, 1
    jne .fail42b
    mov rax, 0x0E00
    mov dl, 0
    int 0x21
    ; AH=0D via INT
    mov rax, 0x0D00
    int 0x21
    cmp al, 0
    jne .fail42b
    ; AH=01 via INT with queued 'z' 0x2C -> 'z'
    mov al, 0x2C
    call kbd_queue_push
    mov rax, 0x0100
    int 0x21
    cmp al, 'z'
    jne .fail42b
    ; AH=3Fh handle 0 count 1 via INT: push 'w' 0x11 -> 'w'
    call kbd_flush
    mov al, 0x11
    call kbd_queue_push
    lea rdx, [rel p9_rwbuf]
    mov rbx, 0
    mov rcx, 1
    mov rax, 0x3F00
    int 0x21
    jc .fail42b
    cmp byte [rel p9_rwbuf], 'w'
    jne .fail42b
    ; AH=40h handle 1 count 3 via INT
    lea rdx, [rel p9_hello3]
    mov rbx, 1
    mov rcx, 3
    mov rax, 0x4000
    int 0x21
    jc .fail42b
    cmp ax, 3
    jne .fail42b
    xor eax, eax
    jmp .done42
.fail42b:
    ; restore drive 0 before fail
    push rax
    mov rax, 0x0E00
    mov dl, 0
    int 0x21
    pop rax
.fail42:
    mov rax, 1
.done42:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Phase11 tests [51]-[58]: Full IDT (IVT replacement)
;   PIC master 0x28 / slave 0x30, exc 0-31 diagnostics, IRQ0 @0x28,
;   IRQ1 @0x29 installed, IRQ14 @0x36, DOS 0x21 preserved. All use CPU
;   `int` (proper IRETQ frames); error vectors (8/10-14/17/21) verified
;   via IDT read only (software `int` pushes no error, would corrupt
;   err stub).
; ------------------------------------------------------------
; Test 51: Full IDT structure + IMR masked
test_idt_full:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; IDTR via SIDT: limit 4095, base == idt_get_base64
    ; (copy SIDT out before calls: calls push ret addr, would shift [rsp])
    sub rsp, 16
    sidt [rsp]
    movzx ecx, word [rsp]
    mov rsi, [rsp+2]
    add rsp, 16
    cmp cx, 4095
    jne .fail51
    call idt_get_base64
    cmp rax, rsi
    jne .fail51
    ; vectors 0 vs 1 distinct (per-vector stubs, not shared default)
    mov rdi, 0
    call idt_get_vector64
    mov r8, rax
    test r8, r8
    jz .fail51
    mov rdi, 1
    call idt_get_vector64
    mov r9, rax
    test r9, r9
    jz .fail51
    cmp r8, r9
    je .fail51
    ; vector 0 type 0x8E kernel, selector 0x08
    call idt_get_base64
    mov rbx, rax
    cmp byte [rbx+5], 0x8E
    jne .fail51
    cmp word [rbx+2], 0x08
    jne .fail51
    ; vector 8 (err) type kernel
    call idt_get_base64
    mov rbx, rax
    cmp byte [rbx+8*16+5], 0x8E
    jne .fail51
    ; vector 0x21 DOS type 0xEE + handler
    mov rdi, 0x21
    call idt_get_vector64
    lea rbx, [rel int21_entry]
    cmp rax, rbx
    jne .fail51
    call idt_get_base64
    mov rbx, rax
    cmp byte [rbx+0x21*16+5], 0xEE
    jne .fail51
    ; vector 0x28 timer + 0x29 kbd + 0x36 disk kernel gates
    mov rdi, 0x28
    call idt_get_vector64
    lea rbx, [rel irq0_timer_handler]
    cmp rax, rbx
    jne .fail51
    mov rdi, 0x29
    call idt_get_vector64
    lea rbx, [rel irq1_kbd_handler]
    cmp rax, rbx
    jne .fail51
    mov rdi, 0x36
    call idt_get_vector64
    lea rbx, [rel irq14_disk_handler]
    cmp rax, rbx
    jne .fail51
    call idt_get_base64
    mov rbx, rax
    cmp byte [rbx+0x28*16+5], 0x8E
    jne .fail51
    cmp byte [rbx+0x29*16+5], 0x8E
    jne .fail51
    cmp byte [rbx+0x36*16+5], 0x8E
    jne .fail51
    ; old 0x20 slot is a default gate now, not the timer
    mov rdi, 0x20
    call idt_get_vector64
    lea rbx, [rel irq0_timer_handler]
    cmp rax, rbx
    je .fail51
    ; IMR masked (deterministic polling drivers)
    call pic_get_mask64
    cmp rax, 0xFFFF
    jne .fail51
    ; old overlap 0x08 is exc stub, not timer
    mov rdi, 0x08
    call idt_get_vector64
    lea rbx, [rel irq0_timer_handler]
    cmp rax, rbx
    je .fail51
    call idt_test_vectors
    test rax, rax
    jnz .fail51
    xor eax, eax
    jmp .done51
.fail51:
    mov rax, 1
.done51:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 52: Exception diagnostics via INT 0/3/4
test_exc_diag:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call idt_reset_stats64
    call idt_get_fault_count64
    test rax, rax
    jnz .fail52
    ; int 0 (#DE) with RBX preservation check
    mov rbx, 0x1234
    int 0
    cmp rbx, 0x1234
    jne .fail52
    call idt_get_fault_count64
    cmp rax, 1
    jne .fail52
    call idt_get_last_vector64
    cmp rax, 0
    jne .fail52
    call idt_get_last_error64
    cmp rax, 0
    jne .fail52
    call idt_get_last_rip64
    test rax, rax
    jz .fail52
    mov rdi, 0
    call idt_get_exc_count64
    cmp rax, 1
    jne .fail52
    ; tick unchanged (IRQ separate)
    call idt_get_tick64
    test rax, rax
    jnz .fail52
    ; int 3 (#BP)
    int 3
    call idt_get_fault_count64
    cmp rax, 2
    jne .fail52
    call idt_get_last_vector64
    cmp rax, 3
    jne .fail52
    mov rdi, 3
    call idt_get_exc_count64
    cmp rax, 1
    jne .fail52
    ; int 4 (#OF)
    int 4
    call idt_get_fault_count64
    cmp rax, 3
    jne .fail52
    call idt_get_last_vector64
    cmp rax, 4
    jne .fail52
    ; error vectors present via IDT read (not via int: no error pushed)
    mov rdi, 13
    call idt_get_vector64
    test rax, rax
    jz .fail52
    mov rdi, 14
    call idt_get_vector64
    test rax, rax
    jz .fail52
    xor eax, eax
    jmp .done52
.fail52:
    mov rax, 1
.done52:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 53: PIC remap + mask/unmask
test_pic_remap:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    call pic_remap64
    test rax, rax
    jnz .fail53
    call pic_get_mask64
    cmp rax, 0xFFFF
    jne .fail53
    ; DOS preserved after remap
    mov rdi, 0x21
    call idt_get_vector64
    lea rbx, [rel int21_entry]
    cmp rax, rbx
    jne .fail53
    ; timer/disk/kbd vectors intact
    mov rdi, 0x28
    call idt_get_vector64
    lea rbx, [rel irq0_timer_handler]
    cmp rax, rbx
    jne .fail53
    mov rdi, 0x29
    call idt_get_vector64
    lea rbx, [rel irq1_kbd_handler]
    cmp rax, rbx
    jne .fail53
    ; unmask IRQ0 -> bit0 clear (0xFFFE low)
    mov rdi, 0
    call pic_unmask_irq64
    test rax, rax
    jnz .fail53
    call pic_get_mask64
    mov rbx, rax
    test bl, 1
    jnz .fail53
    ; mask IRQ0 again -> bit set
    mov rdi, 0
    call pic_mask_irq64
    test rax, rax
    jnz .fail53
    call pic_get_mask64
    cmp rax, 0xFFFF
    jne .fail53
    ; bad irq 16 fails
    mov rdi, 16
    call pic_mask_irq64
    test rax, rax
    jz .fail53
    mov rdi, 16
    call pic_unmask_irq64
    test rax, rax
    jz .fail53
    ; DOS still works after remap (AH=19 GETDRV)
    mov rax, 0x1900
    int 0x21
    cmp al, 0
    jne .fail53b
    xor eax, eax
    jmp .done53
.fail53b:
    ; restore drive? GETDRV doesn't change, just fail
.fail53:
    mov rax, 1
.done53:
    ; leave masked for determinism
    push rax
    mov al, 0xFF
    out 0x21, al
    out 0xA1, al
    pop rax
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 54: Timer IRQ0 via INT 0x28
test_timer_irq:
    push rbx
    push rcx
    push rdx
    call idt_reset_stats64
    call idt_get_tick64
    test rax, rax
    jnz .fail54
    call idt_get_fault_count64
    test rax, rax
    jnz .fail54
    mov rbx, 0x5678
    int 0x28
    cmp rbx, 0x5678
    jne .fail54
    call idt_get_tick64
    cmp rax, 1
    jne .fail54
    call idt_get_fault_count64
    test rax, rax
    jnz .fail54
    int 0x28
    call idt_get_tick64
    cmp rax, 2
    jne .fail54
    xor eax, eax
    jmp .done54
.fail54:
    mov rax, 1
.done54:
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 55: Keyboard IRQ1 handler at its installed vector 0x29
;   (installed since the 0x28/0x30 remap clears DOS 0x21). Fires the
;   real handler via CPU `int`: with no key pending it EOIs cleanly,
;   preserves regs, faults nothing, and leaves DOS 0x21 alone.
test_kbd_irq:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    ; 0x29 must already point at the installed handler (no swap needed)
    mov rdi, 0x29
    call idt_get_vector64
    lea rbx, [rel irq1_kbd_handler]
    cmp rax, rbx
    jne .fail55
    ; flush queue, record fault count
    call kbd_flush
    call idt_get_fault_count64
    mov r8, rax
    ; fire (no hw data expected: just EOI, no crash, regs preserved)
    mov rcx, 0x9ABC
    int 0x29
    cmp rcx, 0x9ABC
    jne .fail55
    call idt_get_fault_count64
    cmp rax, r8
    jne .fail55
    ; with a queued scancode the IRQ path still EOIs cleanly: push a
    ; make code directly, fire, then pop it back (queue order kept)
    mov al, 0x1E
    call kbd_queue_push
    jc .fail55
    int 0x29
    call kbd_queue_pop
    jc .fail55
    cmp al, 0x1E
    jne .fail55
    ; DOS 0x21 untouched (still int21)
    mov rdi, 0x21
    call idt_get_vector64
    lea rbx, [rel int21_entry]
    cmp rax, rbx
    jne .fail55
    ; IRQ-safe queue IF preservation + nested-cli (requires IDT up: uses
    ; sti/cli; unsafe before idt_load, hence here in test 55, not test 15).
    call kbd_test_queue_if
    test rax, rax
    jnz .fail55
    xor eax, eax
    jmp .done55
.fail55:
    mov rax, 1
.done55:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 56: Disk IRQ14 via INT 0x36
test_disk_irq:
    push rbx
    push rcx
    push rdx
    call idt_reset_stats64
    call idt_get_irq14_count64
    test rax, rax
    jnz .fail56
    mov rbx, 0x1357
    int 0x36
    cmp rbx, 0x1357
    jne .fail56
    call idt_get_irq14_count64
    cmp rax, 1
    jne .fail56
    call idt_get_fault_count64
    test rax, rax
    jnz .fail56
    int 0x36
    call idt_get_irq14_count64
    cmp rax, 2
    jne .fail56
    xor eax, eax
    jmp .done56
.fail56:
    mov rax, 1
.done56:
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 57: IRQ vectors SETVECT/GETVECT + DOS preserved
test_irq_vectors:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    ; save 0x28 via GETVECT
    mov al, 0x28
    call handler_getvect
    mov r8, rbx
    test r8, r8
    jz .fail57
    ; set 0x28 to dummy
    mov rax, 0x2500
    mov al, 0x28
    mov rdx, 0x12345000
    call handler_setvect
    test rax, rax
    jnz .fail57
    mov al, 0x28
    call handler_getvect
    cmp rbx, 0x12345000
    jne .fail57b
    ; restore 0x28 to timer
    mov rax, 0x2500
    mov al, 0x28
    mov rdx, r8
    call handler_setvect
    test rax, rax
    jnz .fail57b
    ; verify timer works after restore
    call idt_reset_stats64
    int 0x28
    call idt_get_tick64
    cmp rax, 1
    jne .fail57b
    ; DOS 0x21 still works (AH=19)
    mov rax, 0x1900
    int 0x21
    cmp al, 0
    jne .fail57b
    ; bad SETVECT RDX=0 fails
    mov rax, 0x2500
    mov al, 0x28
    xor edx, edx
    call handler_setvect
    test rax, rax
    jz .fail57b
    xor eax, eax
    jmp .done57
.fail57b:
    push rax
    mov rax, 0x2500
    mov al, 0x28
    mov rdx, r8
    test rdx, rdx
    jz .skip_rest57
    call handler_setvect
.skip_rest57:
    pop rax
.fail57:
    mov rax, 1
.done57:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Test 58: IDT stress + DOS round-trip after remap
test_idt_stress:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call idt_reset_stats64
    call kbd_flush
    ; exc sequence
    int 0
    int 3
    call idt_get_fault_count64
    cmp rax, 2
    jne .fail58
    ; IRQs
    int 0x28
    int 0x36
    call idt_get_tick64
    cmp rax, 1
    jne .fail58
    call idt_get_irq14_count64
    cmp rax, 1
    jne .fail58
    ; DOS round-trip still fine (AH=02/09/19)
    mov rax, 0x0200
    mov dl, 'S'
    int 0x21
    mov rax, 0x0900
    lea rdx, [rel p9_dollar]
    int 0x21
    mov rax, 0x1900
    int 0x21
    cmp al, 0
    jne .fail58
    ; fault count still 2 (IRQs + DOS don't fault)
    call idt_get_fault_count64
    cmp rax, 2
    jne .fail58
    call mem_validate64
    test rax, rax
    jnz .fail58
    xor eax, eax
    jmp .done58
.fail58:
    mov rax, 1
.done58:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------

section .rodata
msg_test1 db " [1] Register mapping (AX->RAX, R8-R15)... ",0
msg_test2 db " [2] String ops (REP MOVSB, SCASB, LOOP->DEC)... ",0
msg_test3 db " [3] BCD (AAM/AAD -> DIV/MUL, CBW, MUL/DIV)... ",0
msg_test4 db " [4] FAT12 UNPACK/PACK (BX->RBX, SHL, LES)... ",0
msg_test5 db " [5] Memory MCB64 (para*16->byte, alloc)... ",0
msg_test6 db " [6] DMA flat (LES/LDS elimination)... ",0
msg_test7 db " [7] Syscall dispatch (SAVREGS, far->near)... ",0
msg_test8 db " [8] Seg:off->linear (seg<<4+off, DMA, para)... ",0
msg_test9 db " [9] RIP-relative/OFFSET DOSGROUP->rel... ",0
msg_test10 db " [10] FAR PTR BIOS -> near dispatch... ",0
msg_test11 db " [11] Flat buffers DIRBUF/BUFFER, seg override elim... ",0
msg_test12 db " [12] Canonical & flat stack... ",0
msg_test13 db " [13] ATA PIO MBR read + CHS->LBA (INT13h)... ",0
msg_test14 db " [14] ATA write/readback verify... ",0
msg_test15 db " [15] Keyboard status/queue (INT16h)... ",0
msg_test16 db " [16] Kbd translation + VGA native... ",0
msg_test17 db " [17] Para/page conv (para*16, pages*4K)... ",0
msg_test18 db " [18] MCB coalesce (split, prev+next merge)... ",0
msg_test19 db " [19] Resize SETBLK (shrink/grow via AH=4Ah)... ",0
msg_test20 db " [20] Page protection (2MiB PS RW/NX)... ",0
msg_test21 db " [21] Stress/validate (totals, double-free)... ",0
msg_test22 db " [22] BPB->DPB + cluster->LBA + FAT sector... ",0
msg_test23 db " [23] FAT12 chain pack/unpack + EOF/free... ",0
msg_test24 db " [24] Root-dir find/delete/end/wildcard... ",0
msg_test25 db " [25] ATA DREAD/DWRITE + DIRREAD (LBA)... ",0
msg_test26 db " [26] Multi-cluster file read via chain... ",0
msg_test27 db " [27] FCB64 open + 64-bit filsiz/rr/DMA... ",0
msg_test28 db " [28] PSP init/validate (SETMEM analog)... ",0
msg_test29 db " [29] PSP cmd tail + exit/fd/CR3... ",0
msg_test30 db " [30] ENV init/set/get/unset/count... ",0
msg_test31 db " [31] Loader COM vs EXE64 + bad hdr... ",0
msg_test32 db " [32] Spawn/exit lifecycle + owner... ",0
msg_test33 db " [33] EXEC/EXIT via INT21 dispatch... ",0
msg_test34 db " [34] Stress max procs + reap/validate... ",0
msg_test35 db " [35] IDT init/load + INT 0x21 gate... ",0
msg_test36 db " [36] Console 01/08/0B/0C (kbd+vga)... ",0
msg_test37 db " [37] Buffered input 0A (line edit)... ",0
msg_test38 db " [38] Drive 0E/19 + reset 0D... ",0
msg_test39 db " [39] Vectors 25/35 via IDT... ",0
msg_test40 db " [40] Read 3F stdin handle 0... ",0
msg_test41 db " [41] Write 40 stdout handles 1/2... ",0
msg_test42 db " [42] INT 0x21 round-trip via CPU INT... ",0
msg_test43 db " [43] Parser SCANOFF/DELIM/SWITCH/drive... ",0
msg_test44 db " [44] DIR format + TYPE ^Z... ",0
msg_test45 db " [45] COPY/DEL/REN fileops... ",0
msg_test46 db " [46] CLS/VER/PROMPT/PATH/REM/PAUSE... ",0
msg_test47 db " [47] DATE/TIME get/set/parse... ",0
msg_test48 db " [48] External EXEC via spawn... ",0
msg_test49 db " [49] Batch open/next/expand... ",0
msg_test50 db " [50] Dispatch + stress... ",0
msg_test51 db " [51] Full IDT 0-31/0x28/0x21/0x36 + IMR... ",0
msg_test52 db " [52] Exceptions 0/3/4 diag + preserve... ",0
msg_test53 db " [53] PIC remap 0x28/0x30 + mask/unmask... ",0
msg_test54 db " [54] Timer IRQ0 @0x28 tick + EOI... ",0
msg_test55 db " [55] Kbd IRQ1 @0x29 installed + EOI... ",0
msg_test56 db " [56] Disk IRQ14 @0x36 count + EOI... ",0
msg_test57 db " [57] IRQ SETVECT/GETVECT + DOS kept... ",0
msg_test58 db " [58] IDT stress + DOS after remap... ",0
msg_test59 db " [59] RSP 16B + I/O/IST stacks... ",0
msg_test60 db " [60] Callee RBX/RBP/R12-R15 + clobber... ",0
msg_test61 db " [61] SysV 6-reg + 2-stack args + ret... ",0
msg_test62 db " [62] Nested depth 32 + RSP restore... ",0
msg_test63 db " [63] IRQ stacks IST==0 + timer preserve... ",0
msg_test64 db " [64] PUSH/POP 64-bit + near CALL + DF... ",0
msg_test65 db " [65] Canary init/intact/detect + stress... ",0
msg_test66 db " [66] ABI stress + DOS after harden... ",0
msg_test67 db " [67] Real FAT12 volume mount + file read... ",0
msg_test68 db " [68] RTC date/time get/set (INT21 2A-2D)... ",0
msg_test69 db " [69] AUX/LIST + VERIFY/NEWBASE/disk info... ",0
msg_test70 db " [70] FCB open/rndread/search/makefcb... ",0
msg_test71 db " [71] FCB create/write/read/rename/delete... ",0
msg_test72 db " [72] Shell line dispatch (DIR/TYPE/EXEC)... ",0
msg_test73 db " [73] Loader negative (image/entry/stack/bad hdr)... ",0
msg_test74 db " [74] ATA negative (range reject, timeout, intact)... ",0
msg_test75 db " [75] Syscall bounds (MAXCOM/MAXCOM+1/FF)... ",0
msg_test76 db " [76] FAT12 negative (BPB/cluster/NULL/missing)... ",0
msg_test77 db " [77] BPB table + sentinels (FAT/root/cluster/tot)... ",0
msg_test78 db " [78] ATA pure table (endpoint/count, no hw)... ",0
msg_test79 db " [79] FAT chain bounds (cycle/iter, clear)... ",0
msg_test80 db " [80] Alloc table (near-UINT64_MAX, aligned/pages)... ",0
msg_test81 db " [81] Queue interleave (empty/full/wrap + IF)... ",0
msg_test82 db " [82] Layout invariants (same as check-layout)... ",0
msg_test83 db " [83] FAT12 crash-order (FAT-first + mirrors/scrub)... ",0
msg_pass db "PASS",13,10,0
msg_fail db "FAIL",13,10,0
msg_skip db "SKIP (destructive, needs SELFTEST_DESTRUCTIVE)",13,10,0
msg_summary db 13,10,"Summary: ",0
msg_summary2 db " passed, ",0
msg_summary3 db " failed",13,10,0
msg_summary4 db "Skipped (destructive): ",0
msg_summary5 db " (run make full for 71+83)",13,10,0
msg_phase3_ok db "Phase3 register conversion: ALL TESTS PASS",13,10,0
msg_phase3_fail db "Phase3: SOME TESTS FAILED",13,10,0
msg_phase4_ok db "Phase4 addressing transformation: ALL TESTS PASS",13,10,0
msg_phase4_fail db "Phase4: SOME TESTS FAILED",13,10,0
msg_phase5_ok db "Phase5 BIOS replacement (Option C): ALL TESTS PASS",13,10,0
msg_phase5_fail db "Phase5: SOME TESTS FAILED",13,10,0
msg_phase6_ok db "Phase6 memory management (MCB64): ALL TESTS PASS",13,10,0
msg_phase6_fail db "Phase6: SOME TESTS FAILED",13,10,0
msg_phase7_ok db "Phase7 filesystem adaptation (FAT12): ALL TESTS PASS",13,10,0
msg_phase7_fail db "Phase7: SOME TESTS FAILED",13,10,0
msg_phase8_ok db "Phase8 process management (PSP64): ALL TESTS PASS",13,10,0
msg_phase8_fail db "Phase8: SOME TESTS FAILED",13,10,0
msg_phase9_ok db "Phase9 syscall interface (INT 21h): ALL TESTS PASS",13,10,0
msg_phase9_fail db "Phase9: SOME TESTS FAILED",13,10,0
msg_phase10_ok db "Phase10 command interpreter (COMMAND64): ALL TESTS PASS",13,10,0
msg_phase10_fail db "Phase10: SOME TESTS FAILED",13,10,0
msg_phase11_ok db "Phase11 IDT full (remap+IRQ+exc): ALL TESTS PASS",13,10,0
msg_phase11_fail db "Phase11: SOME TESTS FAILED",13,10,0
msg_phase12_ok db "Phase12 stack/ABI (16B+SysV+canary): ALL TESTS PASS",13,10,0
msg_phase12_fail db "Phase12: SOME TESTS FAILED",13,10,0
p9_dollar db "P9$INT21$ via INT$",0
p9_hello3 db "Hi!",0
vol_name_hello db "HELLO   TXT"
vol_name_readme db "README  TXT"
vol_name_missing db "NOFILE  TXT"
fcb_str_hello db "HELLO.TXT",0
fcb_str_wild db "*.TXT",0
fcb_str_scratch db "SCRATCH.TXT",0
fcb_str_renamed db "RENAMED.TXT",0
fcb_new_renamed db "RENAMED TXT"
fcb_str_crash db "CRASH.TXT",0
crash_name_11 db "CRASH   TXT"
shl_dir db "DIR",13,0
shl_type db "TYPE HELLO.TXT",13,0
shl_test db "TEST",13,0
shl_bad db "FOOBAR",13,0
shl_empty db 13,0
shl_exit db "EXIT",13,0

str_hello db "Hello64",0
str_lower db "hello",0
xlat_table db 0x00,0x11,0x22,0x33,0x44
demo_dollar2 db "INT21 test$",0
vga_test_str db "VGA",0
ata_dbg_msg db " ATA DBG status=0x",0
ata_dbg_msg2 db " err=0x",0
ata_dbg_msg3 db " ",0
ata_dbg_msg4 db " sig=",0
ata_sig_fail_msg db " SIG MISMATCH",13,10,0
ata_chs_fail_msg db " CHS FAIL",13,10,0
ata_chs_dbg1 db " CHS1 got ",0
ata_chs_exp db " exp 03F0",13,10,0
ata_chs_dbg2 db " CHS2 got C/H/S ",0
ata_chs_dbg3 db " CHS3 got ",0
msg_nl2 db 13,10,0
; Phase8 test strings
p8_cmd_hello db "HELLO WORLD",0
p8_cmd_arg1 db "ARG1",0
p8_env_path db "PATH",0
p8_env_path_val db "/BIN",0
p8_env_path_val2 db "/NEW",0
p8_env_comspec db "COMSPEC",0
p8_env_comspec_val db "COMMAND64",0
p8_env_prompt db "PROMPT",0
p8_env_prompt_val db "$P$G",0
p8_env_bad_eq db "A=B",0
p8_env_empty db 0
p8_env_missing db "NOPE",0
p8_outbuf_val db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

; ------------------------------------------------------------
; Cross-layer tables for tests 77-82 (boundary values obvious).
; ------------------------------------------------------------
align 8
; Test 77: BPB single-field mutations from a valid 1.44M baseline.
; Entry: dd bpb_offset, db width(1/2), db exp_parse(0 ok/1 fail),
;        db exp_valid(0 ok/2 GEOM/0xFF skip), db pad, dd value, dd 0.
; Offsets are BPB_* from include/fs.inc (11=BytsPerSec, 13=SecPerClus,
; 14=Rsvd, 16=NumFATs, 17=RootEnt, 19=Tot16, 22=FATSz).
bpb77_table:
    dd 22
    db 2, 0, 2, 0
    dd 10
    dd 0
    dd 22
    db 2, 1, 0xFF, 0
    dd 0
    dd 0
    dd 17
    db 2, 0, 2, 0
    dd 225
    dd 0
    dd 17
    db 2, 1, 0xFF, 0
    dd 0
    dd 0
    dd 13
    db 1, 1, 0xFF, 0
    dd 128
    dd 0
    dd 13
    db 1, 0, 0, 0
    dd 64
    dd 0
    dd 13
    db 1, 1, 0xFF, 0
    dd 0
    dd 0
    dd 11
    db 2, 0, 2, 0
    dd 1024
    dd 0
    dd 11
    db 2, 1, 0xFF, 0
    dd 123
    dd 0
    dd 19
    db 2, 1, 0xFF, 0
    dd 0
    dd 0
    dd 19
    db 2, 0, 2, 0
    dd 4112
    dd 0
    dd 16
    db 1, 1, 0xFF, 0
    dd 0
    dd 0
    dd 16
    db 1, 1, 0xFF, 0
    dd 5
    dd 0
    dd 14
    db 2, 1, 0xFF, 0
    dd 0
    dd 0
bpb77_table_end:
bpb77_count equ (bpb77_table_end - bpb77_table)/16

align 8
; Test 78: pure ata_validate_range64 (LBA, count, expected 0 ok/1 invalid).
; No hardware: helper only. Boundaries: max LBA 0x0FFFFFFF, max count 64,
; exact-fit 0x0FFFFFC0+64, endpoint inclusive 0x0FFFFFFE+2.
ata78_table:
    dq 0, 1, 0
    dq 0x0FFFFFFF, 1, 0
    dq 0x0FFFFFFF, 2, 1
    dq 0x0FFFFFC0, 64, 0
    dq 0x0FFFFFC1, 64, 1
    dq 0, 0, 1
    dq 0, 65, 1
    dq 0, 256, 1
    dq 0, 0x100000001, 1
    dq 0x10000000, 1, 1
    dq 0x10000001, 1, 1
    dq 0xFFFFFFFFFFFFFFFF, 1, 1
    dq 0, 0xFFFFFFFFFFFFFFFF, 1
    dq 0, 64, 0
    dq 0x0FFFFFFE, 2, 0
    dq 0x0FFFFFFE, 3, 1
ata78_table_end:
ata78_count equ (ata78_table_end - ata78_table)/24

align 8
; Test 80: mem_alloc64 sizes (size, expected 0 fail/1 success).
; Each case runs from an empty heap (mem_reset64 first), so success is
; deterministic. 6M heap: 6291456 bytes; max fitting request is 6M-48
; (header 32 + 16-align). Near-UINT64_MAX sizes must fail via
; size+15 overflow or capacity, never corrupt the chain.
alloc80_table:
    dq 0, 0
    dq 1, 1
    dq 16, 1
    dq 6291408, 1
    dq 6291456, 0
    dq 104857600, 0
    dq 0xFFFFFFFFFFFFFFFF, 0
    dq 0xFFFFFFFFFFFFFFF1, 0
    dq 0xFFFFFFFFFFFFFFF0, 0
    dq 0x7FFFFFFFFFFFFFFF, 0
alloc80_table_end:
alloc80_count equ (alloc80_table_end - alloc80_table)/16

align 8
; Test 82: kernel extent predicate (k_lba, k_sec, v_lba, expected).
; Predicate (same as make check-layout): k_lba+k_sec <= v_lba.
layout82_ext_table:
    dd 16, 176, 512, 0
    dd 16, 176, 191, 1
    dd 16, 500, 512, 1
    dd 0, 16, 512, 0
    dd 16, 176, 192, 0
    dd 16, 177, 192, 1
layout82_ext_table_end:
layout82_ext_count equ (layout82_ext_table_end - layout82_ext_table)/16

align 8
; Test 82: volume-fits predicate (v_lba, v_sec, img_mb, expected).
; Predicate: (v_lba+v_sec)*512 <= img_mb*1M, no 64-bit wrap.
layout82_fit_table:
    dd 512, 2880, 10, 0
    dd 512, 2880, 1, 1
    dd 512, 20000, 10, 1
    dd 0, 2880, 10, 0
layout82_fit_table_end:
layout82_fit_count equ (layout82_fit_table_end - layout82_fit_table)/16


section .bss
alignb 16
p8_env_buf: resb 1024
p8_env_small: resb 64
p8_outbuf: resb 64
p8_com_src: resb 1024
p8_exe_src: resb 1024
p8_file_buf: resb 1024
p9_bufin: resb 32
p9_rwbuf: resb 64
; --- Test 77: BPB table scratch with sentinels (no disk I/O) ---
bpb77_pre: resb 16
bpb77_boot: resb 512
bpb77_post: resb 16
bpb77_dpb: resb 64
bpb77_dpb_post: resb 16
bpb77_snap: resb 48
; --- Test 79: FAT chain bounds scratch with sentinels (no disk I/O) ---
fat79_pre: resb 16
fat79_buf: resb 128
fat79_post: resb 16
fat79_dpb: resb 64
fat79_dpb_post: resb 16


%else
; ---- Lean stub (SKIP_SELFTEST): no suite linked in effect.
selftest_run64:
    xor eax, eax
    ret
%endif
