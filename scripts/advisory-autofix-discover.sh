#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# advisory-autofix-discover.sh — print every Cargo workspace directory in the
# checked-out tree, one per line ("." for the root), sorted.
#
# A workspace is a directory holding a TRACKED Cargo.lock. Nested workspaces
# such as fuzz/ (own Cargo.lock, not a member of the root workspace) are found
# by the same rule, so a new one is covered the day it is committed. Vendored
# trees are not ours to bump and are skipped: any path with a vendor/,
# vendored/, third_party/, node_modules/, target/ or fixtures/ segment (test
# fixtures pin vulnerable crates on purpose), or a path listed
# in ADVISORY_AUTOFIX_EXCLUDE (space-separated directories).
#
# Reads `git ls-files`, so untracked and ignored lockfiles never count.
# Exit 0 (an empty list is a valid answer: no Rust here), 2 outside a git tree.
set -euo pipefail
root="${1:-.}"
cd "$root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git work tree: $root" >&2; exit 2; }
exclude=" ${ADVISORY_AUTOFIX_EXCLUDE:-} "
git ls-files -z -- 'Cargo.lock' '**/Cargo.lock' | tr '\0' '\n' | while IFS= read -r lock; do
  [ -n "$lock" ] || continue
  case "/$lock" in */vendor/*|*/vendored/*|*/third_party/*|*/node_modules/*|*/target/*|*/fixtures/*) continue ;; esac
  dir="$(dirname "$lock")"
  case "$exclude" in *" $dir "*) continue ;; esac
  printf '%s\n' "$dir"
done | sort -u
