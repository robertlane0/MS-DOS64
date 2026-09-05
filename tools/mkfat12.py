#!/usr/bin/env python3
"""Stamp a real FAT12 volume into dos64.img at VOL_LBA (default 512).

Layout (1.44M geometry, 2880 sectors):
  LBA+0        : boot sector with BPB + AA55 (data only; never executed)
  LBA+1..9     : FAT #1 (9 sectors)
  LBA+10..18   : FAT #2 (mirror)
  LBA+19..32   : root dir (14 sectors, 224 entries)
  LBA+33..     : data clusters 2..2848 (1 sector each)

Idempotent: rebuilds the region from scratch on every run so repeated
`make` boots stay deterministic. Files with fixed content:
  HELLO.TXT  1 cluster   greeting text
  README.TXT 2 clusters  volume notes (exercises FAT chaining)
  TEST.COM   1 cluster   single RET (minimal EXEC/loader target)
  DATA.BIN   1 cluster   0x00..0xFF pattern
"""
import struct
import sys

VOL_LBA = 512
SECSIZ = 512
TOTSEC = 2880
FATSZ = 9
ROOTSEC = 14
NROOT = 224

HELLO = (b"Hello from MS-DOS64 FAT12 volume!\r\n"
         b"This file lives on the real disk image at LBA 512+.\r\n"
         b"Read it with INT 21h FCB calls or the COMMAND64 TYPE command.\r\n")

README = ((b"MS-DOS64 FAT12 demo volume (1.44M geometry, LBA 512+).\r\n"
           b"Files: HELLO.TXT README.TXT TEST.COM DATA.BIN.\r\n"
           b"Kernel mounts this region at boot via fs_mount_volume64.\r\n"
           b"Writes flush FAT+root write-through so files persist.\r\n"
           b"Scratch LBAs 200/500-511 stay clear of this region.\r\n"
           b"Padding to force a two-cluster chain follows....\r\n") * 4)[:1000]

TESTCOM = b"\xc3"  # RET — minimal COM: loader copies it, entry = PSP+512
DATA = bytes(range(256)) * 2  # 512B pattern


def chain_for(nclusters, start):
    return list(range(start, start + nclusters))


def main(img_path):
    files = [
        ("HELLO   TXT", 0x20, HELLO),
        ("README  TXT", 0x20, README),
        ("TEST    COM", 0x20, TESTCOM),
        ("DATA    BIN", 0x20, DATA),
    ]
    # Assign clusters sequentially from 2.
    clus = 2
    layout = []
    for name, attr, data in files:
        n = (len(data) + SECSIZ - 1) // SECSIZ
        layout.append((name, attr, data, chain_for(n, clus)))
        clus += n

    vol = bytearray(TOTSEC * SECSIZ)

    # Boot sector + BPB.
    bs = bytearray(SECSIZ)
    bs[0:3] = b"\xeb\x3c\x90"
    bs[3:11] = b"MSDOS64 "
    struct.pack_into("<H", bs, 11, SECSIZ)
    bs[13] = 1
    struct.pack_into("<H", bs, 14, 1)
    bs[16] = 2
    struct.pack_into("<H", bs, 17, NROOT)
    struct.pack_into("<H", bs, 19, TOTSEC)
    bs[21] = 0xF0
    struct.pack_into("<H", bs, 22, FATSZ)
    struct.pack_into("<H", bs, 24, 18)
    struct.pack_into("<H", bs, 26, 2)
    struct.pack_into("<I", bs, 28, 0)
    struct.pack_into("<I", bs, 32, 0)
    struct.pack_into("<H", bs, 510, 0xAA55)
    vol[0:SECSIZ] = bs

    # FATs.
    fat = bytearray(FATSZ * SECSIZ)
    fat[0], fat[1], fat[2] = 0xF0, 0xFF, 0xFF  # media + cluster 1 EOF

    def set12(fat, c, v):
        off = c + (c // 2)
        if c & 1:
            fat[off] = (fat[off] & 0x0F) | ((v & 0xF) << 4)
            fat[off + 1] = (v >> 4) & 0xFF
        else:
            fat[off] = v & 0xFF
            fat[off + 1] = (fat[off + 1] & 0xF0) | ((v >> 8) & 0xF)

    for name, attr, data, chain in layout:
        for i, c in enumerate(chain):
            nxt = chain[i + 1] if i + 1 < len(chain) else 0xFFF
            set12(fat, c, nxt)
    fat_off = SECSIZ  # FAT #1 at volume-relative sector 1
    vol[fat_off:fat_off + len(fat)] = fat
    vol[fat_off + len(fat):fat_off + 2 * len(fat)] = fat  # mirror FAT #2

    # Root dir (volume-relative sector 1+2*9 = 19).
    root_off = (1 + 2 * FATSZ) * SECSIZ
    for i, (name, attr, data, chain) in enumerate(layout):
        e = bytearray(32)
        e[0:11] = name.encode("ascii")
        e[11] = attr
        struct.pack_into("<H", e, 22, 0x7A11)  # time
        struct.pack_into("<H", e, 24, 0x4A21)  # date
        struct.pack_into("<H", e, 26, chain[0])
        struct.pack_into("<I", e, 28, len(data))
        root_off_i = root_off + i * 32
        vol[root_off_i:root_off_i + 32] = e

    # Data area: cluster c -> volume-relative sector 19+14+(c-2) = 31+c.
    data_base = 1 + 2 * FATSZ + ROOTSEC
    for name, attr, data, chain in layout:
        for i, c in enumerate(chain):
            chunk = data[i * SECSIZ:(i + 1) * SECSIZ]
            sec = data_base + (c - 2)
            vol[sec * SECSIZ:sec * SECSIZ + len(chunk)] = chunk

    with open(img_path, "r+b") as f:
        f.seek(VOL_LBA * SECSIZ)
        f.write(vol)
    print(f"mkfat12: stamped {TOTSEC} sectors ({len(vol)}B) at LBA {VOL_LBA} "
          f"in {img_path}: " + ", ".join(n.strip() for n, _, _, _ in layout))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/dos64.img")
