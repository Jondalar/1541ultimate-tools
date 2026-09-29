#!/usr/bin/env bash

set -euo pipefail

ROOT="${ULTIMATE_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
ELF_PATH="$ROOT/target/u64/nios2/ultimate/result/ultimate.elf"

log() { printf '[u64-jtag] %s\n' "$*"; }
die() { printf '[u64-jtag] ERROR: %s\n' "$*" >&2; exit 1; }
add_path() { [[ -d "$1" ]] && PATH="$1:$PATH"; }

# Locate the Intel/Altera toolchain. Set INTEL_FPGA_ROOT to the version
# directory (the one containing quartus/ and nios2eds/) to override, e.g.
#   INTEL_FPGA_ROOT=/opt/intelFPGA_lite/19.1 bash tooling/build_and_deploy_u64.sh
if [[ -z "${INTEL_FPGA_ROOT:-}" ]]; then
    if [[ -n "${QUARTUS_ROOTDIR:-}" && -d "$QUARTUS_ROOTDIR/.." ]]; then
        INTEL_FPGA_ROOT="$(cd "$QUARTUS_ROOTDIR/.." && pwd -P)"
    else
        for candidate in \
            "$HOME"/intelFPGA_lite/*  "$HOME"/intelFPGA/*  "$HOME"/altera_lite/* \
            /opt/intelFPGA_lite/*     /opt/intelFPGA/*     /opt/altera_lite/*; do
            if [[ -x "$candidate/quartus/bin/jtagconfig" ]]; then
                INTEL_FPGA_ROOT="$candidate"
                break
            fi
        done
    fi
fi
[[ -n "${INTEL_FPGA_ROOT:-}" ]] || die "Could not locate the Intel FPGA tools; set INTEL_FPGA_ROOT"

[[ $# -eq 0 ]] || die "This helper does not accept arguments"
[[ -s "$ELF_PATH" ]] || die "Missing deployable ELF: $ELF_PATH"
[[ -x "$INTEL_FPGA_ROOT/quartus/bin/jtagconfig" ]] || die "Missing jtagconfig under $INTEL_FPGA_ROOT"
[[ -x "$INTEL_FPGA_ROOT/nios2eds/bin/nios2-download" ]] || die "Missing nios2-download under $INTEL_FPGA_ROOT"

export QUARTUS_ROOTDIR="$INTEL_FPGA_ROOT/quartus"
export QSYS_ROOTDIR="$QUARTUS_ROOTDIR/sopc_builder/bin"
add_path "$INTEL_FPGA_ROOT/quartus/bin"
add_path "$INTEL_FPGA_ROOT/nios2eds/bin"
add_path "$INTEL_FPGA_ROOT/nios2eds/bin/gnu/H-x86_64-pc-linux-gnu/bin"
add_path "$INTEL_FPGA_ROOT/nios2eds/sdk2/bin"
add_path "$QSYS_ROOTDIR"
export PATH

log "Checking JTAG hardware"
JTAG_OUTPUT="$(jtagconfig 2>/dev/null || true)"
printf '%s\n' "$JTAG_OUTPUT"
grep -Eq '[0-9]+\)' <<<"$JTAG_OUTPUT" || die "No JTAG hardware available"

log "Downloading $ELF_PATH via nios2-download"
nios2-download -g "$ELF_PATH"
log "U64 JTAG deployment completed"
