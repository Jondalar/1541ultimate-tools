#!/usr/bin/env bash
# Run tooling/u64ii_jtag.py with pyftdi available.
#
# pyftdi is installed once into a virtual environment under the user cache,
# so nothing is added to the system Python. Set U64II_JTAG_PYTHON to use an
# interpreter that already has pyftdi instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VENV="${U64II_JTAG_VENV:-${XDG_CACHE_HOME:-$HOME/.cache}/1541ultimate-tools/jtag-venv}"
PYFTDI_VERSION="0.57.2"

die() { printf '[u64ii-jtag] ERROR: %s\n' "$*" >&2; exit 1; }

PYTHON="${U64II_JTAG_PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    PYTHON="$VENV/bin/python"
    if ! "$PYTHON" -c 'import pyftdi' >/dev/null 2>&1; then
        printf '[u64ii-jtag] creating %s with pyftdi %s\n' "$VENV" "$PYFTDI_VERSION" >&2
        python3 -m venv "$VENV" || die "python3 -m venv failed; install python3-venv"
        "$VENV/bin/pip" install -q "pyftdi==$PYFTDI_VERSION" || die "pip install pyftdi failed"
    fi
fi

exec "$PYTHON" "$SCRIPT_DIR/u64ii_jtag.py" "$@"
