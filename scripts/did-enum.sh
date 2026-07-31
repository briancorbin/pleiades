#!/usr/bin/env bash
# Read everything one module has, by walking its own support bitmasks.
#
#   ./scripts/did-enum.sh --module 75A --tag "gate closed"
#   ...open the tailgate...
#   ./scripts/did-enum.sh --module 75A --tag "gate open"
#
# Faster and more complete than sweeping a range: ask 22 XX00, decode which
# identifiers it advertises, follow the chain bit, read only those. And it
# listens to one module at a time, so nothing is lost to fifteen of them
# answering at once.
#
# The modules this car has, from their own F197 replies:
#
#   75A  Integ. Unit                      <- doors, gate, chimes live here
#   7BC  Keyless Access & Push Start (C)  <- knows door/gate state for entry
#   7C9  Keyless Access & Push Start (P)
#   788  Airbag System                    <- seatbelt buckles
#   75B  Tire pressure monitor            <- TPMS
#   71F  Electric Brake Booster           78E  Sonar system
#   74A  RADAR ASSY B&S LH                78F  EyeSight
#   74B  RADAR ASSY B&S RH                7B8  VDC/Parking Brake System
#   77E  Data Communication Module        7DD  MFD
#   7E8  2.5 DOHC (engine)                78B  (wouldn't say)
#
#   --pages 01,02,10,11   which pages to walk (default: the common set)
#   --passes 2            repeats, to flag values that drift on their own
#   --st 64               slower adapter timeout
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

exec "$(swift build --product pleiades --show-bin-path)/pleiades" enum "$@"
