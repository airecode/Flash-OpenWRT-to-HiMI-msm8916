#!/bin/bash
# Reboot the stick out of EDL back into whatever is flashed on it.
# A "USBError(32, 'Pipe error')" at the end is normal - that is the device
# dropping off the bus as it resets.
set -euo pipefail
cd "$(dirname "$0")/.."
source "scripts/common.sh"
edl reset || true
