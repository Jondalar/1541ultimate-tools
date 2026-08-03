#!/usr/bin/env bash
# common.sh — generic Bash helpers with no project-specific dependencies

# contains_value NEEDLE [ITEM...] — returns 0 if NEEDLE is in the list
contains_value() {
    local needle=$1
    shift || true
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# quote_command CMD [ARGS...] — shell-quote each word, space-separated
quote_command() {
    printf '%q ' "$@"
}

# elapsed_seconds START_EPOCH — integer seconds since START_EPOCH
elapsed_seconds() {
    printf '%d' $(( $(date +%s) - $1 ))
}

# format_duration SECONDS — human-readable e.g. "3m 07s" or "45s"
format_duration() {
    local secs=$1
    local mins=$(( secs / 60 ))
    local rem=$(( secs  % 60 ))
    if [ "$mins" -gt 0 ]; then
        printf '%dm %02ds' "$mins" "$rem"
    else
        printf '%ds' "$rem"
    fi
}