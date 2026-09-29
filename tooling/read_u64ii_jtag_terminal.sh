#!/usr/bin/env bash
# Print the Ultimate 64 Elite II / C64 Ultimate application's UART output,
# read over JTAG from the FPGA's console FIFO. The FIFO holds 1024 bytes and
# keeps what the CPU wrote since it was last read.
#
# Usage: read_u64ii_jtag_terminal.sh [seconds]   (default 5, 0 = until Ctrl-C)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SECONDS_TO_CAPTURE="${1:-5}"

[[ "$#" -le 1 ]] || { echo "Usage: $(basename "$0") [seconds]" >&2; exit 1; }
[[ "$SECONDS_TO_CAPTURE" =~ ^[0-9]+$ ]] \
    || { echo "Capture duration must be a non-negative integer" >&2; exit 1; }

exec "$SCRIPT_DIR/u64ii_jtag.sh" console --secs "$SECONDS_TO_CAPTURE"
