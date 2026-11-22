#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Firing and silence fixtures for actions/rust-ci-check/install-apt.sh.
#   silence  an empty or blank list installs nothing; valid names reach apt-get
#            as separate arguments, after one update
#   firing   a leading '-', a shell metacharacter or an uppercase name is exit 2,
#            names the offender, and never reaches apt-get
# sudo is a recording stub on PATH, so nothing is installed.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/actions/rust-ci-check/install-apt.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL $*"; fail=1; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
# One line per call, with each argument escaped and delimited separately.
{
  printf '<%q>' "$@"
  printf '\n'
} >>"$SUDO_LOG"
SUDO
chmod +x "$tmp/bin/sudo"

# run NAME WANT_RC WANT_OUTPUT WANT_SUDO_LOG APT_PACKAGES
run() {
  local name=$1 want=$2 phrase=$3 calls=$4 pkgs=$5 rc=0 out
  : >"$tmp/sudo.log"
  out=$(PATH="$tmp/bin:$PATH" SUDO_LOG="$tmp/sudo.log" APT_PACKAGES="$pkgs" bash "$script" 2>&1) || rc=$?
  if [[ $rc == "$want" && $out == *"$phrase"* && $(cat "$tmp/sudo.log") == "$calls" ]]; then ok "$name"
  else bad "$name: exit $rc (want $want), output: $out, sudo: $(tr '\n' '|' <"$tmp/sudo.log")"; fi
}

run "empty list installs nothing" 0 "nothing to install" "" ""
run "blank list installs nothing" 0 "nothing to install" "" $' \t\n'
unset APT_PACKAGES
rc=0; out=$(PATH="$tmp/bin:$PATH" SUDO_LOG="$tmp/sudo.log" bash "$script" 2>&1) || rc=$?
if [[ $rc == 0 && $out == *"nothing to install"* ]]; then ok "unset list installs nothing"; else bad "unset list: exit $rc, $out"; fi
run "valid names are installed after one update" 0 "" $'<apt-get><update><-qq>\n<apt-get><install><-y><--no-install-recommends><capnproto><protobuf-compiler><libssl-dev><g++>' \
  $'capnproto  protobuf-compiler\nlibssl-dev g++'
run "an option-looking name is refused" 2 "'--allow-unauthenticated' is not a valid" "" "capnproto --allow-unauthenticated"
run "a shell metacharacter is refused" 2 "'a;b' is not a valid" "" "a;b"
run "an uppercase name is refused" 2 "'Capnp' is not a valid" "" "Capnp"
run "a one-character name is refused" 2 "'a' is not a valid" "" "a"
exit "$fail"
