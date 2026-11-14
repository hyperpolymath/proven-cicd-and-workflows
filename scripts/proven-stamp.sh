#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-stamp.sh hash|stamp|check FILE
#
# The stamp is line 2 of a stamped copy, directly under the SPDX line:
#   # SPDX-License-Identifier: <id>
#   # proven-cicd: <artifact>@<version> sha256:<hex>
# Line 1 stays the SPDX line because consumer workflow linters require
# `head -1` to be `# SPDX-License-Identifier:`.
#
# The hash covers the HASHED REGION, meaning every line of the file except
#   * the stamp line itself (line 2), and
#   * each line that directly follows a line reading `# proven-cicd:local-next`
#     (after optional indentation). That is the LOCAL REGION: values that
#     legitimately differ per repository, such as the pinned suite SHA and the
#     third-party `uses:` SHAs that Dependabot moves. The marker sits on a line
#     of its own, so a Dependabot rewrite of the next line cannot disturb it.
# The SPDX line on line 1 is inside the hashed region.
#
# LEGACY layout: copies installed before this change carry the stamp on line 1
# and no SPDX line above it. `check` still accepts them, hashing every line
# except line 1 (and the local region). `stamp` never writes the legacy layout.
# Any other position of the stamp is refused.
#
#   hash   print the hashed-region sha256
#   stamp  rewrite the stamp line's hash to match the body (line 1 must be an
#          SPDX line and line 2 a stamp line naming artifact and version)
#   check  exit 0 when the stamp matches the body, 1 on drift, 2 when the file
#          has no stamp in line 2 (or legacy line 1) or cannot be read
#
# The check detects edits only. Whoever edits the body can edit the stamp, so
# staleness (BEHIND) is judged by the applier against the published manifest,
# never by the copy itself.
set -euo pipefail

mode=${1:-} file=${2:-}
[[ -f $file ]] || { echo "proven-stamp: $file missing" >&2; exit 2; }
readonly stamp_re='^# proven-cicd: [A-Za-z0-9._-]+@[0-9]+\.[0-9]+\.[0-9]+ sha256:[0-9a-f]{64}$'
readonly stamp_head_re='^# proven-cicd: [A-Za-z0-9._-]+@[0-9]+\.[0-9]+\.[0-9]+ sha256:'
readonly spdx_re='^# SPDX-License-Identifier: [^[:space:]].*$'

line1=$(sed -n 1p "$file")
line2=$(sed -n 2p "$file")
# stamp_line: 2 for the current layout, 1 for the legacy layout, 0 for neither.
stamp_line=0
if [[ $line1 =~ $stamp_head_re ]]; then stamp_line=1
elif [[ $line1 =~ $spdx_re && $line2 =~ $stamp_head_re ]]; then stamp_line=2
fi

region() {
  awk -v sl="$stamp_line" 'NR == sl { next }
       skip { skip = 0; next }
       /^[[:space:]]*# proven-cicd:local-next[[:space:]]*$/ { print; skip = 1; next }
       { print }' "$file"
}
digest() { region | sha256sum | cut -d' ' -f1; }

case $mode in
  hash)
    [[ $stamp_line != 0 ]] || { echo "proven-stamp: $file has no stamp on line 2 (or legacy line 1)" >&2; exit 2; }
    digest ;;
  stamp)
    [[ $line1 =~ $spdx_re ]] ||
      { echo "proven-stamp: $file line 1 is not an SPDX-License-Identifier line" >&2; exit 2; }
    [[ $stamp_line == 2 ]] ||
      { echo "proven-stamp: $file line 2 is not a stamp line" >&2; exit 2; }
    h=$(digest)
    tmp=$(mktemp)
    { printf '%s\n' "$line1" "${line2%%sha256:*}sha256:$h"; tail -n +3 "$file"; } > "$tmp"
    cat "$tmp" > "$file"; rm -f -- "$tmp"
    echo "stamped $file sha256:$h" ;;
  check)
    [[ $stamp_line != 0 ]] || { echo "proven-stamp: $file has no valid stamp on line 2 (or legacy line 1)" >&2; exit 2; }
    stamp=$(sed -n "${stamp_line}p" "$file")
    [[ $stamp =~ $stamp_re ]] || { echo "proven-stamp: $file has no valid stamp line" >&2; exit 2; }
    want=${stamp##*sha256:} got=$(digest)
    if [[ $want == "$got" ]]; then
      [[ $stamp_line == 2 ]] || echo "note: $file uses the LEGACY layout (stamp on line 1); re-stamp it to move the stamp under the SPDX line" >&2
      echo "ok: $file matches its stamp"; exit 0
    fi
    echo "DRIFT: $file body sha256:$got, stamp says sha256:$want" >&2
    exit 1 ;;
  *) echo "usage: proven-stamp.sh hash|stamp|check FILE" >&2; exit 2 ;;
esac
