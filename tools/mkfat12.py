#!/usr/bin/env python3
"""Stamp a real FAT12 volume into a dos64 image at the canonical VOL_LBA.

Layout (default 1.44M geometry, 2880 sectors, 1 sector/cluster):
  LBA+0        : boot sector with BPB + AA55 (data only; never executed)
  LBA+1..9     : FAT #1 (9 sectors)
  LBA+10..18   : FAT #2 (mirror)
  LBA+19..32   : root dir (14 sectors, 224 entries)
  LBA+33..     : data clusters 2..2848 (1 sector each)

Bigger volumes (PLAN.md N4A.3, `dos64-tools.img`): `--sec-per-clus` grows
the cluster size (sectors/cluster, power-of-2) so a larger `--vol-totsec`
still fits FAT12's ~4084-cluster ceiling. FAT size (sectors/FAT) is
computed from cluster count, not hardcoded, so the default 1-sector-
cluster/2880-sector geometry above still yields the historical 9-sector
FAT byte-for-byte; only bigger/differently-shaped volumes see a
different FATSZ. Root dir stays 14 sectors/224 entries in every case
(more than enough for any corpus shipped so far).

Idempotent: rebuilds the region from scratch on every run so repeated
`make` boots stay deterministic. Files with fixed content:
  HELLO.TXT  1 cluster   greeting text
  README.TXT 2 clusters  volume notes (exercises FAT chaining)
  TEST.COM   1 cluster   single RET (minimal EXEC/loader target)
  DATA.BIN   1 cluster   0x00..0xFF pattern

Client files (N1 cross-assembled samples): `--extra-file NAME=HOSTPATH`
appends one 8.3 file per flag (e.g. `HELLO.COM=build/nasm-samples/HELLO.COM`).
Used by `make nasm-samples` for the dos64-nasm.img variant and by
`make dos64-tools.img` (N4A.3) for the bigger NASM64.COM volume; the
default `make` image carries only the four fixed files. Extra files must
fit the remaining clusters and must not collide with fixed or reserved
test names.

Single source of truth: the Makefile disk-layout block is canonical. It
generates build/include/layout.inc for the bootloader/kernel and passes
the same numbers here explicitly on every invocation, e.g.::

  python3 tools/mkfat12.py --vol-lba 512 --vol-totsec 2880 \\
      --sector-size 512 --kernel-lba 16 --kernel-sectors 224 build/dos64.img

This script owns NO hardcoded layout defaults: every layout value must
arrive via CLI flag or its DOS64_* env fallback (DOS64_VOL_LBA,
DOS64_VOL_TOTSEC, DOS64_SECSIZ, DOS64_KERNEL_LBA, DOS64_KERNEL_SECTORS).
A missing value is fatal, so a half-relocated image can never be stamped
silently. The kernel/volume extents must not overlap, and the stamp is
read back (BPB TotSec16 + AA55) before reporting success.
"""
import argparse
import os
import re
import struct
import sys

ROOTSEC = 14
NROOT = 224
# FAT12 requires CountOfClusters < 4085 (else the volume is FAT16+ by the
# Microsoft FAT spec); leave a little headroom under the true ceiling.
FAT12_MAX_CLUSTERS = 4084

HELLO = (b"Hello from MS-DOS64 FAT12 volume!\r\n"
         b"This file lives on the real disk image at LBA 512+.\r\n"
         b"Read it with INT 21h FCB calls or the COMMAND64 TYPE command.\r\n")

README = ((b"MS-DOS64 FAT12 demo volume (1.44M geometry, LBA 512+).\r\n"
           b"Files: HELLO.TXT README.TXT TEST.COM DATA.BIN.\r\n"
           b"Kernel mounts this region at boot via fs_mount_volume64.\r\n"
           b"Writes flush FAT+root write-through so files persist.\r\n"
           b"Scratch LBAs 400/500-511 stay clear of this region.\r\n"
           b"Padding to force a two-cluster chain follows....\r\n") * 4)[:1000]

TESTCOM = b"\xc3"  # RET — minimal COM: loader copies it, entry = PSP+PSP_SIZE
DATA = bytes(range(256)) * 2  # 512B pattern


def _env_int(name):
    """Return int(os.environ[name]) or None when unset/empty.

    Never supplies a layout default: callers must pass the value
    explicitly (CLI flag preferred). Exits only on malformed integers.
    """
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return None
    try:
        return int(raw, 0)
    except ValueError:
        sys.exit(f"mkfat12: invalid {name}={raw!r}: expected integer")


def _resolve(cli_value, env_name, flag):
    if cli_value is not None:
        return cli_value
    value = _env_int(env_name)
    if value is not None:
        return value
    sys.exit(f"mkfat12: missing layout value: pass {flag} (or set {env_name}). "
             f"Canonical values live in the Makefile disk-layout block.")


def _int(s):
    return int(s, 0)


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Stamp the canonical FAT12 volume into a dos64 image. "
                    "All layout values are required (no built-in defaults).")
    p.add_argument("--vol-lba", type=_int, default=None,
                   help="volume start LBA (or DOS64_VOL_LBA)")
    p.add_argument("--vol-totsec", "--vol-sectors", dest="vol_totsec",
                   type=_int, default=None,
                   help="volume size in sectors (or DOS64_VOL_TOTSEC)")
    p.add_argument("--sector-size", "--secsiz", dest="sector_size",
                   type=_int, default=None,
                   help="bytes/sector, must be 512 (or DOS64_SECSIZ)")
    p.add_argument("--kernel-lba", type=_int, default=None,
                   help="kernel start LBA, for overlap check (or DOS64_KERNEL_LBA)")
    p.add_argument("--kernel-sectors", type=_int, default=None,
                    help="kernel extent in sectors, for overlap check (or DOS64_KERNEL_SECTORS)")
    p.add_argument("--sec-per-clus", dest="sec_per_clus", type=_int, default=1,
                    help="sectors per cluster, power of 2 (default 1, the "
                         "1.44M-floppy geometry). Bigger volumes (N4A.3 "
                         "dos64-tools.img) need >1 to stay under FAT12's "
                         "~4084-cluster ceiling; FAT size is computed to fit.")
    p.add_argument("--extra-file", dest="extra_files", action="append",
                    default=[],
                    metavar="NAME=HOSTPATH",
                    help="stage one client file (repeatable): 8.3 volume name "
                         "= host path, e.g. HELLO.COM=build/nasm-samples/HELLO.COM "
                         "(N1 samples for dos64-nasm.img; default image omits these)")
    p.add_argument("image", nargs="?", default="build/dos64.img",
                    help="image file to stamp (default: build/dos64.img)")
    return p.parse_args(argv)


# 8.3 client-file names (uppercased before matching; per-part charset is the
# FAT conservative set so the in-guest FCB parser accepts them verbatim).
_NAME_PART = r"[A-Z0-9!$#%&'()\-@^_`{}~]+"
_EXTRA_RE = re.compile(rf"^({_NAME_PART})\.({_NAME_PART})$")

# Fixed + reserved names an --extra-file must not shadow (base volume files
# and the destructive-test namespace owned by tests 71/83).
_FIXED_NAMES = {"HELLO   TXT", "README  TXT", "TEST    COM", "DATA    BIN"}
_RESERVED_NAMES = {"SCRATCH TXT", "RENAMED TXT", "CRASH   TXT"}


def _parse_extra(spec):
    """Parse one NAME=HOSTPATH spec into (dir11, data). Fatal on misuse."""
    if "=" not in spec:
        sys.exit(f"mkfat12: bad --extra-file {spec!r}: want NAME=HOSTPATH "
                 f"(e.g. HELLO.COM=build/nasm-samples/HELLO.COM)")
    name, _, host = spec.partition("=")
    name = name.strip().upper()
    host = host.strip()
    m = _EXTRA_RE.match(name)
    if not m or len(m.group(1)) > 8 or len(m.group(2)) > 3:
        sys.exit(f"mkfat12: bad --extra-file name {name!r}: want 8.3 "
                 f"(1-8 + '.' + 1-3 chars)")
    dir11 = m.group(1).ljust(8) + m.group(2).ljust(3)
    if dir11 in _FIXED_NAMES or dir11 in _RESERVED_NAMES:
        sys.exit(f"mkfat12: --extra-file {name!r} collides with a fixed or "
                 f"reserved volume name")
    try:
        with open(host, "rb") as f:
            data = f.read()
    except OSError as e:
        sys.exit(f"mkfat12: cannot read --extra-file {host!r}: {e}")
    if not data:
        sys.exit(f"mkfat12: --extra-file {name!r} is empty ({host})")
    return dir11, data


def chain_for(nclusters, start):
    return list(range(start, start + nclusters))


def calc_fatsz(totsec, secsiz, sec_per_clus, rootsec):
    """Compute FAT size in sectors for a FAT12 volume, iteratively (the
    classic circular FAT-sizing formula: FAT size depends on cluster
    count, cluster count depends on data-area size, data-area size
    depends on FAT size). Converges in a couple of iterations since FATSZ
    is tiny relative to TOTSEC. Mirrors real FAT12 formatters; for the
    canonical 2880-sector/1-sector-cluster geometry this reproduces the
    historical FATSZ=9 exactly (verified by check-layout / test-82
    invariants elsewhere), so the default image is unaffected byte-for-
    byte. Returns (fatsz_sectors, data_clusters).
    """
    fatsz = 1
    for _ in range(32):
        data_sectors = totsec - 1 - 2 * fatsz - rootsec
        if data_sectors <= 0:
            sys.exit(f"mkfat12: volume too small: {totsec} sectors leaves no "
                      f"room for data after 1 boot + 2x{fatsz} FAT + "
                      f"{rootsec} root")
        clusters = data_sectors // sec_per_clus
        # Each FAT12 entry is 12 bits; N entries need ceil(N*3/2) bytes.
        fat_bytes_needed = ((clusters + 2) * 3 + 1) // 2
        needed = (fat_bytes_needed + secsiz - 1) // secsiz
        if needed == fatsz:
            return fatsz, clusters
        fatsz = needed
    sys.exit("mkfat12: FAT size calculation did not converge")


def main(img_path=None, argv=None):
    """Entry point. CLI: main() parses sys.argv. Programmatic legacy
    style main("path/to.img") still works (layout via DOS64_* env)."""
    if argv is not None:
        args = parse_args(argv)
        if img_path is not None:
            args.image = img_path
    elif img_path is not None:
        # Legacy programmatic call: do not touch sys.argv; layout comes
        # from the DOS64_* environment.
        args = parse_args([])
        args.image = img_path
    else:
        args = parse_args(None)
    img_path = args.image
    VOL_LBA = _resolve(args.vol_lba, "DOS64_VOL_LBA", "--vol-lba")
    TOTSEC = _resolve(args.vol_totsec, "DOS64_VOL_TOTSEC", "--vol-totsec")
    SECSIZ = _resolve(args.sector_size, "DOS64_SECSIZ", "--sector-size")
    KERNEL_LBA = _resolve(args.kernel_lba, "DOS64_KERNEL_LBA", "--kernel-lba")
    KERNEL_SECTORS = _resolve(args.kernel_sectors, "DOS64_KERNEL_SECTORS",
                              "--kernel-sectors")
    SECPERCLUS = args.sec_per_clus

    if SECSIZ != 512:
        sys.exit(f"mkfat12: unsupported sector size {SECSIZ}: "
                 f"FAT12 geometry assumes 512 (canonical Makefile value)")
    if SECPERCLUS <= 0 or (SECPERCLUS & (SECPERCLUS - 1)) != 0:
        sys.exit(f"mkfat12: --sec-per-clus {SECPERCLUS} must be a positive "
                 f"power of 2")
    if VOL_LBA < 0 or TOTSEC <= 0:
        sys.exit(f"mkfat12: bad volume extent LBA {VOL_LBA}+{TOTSEC}")
    if KERNEL_LBA < 0 or KERNEL_SECTORS <= 0:
        sys.exit(f"mkfat12: bad kernel extent LBA {KERNEL_LBA}+{KERNEL_SECTORS}")
    k_end = KERNEL_LBA + KERNEL_SECTORS
    v_end = VOL_LBA + TOTSEC
    if KERNEL_LBA < v_end and VOL_LBA < k_end:
        sys.exit(f"mkfat12: layout overlap: kernel [{KERNEL_LBA},{k_end}) "
                 f"vs volume [{VOL_LBA},{v_end})")

    FATSZ, maxclus = calc_fatsz(TOTSEC, SECSIZ, SECPERCLUS, ROOTSEC)
    if maxclus >= FAT12_MAX_CLUSTERS:
        sys.exit(f"mkfat12: {maxclus} clusters exceeds the FAT12 ceiling "
                 f"({FAT12_MAX_CLUSTERS}): raise --sec-per-clus or shrink "
                 f"--vol-totsec")
    CLUSSIZ = SECSIZ * SECPERCLUS

    files = [
        ("HELLO   TXT", 0x20, HELLO),
        ("README  TXT", 0x20, README),
        ("TEST    COM", 0x20, TESTCOM),
        ("DATA    BIN", 0x20, DATA),
    ]
    seen = set()
    for spec in args.extra_files:
        dir11, data = _parse_extra(spec)
        if dir11 in seen:
            sys.exit(f"mkfat12: duplicate --extra-file {dir11!r}")
        seen.add(dir11)
        files.append((dir11, 0x20, data))
    # Assign clusters sequentially from 2 (cluster size = SECPERCLUS sectors).
    clus = 2
    layout = []
    for name, attr, data in files:
        n = (len(data) + CLUSSIZ - 1) // CLUSSIZ
        layout.append((name, attr, data, chain_for(n, clus)))
        clus += n
    if clus - 2 > maxclus:
        sys.exit(f"mkfat12: volume full: {len(files)} files need {clus - 2} "
                 f"clusters, have {maxclus}")
    if len(files) > NROOT:
        sys.exit(f"mkfat12: volume full: {len(files)} files exceed "
                 f"{NROOT} root entries")

    vol = bytearray(TOTSEC * SECSIZ)

    # Boot sector + BPB.
    bs = bytearray(SECSIZ)
    bs[0:3] = b"\xeb\x3c\x90"
    bs[3:11] = b"MSDOS64 "
    struct.pack_into("<H", bs, 11, SECSIZ)
    bs[13] = SECPERCLUS
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

    # Data area: cluster c -> volume-relative sector data_base+(c-2)*SECPERCLUS,
    # each cluster spanning CLUSSIZ = SECSIZ*SECPERCLUS bytes.
    data_base = 1 + 2 * FATSZ + ROOTSEC
    for name, attr, data, chain in layout:
        for i, c in enumerate(chain):
            chunk = data[i * CLUSSIZ:(i + 1) * CLUSSIZ]
            off = (data_base + (c - 2) * SECPERCLUS) * SECSIZ
            vol[off:off + len(chunk)] = chunk

    need = (VOL_LBA + TOTSEC) * SECSIZ
    try:
        have = os.path.getsize(img_path)
    except OSError as e:
        sys.exit(f"mkfat12: cannot write {img_path}: {e}")
    if have < need:
        sys.exit(f"mkfat12: image {img_path} too small ({have} bytes): "
                 f"need >= {need} bytes for volume LBA {VOL_LBA}+{TOTSEC} "
                 f"x {SECSIZ}B")
    try:
        with open(img_path, "r+b") as f:
            f.seek(VOL_LBA * SECSIZ)
            f.write(vol)
            # Read-back verification: the stamped boot sector must carry
            # the requested geometry before we declare success.
            f.seek(VOL_LBA * SECSIZ)
            back = f.read(SECSIZ)
    except OSError as e:
        sys.exit(f"mkfat12: cannot write {img_path}: {e}")
    (tot_back,) = struct.unpack_from("<H", back, 19)
    (sig_back,) = struct.unpack_from("<H", back, 510)
    if tot_back != TOTSEC or sig_back != 0xAA55:
        sys.exit(f"mkfat12: read-back mismatch at LBA {VOL_LBA}: "
                 f"TotSec16={tot_back} (want {TOTSEC}) sig={sig_back:#x}")
    print(f"mkfat12: stamped {TOTSEC} sectors ({len(vol)}B) at LBA {VOL_LBA} "
          f"in {img_path}: " + ", ".join(n.strip() for n, _, _, _ in layout))


if __name__ == "__main__":
    main()
