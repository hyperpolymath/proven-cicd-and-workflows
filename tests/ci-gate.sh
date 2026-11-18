#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Controls for the reusable CI/gate workflow's status descriptions.
#
# The defect: GitHub's statuses API rejects a description holding a 4-byte UTF-8 character (a
# codepoint above U+FFFF) with HTTP 422 "Description doesn't accept 4-byte Unicode". Consumer
# check and workflow names carry emoji, and "not green: <names>" puts them in the description,
# so the POST failed and the failure handler turned a verdict into a false red.
#
# The workflow's publish() is the one write site for a verdict. It is extracted from the workflow
# (never retyped) and run against a fake gh that refuses a 4-byte description like the real API.
# The negative controls show that the test can fail: the old expression keeps the emoji, and the
# fake gh does refuse it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci-gate.yml"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
dlen() { printf "%s" "$1" | jq -Rr length; }
four_byte() { printf '%s' "$1" | LC_ALL=C grep -qP '[\xF0-\xF7]'; }   # any UTF-8 lead byte >= 0xF0

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
# Fake gh: log the POSTed state and description; refuse a 4-byte description like the real API.
desc=''; state=''
for a in "$@"; do case $a in description=*) desc=${a#description=} ;; state=*) state=${a#state=} ;; esac; done
if printf '%s' "$desc" | LC_ALL=C grep -qP '[\xF0-\xF7]'; then
  echo "gh: HTTP 422 Description doesn't accept 4-byte Unicode" >&2; exit 1
fi
printf '%s\t%s\n' "$state" "$desc" >> "$FAKEGH_LOG"
GH_EOF
chmod +x "$WORK/bin/gh"

# Extract publish() (from its header to the closing brace at the same indent) out of the workflow.
PUBLISH_DEF=$(awk '/^ *publish\(\) \{/ { f = 1; match($0, /^ */); ind = RLENGTH }
                   f { print; if ($0 ~ "^ {" ind "}\\}$") exit }' "$WORKFLOW")
[ -n "$PUBLISH_DEF" ] && grep -q 'gh api' <<<"$PUBLISH_DEF" && ok "extracted publish() from the workflow" || bad "could not extract publish() from the workflow"

publish_of() { # <state> <description> -> sets RC and POSTED (state<TAB>description), via the real publish()
  : > "$WORK/log"
  PUBOUT=$(env PATH="$WORK/bin:$PATH" FAKEGH_LOG="$WORK/log" GITHUB_OUTPUT="$WORK/gho" REPO=example/repo SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    CONTEXT='CI/gate' url=https://example.invalid/run bash -c $'set -euo pipefail\n'"$PUBLISH_DEF"$'\n''publish "$1" "$2"' _ "$1" "$2" 2>&1)
  RC=$?
  POSTED=$(cat "$WORK/log")
}

RED=$'\xf0\x9f\x94\xb4'; YEL=$'\xf0\x9f\x9f\xa1'
NAME_RG="${RED} GATE: Invisible Character Detection (failure), ${YEL} CHECK: Groove Protocol Compliance (cancelled)"
NEAR=$(printf 'a%.0s' $(seq 1 137))${RED}${YEL}${RED}tail           # emoji straddling the 140 boundary
LONG=$(printf 'n%.0s' $(seq 1 120))${RED}$(printf 'm%.0s' $(seq 1 40))  # 160 characters, emoji inside the first 140

echo "== negative controls: the old expression keeps the emoji, and the fake API refuses it =="
OLD=$(bash -c 'd=$1; (( ${#d} > 140 )) && d="${d:0:139}…"; printf %s "$d"' _ "not green: $NAME_RG")
four_byte "$OLD" && ok "the old bash truncation keeps the emoji (the 4-byte detector fires)" || bad "the old expression dropped the emoji, so the tests below prove nothing"
PATH="$WORK/bin:$PATH" FAKEGH_LOG="$WORK/log" gh api -X POST x -f description="$OLD" 2>/dev/null && bad "the fake gh accepted a 4-byte description" || ok "the fake gh refuses a 4-byte description (HTTP 422)"

echo "== publish(): emoji in a description =="
publish_of failure "not green: $NAME_RG"
D=$(cut -f2 <<<"$POSTED")
{ [ "$RC" -eq 0 ] && [ -n "$POSTED" ]; } && ok "a name with 🔴 and 🟡: the POST goes through (exit 0)" || bad "a name with emoji: rc=$RC out='$PUBOUT'"
four_byte "$D" && bad "a name with emoji: the description still has a 4-byte character" || ok "a name with 🔴 and 🟡: no 4-byte character in the description"
[ "$(dlen "$D")" -le 140 ] && ok "a name with emoji: at most 140 characters ($(dlen "$D"))" || bad "a name with emoji: $(dlen "$D") characters"
case "$D" in *"GATE: Invisible Character Detection (failure)"*"CHECK: Groove Protocol Compliance (cancelled)"*) ok "the text of the names is kept" ;; *) bad "the text was damaged: $D" ;; esac
[ "$(cut -f1 <<<"$POSTED")" = failure ] && ok "the state is passed through unchanged (failure)" || bad "state changed: $POSTED"
for nm in "$NEAR" "$LONG"; do
  publish_of failure "$nm"; D=$(cut -f2 <<<"$POSTED")
  four_byte "$D" && bad "a long name (${#nm} chars): 4-byte character left" || ok "a long name (${#nm} chars) with emoji near the boundary: no 4-byte character"
  [ "$(dlen "$D")" -le 140 ] && ok "that description is at most 140 characters ($(dlen "$D"))" || bad "that description is $(dlen "$D") characters"
  case "$D" in *…) ok "it is cut with an ellipsis" ;; *) bad "no ellipsis: $D" ;; esac
done
publish_of success "all 3 other checks and workflow runs passed"
[ "$POSTED" = $'success\tall 3 other checks and workflow runs passed' ] && ok "a plain description passes through unchanged" || bad "a plain description changed: $POSTED"
publish_of failure "$(printf 'x%.0s' $(seq 1 200))"
[ "$(dlen "$(cut -f2 <<<"$POSTED")")" -eq 140 ] && ok "a plain 200-character description is cut to exactly 140" || bad "plain long description: $POSTED"

echo "== static guard: every status description is static or goes through publish() =="
bad_sites=$(grep -n -- 'description=' "$WORKFLOW" | grep -v '^[0-9]*: *#' | grep -vE 'description="\$d"' | grep -E 'description="[^"]*[$`]' || true)
[ -z "$bad_sites" ] && ok "no description is built from a variable outside publish()" || bad "a description interpolates a variable outside publish(): $bad_sites"
[ "$(grep -c 'gsub("\[\\\\x{10000}-\\\\x{10FFFF}\]"; "")' "$WORKFLOW")" -eq 1 ] && ok "exactly one strip expression, in the one write site" || bad "the strip expression is not in exactly one place"

echo
printf 'ci-gate: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
