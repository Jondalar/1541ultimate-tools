#!/usr/bin/env bash
# Host tests for apply_pr.sh against throwaway git repositories; no network.
#
#   bash tooling/test_apply_pr.sh

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/apply_pr.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

git_() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=master "$@"; }
check() {    # check NAME COMMAND...: pass when COMMAND succeeds
    local name=$1; shift
    if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILS=$((FAILS + 1)); fi
}

# upstream: master with f (lines a..h), and PRs as refs/pull/N/head
#   1: b -> B      2: g -> G      3: d -> D (conflicts with the tree below)
setup() {
    rm -rf "$TMP/up" "$TMP/tree" "$TMP"/wt*
    git_ init -q "$TMP/up"
    printf '%s\n' a b c d e f g h > "$TMP/up/f"
    git_ -C "$TMP/up" add f
    git_ -C "$TMP/up" commit -qm base
    local pr from to
    for pr in 1:b:B 2:g:G 3:d:D; do
        IFS=: read -r pr from to <<<"$pr"
        git_ -C "$TMP/up" checkout -q -b "pr$pr" master
        sed -i "s/^$from\$/$to/" "$TMP/up/f"
        git_ -C "$TMP/up" commit -qam "pr$pr"
        git_ -C "$TMP/up" update-ref "refs/pull/$pr/head" "pr$pr"
        git_ -C "$TMP/up" checkout -q master
    done
    # The tree under test differs from upstream on line d.
    git_ clone -q -o up "$TMP/up" "$TMP/tree"
    sed -i 's/^d$/d-local/' "$TMP/tree/f"
    git_ -C "$TMP/tree" commit -qam local
}
run() { "$SCRIPT" --repo "$TMP/tree" --remote up "$@" >"$TMP/log" 2>&1; }

setup
check "two PRs changing one file stack" run 1 2 "$TMP/wt"
check "  both changes present" grep -qx B "$TMP/wt/f"
check "  second change present" grep -qx G "$TMP/wt/f"

setup
rc=0; run 3 2 "$TMP/wt" || rc=$?
check "a conflict exits 3" test "$rc" -eq 3
rc=0; run --keep 3 2 "$TMP/wt" || rc=$?
check "--keep refuses while conflict markers remain" test "$rc" -eq 3
printf '%s\n' a b c D e f g h > "$TMP/wt/f"          # resolve by hand
rc=0; run --keep 3 2 "$TMP/wt" || rc=$?
check "--keep after resolving applies the remaining PR" test "$rc" -eq 0
check "  remaining PR applied" grep -qx G "$TMP/wt/f"
check "  resolved PR not applied twice" test "$(grep -c '^D$' "$TMP/wt/f")" -eq 1
check "  nothing left staged" test -z "$(git -C "$TMP/wt" diff --cached --name-only)"
rc=0; run --keep 3 2 "$TMP/wt" || rc=$?
check "--keep with every PR applied is a no-op" test "$rc" -eq 0

for opt in --repo --base --remote; do
    rc=0; "$SCRIPT" "$opt" >"$TMP/log" 2>&1 || rc=$?
    check "$opt without a value is reported" grep -q -e "$opt needs a value" "$TMP/log"
done

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
