#!/usr/bin/env python3
"""Listen to a real CAN bus through the CANable, and say what's on it.

Why this is Python when the rest of the project is Swift: the adapter runs
candleLight/gs_usb firmware, which is raw USB rather than a serial port.
Reaching it from Swift would mean libusb bindings; from Python it's an
import. gs_usb is also the right firmware to keep — it handles full bus load,
where slcan would drop frames on a busy car.

The split is clean: Swift is the product that runs on the iPad, this is bench
tooling that runs on a laptop, and `docs/signal-registry.json` is the shared
artefact between them.

Three modes, and the second is the one that answers questions:

    inventory   what ids exist, how often, and what their bytes look like
    watch       mark, change one thing about the car, and see what moved
    decode      render known frames as named signals via the opendbc DBC

Usage:
    ./scripts/can-sniff.sh inventory --bitrate 500000
    ./scripts/can-sniff.sh watch --decode
    ./scripts/can-sniff.sh decode --ids 3AC,390
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import sys
import time
from collections import defaultdict

import can
import usb.core

REPO = pathlib.Path(__file__).resolve().parents[2]
DBC = REPO / "tools" / "canbus" / "dbc" / "subaru_global.dbc"
LOGS = REPO / "logs"

# The bitrates worth trying, in the order they're worth trying. Powertrain
# buses on this platform are 500k; body networks are frequently slower, and
# a bus that answers at neither is probably LIN rather than a bad tap.
BITRATES = [500_000, 250_000, 125_000, 1_000_000]


def _allow_macos_open() -> None:
    """Stop `GsUsb.start()` trying to detach a kernel driver on macOS.

    `start()` opens with a USB reset. On macOS the re-enumeration that follows
    makes libusb report a kernel driver attached to interface 0, and
    `libusb_detach_kernel_driver` then fails with "[Errno 13] Access denied"
    — followed by a segfault during cleanup, and a device left in a state
    that needs a physical replug.

    There is nothing genuinely to detach: interface 0 is vendor-specific
    (class 0xFF), and macOS ships no driver that binds it. Only interface 1
    is class 0xFE (DFU), which isn't the one being claimed. So the probe is
    answering about a transient post-reset state rather than a real driver,
    and reporting "no driver attached" is both true and what lets the open
    succeed.

    If something *were* genuinely holding the interface, claiming it fails
    immediately afterwards with a clear error rather than a silent wrong
    answer.
    """
    if platform.system() != "Darwin":
        return
    if getattr(usb.core.Device, "_pleiades_macos_patched", False):
        return
    usb.core.Device.is_kernel_driver_active = lambda self, interface: False
    usb.core.Device._pleiades_macos_patched = True


def open_bus(bitrate: int, listen_only: bool = True) -> can.BusABC:
    """The CANable in gs_usb firmware, genuinely in listen-only mode.

    **python-can does not expose this.** `GsUsbBus.__init__` ends with a bare
    `self.gs_usb.start()`, which is `GS_CAN_MODE_NORMAL` — the transceiver
    drives the bus, ACKs every frame it receives, and transmits *error frames*
    when it sees something it can't decode.

    That last part is why this matters rather than being pedantry. The bitrate
    hunt below tries 500k, 250k, 125k and 1M; on any given bus three of those
    are wrong, and a normal-mode node at the wrong bitrate sees continuous
    framing errors and shouts about them onto a live vehicle network. Probing
    a moving car that way could disturb real traffic.

    So the device gets restarted with GS_CAN_MODE_LISTEN_ONLY after python-can
    is done with it. In listen-only the transceiver never drives the line at
    all: no ACKs, no error frames, electrically invisible. Nothing about a
    passive tap should be able to change how the car behaves.
    """
    _allow_macos_open()
    bus = can.Bus(
        interface="gs_usb",
        channel=0,
        index=0,
        bitrate=bitrate,
        receive_own_messages=False,
    )
    if not listen_only:
        return bus

    from gs_usb.gs_usb import (
        GS_CAN_MODE_HW_TIMESTAMP,
        GS_CAN_MODE_LISTEN_ONLY,
        GS_CAN_MODE_START,
        DeviceMode,
        _GS_USB_BREQ_MODE,
    )

    device = bus.gs_usb

    # Send the mode command straight to the device rather than calling
    # `GsUsb.start()` again. That method begins with a USB reset, and on macOS
    # the re-enumeration lets the OS re-attach a driver that libusb then
    # refuses to detach — "[Errno 13] Access denied", followed by a segfault
    # on cleanup. python-can has already done the reset and timing setup; all
    # that's left is to re-issue the mode with the listen-only bit set.
    wanted = GS_CAN_MODE_LISTEN_ONLY | GS_CAN_MODE_HW_TIMESTAMP
    supported = wanted & device.device_capability.feature
    device.device_flags = supported
    device.gs_usb.ctrl_transfer(
        0x41, _GS_USB_BREQ_MODE, 0, 0, DeviceMode(GS_CAN_MODE_START, supported).pack()
    )

    # The hardware masks off features it doesn't have, so confirm rather than
    # assume — silently running in normal mode is the exact failure this
    # function exists to prevent.
    if not supported & GS_CAN_MODE_LISTEN_ONLY:
        bus.shutdown()
        raise RuntimeError(
            "This adapter won't enter listen-only mode. It would ACK frames "
            "and emit error frames at the wrong bitrate. Pass --transmit-ok "
            "only if you're on a bench you own."
        )
    return bus


def load_dbc():
    if not DBC.exists():
        return None
    import cantools

    return cantools.database.load_file(str(DBC))


def capture(bus: can.BusABC, seconds: float) -> dict[int, list]:
    """Collect frames, keyed by id, newest last."""
    frames: dict[int, list] = defaultdict(list)
    deadline = time.time() + seconds
    while time.time() < deadline:
        msg = bus.recv(timeout=max(0.0, deadline - time.time()))
        if msg is None:
            continue
        frames[msg.arbitration_id].append(bytes(msg.data))
    return frames


def hexs(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


# --------------------------------------------------------------------------
# inventory


def cmd_inventory(args) -> int:
    """What is on this wire at all — the first question at any new tap."""
    bitrates = [args.bitrate] if args.bitrate else BITRATES
    db = load_dbc() if args.decode else None

    for bitrate in bitrates:
        print(f"\nListening at {bitrate:,} bit/s for {args.seconds:g}s…")
        try:
            bus = open_bus(bitrate, listen_only=not args.transmit_ok)
        except Exception as exc:  # noqa: BLE001 — surface the real reason
            print(f"  ✗ couldn't open the adapter: {exc}")
            return 1

        try:
            frames = capture(bus, args.seconds)
        finally:
            bus.shutdown()

        if not frames:
            print("  nothing heard.")
            continue

        total = sum(len(v) for v in frames.values())
        print(f"  ── {len(frames)} ids, {total} frames ──")
        for can_id in sorted(frames):
            samples = frames[can_id]
            name = ""
            if db:
                try:
                    name = f"  {db.get_message_by_frame_id(can_id).name}"
                except KeyError:
                    pass
            print(
                f"  0x{can_id:03X}  x{len(samples):<5} {hexs(samples[-1]):<24}{name}"
            )

        print(
            f"\n{len(frames)} ids at {bitrate:,}. "
            "Broadcast traffic means this is a real bus, not a diagnostic stub."
        )
        return 0

    print(
        "\nSilence at every bitrate. Most likely one of:\n"
        "  · CAN_H and CAN_L swapped — harmless, just swap them back\n"
        "  · this pair is LIN, not CAN (single wire, common on doors)\n"
        "  · the probe isn't making contact\n"
        "  · the car is fully asleep — open a door and try again"
    )
    return 1


# --------------------------------------------------------------------------
# watch


def cmd_watch(args) -> int:
    """Mark, change one thing, see what moved.

    The same method that found the tailgate over mode 22, except a bus
    broadcasts everything at once, so one capture covers every signal on it
    rather than one identifier at a time.
    """
    db = load_dbc() if args.decode else None
    bus = open_bus(args.bitrate, listen_only=not args.transmit_ok)

    try:
        input(
            f"\nBaseline: leave the car as it is and press Enter "
            f"({args.seconds:g}s capture)…"
        )
        before = capture(bus, args.seconds)
        print(f"  captured {len(before)} ids")

        input(
            "\nNow change ONE thing — open the tailgate, unbuckle a belt — "
            "then press Enter…"
        )
        after = capture(bus, args.seconds)
        print(f"  captured {len(after)} ids")
    finally:
        bus.shutdown()

    report_diff(before, after, db, args.tag)
    return 0


def report_diff(before, after, db, tag: str | None) -> None:
    print("\n" + "─" * 64)
    print(f"  what moved{f' — {tag}' if tag else ''}")
    print("─" * 64)

    moved = []
    for can_id in sorted(set(before) | set(after)):
        # A byte that changes on its own — a counter, a checksum, a rolling
        # timestamp — varies *within* a single capture. Only bytes that held
        # still through both captures, at different values, are evidence that
        # something was done to the car. This is the bus-level equivalent of
        # the two-pass volatile filter in the DID scanner, and it earns its
        # keep the same way: every CAN frame here carries a live counter.
        was = stable_profile(before.get(can_id, []))
        now = stable_profile(after.get(can_id, []))
        if was is None or now is None:
            continue
        was_bytes, was_steady = was
        now_bytes, now_steady = now

        comparable = was_steady & now_steady
        changed = [
            i for i in sorted(comparable)
            if i < min(len(was_bytes), len(now_bytes)) and was_bytes[i] != now_bytes[i]
        ]
        if changed:
            moved.append((can_id, was_bytes, now_bytes, changed))

    if not moved:
        print(
            "\nNothing moved.\n\n"
            "Either the signal isn't on this bus, or it's inside a byte that\n"
            "also carries something that changes on its own — those are\n"
            "filtered out here because they can't be evidence."
        )
        return

    for can_id, was, now, changed in moved:
        name = ""
        if db:
            try:
                name = f"  ({db.get_message_by_frame_id(can_id).name})"
            except KeyError:
                pass
        print(f"\n  0x{can_id:03X}{name}")
        print(f"     before  {hexs(was)}")
        print(f"     after   {hexs(now)}")
        caret = "".join("^^ " if i in changed else "   " for i in range(len(now)))
        print(f"             {caret.rstrip()}")

        if db:
            try:
                a = db.decode_message(can_id, was)
                b = db.decode_message(can_id, now)
                for key in sorted(set(a) | set(b)):
                    # The representative frames carry whatever counter and
                    # checksum happened to be in them; those bytes were
                    # already excluded from the comparison, so reporting them
                    # here would be noise contradicting the carets above.
                    if key in ("CHECKSUM", "COUNTER"):
                        continue
                    if a.get(key) != b.get(key):
                        print(f"     {key}: {a.get(key)} → {b.get(key)}")
            except Exception:  # noqa: BLE001 — decoding is a bonus, not the point
                pass

    print(f"\n{len(moved)} frame(s) moved. Change the same thing back to confirm.")


def stable_profile(samples: list[bytes]) -> tuple[bytes, set[int]] | None:
    """A representative payload plus which byte positions held still.

    Per *byte*, not per frame — because a frame is usually a mix. `BodyInfo`
    carries door latches next to a rolling counter and a checksum, so
    discarding the whole frame for being unstable would throw away the doors.
    """
    if not samples:
        return None
    first = samples[0]
    if any(len(s) != len(first) for s in samples):
        return None
    steady = {i for i in range(len(first)) if all(s[i] == first[i] for s in samples)}
    return first, steady


# --------------------------------------------------------------------------
# decode


def cmd_decode(args) -> int:
    """Live-render known frames as named signals."""
    db = load_dbc()
    if db is None:
        print(f"No DBC at {DBC}")
        return 1

    wanted = None
    if args.ids:
        wanted = {int(x, 16) for x in args.ids.split(",")}

    bus = open_bus(args.bitrate, listen_only=not args.transmit_ok)
    print("Decoding. Ctrl-C to stop.\n")
    seen: dict[int, dict] = {}
    try:
        while True:
            msg = bus.recv(timeout=1.0)
            if msg is None:
                continue
            if wanted and msg.arbitration_id not in wanted:
                continue
            try:
                decoded = db.decode_message(msg.arbitration_id, bytes(msg.data))
                name = db.get_message_by_frame_id(msg.arbitration_id).name
            except KeyError:
                continue
            except Exception:  # noqa: BLE001
                continue
            # Only print on change, or the terminal is unreadable.
            if seen.get(msg.arbitration_id) == decoded:
                continue
            seen[msg.arbitration_id] = decoded
            interesting = {
                k: v
                for k, v in decoded.items()
                if k not in ("CHECKSUM", "COUNTER")
            }
            print(f"0x{msg.arbitration_id:03X} {name:16} {interesting}")
    except KeyboardInterrupt:
        print("\nstopped.")
    finally:
        bus.shutdown()
    return 0


# --------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="can-sniff", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    inv = sub.add_parser("inventory", help="what ids exist on this wire")
    inv.add_argument("--bitrate", type=int, default=None,
                     help="default: try 500k, 250k, 125k, 1M in turn")
    inv.add_argument("--seconds", type=float, default=5.0)
    inv.add_argument("--decode", action="store_true", help="name known frames")
    inv.set_defaults(func=cmd_inventory)

    watch = sub.add_parser("watch", help="mark, change one thing, diff")
    watch.add_argument("--bitrate", type=int, default=500_000)
    watch.add_argument("--seconds", type=float, default=3.0)
    watch.add_argument("--tag", type=str, default=None)
    watch.add_argument("--decode", action="store_true", default=True)
    watch.set_defaults(func=cmd_watch)

    dec = sub.add_parser("decode", help="live named signals")
    dec.add_argument("--bitrate", type=int, default=500_000)
    dec.add_argument("--ids", type=str, default=None, help="e.g. 3AC,390")
    dec.set_defaults(func=cmd_decode)

    # Listen-only is the default everywhere. Opting out is for a bench you
    # own, never for a car that's running.
    for sub_parser in (inv, watch, dec):
        sub_parser.add_argument(
            "--transmit-ok", action="store_true",
            help="allow the adapter to ACK and emit error frames (bench only)",
        )

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
