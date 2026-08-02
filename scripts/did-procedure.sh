#!/usr/bin/env bash
# Run a scripted capture session at the car.
#
#   ./scripts/did-procedure.sh              list the available procedures
#   ./scripts/did-procedure.sh doors        one opening at a time, checked both ways
#   ./scripts/did-procedure.sh belts        one belt at a time, unfastened between
#
# The tool drives the procedure so you don't have to remember it. It tells you
# what to change, captures, tells you to put it back, captures again, and only
# calls something confirmed if it moved AND returned.
#
# That last part is why this beats doing it by hand: a byte that goes true
# when the door opens and false when it shuts is the door. One that only does
# the first is a coincidence that happened to line up — which is exactly what
# 0x1024 was, and it took three runs to notice.
#
# Tags are written from the step names, so a capture can't end up ambiguous
# about what state the car was in. The belt captures needed a re-run for
# precisely that reason.
#
# Run this yourself — an agent session doesn't inherit your Terminal's
# Bluetooth grant and gets killed silently.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product pleiades \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker Sources/PleiadesCLI/Info.plist

exec "$(swift build --product pleiades --show-bin-path)/pleiades" procedure "$@"
