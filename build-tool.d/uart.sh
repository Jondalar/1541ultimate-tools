#!/usr/bin/env bash
# uart.sh — UART serial terminal monitoring

run_uart_monitor() {
    local target=$1

    if [ "$target" != "u64" ]; then
        MONITOR_FAILED=1; FAILED_UART_MONITORS+=("$target")
        log_error "UART monitor is only supported for u64."
        return 1
    fi

    local helper_script="$REPO_DIR/tooling/read_u64_uart_terminal.sh"
    if [ ! -x "$helper_script" ]; then
        MONITOR_FAILED=1; FAILED_UART_MONITORS+=("$target")
        log_error "U64 UART monitor helper not found or not executable: $helper_script"
        return 1
    fi

    local cmd=("$helper_script" --secs "$UART_MONITOR_SECS" --baud "$UART_BAUD")
    [ -n "$UART_PORT" ] && cmd+=(--port "$UART_PORT")

    CURRENT_ACTION="Reading UART monitor output for ${target}"
    if ! run_command "${cmd[@]}"; then
        MONITOR_FAILED=1; FAILED_UART_MONITORS+=("$target")
        log_error "UART monitor failed for ${target}."
        CURRENT_ACTION=""; return 1
    fi

    log_success "UART monitor completed for ${target}."
    CURRENT_ACTION=""; return 0
}
