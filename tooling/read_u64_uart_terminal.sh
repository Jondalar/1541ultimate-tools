#!/usr/bin/env bash

set -euo pipefail

PORT=""
BAUD=115200
SECONDS_TO_CAPTURE=5

log() { printf '[u64-uart-monitor] %s\n' "$*"; }
die() { printf '[u64-uart-monitor] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: read_u64_uart_terminal.sh [--port DEVICE] [--baud N] [--secs N]

Reads the U64 debug UART using a USB-TTL serial adapter.

If --port is omitted, the script auto-detects a single /dev/ttyUSB* or
/dev/ttyACM* device.
EOF
}

detect_port() {
    local ports=()
    local candidate

    for candidate in /dev/ttyUSB* /dev/ttyACM*; do
        if [ -e "$candidate" ]; then
            ports+=("$candidate")
        fi
    done

    if [ "${#ports[@]}" -eq 0 ]; then
        die "No USB serial adapters detected. Connect a 3.3V USB-TTL adapter or pass --port."
    fi
    if [ "${#ports[@]}" -gt 1 ]; then
        printf '[u64-uart-monitor] Multiple serial adapters detected:\n' >&2
        printf '  %s\n' "${ports[@]}" >&2
        die "Pass --port to choose the correct device."
    fi

    printf '%s\n' "${ports[0]}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --port)
            [ "$#" -ge 2 ] || die "Missing value for $1"
            PORT=$2
            shift
            ;;
        --baud)
            [ "$#" -ge 2 ] || die "Missing value for $1"
            BAUD=$2
            shift
            ;;
        --secs)
            [ "$#" -ge 2 ] || die "Missing value for $1"
            SECONDS_TO_CAPTURE=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
    shift
done

case "$BAUD" in
    ''|*[!0-9]*)
        die "Baud rate must be a positive integer"
        ;;
esac
case "$SECONDS_TO_CAPTURE" in
    ''|*[!0-9]*)
        die "Capture duration must be a non-negative integer number of seconds"
        ;;
esac

if [ -z "$PORT" ]; then
    PORT=$(detect_port)
fi

[ -e "$PORT" ] || die "Serial device not found: $PORT"
[ -r "$PORT" ] || die "Serial device is not readable: $PORT"
[ -w "$PORT" ] || die "Serial device is not writable: $PORT"

ORIGINAL_STTY=$(stty -F "$PORT" -g) || die "Failed to read serial settings from $PORT"
cleanup() {
    stty -F "$PORT" "$ORIGINAL_STTY" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

stty -F "$PORT" "$BAUD" cs8 -cstopb -parenb -ixon -ixoff -crtscts -echo raw min 0 time 1

log "Listening on $PORT at ${BAUD} baud"
if [ "$SECONDS_TO_CAPTURE" -eq 0 ]; then
    log "Streaming until interrupted"
    exec cat "$PORT"
fi

log "Capturing UART output for ${SECONDS_TO_CAPTURE}s"
set +e
timeout "$SECONDS_TO_CAPTURE" cat "$PORT"
status=$?
set -e

if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    die "UART capture failed with status $status"
fi
