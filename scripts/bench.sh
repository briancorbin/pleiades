#!/usr/bin/env bash
# The full bench: everything pleiades can prove without a car.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── Swift: Maia · Electra · Sterope · Celaeno · Alcyone"
swift test

echo ""
echo "── C: Merope black-box core (host)"
(cd firmware/merope && pio test -e native)

# The signal registry documents what the car exposes and how we know. Keep the
# generated sheet honest: it must match the data it was rendered from.
swift run pleiades registry --check

echo ""
echo "✦ bench green — the fake Forester approves"
