#!/usr/bin/env bash
# Listen to a real CAN bus through the CANable.
#
#   ./scripts/can-sniff.sh inventory            what ids exist on this wire
#   ./scripts/can-sniff.sh inventory --decode   ...and name the known ones
#   ./scripts/can-sniff.sh watch --tag gate     mark, change one thing, diff
#   ./scripts/can-sniff.sh decode --ids 3AC     live named signals
#
# Where to connect: the EyeSight camera connector behind the rear-view
# mirror. Pop the shroud, back-probe CAN_H and CAN_L (pinout in comma's
# Subaru_C_Harness.pdf), and leave the connector mated — nothing is cut.
#
# **Terminator switch OFF.** The car's bus already has its two 120 Ω. A
# third drops it to 40 Ω and the transceivers can't drive dominant.
#
# The adapter is opened listen-only: it never drives the bus, never ACKs,
# and cannot put a module into an error state.
#
# Python rather than Swift because the CANable runs gs_usb firmware — raw
# USB, not a serial port. Swift would need libusb bindings; Python needs an
# import. First run creates the venv.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=tools/canbus/.venv
if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating tools/canbus/.venv …"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q -r tools/canbus/requirements.txt
fi

exec "$VENV/bin/python" tools/canbus/sniff.py "$@"
