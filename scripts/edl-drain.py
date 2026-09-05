#!/usr/bin/env python3
"""Recover an EDL session stuck in "Mode detected: error".

Symptom
-------
A dump or flash died mid-transfer (a crash, Ctrl-C, a UnicodeEncodeError from the
progress bar...). Every later edl command now prints:

    main - Mode detected: error
    Connection detected, quiting.

Cause
-----
The firehose loader is alive and well, but it had already queued megabytes of
sector data for the aborted read. edl's handshake reads that raw payload, does not
find 0x01 / "<?xml" / 0x7E at the head of it, and declares the device broken.

Fix
---
Drain the bulk IN endpoint until it goes quiet, then poke it with a <nop/>. The
loader stays resident, so no power cycle and no test points are needed.

Usage
-----
    python scripts/edl-drain.py [--dll <dir containing libusb-1.0.dll>]

On Windows the device must be bound to WinUSB (Zadig) and libusb-1.0.dll must be
findable - point --dll at edl/edlclient/Windows if needed.
"""
import os
import sys

VID, PID = 0x05C6, 0x9008


def main():
    dll_dir = None
    if "--dll" in sys.argv:
        dll_dir = sys.argv[sys.argv.index("--dll") + 1]
    else:
        guess = os.path.join("edl", "edlclient", "Windows")
        if os.path.isdir(guess):
            dll_dir = guess
    if dll_dir and os.path.isdir(dll_dir):
        dll_dir = os.path.abspath(dll_dir)
        os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
        try:
            os.add_dll_directory(dll_dir)
        except (AttributeError, OSError):
            pass

    import usb.core
    import usb.util

    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit(f"no {VID:04x}:{PID:04x} device found "
                 "(is it in EDL mode? is WinUSB bound via Zadig?)")

    intf = dev.get_active_configuration()[(0, 0)]
    ep_in = usb.util.find_descriptor(
        intf,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
    ep_out = usb.util.find_descriptor(
        intf,
        custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
    print(f"interface {intf.bInterfaceNumber}  IN 0x{ep_in.bEndpointAddress:02x}  "
          f"OUT 0x{ep_out.bEndpointAddress:02x}")

    total, quiet = 0, 0
    while quiet < 3:
        try:
            data = ep_in.read(0x100000, timeout=500)
            if len(data):
                total += len(data)
                quiet = 0
            else:
                quiet += 1
        except usb.core.USBTimeoutError:
            quiet += 1
        except usb.core.USBError as exc:
            print("usb error while draining:", exc)
            break
    print(f"drained {total} bytes ({total / 1048576:.1f} MiB) of stale data")

    ep_out.write(b'<?xml version="1.0" ?><data><nop /></data>')
    try:
        rsp = bytes(ep_in.read(0x4000, timeout=3000))
        print("nop response:", rsp[:120].decode("ascii", "replace"))
        print("\n[+] loader is responding again - rerun your edl command")
    except Exception as exc:
        print("no response to nop:", exc)
        print("\n[-] still stuck; power-cycle the device back into EDL")


if __name__ == "__main__":
    main()
