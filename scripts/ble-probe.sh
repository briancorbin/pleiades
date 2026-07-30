#!/usr/bin/env bash
# BLE dongle probe.
#
#   ./scripts/ble-probe.sh --scan            list nearby BLE devices
#   ./scripts/ble-probe.sh                   connect, dump the PID map
#   ./scripts/ble-probe.sh --name vgate      when several devices are around
#
# Why a script instead of `swift run`: macOS kills any process that touches
# CoreBluetooth without an Info.plist declaring a usage string, and a bare
# SwiftPM executable has none. We embed one at link time. That flag can't live
# in Package.swift — `unsafeFlags` there would stop other packages depending
# on Maia, which is the point of publishing it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product pleiades \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Sources/PleiadesCLI/Info.plist

exec "$(swift build --product pleiades --show-bin-path)/pleiades" ble "$@"
