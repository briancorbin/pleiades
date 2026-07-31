#!/usr/bin/env bash
# Capture a recon session: show the console live and save it to a log.
#
#   ./scripts/recon.sh            auto-detect the port
#   ./scripts/recon.sh /dev/cu.usbmodem1101
#
# Ctrl-C to stop. The log lands in logs/ — that's what we decode afterward,
# so don't rely on scrollback.
set -uo pipefail
cd "$(dirname "$0")/.."

PORT="${1:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}"
if [[ -z "${PORT:-}" || ! -e "$PORT" ]]; then
  echo "No ESP32 found. Plug it in and check: ls /dev/cu.usbmodem*"
  exit 1
fi

mkdir -p logs
LOG="logs/recon-$(date +%Y%m%d-%H%M%S).log"

echo "Port:  $PORT"
echo "Log:   $LOG"
echo
echo "  BOOT once  → mark the baseline"
echo "  do ONE thing (open the gate)"
echo "  BOOT again → see which bytes moved"
echo
echo "Ctrl-C when done."
echo "────────────────────────────────────────"

# cat, not pio device monitor — PlatformIO's monitor crashes on the
# Homebrew Python 3.14 build.
cat "$PORT" | tee "$LOG"
