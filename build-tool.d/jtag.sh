#!/usr/bin/env bash
# jtag.sh — JTAG recovery and JTAG terminal monitoring

run_jtag_recovery() {
    local target=$1

    if [ "$target" = "u64" ]; then
        local helper_script="$REPO_DIR/tooling/build_and_deploy_u64.sh"
        if [ ! -x "$helper_script" ]; then
            DEPLOY_FAILED=1; FAILED_JTAGS+=("$target")
            log_error "U64 JTAG helper not found or not executable: $helper_script"
            return 1
        fi
        CURRENT_ACTION="Running JTAG deployment for ${target}"
        if ! run_command "$helper_script"; then
            DEPLOY_FAILED=1; FAILED_JTAGS+=("$target")
            log_error "JTAG deployment failed for ${target}."
            CURRENT_ACTION=""; return 1
        fi
        log_success "JTAG deployment completed for ${target}."
        CURRENT_ACTION=""; return 0
    fi

    if [ "$target" != "u64ii" ]; then
        DEPLOY_FAILED=1; FAILED_JTAGS+=("$target")
        log_error "JTAG recovery is only supported for u64ii (and u64 via helper)."
        return 1
    fi

    require_command python3
    CURRENT_ACTION="Checking pyftdi availability"
    if ! python3 -c 'import pyftdi' >/dev/null 2>&1; then
        DEPLOY_FAILED=1; FAILED_JTAGS+=("$target")
        log_error "pyftdi is not installed. Install it with: pip install pyftdi"
        CURRENT_ACTION=""; return 1
    fi

    CURRENT_ACTION="Running JTAG recovery for ${target}"
    local python_cmd
    python_cmd=$(cat <<'EOF'
import pathlib, sys
sys.path.insert(0, str(pathlib.Path('recovery/u64ii').resolve()))
import recover

recover.logger.addHandler(recover.ch)
jtag = recover.JtagClient(sys.argv[1])
jtag.xilinx_read_id()
recover.prog_fpga(recover.logger, jtag, 'recovery/u64ii/u64_mk2_artix.bit')
jtag.user_set_outputs(0x80)
jtag.user_upload('recovery/u64ii/ultimate.bin', 0x30000)
magic = recover.struct.pack('<LL', 0x30000, 0x1571babe)
jtag.user_write_memory(0xFFF8, magic)
jtag.user_set_outputs(0x00)
jtag.user_read_id()
EOF
)

    if ! run_command python3 -c "$python_cmd" "$JTAG_URL"; then
        DEPLOY_FAILED=1; FAILED_JTAGS+=("$target")
        log_error "JTAG recovery failed for ${target}."
        CURRENT_ACTION=""; return 1
    fi

    log_success "JTAG recovery completed for ${target}."
    CURRENT_ACTION=""; return 0
}

run_jtag_monitor() {
    local target=$1

    if [ "$target" != "u64" ]; then
        MONITOR_FAILED=1; FAILED_JTAG_MONITORS+=("$target")
        log_error "JTAG monitor is only supported for u64."
        return 1
    fi

    local helper_script="$REPO_DIR/tooling/read_u64_jtag_terminal.sh"
    if [ ! -x "$helper_script" ]; then
        MONITOR_FAILED=1; FAILED_JTAG_MONITORS+=("$target")
        log_error "U64 JTAG monitor helper not found or not executable: $helper_script"
        return 1
    fi

    CURRENT_ACTION="Reading JTAG monitor output for ${target}"
    if ! run_command "$helper_script" "$JTAG_MONITOR_SECS"; then
        MONITOR_FAILED=1; FAILED_JTAG_MONITORS+=("$target")
        log_error "JTAG monitor failed for ${target}."
        CURRENT_ACTION=""; return 1
    fi

    log_success "JTAG monitor completed for ${target}."
    CURRENT_ACTION=""; return 0
}
