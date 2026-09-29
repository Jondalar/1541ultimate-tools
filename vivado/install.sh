#!/usr/bin/env bash
# Unattended install of AMD Vivado ML Standard 2024.1 with Artix-7 support only.
#
# Usage: vivado/install.sh [--dry-run] [--bin PATH] [--dest DIR] [--extract DIR]
#
#   --bin      the web installer (default ~/Downloads/FPGAs_AdaptiveSoCs_Unified_2024.1_0522_2023_Lin64.bin)
#   --dest     install root; Vivado lands in DIR/Vivado/2024.1 (default ~/Xilinx)
#   --extract  where the installer client is unpacked
#              (default ~/.cache/1541ultimate-tools/vivado-2024.1-installer)
#   --dry-run  print what would run and change nothing
#
# The AMD login token is obtained by auth_token.py from AMD_EMAIL and
# AMD_PASSWORD (environment or ~/.env) whenever it is missing or has under a
# day left, so the install needs no interaction.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOME}/Downloads/FPGAs_AdaptiveSoCs_Unified_2024.1_0522_2023_Lin64.bin"
DEST="${HOME}/Xilinx"
EXTRACT_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/1541ultimate-tools/vivado-2024.1-installer"
CONFIG="${HERE}/install_config.txt"
# MD5 of the 2024.1 Linux web installer. A mismatch is reported, not fatal.
EXPECTED_MD5="8b0e99a41b851b50592d5d6ef1b1263d"
MIN_FREE_GB=80
DRY_RUN=0

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }
need_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then echo "$1 needs a value" >&2; exit 2; fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --bin) need_value "$@"; BIN="$2"; shift 2 ;;
        --dest) need_value "$@"; DEST="$2"; shift 2 ;;
        --extract) need_value "$@"; EXTRACT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say() { echo "[install] $*"; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] would run:'; printf ' %q' "$@"; echo
    else
        say "running: $*"; "$@"
    fi
}

DEST="$(realpath -m "$DEST")"
if [ -e "${DEST}/Vivado/2024.1" ]; then
    die "${DEST}/Vivado/2024.1 already exists; refusing to install over it"
fi

[ -f "$CONFIG" ] || die "missing ${CONFIG}"
grep -q '^Modules=.*Artix-7:1' "$CONFIG" || die "${CONFIG} does not select Artix-7"

# Free space on the destination filesystem (nearest existing parent).
probe="$DEST"; while [ ! -d "$probe" ]; do probe="$(dirname "$probe")"; done
free_gb=$(( $(df -Pk "$probe" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
    die "only ${free_gb} GB free under ${probe}; want at least ${MIN_FREE_GB} GB"
fi
say "free space under ${probe}: ${free_gb} GB"

# Step 1: unpack the web installer client. --nox11 keeps it from opening a
# terminal window of its own.
if [ -x "${EXTRACT_DIR}/xsetup" ]; then
    say "installer client already unpacked in ${EXTRACT_DIR}"
elif [ -f "$BIN" ] || [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$BIN" ]; then
        actual_md5="$(md5sum "$BIN" | awk '{print $1}')"
        [ "$actual_md5" = "$EXPECTED_MD5" ] ||
            say "WARNING: md5 ${actual_md5} of ${BIN} differs from ${EXPECTED_MD5}"
    else
        say "installer ${BIN} not found (dry run continues)"
    fi
    run sh "$BIN" --noexec --keep --nox11 --target "$EXTRACT_DIR"
else
    die "installer ${BIN} not found; download it from AMD's 2024.1 downloads page"
fi

# Step 2: authentication token for the web installer.
run python3 "${HERE}/auth_token.py" --ensure --xsetup "${EXTRACT_DIR}/xsetup"

# Step 3: batch install. -l overrides the config's Destination.
run "${EXTRACT_DIR}/xsetup" -b Install -a XilinxEULA,3rdPartyEULA \
    -c "$CONFIG" -l "$DEST"

if [ "$DRY_RUN" -eq 0 ]; then
    [ -x "${DEST}/Vivado/2024.1/bin/vivado" ] ||
        die "install finished but ${DEST}/Vivado/2024.1/bin/vivado is missing"
    say "installed: ${DEST}/Vivado/2024.1"
fi
