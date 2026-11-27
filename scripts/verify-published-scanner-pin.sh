#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Production scanner callers must pin a commit already published on suite main.
# PR-only implementation pins can become unresolvable after squash/branch deletion.
set -euo pipefail
pin=${1:-}
repository=${2-hyperpolymath/cicd-suite}
[[ $pin =~ ^[0-9a-f]{40}$ ]] || { echo 'scanner pin must be a full SHA' >&2; exit 2; }
case "$repository" in
    hyperpolymath/cicd-suite|hyperpolymath/proven-cicd|hyperpolymath/proven-cicd-and-workflows) ;;
    *) echo 'scanner source repository is not admitted' >&2; exit 2 ;;
esac
# First by git: one anonymous commits-only fetch of main (no REST call), then the pin must be
# in main's history. A private source or a failed fetch falls back to the compare API.
# PIN_GIT_BASE exists for tests only; production leaves it unset.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git init -q "$work"
if GIT_TERMINAL_PROMPT=0 git -C "$work" fetch -q --filter=tree:0 --no-tags "${PIN_GIT_BASE:-https://github.com}/$repository" main 2>/dev/null \
    && head=$(git -C "$work" rev-parse --verify -q FETCH_HEAD) && [[ $head =~ ^[0-9a-f]{40}$ ]]; then
    # List to a file first: with pipefail, `rev-list | grep -q` fails when grep stops early
    # and rev-list dies of SIGPIPE on a long history, which would call a published pin unpublished.
    GIT_NO_LAZY_FETCH=1 git -C "$work" rev-list FETCH_HEAD > "$work/main-commits" \
        || { echo 'cannot list the scanner source main history' >&2; exit 2; }
    if grep -qx "$pin" "$work/main-commits"; then
        status=$([[ $head == "$pin" ]] && echo identical || echo ahead)
    else
        status=diverged
    fi
    echo "read $repository main by git ($head)"
else
    status=$(gh api "repos/$repository/compare/$pin...main" --jq .status) \
        || { echo 'cannot verify published scanner ancestry' >&2; exit 2; }
fi
case $status in
    ahead|identical) echo "scanner pin $repository@$pin is published on its main" ;;
    behind|diverged) echo "scanner pin $repository@$pin is not on its main (comparison=$status)" >&2; exit 1 ;;
    *) echo 'scanner ancestry result is unavailable or unknown' >&2; exit 2 ;;
esac
