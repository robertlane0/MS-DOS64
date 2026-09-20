#!/usr/bin/env python3
"""Convert a -pie-linked freestanding ELF into DOS64's EXE64 ('MZ64')
flat image format (PLAN.md item 11 N4A.3/N4A.4 record; full design
rationale in docs/25-n4a1-trim.md §7 and the EXE64_HDR_SIZE comment in
src/kernel/proc64.asm — this tool's output must match that reader
exactly, field for field).

Why this exists: `objcopy -O binary` (what every other userland program
here uses) produces a flat, headerless, base-0-linked image. That is
"slide-safe" for CODE — RIP-relative addressing means an instruction
computing "the address of X" is correct at any load address — but NOT
for static DATA initialized to the address of another static (e.g. a
`static const T *table[] = {&foo, ...}` dispatch table, an ordinary and
common C idiom, though never one the hand-written N1/N4B asm samples
have any reason to use). Such a value is a plain compile-time constant
once the final link resolves it, correct only if the image truly loads
at address 0 — never the case here (DOS64 loads .COM/.EXE64 images at
PSP+PSP_SIZE, a nonzero, heap-allocation-dependent address that varies
run to run). Linking with `-pie` instead keeps those fixups as
`R_X86_64_RELATIVE` entries in `.rela.dyn` rather than letting `ld`
resolve them away — this tool extracts that table and embeds it
alongside the flat payload, in a format `proc_load_image64` (the
kernel loader) applies once after copying the image in, adding the
true load bias to each entry.

Usage:
    python3 elf2exe64.py INPUT.elf OUTPUT.exe64 [--stack-size N]

INPUT.elf must be linked with `-pie` (so `.rela.dyn` carries
R_X86_64_RELATIVE fixups instead of having them resolved away) and,
like every other userland image here, with crt0.o first so the entry
point lands at the very start of the image.
"""
import argparse
import struct
import subprocess
import sys
import tempfile
import os

EXE64_MAGIC = 0x34365A4D          # 'MZ64' LE
EXE64_HDR_SIZE = 48
R_X86_64_RELATIVE = 8


def read_elf64_header(data):
    if data[:4] != b"\x7fELF":
        sys.exit("elf2exe64: not an ELF file")
    ei_class = data[4]
    if ei_class != 2:
        sys.exit("elf2exe64: not a 64-bit ELF")
    (e_type, e_machine, e_version, e_entry, e_phoff, e_shoff, e_flags,
     e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum,
     e_shstrndx) = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    return {
        "e_type": e_type, "e_entry": e_entry, "e_phoff": e_phoff,
        "e_shoff": e_shoff, "e_phentsize": e_phentsize, "e_phnum": e_phnum,
        "e_shentsize": e_shentsize, "e_shnum": e_shnum,
        "e_shstrndx": e_shstrndx,
    }


def read_program_headers(data, hdr):
    phdrs = []
    for i in range(hdr["e_phnum"]):
        off = hdr["e_phoff"] + i * hdr["e_phentsize"]
        (p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz,
         p_align) = struct.unpack_from("<IIQQQQQQ", data, off)
        phdrs.append({
            "p_type": p_type, "p_offset": p_offset, "p_vaddr": p_vaddr,
            "p_filesz": p_filesz, "p_memsz": p_memsz,
        })
    return phdrs


def read_section_headers(data, hdr):
    shdrs = []
    for i in range(hdr["e_shnum"]):
        off = hdr["e_shoff"] + i * hdr["e_shentsize"]
        (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size,
         sh_link, sh_info, sh_addralign, sh_entsize) = struct.unpack_from(
            "<IIQQQQIIQQ", data, off)
        shdrs.append({
            "sh_name": sh_name, "sh_type": sh_type, "sh_addr": sh_addr,
            "sh_offset": sh_offset, "sh_size": sh_size,
        })
    shstr = shdrs[hdr["e_shstrndx"]]
    strtab_off = shstr["sh_offset"]

    def name_of(sh):
        end = data.index(b"\0", strtab_off + sh["sh_name"])
        return data[strtab_off + sh["sh_name"]:end].decode()
    for sh in shdrs:
        sh["name"] = name_of(sh)
    return shdrs


PT_LOAD = 1
SHT_RELA = 4


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf", help="input ELF, linked with -pie")
    ap.add_argument("out", help="output EXE64 flat image")
    ap.add_argument("--stack-size", type=int, default=0,
                     help="requested stack size hint, 0..65536 (informational; "
                          "the actual per-process stack is PROC_STACK_SIZE, "
                          "src/kernel/proc64.asm — this field is currently "
                          "unused by the loader beyond bounds-checking)")
    args = ap.parse_args()

    with open(args.elf, "rb") as f:
        data = f.read()

    ehdr = read_elf64_header(data)
    if ehdr["e_type"] != 3:  # ET_DYN
        sys.exit("elf2exe64: expected ET_DYN (a -pie link) — "
                 f"got e_type={ehdr['e_type']}")

    phdrs = read_program_headers(data, ehdr)
    loads = [p for p in phdrs if p["p_type"] == PT_LOAD]
    if not loads:
        sys.exit("elf2exe64: no PT_LOAD segments")
    lowest_vaddr = min(p["p_vaddr"] for p in loads)
    if lowest_vaddr != 0:
        sys.exit(f"elf2exe64: expected base 0, lowest PT_LOAD vaddr is "
                 f"{hex(lowest_vaddr)} — link script origin changed?")
    mem_size = max(p["p_vaddr"] + p["p_memsz"] for p in loads)

    entry_off = ehdr["e_entry"]

    # Flat code+data payload: reuse objcopy, exactly like every other
    # userland image here, so this stays byte-identical to that path
    # for the parts objcopy alone already gets right (it naturally
    # excludes .bss — NOBITS has no file content — which is exactly
    # image_size's meaning here; the loader zeroes [image_size,
    # mem_size) itself, see proc_load_image64).
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tf:
        payload_path = tf.name
    try:
        subprocess.run(["objcopy", "-O", "binary", "-R", ".rela.dyn",
                        args.elf, payload_path], check=True)
        with open(payload_path, "rb") as f:
            payload = f.read()
    finally:
        os.unlink(payload_path)
    image_size = len(payload)
    if image_size > mem_size:
        sys.exit(f"elf2exe64: payload ({image_size} B) exceeds computed "
                 f"mem_size ({mem_size} B) — PT_LOAD parsing bug?")
    if image_size == 0:
        sys.exit("elf2exe64: empty payload")
    if image_size > 8 * 1024 * 1024:
        sys.exit(f"elf2exe64: payload {image_size} B exceeds the 8 MiB "
                 f"proc_verify_image64 ceiling")
    if mem_size > 8 * 1024 * 1024:
        sys.exit(f"elf2exe64: mem_size {mem_size} B exceeds the 8 MiB "
                 f"proc_verify_image64 ceiling")
    if entry_off >= image_size:
        sys.exit(f"elf2exe64: entry {hex(entry_off)} falls outside the "
                 f"{image_size}-byte payload — crt0.o not linked first?")

    # Extract .rela.dyn: every entry must be R_X86_64_RELATIVE (no
    # imported/exported dynamic symbols expected in a -nostdlib,
    # fully self-contained freestanding link; anything else means this
    # link pulled in something needing real dynamic-linker support,
    # which this loader does not provide).
    shdrs = read_section_headers(data, ehdr)
    rela = [s for s in shdrs if s["name"] == ".rela.dyn"]
    entries = []
    if rela:
        s = rela[0]
        count = s["sh_size"] // 24
        for i in range(count):
            off = s["sh_offset"] + i * 24
            r_offset, r_info, r_addend = struct.unpack_from("<QQq", data, off)
            r_type = r_info & 0xffffffff
            if r_type != R_X86_64_RELATIVE:
                sys.exit(f"elf2exe64: unsupported relocation type {r_type} "
                         f"at .rela.dyn[{i}] (only R_X86_64_RELATIVE is "
                         f"supported — a real dynamic symbol import/export "
                         f"snuck into the link)")
            if r_offset >= image_size:
                sys.exit(f"elf2exe64: relocation offset {hex(r_offset)} "
                         f"falls outside the {image_size}-byte payload")
            entries.append((r_offset, r_addend))
    reloc_count = len(entries)

    if not (0 <= args.stack_size <= 65536):
        sys.exit("elf2exe64: --stack-size must be 0..65536")

    reloc_off = EXE64_HDR_SIZE + image_size if reloc_count else 0
    header = struct.pack(
        "<IIQIIIIQQ",
        EXE64_MAGIC, EXE64_HDR_SIZE, image_size, entry_off,
        args.stack_size, reloc_count, reloc_off, mem_size, 0,
    )
    assert len(header) == EXE64_HDR_SIZE, len(header)

    reloc_table = b"".join(struct.pack("<Qq", off, addend)
                            for off, addend in entries)

    with open(args.out, "wb") as f:
        f.write(header)
        f.write(payload)
        f.write(reloc_table)

    total = EXE64_HDR_SIZE + image_size + len(reloc_table)
    print(f"elf2exe64: {args.out}: {total} bytes "
         f"(hdr {EXE64_HDR_SIZE} + image {image_size} + "
         f"{reloc_count} relocs x 16 B = {len(reloc_table)}); "
         f"mem_size {mem_size} B ({mem_size - image_size} B .bss), "
         f"entry +{hex(entry_off)}")


if __name__ == "__main__":
    main()
