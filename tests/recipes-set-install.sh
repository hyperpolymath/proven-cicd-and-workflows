#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Recipes Set Validation Gate: the `just` install is pinned, and a failed
# install says why.
#
# The defect: the gate installed `just` by piping https://just.systems/install.sh
# into bash with its output sent to /dev/null. That script resolves the latest
# release through the GitHub API at run time, so the gate failed intermittently
# on consumers of main-estate-audit (measured on trope-checker, 2026-11-16:
# failed on two attempts of one run and passed on a third, same commit), and the
# log said only that `just` "could not be installed".
#
# This suite runs the step in the shell GitHub uses for a composite, with `just`
# absent from PATH and a stand-in `curl`:
#   * download fails        -> exit 1, the downloader's error is in the output,
#                              and no parse result is printed
#   * wrong bytes delivered -> exit 1 on the checksum, nothing installed
#   * real pinned download  -> the Justfile is parsed (SKIP if offline)
#   * a Justfile that does not parse still fails after a good install
# and it kills a mutant: the pre-fix install line, put back, must fail the
# "says why" assertion. 0=pass, 1=violation, 2=cannot run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v yq >/dev/null || { echo "yq is required (Y-1: gates read YAML with yq, never grep)"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ACTION="$ROOT/actions/recipes-set-check"
yq -r '.runs.steps[0].run' "$ACTION/action.yml" > "$WORK/step.sh"

# A PATH with every tool the step needs except `just`.
BIN="$WORK/bin"; mkdir -p "$BIN"
for t in bash curl sha256sum tar gzip install mktemp mkdir rm uname wc make printf cat grep sed env dirname; do
    p=$(command -v "$t" 2>/dev/null) || continue
    [[ $p == /* ]] && ln -sf "$p" "$BIN/$t"
done
[[ -x $BIN/just ]] && { echo "internal: just leaked into the test PATH"; exit 2; }

FIX="$WORK/fixture"; mkdir -p "$FIX"
printf 'default:\n\techo ok\n' > "$FIX/Justfile"

# run_step <action dir> <stub dir or ''>: run the step as GitHub would.
run_step() {
    local action=$1 stub=$2 path=$BIN
    [[ -n $stub ]] && path="$stub:$BIN"
    rm -rf "$WORK/rt"; mkdir -p "$WORK/rt"
    ( cd "$FIX" && env -i PATH="$path" HOME="$WORK" RUNNER_TEMP="$WORK/rt" GITHUB_ACTION_PATH="$action" \
        ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} ${SSL_CERT_FILE:+SSL_CERT_FILE="$SSL_CERT_FILE"} \
        ${CURL_CA_BUNDLE:+CURL_CA_BUNDLE="$CURL_CA_BUNDLE"} \
        bash --noprofile --norc -e -o pipefail "$WORK/step.sh" ) > "$WORK/out" 2>&1
}

# Stand-in curl that fails the way an unreachable host does.
DEAD="$WORK/dead"; mkdir -p "$DEAD"
printf '#!/bin/bash\necho "curl: (6) Could not resolve host: stand-in" >&2\nexit 6\n' > "$DEAD/curl"
chmod +x "$DEAD/curl"

# Stand-in curl that "succeeds" with the wrong bytes.
WRONG="$WORK/wrong"; mkdir -p "$WRONG"
cat > "$WRONG/curl" <<'EOF'
#!/bin/bash
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && printf 'not the release archive\n' > "$out"
exit 0
EOF
chmod +x "$WRONG/curl"

echo "== download fails =="
run_step "$ACTION" "$DEAD"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1" || bad "exit $rc, expected 1"
grep -q 'Could not resolve host' "$WORK/out" && ok "the downloader's error is shown" || bad "the log does not say why the install failed"
grep -q 'verified nothing' "$WORK/out" && ok "the gate says it verified nothing" || bad "no 'verified nothing' line"
grep -q 'recipes parsed' "$WORK/out" && bad "a parse result was printed with no just" || ok "no parse result printed"

echo "== wrong bytes delivered =="
run_step "$ACTION" "$WRONG"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1" || bad "exit $rc, expected 1"
[[ -e $WORK/rt/just-bin/just ]] && bad "an unverified binary was installed" || ok "nothing installed"
grep -qi 'FAILED\|checksum' "$WORK/out" && ok "the checksum failure is shown" || bad "no checksum failure in the log"

echo "== the mutant: the pre-fix install line =="
MUT="$WORK/mutant"; mkdir -p "$MUT"
cp "$ACTION/install.sh" "$MUT/install.sh"
cp "$WORK/step.sh" "$WORK/step.keep"
# Put back the old behaviour: discard the installer's output.
sed 's|bash "\$GITHUB_ACTION_PATH/install.sh" "\$RUNNER_TEMP/just-bin"; then|bash "$GITHUB_ACTION_PATH/install.sh" "$RUNNER_TEMP/just-bin" >/dev/null 2>\&1; then|' \
    "$WORK/step.keep" > "$WORK/step.sh"
cmp -s "$WORK/step.keep" "$WORK/step.sh" && bad "the mutation did not apply; the step no longer has the line this control edits" \
    || {
        run_step "$MUT" "$DEAD"
        grep -q 'Could not resolve host' "$WORK/out" && bad "mutant survived: the reason is shown even with output discarded" \
            || ok "mutant killed: with output discarded the reason is absent"
    }
cp "$WORK/step.keep" "$WORK/step.sh"

echo "== no floating release resolution =="
grep -q 'just\.systems' "$ACTION/action.yml" "$ACTION/install.sh" && bad "the floating installer is still referenced" || ok "no just.systems reference"
grep -Eq '^checksum=[0-9a-f]{64}$' "$ACTION/install.sh" && ok "a SHA-256 is pinned" || bad "no pinned SHA-256"
grep -Eq '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$ACTION/install.sh" && ok "an exact version is pinned" || bad "no exact version"

echo "== real pinned download =="
run_step "$ACTION" ""; rc=$?
if grep -q 'recipes parsed' "$WORK/out"; then
    [[ $rc -eq 0 ]] && ok "installed, verified and parsed the Justfile" || bad "parsed but exit $rc"
    printf 'default:\n\techo ok\n  bad indent {{\n' > "$FIX/Justfile"
    run_step "$ACTION" ""; rc=$?
    [[ $rc -eq 1 ]] && grep -q 'does not parse' "$WORK/out" && ok "a Justfile that does not parse fails" || bad "broken Justfile gave exit $rc"
elif grep -q 'curl: ' "$WORK/out"; then
    echo "  SKIP real download (no network): $(grep -m1 'curl: ' "$WORK/out")"
else
    bad "real install neither parsed nor reported a download error (exit $rc)"; sed 's/^/      /' "$WORK/out"
fi

echo
echo "recipes-set install controls: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
