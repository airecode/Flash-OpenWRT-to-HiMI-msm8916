#!/usr/bin/env python3
"""Carve partitions out of a raw MSM8916 eMMC image using its own GPT.

Reads the primary GPT from the image, writes each partition to <outdir>/<name>.bin,
and produces manifest.txt with offsets, sizes and SHA-256 hashes.

Works on both the stock Android image and an OpenWrt image — the layout is taken
from the image itself, nothing is hardcoded.

Usage:
    python carve.py <image.bin> [outdir] [--max-mb N] [--all]

    --max-mb N   skip partitions larger than N MiB (default 512). Bulk filesystems
                 (system / userdata / rootfs_data) are usually not worth duplicating;
                 they are still inside the full image.
    --all        carve everything regardless of size.
"""
import hashlib
import os
import struct
import sys

SECTOR = 512


def read_gpt(f):
    """Return (declared_sectors, [(name, start_lba, end_lba), ...]) from the primary GPT."""
    f.seek(1 * SECTOR)
    hdr = f.read(SECTOR)
    if hdr[:8] != b"EFI PART":
        raise SystemExit("no GPT signature at LBA 1 — is this a raw eMMC image?")
    alt_lba = struct.unpack("<Q", hdr[32:40])[0]
    pe_lba, npe, pesz = struct.unpack("<QII", hdr[72:88])
    f.seek(pe_lba * SECTOR)
    ents = f.read(npe * pesz)
    parts = []
    for i in range(npe):
        e = ents[i * pesz:(i + 1) * pesz]
        if len(e) < 128 or e[:16] == b"\0" * 16:
            continue
        start, end = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16-le").rstrip("\0").strip()
        if name:
            parts.append((name, start, end))
    return alt_lba + 1, parts


def sha256_file(path, chunk=1 << 22):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(chunk), b""):
            h.update(blk)
    return h.hexdigest()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = [a for a in sys.argv[1:] if a.startswith("--")]
    if not args:
        raise SystemExit(__doc__)
    image = args[0]
    outdir = args[1] if len(args) > 1 else os.path.join(os.path.dirname(image) or ".", "partitions")
    carve_all = "--all" in flags
    max_mb = 512
    for i, a in enumerate(sys.argv):
        if a == "--max-mb" and i + 1 < len(sys.argv):
            max_mb = int(sys.argv[i + 1])
    limit = max_mb * 1024 * 1024

    total = os.path.getsize(image)
    os.makedirs(outdir, exist_ok=True)

    print(f"image      : {image}")
    print(f"size       : {total} bytes ({total / 1024 / 1024:.0f} MiB)")
    print("hashing full image (this takes a moment) ...")
    digest = sha256_file(image)
    print(f"sha256     : {digest}")
    with open(image + ".sha256", "w") as fh:
        fh.write(f"{digest} *{os.path.basename(image)}\n")

    rows = []
    with open(image, "rb") as f:
        declared, parts = read_gpt(f)
        print(f"GPT declares {declared} sectors ({declared * SECTOR} bytes), "
              f"{len(parts)} partitions\n")
        for name, start, end in parts:
            off = start * SECTOR
            size = (end - start + 1) * SECTOR
            if off + size > total:
                rows.append((name, off, size, "OUTSIDE IMAGE - skipped"))
                continue
            if size > limit and not carve_all:
                rows.append((name, off, size, f"skipped (>{max_mb} MiB)"))
                continue
            f.seek(off)
            data = f.read(size)
            with open(os.path.join(outdir, name + ".bin"), "wb") as out:
                out.write(data)
            rows.append((name, off, size, hashlib.sha256(data).hexdigest()[:16]))

    man = os.path.join(os.path.dirname(image) or ".", "manifest.txt")
    with open(man, "w") as m:
        m.write(f"MSM8916 eMMC image\nfile   : {os.path.basename(image)}\n"
                f"size   : {total} bytes\nsha256 : {digest}\n\n")
        m.write(f"{'partition':<16}{'offset':>14}{'size':>13}  sha256[:16]\n")
        for name, off, size, tag in rows:
            m.write(f"{name:<16}{'0x%09x' % off:>14}{size:>13}  {tag}\n")

    print(open(man).read())
    print(f"partitions -> {outdir}")
    print(f"manifest   -> {man}")


if __name__ == "__main__":
    main()
