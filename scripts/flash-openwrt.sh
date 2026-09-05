#!/bin/bash
# Flash OpenWrt to the HiMI MSM8916 4G stick entirely over EDL.
#
#   ./scripts/flash-openwrt.sh <dir-with-extracted-openwrt-release>
#
# <dir> is the unpacked hkfuertes/msm8916-openwrt release zip, containing:
#   *-squashfs-gpt_both0.bin   *-squashfs-boot.img   *-squashfs-system.img   *-firmware.zip
#
# The device must be in EDL mode (05C6:9008). Add --yes to skip the prompt.
#
# What it does, in order:
#   1. backs up this device's radio partitions  (IMEI + RF calibration)
#   2. writes the OpenWrt GPT                   (repartitions the eMMC)
#   3. writes aboot/hyp/rpm/sbl1/tz, boot, rootfs
#   4. restores the radio partitions it saved in step 1
#   5. wipes the head of rootfs_data so OpenWrt formats a clean overlay
#
# Android (system / userdata / cache) is destroyed. Take a dump first:
#   ./scripts/dump-device.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source "scripts/common.sh"

IMGDIR="$(abspath "${1:?usage: flash-openwrt.sh <dir-with-extracted-release> [--yes]}")"
ASSUME_YES=0; [[ "${2:-}" == "--yes" ]] && ASSUME_YES=1

find1() { find "$IMGDIR" -maxdepth 1 -type f -name "$1" | head -n1; }
GPT="$(find1 '*-squashfs-gpt_both0.bin')"
BOOT="$(find1 '*-squashfs-boot.img')"
ROOTFS="$(find1 '*-squashfs-system.img')"
FWZIP="$(find1 '*-firmware.zip')"
for v in GPT BOOT ROOTFS FWZIP; do
    [[ -n "${!v}" ]] || { echo "[-] missing $v in $IMGDIR"; exit 1; }
done
echo "GPT    : $(basename "$GPT")"
echo "boot   : $(basename "$BOOT")"
echo "rootfs : $(basename "$ROOTFS")"
echo "fw zip : $(basename "$FWZIP")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/mbn" backup

echo
echo "[*] extracting bootloader .mbn files"
"$PY" - "$FWZIP" "$WORK/mbn" <<'PYEOF'
import sys, zipfile, os
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for n in z.namelist():
        if n.lower().endswith(".mbn"):
            with z.open(n) as fh, open(os.path.join(dst, os.path.basename(n)), "wb") as out:
                out.write(fh.read())
print(" ", sorted(os.listdir(dst)))
PYEOF
for p in aboot hyp rpm sbl1 tz; do
    [[ -f "$WORK/mbn/$p.mbn" ]] || { echo "[-] $p.mbn missing from firmware zip"; exit 1; }
done

# Derive geometry from the GPT image itself rather than hardcoding it.
read -r TOT_SECTORS ROOTFS_DATA_START < <("$PY" - "$GPT" <<'PYEOF'
import struct, sys
g = open(sys.argv[1], "rb").read()
alt = struct.unpack("<Q", g[512+32:512+40])[0]
pe_lba, npe, pesz = struct.unpack("<QII", g[512+72:512+88])
start = 0
for i in range(npe):
    e = g[pe_lba*512 + i*pesz: pe_lba*512 + (i+1)*pesz]
    if len(e) < 128 or e[:16] == b"\0"*16:
        continue
    if e[56:128].decode("utf-16-le").rstrip("\0").strip() == "rootfs_data":
        start = struct.unpack("<Q", e[32:40])[0]
print(alt + 1, start)
PYEOF
)
echo "[*] GPT declares $TOT_SECTORS sectors; rootfs_data starts at sector $ROOTFS_DATA_START"

wait_for_edl 20 || exit 1
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Flash OpenWrt now? This ERASES Android on this device (y/N): " r
    [[ "$r" =~ ^[Yy]$ ]] || { echo "[!] cancelled"; exit 0; }
fi

echo
echo "############ 1/5  back up radio partitions ############"
for n in fsc fsg modemst1 modemst2 modem persist sec; do
    echo ">>> $n"
    edl r "$n" "backup/$n.bin" --memory=emmc
done

echo
echo "############ 2/5  write OpenWrt GPT ############"
dd if="$GPT" bs=512 count=34         of="$WORK/gpt_primary.bin"        status=none
dd if="$GPT" bs=512 skip=34 count=32 of="$WORK/gpt_backup_entries.bin" status=none
dd if="$GPT" bs=512 skip=66 count=1  of="$WORK/gpt_backup_header.bin"  status=none
edl ws 0                       "$WORK/gpt_primary.bin"        --memory=emmc
edl ws $((TOT_SECTORS - 33))   "$WORK/gpt_backup_entries.bin" --memory=emmc
edl ws $((TOT_SECTORS - 1))    "$WORK/gpt_backup_header.bin"  --memory=emmc

echo
echo "############ 3/5  bootloader chain + boot + rootfs ############"
for p in aboot hyp rpm sbl1 tz; do
    echo ">>> $p"
    edl w "$p" "$WORK/mbn/$p.mbn" --memory=emmc
done
echo ">>> boot";   edl w boot   "$BOOT"   --memory=emmc
echo ">>> rootfs"; edl w rootfs "$ROOTFS" --memory=emmc

echo
echo "############ 4/5  restore radio partitions ############"
for n in fsc fsg modemst1 modemst2 modem persist sec; do
    echo ">>> $n"
    edl w "$n" "backup/$n.bin" --memory=emmc
done

echo
echo "############ 5/5  clear head of rootfs_data ############"
# `edl e rootfs_data` fails on this old firehose ("No storage drive number"), and
# its fallback would zero-write 3.5 GB. Zeroing the first 16 MiB is enough: it
# destroys any stale superblock, and OpenWrt's preinit hook (79-format-rootfs-data)
# then makes a fresh ext4 overlay on first boot.
"$PY" -c "open(r'$WORK/zero16m.bin','wb').write(b'\x00'*16*1024*1024)"
edl ws "$ROOTFS_DATA_START" "$WORK/zero16m.bin" --memory=emmc

echo
echo "[+] flash complete - rebooting into OpenWrt"
edl reset || true
cat <<'EOF'

Next:
  * The stick comes up as a USB NCM/RNDIS network adapter.
  * Default OpenWrt LAN is 192.168.1.1. If your home router also uses
    192.168.1.1 you will reach the WRONG device - see the README section
    "Address clash" before you go hunting for bugs.
  * WiFi is DISABLED by default; enable it in LuCI (Network -> Wireless).
EOF
