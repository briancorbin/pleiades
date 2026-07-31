#!/usr/bin/env bash
# Find where the car keeps its data, before sweeping for it.
#
#   ./scripts/did-map.sh
#
# Two things, about a minute:
#   1. Reads the standard UDS identity identifiers from every module, so
#      0x78E stops being an address and starts being a name.
#   2. Probes all 256 page markers (22 0000 … 22 FF00). Page 01 turned out to
#      be a support bitmask covering the next 32 identifiers, mode-01 style,
#      so a marker that answers means a block of identifiers lives behind it.
#
# That maps a 65,536-identifier space with 256 requests. Then sweep only the
# pages that exist, with did-scan.sh.
#
#   --module 78E     listen to one module only, no contention
#   --st 64          slower adapter timeout, for late modules
#   --extended       enter diagnostic session 10 03 first
#
# Run it yourself — an agent session doesn't inherit your Terminal's
# Bluetooth grant and gets killed silently.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product pleiades \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Sources/PleiadesCLI/Info.plist

exec "$(swift build --product pleiades --show-bin-path)/pleiades" map "$@"
