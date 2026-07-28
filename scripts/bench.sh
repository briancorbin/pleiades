#!/usr/bin/env bash
# The full bench: everything pleiades can prove without a car.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── Swift: Maia · Electra · Sterope · Celaeno · Alcyone"
swift test

echo ""
echo "── C: Merope black-box core (host)"
(cd firmware/merope && pio test -e native)

echo ""
echo "✦ bench green — the fake Forester approves"
