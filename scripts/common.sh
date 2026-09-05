#!/bin/bash
# Shared setup for the flash / dump / restore scripts. Sourced, not run.
#
# Env overrides:
#   EDL_DIR   path to a bkerler/edl checkout   (default: ./edl)
#   PY        python interpreter               (default: ./.venv/Scripts/python.exe)

EDL_DIR="${EDL_DIR:-./edl}"
PY="${PY:-./.venv/Scripts/python.exe}"

# edl's progress bar prints U+2588; without this it dies with UnicodeEncodeError
# on a cp1252 console (and takes the whole flash run with it).
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1

abspath() {
    if [[ -e "$1" ]]; then
        printf '%s\n' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
    else
        printf '%s\n' "$1"   # bare command name such as "python3" — leave on PATH
    fi
}

EDL_DIR="$(abspath "$EDL_DIR")"
PY="$(abspath "$PY")"

[[ -f "$EDL_DIR/edl.py" ]] || {
    echo "[-] edl.py not found in $EDL_DIR"
    echo "    git clone --recurse-submodules https://github.com/bkerler/edl.git"
    exit 1
}
command -v "$PY" >/dev/null 2>&1 || [[ -x "$PY" ]] || {
    echo "[-] python not found at: $PY"; exit 1
}

# Run an edl subcommand from inside the edl checkout (it resolves Loaders/ relatively).
edl() { ( cd "$EDL_DIR" && "$PY" edl.py "$@" ); }

# Wait until the device enumerates in EDL mode (05C6:9008).
wait_for_edl() {
    local tries="${1:-120}"
    echo "[*] waiting for EDL device (05C6:9008) ..."
    for ((i = 0; i < tries; i++)); do
        if powershell.exe -NonInteractive -Command \
            "if (Get-PnpDevice -PresentOnly -EA SilentlyContinue | Where-Object { \$_.InstanceId -like 'USB\VID_05C6&PID_9008*' }) { 'FOUND' }" \
            2>/dev/null | grep -q FOUND; then
            echo "[+] EDL device present"; return 0
        fi
        sleep 3
    done
    echo "[-] timed out waiting for EDL mode"; return 1
}
