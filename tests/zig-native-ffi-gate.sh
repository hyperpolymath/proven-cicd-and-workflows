#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Control tests of orchestration. The fake tools here do NOT qualify a native
# compiler, C ABI implementation, or formal proof. Live consumers must do that.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
gate=$root/scripts/zig-native-ffi-gate.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/ffi/src" "$repo/.proven-tests/integrations/contract/c-abi" "$tmp/fakebin"
printf 'const std = @import("std");\n' > "$repo/ffi/build.zig"
printf 'const std = @import("std");\n' > "$repo/ffi/src/main.zig"
printf '#define VALUE 7\n' > "$repo/ffi/subject.h"
printf '#include "subject.h"\nint main(void) { return VALUE == 7 ? 0 : 1; }\n' > "$repo/ffi/consumer.c"
cat > "$repo/.proven-tests/integrations/contract/c-abi/run.sh" <<'EOF'
#!/usr/bin/env bash
# Stand-in for the runner only: this suite tests the orchestrator's statuses.
exit "${FAKE_CONTRACT_RC:-0}"
EOF
git -C "$repo/.proven-tests" init -q
git -C "$repo/.proven-tests" -c user.name=Fixture -c user.email=fixture@example.invalid add .
git -C "$repo/.proven-tests" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture runner'
sha=$(git -C "$repo/.proven-tests" rev-parse HEAD)
git -C "$repo" init -q
git -C "$repo" add ffi
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture native project'
cat > "$tmp/fakebin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    echo "${FAKE_ZIG_VERSION:-0.13.0}" ;;
  build)
    if [[ ${2:-} == test ]]; then
      [[ ${FAKE_FAIL_PHASE:-} != test ]] || exit 1
    else
      [[ ${FAKE_FAIL_PHASE:-} != build ]] || exit 1
      if [[ ${FAKE_SUPPRESS_ARCHIVE:-} != yes ]]; then
        mkdir -p "$(dirname "$FAKE_ABI_ARCHIVE")"
        printf 'fake archive; this is NOT a native qualification\n' > "$FAKE_ABI_ARCHIVE"
      fi
    fi ;;
  fmt)
    [[ ${FAKE_FAIL_PHASE:-} != fmt ]] || exit 1 ;;
  *)
    echo 'unexpected Zig command' >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/fakebin/zig"
export PATH="$tmp/fakebin:$PATH"
export ZIG_PROJECT_DIR=ffi ZIG_VERSION=0.13.0
export PROVEN_TESTS_ROOT=.proven-tests PROVEN_TESTS_SHA="$sha"
export C_ABI_HEADER=ffi/subject.h C_ABI_CONSUMER=ffi/consumer.c
export C_ABI_ARCHIVE=ffi/zig-out/lib/libsubject.a
export FAKE_ABI_ARCHIVE="$repo/$C_ABI_ARCHIVE"
cd "$repo"
run() {
  local want=$1 label=$2
  shift 2
  rm -f "$FAKE_ABI_ARCHIVE"
  local got=0
  "$@" > "$tmp/out" 2>&1 || got=$?
  if [[ $got != "$want" ]]; then
    printf 'FAIL: %s returned %s (expected %s)\n' "$label" "$got" "$want" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  printf 'ok: %s (exit %s)\n' "$label" "$want"
}
run 0 'silence: all phases invoked and contract accepted' bash "$gate"
grep -Fq 'PASS: native build + tests + format + linked ABI contract' "$tmp/out"
run 1 'firing: native build failure' env FAKE_FAIL_PHASE=build bash "$gate"
run 1 'firing: native test failure' env FAKE_FAIL_PHASE=test bash "$gate"
run 1 'firing: native format failure' env FAKE_FAIL_PHASE=fmt bash "$gate"
run 1 'firing: C ABI subject contract failure' env FAKE_CONTRACT_RC=1 bash "$gate"
run 2 'void: C ABI harness unavailable' env FAKE_CONTRACT_RC=2 bash "$gate"
run 2 'void: source SHA mismatches' env PROVEN_TESTS_SHA=0000000000000000000000000000000000000000 bash "$gate"
run 2 'void: Zig version mismatch' env FAKE_ZIG_VERSION=0.14.0 bash "$gate"
run 2 'void: native archive not built' env FAKE_SUPPRESS_ARCHIVE=yes bash "$gate"
run 2 'void: missing native project' env ZIG_PROJECT_DIR=missing bash "$gate"
run 2 'void: missing C consumer' env C_ABI_CONSUMER=missing.c bash "$gate"
run 2 'void: incomplete inputs' env PROVEN_TESTS_SHA='' bash "$gate"
echo 'ok: native workflow can fail for every named phase or report NOT RUN'
