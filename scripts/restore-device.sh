#!/bin/bash
# Restore a previously dumped image back to the SAME stick over EDL.
#
#   ./scripts/restore-device.sh full  <image.bin>                  # whole device (~20 min)
#   ./scripts/restore-device.sh parts <partitions_dir> boot rootfs # just those partitions
#
# Add --yes to skip the confirmation prompt.
#
# The device must be in EDL mode (05C6:9008).
#
# ONLY restore an image onto the unit it came from. The radio partitions
# (modemst1, modemst2, fsg, fsc, sec) hold that unit's IMEI and per-unit RF
# calibration; writing them to a different stick clones the IMEI onto it, which
# is illegal in many jurisdictions and degrades the radio regardless. To set up a
# second device, flash OpenWrt with flash-openwrt.sh instead - it preserves each
# device's own radio partitions - and carry your settings over with `sysupgrade -b`.
set -euo pipefail
cd "$(dirname "$0")/.."
source "scripts/common.sh"

MODE="${1:-}"; shift || true
ASSUME_YES=0
ARGS=()
for a in "$@"; do [[ "$a" == "--yes" ]] && ASSUME_YES=1 || ARGS+=("$a"); done
set -- "${ARGS[@]+"${ARGS[@]}"}"

confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -r -p "$1 (y/N): " r
    [[ "$r" =~ ^[Yy]$ ]] || { echo "[!] cancelled"; exit 0; }
}

case "$MODE" in
full)
    IMG="$(abspath "${1:?usage: restore-device.sh full <image.bin>}")"
    [[ -f "$IMG" ]] || { echo "[-] no such image: $IMG"; exit 1; }
    SZ=$(stat -c %s "$IMG")
    echo "image  : $IMG"
    echo "size   : $SZ bytes"
    if [[ -f "$IMG.sha256" ]]; then
        echo "[*] verifying recorded sha256 before writing ..."
        want=$(cut -d' ' -f1 < "$IMG.sha256")
        have=$("$PY" -c "import hashlib,sys;h=hashlib.sha256();f=open(sys.argv[1],'rb');[h.update(c) for c in iter(lambda:f.read(1<<22),b'')];print(h.hexdigest())" "$IMG")
        [[ "$want" == "$have" ]] || { echo "[-] CHECKSUM MISMATCH - refusing to flash a corrupt image"; exit 1; }
        echo "[+] checksum OK"
    else
        echo "[!] no .sha256 alongside the image - cannot verify integrity"
    fi
    wait_for_edl 20 || exit 1
    confirm "Overwrite the ENTIRE eMMC of the attached device?"
    edl ws 0 "$IMG" --memory=emmc
    ;;
parts)
    DIR="$(abspath "${1:?usage: restore-device.sh parts <dir> <name> [name...]}")"; shift
    [[ $# -ge 1 ]] || { echo "[-] name at least one partition"; exit 1; }
    for n in "$@"; do
        [[ -f "$DIR/$n.bin" ]] || { echo "[-] missing $DIR/$n.bin"; exit 1; }
    done
    wait_for_edl 20 || exit 1
    echo "about to write: $*"
    for n in "$@"; do
        case "$n" in
            modemst1|modemst2|fsg|fsc|sec|persist)
                echo "[!] '$n' is per-unit radio data (IMEI / calibration)."
                confirm "    Confirm this image came from THIS SAME stick" ;;
        esac
    done
    confirm "Write these partitions now?"
    for n in "$@"; do
        echo ">>> $n"
        edl w "$n" "$DIR/$n.bin" --memory=emmc
    done
    ;;
*)
    sed -n '2,20p' "$0"; exit 1 ;;
esac

echo
echo "[+] restore complete - rebooting"
edl reset || true
