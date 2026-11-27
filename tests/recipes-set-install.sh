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
#   * HTTP error (404)      -> a failure, never an "offline" skip, including
#                              a 404 that follows a retried timeout
#   * unsupported runner    -> exit 1, the installer names the runner
#   * real pinned download  -> the Justfile is parsed (SKIP only on a
#                              connectivity failure: curl 5, 6, 7, 28 or 35)
#   * a Justfile that does not parse still fails, using the binary the
#     previous case installed (one download per run of this suite)
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
for t in bash curl sha256sum shasum tar gzip install mktemp mkdir rm uname wc make printf cat grep sed env dirname cp; do
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

# Stand-in curl that fails the way a missing release asset does under --fail.
GONE="$WORK/gone"; mkdir -p "$GONE"
printf '#!/bin/bash\necho "curl: (22) The requested URL returned error: 404" >&2\nexit 22\n' > "$GONE/curl"
chmod +x "$GONE/curl"

# Stand-in uname for a runner no arm of the installer pins.
ALIEN="$WORK/alien"; mkdir -p "$ALIEN"
printf '#!/bin/bash\ncase "${1:-}" in -m) echo mips ;; *) echo Plan9 ;; esac\n' > "$ALIEN/uname"
chmod +x "$ALIEN/uname"

# What the real-download case may do with a run's output. Only a connectivity
# failure is an honest "offline": curl 5 (proxy resolve), 6 (host resolve),
# 7 (connect), 28 (timeout), 35 (TLS connect). An HTTP error such as 404 means
# the pinned URL is wrong, and treating it as offline would let a broken pin
# pass this suite. Review on #140.
#
# Use the download's exit status reported by the installer. A retried timeout
# can precede a final HTTP error or a successful download followed by a
# checksum or extraction failure.
classify() {
    if grep -q 'recipes parsed' "$1"; then echo parsed; return; fi
    if grep -Eq '^just download failed \(curl exit (5|6|7|28|35)\)$' "$1"; then
        echo offline
    else
        echo error
    fi
}

# Stand-in curl for a retried download: a timeout first, then a 404.
MIXED="$WORK/mixed"; mkdir -p "$MIXED"
printf '#!/bin/bash\necho "curl: (28) Operation timed out after 60000 milliseconds" >&2\necho "curl: (22) The requested URL returned error: 404" >&2\nexit 22\n' > "$MIXED/curl"
chmod +x "$MIXED/curl"

# Stand-in curl that times out once, then "succeeds" with the wrong bytes.
WRONG="$WORK/wrong"; mkdir -p "$WRONG"
cat > "$WRONG/curl" <<'EOF'
#!/bin/bash
echo "curl: (28) Operation timed out after 60000 milliseconds" >&2
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
grep -Eq ': FAILED$' "$WORK/out" && ok "the checksum failure is shown" || bad "no checksum failure in the log"
[[ $(classify "$WORK/out") == error ]] && ok "a checksum failure after a retried timeout is an error" || bad "wrong bytes after a timeout were classified as $(classify "$WORK/out")"

echo "== an HTTP error is a failure, not an offline skip =="
run_step "$ACTION" "$GONE"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1" || bad "exit $rc, expected 1"
[[ $(classify "$WORK/out") == error ]] && ok "a 404 is classified as an error" || bad "a 404 was classified as $(classify "$WORK/out")"
cp "$WORK/out" "$WORK/out.404"
run_step "$ACTION" "$DEAD"
[[ $(classify "$WORK/out") == offline ]] && ok "an unresolvable host is classified as offline (control)" || bad "an unresolvable host was classified as $(classify "$WORK/out")"
run_step "$ACTION" "$MIXED"; rc=$?
[[ $rc -eq 1 && $(classify "$WORK/out") == error ]] && ok "a timeout followed by a final 404 is an error" || bad "timeout-then-404 gave exit $rc, classified $(classify "$WORK/out")"

echo "== unsupported runner =="
run_step "$ACTION" "$ALIEN"; rc=$?
[[ $rc -eq 1 ]] && ok "exit 1" || bad "exit $rc, expected 1"
grep -q 'unsupported runner Plan9/mips' "$WORK/out" && ok "the installer names the runner" || bad "no unsupported-runner message"
grep -q 'verified nothing' "$WORK/out" && ok "the gate says it verified nothing" || bad "no 'verified nothing' line"

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
targets=$(grep -Ec '^[[:space:]]+target=' "$ACTION/install.sh")
pins=$(grep -Ec '^[[:space:]]+checksum=[0-9a-f]{64} ;;$' "$ACTION/install.sh")
[[ $targets -eq 4 && $pins -eq 4 ]] && ok "each of the 4 platform arms pins a SHA-256" || bad "$targets platform arm(s), $pins pinned SHA-256"
grep -Eq '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$ACTION/install.sh" && ok "an exact version is pinned" || bad "no exact version"

echo "== real pinned download =="
run_step "$ACTION" ""; rc=$?
case $(classify "$WORK/out") in
    parsed)
        [[ $rc -eq 0 ]] && ok "installed, verified and parsed the Justfile" || bad "parsed but exit $rc"
        # Reuse the binary just installed and verified: a second download would
        # prove nothing more and doubles the worst-case run time.
        KEPT="$WORK/kept"; mkdir -p "$KEPT"; cp "$WORK/rt/just-bin/just" "$KEPT/just"
        printf 'default:\n\techo ok\n  bad indent {{\n' > "$FIX/Justfile"
        run_step "$ACTION" "$KEPT"; rc=$?
        [[ $rc -eq 1 ]] && grep -q 'does not parse' "$WORK/out" && ok "a Justfile that does not parse fails" || bad "broken Justfile gave exit $rc"
        ;;
    offline)
        echo "  SKIP real download (no connectivity): $(grep -m1 'curl: ' "$WORK/out")"
        ;;
    *)
        bad "real install failed for a reason other than connectivity (exit $rc)"; sed 's/^/      /' "$WORK/out"
        ;;
esac

echo
echo "recipes-set install controls: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
