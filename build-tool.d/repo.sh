#!/usr/bin/env bash
# repo.sh — repository filesystem predicates used by support probes

# repo_has_all_files PATH... — returns 0 only if every path exists
repo_has_all_files() {
    local path
    for path in "$@"; do
        [ -e "$path" ] || return 1
    done
    return 0
}