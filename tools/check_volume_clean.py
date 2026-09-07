#!/usr/bin/env python3
"""Verify a dos64.img FAT12 volume is clean after a self-test cycle.

Clean means:
  - boot signature AA55 + TotSec16 match the expected extent,
  - FAT1 == FAT2 byte-for-byte (mirrors match),
  - no LIVE test-namespace entries (SCRATCH.TXT / RENAMED.TXT / CRASH.TXT),
  - non-test files HELLO.TXT / README.TXT / TEST.COM / DATA.BIN present
    with the exact sizes/content stamped by tools/mkfat12.py,
  - no DANGLING (live entry reaches free/bad/oob/truncated chain),
  - no XLINK (one cluster reachable from two live entries),
  - no orphans (allocated-but-unreachable clusters, i.e. leaks).

This is the host-side counterpart of the in-guest checks in tests 71/83
(pre-clean recovery + post-run preservation + scrub/mirror verification).
Use it to compare pre/post directory metadata and FAT allocations around
a self-test run, including deliberately interrupted runs:

  python3 tools/mkfat12.py ... build/dos64.img   # fresh stamp
  python3 tools/check_volume_clean.py ... build/dos64.img   # pre: must be clean
  timeout 25 qemu-system-x86_64 -drive file=build/dos64.img,format=raw \\
      -serial stdio -display none                # smoke or full boot
  python3 tools/check_volume_clean.py ... build/dos64.img   # post: must be clean

A fresh image must have identical directory contents before and after a
complete self-test cycle; a failed/interrupted destructive cycle must not
destroy non-test files (recovery is delete + reclaim + heal on next boot,
so only leaks remain, which this tool reports as orphans).

Layout values must arrive explicitly (same flags as tools/mkfat12.py) or
via DOS64_* env; no hardcoded defaults.
"""
import argparse
import os
import struct
import sys

FATSZ = 9
ROOTSEC = 14
NROOT = 224

# Reserved destructive-test namespace (must never be LIVE on a clean image).
TEST_NAMES = {b"SCRATCH TXT", b"RENAMED TXT", b"CRASH   TXT"}

# Expected non-test files (names as 11-byte dir entries).
HELLO_NAME = b"HELLO   TXT"
README_NAME = b"README  TXT"
TESTCOM_NAME = b"TEST    COM"
DATABIN_NAME = b"DATA    BIN"


def _env_int(name):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return None
    try:
        return int(raw, 0)
    except ValueError:
        sys.exit(f"check_volume_clean: invalid {name}={raw!r}: expected integer")


def _resolve(cli_value, env_name, flag):
    if cli_value is not None:
        return cli_value
    value = _env_int(env_name)
    if value is not None:
        return value
    sys.exit(f"check_volume_clean: missing layout value: pass {flag} "
             f"(or set {env_name}). Canonical values live in the Makefile "
             f"disk-layout block.")


def _int(s):
    return int(s, 0)


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Verify a dos64.img FAT12 volume is clean "
                    "(no test files, mirrors match, no orphans/dangling).")
    p.add_argument("--vol-lba", type=_int, default=None,
                   help="volume start LBA (or DOS64_VOL_LBA)")
    p.add_argument("--vol-totsec", "--vol-sectors", dest="vol_totsec",
                   type=_int, default=None,
                   help="volume size in sectors (or DOS64_VOL_TOTSEC)")
    p.add_argument("--sector-size", "--secsiz", dest="sector_size",
                   type=_int, default=None,
                   help="bytes/sector, must be 512 (or DOS64_SECSIZ)")
    p.add_argument("--kernel-lba", type=_int, default=None,
                   help="kernel start LBA, for overlap sanity (or DOS64_KERNEL_LBA)")
    p.add_argument("--kernel-sectors", type=_int, default=None,
                   help="kernel extent in sectors (or DOS64_KERNEL_SECTORS)")
    p.add_argument("image", nargs="?", default="build/dos64.img",
                   help="image file to check (default: build/dos64.img)")
    return p.parse_args(argv)


def get12(fat, c):
    off = c + (c // 2)
    if c & 1:
        return ((fat[off] >> 4) | (fat[off + 1] << 4)) & 0xFFF
    return (fat[off] | ((fat[off + 1] & 0x0F) << 8)) & 0xFFF


def main(argv=None):
    args = parse_args(argv)
    VOL_LBA = _resolve(args.vol_lba, "DOS64_VOL_LBA", "--vol-lba")
    TOTSEC = _resolve(args.vol_totsec, "DOS64_VOL_TOTSEC", "--vol-totsec")
    SECSIZ = _resolve(args.sector_size, "DOS64_SECSIZ", "--sector-size")
    if SECSIZ != 512:
        sys.exit(f"check_volume_clean: unsupported sector size {SECSIZ}: "
                 f"want 512 (canonical Makefile value)")
    img_path = args.image
    try:
        with open(img_path, "rb") as f:
            f.seek(VOL_LBA * SECSIZ)
            vol = f.read(TOTSEC * SECSIZ)
    except OSError as e:
        sys.exit(f"check_volume_clean: cannot read {img_path}: {e}")
    if len(vol) < TOTSEC * SECSIZ:
        sys.exit(f"check_volume_clean: short read on {img_path}: "
                 f"got {len(vol)} want {TOTSEC * SECSIZ}")

    errors = []

    boot = vol[0:SECSIZ]
    (tot_back,) = struct.unpack_from("<H", boot, 19)
    (sig_back,) = struct.unpack_from("<H", boot, 510)
    if sig_back != 0xAA55:
        errors.append(f"boot sig {sig_back:#x} != 0xaa55")
    if tot_back != TOTSEC:
        errors.append(f"TotSec16 {tot_back} != {TOTSEC}")
    byts = struct.unpack_from("<H", boot, 11)[0]
    if byts != 512:
        errors.append(f"BytsPerSec {byts} != 512")
    fatsz = struct.unpack_from("<H", boot, 22)[0]
    if fatsz != FATSZ:
        errors.append(f"FATSz {fatsz} != {FATSZ}")

    fat_off = SECSIZ
    fat1 = vol[fat_off:fat_off + FATSZ * SECSIZ]
    fat2 = vol[fat_off + FATSZ * SECSIZ:fat_off + 2 * FATSZ * SECSIZ]
    if fat1 != fat2:
        errors.append("FAT mirrors differ (FAT1 != FAT2)")

    root_off = (1 + 2 * FATSZ) * SECSIZ
    root = vol[root_off:root_off + ROOTSEC * SECSIZ]
    data_base = 1 + 2 * FATSZ + ROOTSEC  # volume-relative sector of cluster 2
    maxclus = (TOTSEC - data_base) + 1  # clusters 2..maxclus

    live = []  # (name, firstclus, size)
    for i in range(NROOT):
        e = root[i * 32:(i + 1) * 32]
        first = e[0]
        if first == 0x00:
            break  # end of directory
        if first == 0xE5:
            continue  # deleted slot
        name = bytes(e[0:11])
        attr = e[11]
        if attr in (0x08, 0x0F):
            continue  # volume label / LFN: skip chain walk
        (firstclus,) = struct.unpack_from("<H", e, 26)
        (size,) = struct.unpack_from("<I", e, 28)
        live.append((name, firstclus, size))
        if name in TEST_NAMES:
            errors.append(f"test file {name.decode()} still LIVE (dirty)")

    by_name = {n: (c, s) for (n, c, s) in live}
    for want in (HELLO_NAME, README_NAME, TESTCOM_NAME, DATABIN_NAME):
        if want not in by_name:
            errors.append(f"non-test file {want.decode()} missing")

    def read_chain(firstclus, size):
        if size == 0:
            return b"" if firstclus == 0 else None
        if firstclus < 2 or firstclus > maxclus:
            return None
        out = bytearray()
        seen = set()
        c = firstclus
        hops = 0
        while True:
            if c in seen or hops > maxclus + 1:
                return None
            seen.add(c)
            v = get12(fat1, c)
            sec = data_base + (c - 2)
            chunk = vol[sec * SECSIZ:(sec + 1) * SECSIZ]
            out += chunk
            hops += 1
            if v >= 0xFF8:
                break
            if v in (0x000, 0x001) or v == 0xFF7 or v < 2 or v > maxclus:
                return None
            c = v
        return bytes(out[:size])

    # Content checks mirror the in-guest prefix/size assertions.
    if HELLO_NAME in by_name:
        c, s = by_name[HELLO_NAME]
        data = read_chain(c, s)
        if data is None:
            errors.append("HELLO.TXT chain dangling/truncated")
        else:
            if s < 32 or not data.startswith(b"Hello"):
                errors.append(f"HELLO.TXT content mismatch (size {s})")
    if README_NAME in by_name:
        c, s = by_name[README_NAME]
        data = read_chain(c, s)
        if data is None:
            errors.append("README.TXT chain dangling/truncated")
        else:
            if s != 1000 or not data.startswith(b"MS-D"):
                errors.append(f"README.TXT content mismatch (size {s})")
    if TESTCOM_NAME in by_name:
        c, s = by_name[TESTCOM_NAME]
        data = read_chain(c, s)
        if data is None:
            errors.append("TEST.COM chain dangling/truncated")
        else:
            if s != 1 or data != b"\xc3":
                errors.append(f"TEST.COM content mismatch (size {s})")
    if DATABIN_NAME in by_name:
        c, s = by_name[DATABIN_NAME]
        data = read_chain(c, s)
        if data is None:
            errors.append("DATA.BIN chain dangling/truncated")
        else:
            if s != 512 or data != bytes(range(256)) * 2:
                errors.append(f"DATA.BIN content mismatch (size {s})")

    # Chain walk for DANGLING / XLINK + orphan census.
    visited = set()
    for (name, firstclus, size) in live:
        if size == 0:
            if firstclus != 0:
                errors.append(f"{name.decode()}: size 0 but firstclus {firstclus}")
            continue
        if firstclus < 2 or firstclus > maxclus:
            errors.append(f"{name.decode()}: firstclus {firstclus} out of range")
            continue
        c = firstclus
        hops = 0
        while True:
            if c in visited:
                errors.append(f"XLINK: cluster {c} reachable twice "
                              f"(via {name.decode()})")
                break
            visited.add(c)
            v = get12(fat1, c)
            hops += 1
            if hops > maxclus + 1:
                errors.append(f"{name.decode()}: chain overlong/cycle")
                break
            if v >= 0xFF8:
                break
            if v == 0x000 or v == 0x001 or v == 0xFF7 or v < 2 or v > maxclus:
                errors.append(f"DANGLING: {name.decode()} reaches "
                              f"cluster {c} -> {v:#x}")
                break
            c = v

    orphans = []
    for c in range(2, maxclus + 1):
        v = get12(fat1, c)
        if v != 0 and v != 0xFF7 and c not in visited:
            orphans.append(c)
    if orphans:
        errors.append(f"{len(orphans)} orphan cluster(s): {orphans[:8]}"
                      + ("..." if len(orphans) > 8 else ""))

    if errors:
        print(f"check_volume_clean: DIRTY {img_path} "
              f"(vol LBA {VOL_LBA}+{TOTSEC}):")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"check_volume_clean: CLEAN {img_path} (vol LBA {VOL_LBA}+{TOTSEC}): "
          f"{len(live)} live entries, mirrors match, orphans 0, "
          f"non-test files intact, no {sorted(n.decode().strip() for n in TEST_NAMES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
