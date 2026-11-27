#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# self-pin-reachable.sh [BASE_REF]
#
# Every self-pin (uses: hyperpolymath/proven-cicd-and-workflows/<path>@<sha>) in a
# tracked workflow, composite or template must name a commit reachable from BASE_REF
# (default origin/main). A pin to a PR branch's own commit works until the squash
# merge deletes that branch; then main breaks (#136, repaired by #175).
# Exit 0 all reachable, 1 a pin is unreachable or absent, 2 cannot check
# (shallow clone, BASE_REF unknown, not a git checkout).
set -euo pipefail
base=${1:-origin/main}
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "self-pin-reachable: not a git checkout; NOT RUN" >&2; exit 2; }
cd "$root"
[[ $(git rev-parse --is-shallow-repository) == false ]] || {
  echo "self-pin-reachable: shallow clone (need fetch-depth: 0); NOT RUN" >&2; exit 2; }
git rev-parse -q --verify "$base^{commit}" >/dev/null || {
  echo "self-pin-reachable: $base does not resolve; NOT RUN" >&2; exit 2; }
fail=0 n=0
while IFS=: read -r file line text; do
  sha=${text##*@}; sha=${sha:0:40}
  n=$((n + 1))
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
    echo "FAIL $file:$line pins $sha, which is not in this clone"; fail=1
  elif ! git merge-base --is-ancestor "$sha" "$base"; then
    echo "FAIL $file:$line pins $sha, which is not reachable from $base"; fail=1
  fi
done < <(git grep -n -o -E 'hyperpolymath/proven-cicd-and-workflows/[^@[:space:]"'\'']+@[0-9a-f]{40}' \
           -- '*.yml' '*.yaml' ':!tests/fixtures/**' || true)
echo "self-pin-reachable: $n pins checked against $base"
exit "$fail"
