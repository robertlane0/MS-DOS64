/* 64-bit kernel linker – flat binary at 1 MiB */
OUTPUT_FORMAT("elf64-x86-64")
ENTRY(_start)
PHDRS
{
    text PT_LOAD FLAGS(5);   /* R + X: code + rodata (no W) */
    data PT_LOAD FLAGS(6);   /* R + W: data + bss (no X) */
}
SECTIONS
{
    . = 0x100000;
    .text : {
        *(.text.start)
        *(.text)
        *(.text.*)
    } :text
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } :text
    .data : {
        *(.data)
        *(.data.*)
    } :data
    .bss : {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } :data
    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
    }
}
