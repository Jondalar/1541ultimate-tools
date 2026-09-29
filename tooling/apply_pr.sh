#!/usr/bin/env bash
# Make a throwaway worktree of a firmware tree with 1541ultimate pull requests
# applied to it as uncommitted changes, for building and testing only.
#
# Usage:
#   apply_pr.sh [--repo DIR] [--base REF] [--remote NAME] [--keep] PR [PR ...] WORKTREE
#
#   --repo DIR     tree to start from (default: the current git checkout). It
#                  can be this repository or another firmware tree with the same
#                  layout, such as a C64 Ultimate firmware tree.
#   --base REF     commit the worktree starts at (default: HEAD of --repo)
#   --remote NAME  remote of --repo that points at GideonZ/1541ultimate
#                  (default: found by URL)
#   --keep         reuse WORKTREE if it exists instead of refusing
#
# Each PR is applied as its net change: the diff from its merge base with the
# upstream master to its head. Merging the PR branch instead would also bring
# in every upstream commit the target tree does not have. The diff is applied
# with a three-way merge, so conflicts are left as markers to resolve by hand.
# A file the PR changes but the target tree does not have (a target this tree
# does not build, for example) is skipped and listed.
#
# Nothing is committed or pushed. Besides WORKTREE, the fetch updates the
# remote-tracking refs <remote>/master and <remote>/pr/N of --repo;
# `git worktree remove WORKTREE` undoes the rest. Exit status: 0 applied
# cleanly, 3 applied with conflicts to resolve, 1 error.

set -euo pipefail

log() { printf '[apply-pr] %s\n' "$*" >&2; }
die() { printf '[apply-pr] ERROR: %s\n' "$*" >&2; exit 1; }

REPO="" BASE="HEAD" REMOTE="" KEEP=0 PRS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)   REPO=$2; shift 2 ;;
        --base)   BASE=$2; shift 2 ;;
        --remote) REMOTE=$2; shift 2 ;;
        --keep)   KEEP=1; shift ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *)  PRS+=("$1"); shift ;;
    esac
done
[[ ${#PRS[@]} -ge 2 ]] || die "need at least one PR number and a worktree path"
WORKTREE=$(realpath -m "${PRS[-1]}"); unset 'PRS[-1]'
for pr in "${PRS[@]}"; do [[ "$pr" =~ ^[0-9]+$ ]] || die "not a PR number: $pr"; done

REPO=$(git -C "${REPO:-.}" rev-parse --show-toplevel)
if [[ -z "$REMOTE" ]]; then
    REMOTE=$(git -C "$REPO" remote -v | awk '/GideonZ\/1541ultimate(\.git)? \(fetch\)/ {print $1; exit}')
    [[ -n "$REMOTE" ]] || die "no remote of $REPO points at GideonZ/1541ultimate; pass --remote"
fi
BASE_SHA=$(git -C "$REPO" rev-parse --verify "$BASE^{commit}")

if [[ -e "$WORKTREE" ]]; then
    [[ $KEEP -eq 1 ]] || die "$WORKTREE exists; remove it or pass --keep"
else
    log "worktree $WORKTREE at $(git -C "$REPO" rev-parse --short "$BASE_SHA")"
    git -C "$REPO" worktree add -q --detach "$WORKTREE" "$BASE_SHA"
fi
WORKTREE=$(cd "$WORKTREE" && pwd -P)

log "fetching master and ${PRS[*]} from $REMOTE"
refspecs=("master:refs/remotes/$REMOTE/master")
for pr in "${PRS[@]}"; do refspecs+=("pull/$pr/head:refs/remotes/$REMOTE/pr/$pr"); done
git -C "$REPO" fetch -q "$REMOTE" "${refspecs[@]}"

status=0
for pr in "${PRS[@]}"; do
    head="refs/remotes/$REMOTE/pr/$pr"
    mb=$(git -C "$REPO" merge-base "$REMOTE/master" "$head")
    log "PR #$pr: $(git -C "$REPO" rev-parse --short "$mb")..$(git -C "$REPO" rev-parse --short "$head"), $(git -C "$REPO" diff --name-only "$mb" "$head" | wc -l) files"

    # Paths the PR modifies or deletes that this tree does not have, counting
    # files an earlier PR in this run has added.
    excludes=()
    while IFS=$'\t' read -r kind path _; do
        [[ "$kind" == A* ]] && continue
        if [[ ! -e "$WORKTREE/$path" ]]; then
            excludes+=("--exclude=$path")
            log "  skipped, not in this tree: $path"
        fi
    done < <(git -C "$REPO" diff --name-status --no-renames "$mb" "$head")

    patch=$(mktemp)
    git -C "$REPO" diff --binary --no-renames "$mb" "$head" > "$patch"
    if git -C "$WORKTREE" apply -3 "${excludes[@]}" "$patch" 2>"$patch.log"; then
        log "  applied cleanly"
    else
        conflicts=$(git -C "$WORKTREE" diff --name-only --diff-filter=U)
        if [[ -z "$conflicts" ]]; then
            cat "$patch.log" >&2
            rm -f "$patch" "$patch.log"
            die "PR #$pr did not apply"
        fi
        log "  conflicts to resolve:"
        printf '    %s\n' $conflicts >&2
        status=3
        rm -f "$patch" "$patch.log"
        log "stopping here; apply the remaining PRs after resolving (--keep)"
        break
    fi
    rm -f "$patch" "$patch.log"
done

# `git apply -3` works through the index, so the next PR in this run applies on
# top of the previous one there. Unstage everything once all are in, so the
# builder sees plain working-tree changes. Conflicted files keep their markers.
[[ $status -eq 0 ]] && git -C "$WORKTREE" reset -q

if [[ $status -eq 3 ]]; then
    log "resolve the conflicts in $WORKTREE, then build it with --repo-dir"
else
    log "ready: $WORKTREE ($(git -C "$WORKTREE" status --short | wc -l) changed paths, nothing committed)"
fi
exit $status
