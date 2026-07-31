#!/usr/bin/env bash
# Mode-22 identifier sweep, through the BLE dongle.
#
# The workflow is mark-and-diff. Two sweeps, one change between them:
#
#   ./scripts/did-scan.sh --tag "gate closed"
#   ...walk back and open the tailgate...
#   ./scripts/did-scan.sh --tag "gate open"      # diffs itself against the first
#
# The second run finds the previous snapshot in logs/ on its own and prints
# what moved. Tag every sweep — in a week the tags are the only thing that
# says what the diff meant.
#
#   --from 0100 --to 01FF     range (default: the range the car answers)
#   --passes 2                repeats per sweep, to flag values that drift
#   --include-volatile        show the drifters anyway
#   --name IOS-Vlink          when more than one dongle is in range
#
# Run this yourself rather than handing it to an agent: macOS attributes
# Bluetooth permission to the app that spawned the process, so a command run
# from an agent session gets killed on the spot, silently. Same reason
# ble-probe.sh exists as a script — the -sectcreate flag embeds the Info.plist
# that lets the binary ask for permission at all.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product pleiades \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Sources/PleiadesCLI/Info.plist

exec "$(swift build --product pleiades --show-bin-path)/pleiades" scan "$@"
