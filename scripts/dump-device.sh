#!/bin/bash
# Full raw eMMC dump of the HiMI MSM8916 stick over EDL (Sahara/Firehose).
# Read-only: this never writes to the device.
#
#   ./scripts/dump-device.sh [outdir]        # default outdir: ./dump
#
# The device must already be in EDL mode (USB 05C6:9008, "QHSUSB__BULK").
#
# Env: EDL_DIR, PY (see common.sh), SECTORS (default 7634944 = 3.64 GiB)
#
# Why SECTORS is explicit: after flashing OpenWrt the on-disk GPT declares only
# 7,569,408 sectors, so `edl rf` would stop short of the physical end of the eMMC.
# Reading a fixed 7,634,944 sectors gives a true whole-device image and keeps the
# stock and OpenWrt dumps directly comparable.
set -euo pipefail
cd "$(dirname "$0")/.."
source "scripts/common.sh"

OUT="$(abspath "${1:-dump}")"
SECTORS="${SECTORS:-7634944}"
mkdir -p "$OUT"
IMG="$OUT/emmc_full.bin"

wait_for_edl 20 || exit 1

echo
echo "=== 1/3  partition table (also proves the link works) ==="
edl printgpt --memory=emmc | tee "$OUT/gpt.txt" || true

echo
echo "=== 2/3  reading $SECTORS sectors -> $IMG ==="
echo "         ~8-10 minutes; do not unplug"
edl rs 0 "$SECTORS" "$IMG" --memory=emmc

echo
echo "=== 3/3  hashing + carving partitions ==="
"$PY" scripts/carve.py "$IMG" "$OUT/partitions"

cat <<EOF

[+] Done.  Image: $IMG

[!] This image contains the unit's IMEI, radio calibration, WiFi key and root
    password. Keep it private - never commit it or pass it to anyone else.

    Boot the device back out of EDL with:
        ./scripts/reset-device.sh
EOF
