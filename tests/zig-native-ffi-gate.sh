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
printf '/* independent fixture harness launcher */\n' > "$repo/.proven-tests/integrations/contract/c-abi/launcher.c"
git -C "$repo/.proven-tests" init -q
git -C "$repo/.proven-tests" -c user.name=Fixture -c user.email=fixture@example.invalid add .
git -C "$repo/.proven-tests" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture runner'
sha=$(git -C "$repo/.proven-tests" rev-parse HEAD)
git -C "$repo" init -q
# Tracked aliases exercise canonical paths without introducing dirty inputs.
for generated in zig-out zig-cache .zig-cache; do
  ln -s "$generated" "$repo/ffi/alias-$generated"
done
mkdir -p "$repo/ffi/zig-outside"
cp "$repo/ffi/subject.h" "$repo/ffi/zig-outside/subject.h"
git -C "$repo" add ffi
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture native project'
cat > "$tmp/fakebin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    echo "${FAKE_ZIG_VERSION:-0.13.0}" ;;
  test)
    [[ ${FAKE_FAIL_PHASE:-} != explicit_test ]] || exit 1
    if [[ ${FAKE_MISSING_RECEIPT:-} == yes ]]; then
      echo 'All 0 tests passed.' >&2
    else
      echo 'All 3 tests passed.' >&2
    fi ;;
  build)
    if [[ ${2:-} == test ]]; then
      [[ ${FAKE_FAIL_PHASE:-} != test ]] || exit 1
      if [[ ${FAKE_TEST_CLOBBER_ARCHIVE:-} == yes ]]; then
        printf 'debug archive should NOT survive\n' > "$FAKE_ABI_ARCHIVE"
      fi
      if [[ ${FAKE_MUTATE_HARNESS:-} == yes ]]; then
        printf '# modified by subject test\n' >> "$FAKE_HARNESS_FILE"
      fi
    else
      [[ ${FAKE_FAIL_PHASE:-} != build ]] || exit 1
      if [[ ${FAKE_SUPPRESS_ARCHIVE:-} != yes ]]; then
        mkdir -p "$(dirname "$FAKE_ABI_ARCHIVE")"
        if [[ ${FAKE_ARCHIVE_SYMLINK:-} == yes ]]; then
          ln -s "$FAKE_OLD_ARCHIVE" "$FAKE_ABI_ARCHIVE"
        else
          printf 'fake archive; this is NOT a native qualification\n' > "$FAKE_ABI_ARCHIVE"
        fi
      fi
    fi ;;
  fmt)
    [[ ${FAKE_FAIL_PHASE:-} != fmt ]] || exit 1
    if [[ ${FAKE_FAIL_ON_CACHE:-} == yes ]]; then
      for file in "$@"; do
        [[ $file != *'/.zig-cache/'* ]] || exit 1
      done
    fi ;;
  *)
    echo 'unexpected Zig command' >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/fakebin/zig"
cat > "$tmp/fakebin/find" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${FAKE_FIND_FAIL:-} == yes ]]; then
  printf 'ffi/src/main.zig\0'
  exit 1
fi
exec /usr/bin/find "$@"
EOF
chmod +x "$tmp/fakebin/find"
export PATH="$tmp/fakebin:$PATH"
export ZIG_PROJECT_DIR=ffi ZIG_VERSION=0.13.0
export EXPECTED_SUBJECT_SHA
EXPECTED_SUBJECT_SHA=$(git -C "$repo" rev-parse HEAD)
export ZIG_TEST_ENTRY=src/main.zig
export PROVEN_TESTS_ROOT=.proven-tests PROVEN_TESTS_SHA="$sha"
export C_ABI_HEADER=ffi/subject.h C_ABI_CONSUMER=ffi/consumer.c
export C_ABI_ARCHIVE=ffi/zig-out/lib/libsubject.a
export FAKE_ABI_ARCHIVE="$repo/$C_ABI_ARCHIVE"
export FAKE_HARNESS_FILE="$repo/.proven-tests/integrations/contract/c-abi/run.sh"
export FAKE_OLD_ARCHIVE="$tmp/old-archive.a"
printf 'obsolete archive that must never qualify\n' > "$FAKE_OLD_ARCHIVE"
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
run 1 'firing: explicit Zig test run fails' env FAKE_FAIL_PHASE=explicit_test bash "$gate"
run 2 'void: zero actually executed Zig tests' env FAKE_MISSING_RECEIPT=yes bash "$gate"
run 2 'void: incorrect subject SHA' env EXPECTED_SUBJECT_SHA=0000000000000000000000000000000000000000 bash "$gate"
run 2 'void: missing Zig test entrypoint' env ZIG_TEST_ENTRY=missing.zig bash "$gate"
mkdir -p "$repo/ffi/.zig-cache"
printf 'not legitimate Zig formatting input\n' > "$repo/ffi/.zig-cache/generated.zig"
run 0 'silence: generated .zig-cache excluded from formatter' env FAKE_FAIL_ON_CACHE=yes bash "$gate"
printf '# mutated\n' >> "$repo/.proven-tests/integrations/contract/c-abi/run.sh"
run 2 'void: pinned harness has uncommitted mutation' bash "$gate"
git -C "$repo/.proven-tests" checkout -- integrations/contract/c-abi/run.sh
run 2 'void: subject test mutates pinned harness after initial check' \
  env FAKE_MUTATE_HARNESS=yes bash "$gate"
git -C "$repo/.proven-tests" checkout -- integrations/contract/c-abi/run.sh
# Assume-unchanged index bits must not conceal rewritten harness bytes.
git -C "$repo/.proven-tests" update-index --assume-unchanged integrations/contract/c-abi/run.sh
printf '# malicious replacement despite Git index flag\n' >> "$FAKE_HARNESS_FILE"
run 2 'void: harness index assume-unchanged does not mask changed bytes' bash "$gate"
git -C "$repo/.proven-tests" update-index --no-assume-unchanged integrations/contract/c-abi/run.sh
git -C "$repo/.proven-tests" checkout -- integrations/contract/c-abi/run.sh
# Subject bytes must also be checked independently of index flags.
for flag in assume-unchanged skip-worktree; do
  git -C "$repo" update-index --"$flag" ffi/build.zig
  run 0 "silence: unchanged subject with $flag" bash "$gate"
  printf '# concealed subject mutation\n' >> "$repo/ffi/build.zig"
  run 2 "void: subject $flag does not mask changed bytes" bash "$gate"
  grep -Fq 'subject content mismatch despite index status: ffi/build.zig' "$tmp/out"
  git -C "$repo" update-index --no-"$flag" ffi/build.zig
  git -C "$repo" checkout -- ffi/build.zig
done
# Outputs cannot masquerade as immutable headers supplied by the consumer.
mkdir -p "$repo/ffi/zig-out"
cp "$repo/ffi/subject.h" "$repo/ffi/zig-out/generated.h"
run 2 'void: ABI header from generated output tree' \
  env C_ABI_HEADER=ffi/zig-out/generated.h bash "$gate"
for generated in zig-out zig-cache .zig-cache; do
  mkdir -p "$repo/ffi/$generated"
  cp "$repo/ffi/subject.h" "$repo/ffi/$generated/generated.h"
  cp "$repo/ffi/consumer.c" "$repo/ffi/$generated/consumer.c"
  cp "$repo/ffi/src/main.zig" "$repo/ffi/$generated/main.zig"
  for alias in "./$generated" "$generated/./" "alias-$generated"; do
    for input in C_ABI_HEADER C_ABI_CONSUMER ZIG_TEST_ENTRY; do
      case "$input" in
        C_ABI_HEADER) value="ffi/$alias/generated.h" ;;
        C_ABI_CONSUMER) value="ffi/$alias/consumer.c" ;;
        ZIG_TEST_ENTRY) value="$alias/main.zig" ;;
      esac
      run 2 "void: $input canonical generated tree $alias" env "$input=$value" bash "$gate"
      grep -Fq 'source input placed under generated output tree:' "$tmp/out"
    done
  done
done
run 0 'silence: source with generated-root prefix is allowed' \
  env C_ABI_HEADER=ffi/zig-outside/subject.h bash "$gate"
run 2 'void: declared source cannot be canonicalised' \
  env C_ABI_HEADER=ffi/absent/subject.h bash "$gate"
grep -Fq 'source input cannot be canonicalised:' "$tmp/out"
run 2 'void: final archive symlink to old data' \
  env FAKE_ARCHIVE_SYMLINK=yes bash "$gate"
printf '# modified subject input\n' >> "$repo/ffi/build.zig"
run 2 'void: source tree differs from claimed subject SHA' bash "$gate"
git -C "$repo" checkout -- ffi/build.zig
run 2 'void: find returns partial source list and nonzero status' \
  env FAKE_FIND_FAIL=yes bash "$gate"
run 0 'silence: Debug archive overwritten by final ReleaseSafe build' \
  env FAKE_TEST_CLOBBER_ARCHIVE=yes bash "$gate"
grep -Fq 'fake archive; this is NOT a native qualification' "$FAKE_ABI_ARCHIVE" || {
  echo 'FAIL: final ReleaseSafe archive did not replace debug test artifact' >&2
  exit 1
}
printf 'stale archive must not be trusted\n' > "$FAKE_ABI_ARCHIVE"
# This direct run intentionally preserves the stale file before invoking gate.
stale_rc=0
env FAKE_SUPPRESS_ARCHIVE=yes bash "$gate" > "$tmp/out" 2>&1 || stale_rc=$?
[[ $stale_rc == 2 ]] || {
  echo "FAIL: stale archive was accepted when fresh build omitted it (rc=$stale_rc)" >&2
  cat "$tmp/out" >&2
  exit 1
}
echo 'ok: void: stale archive removed before build (exit 2)'
run 1 'firing: C ABI subject contract failure' env FAKE_CONTRACT_RC=1 bash "$gate"
run 2 'void: C ABI harness unavailable' env FAKE_CONTRACT_RC=2 bash "$gate"
run 2 'void: source SHA mismatches' env PROVEN_TESTS_SHA=0000000000000000000000000000000000000000 bash "$gate"
run 2 'void: Zig version mismatch' env FAKE_ZIG_VERSION=0.14.0 bash "$gate"
run 2 'void: native archive not built' env FAKE_SUPPRESS_ARCHIVE=yes bash "$gate"
run 2 'void: missing native project' env ZIG_PROJECT_DIR=missing bash "$gate"
run 2 'void: missing C consumer' env C_ABI_CONSUMER=missing.c bash "$gate"
run 2 'void: incomplete inputs' env PROVEN_TESTS_SHA='' bash "$gate"
echo 'ok: native workflow can fail for every named phase or report NOT RUN'
