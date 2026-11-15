#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath)
# Tool-dependent orchestration of a pinned native Zig project and a pinned
# Proven-Tests C ABI contract harness. Not a formal compiler/proof certificate.
# Exit 0: actual steps ran and passed; 1: subject failed; 2: NOT RUN.
set -euo pipefail
void() { printf 'NOT RUN: %s\n' "$*" >&2; exit 2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

: "${ZIG_PROJECT_DIR:=}"
: "${ZIG_VERSION:=}"
: "${PROVEN_TESTS_ROOT:=}"
: "${PROVEN_TESTS_SHA:=}"
: "${C_ABI_HEADER:=}"
: "${C_ABI_CONSUMER:=}"
: "${C_ABI_ARCHIVE:=}"
[[ -n $ZIG_PROJECT_DIR && -n $ZIG_VERSION && -n $PROVEN_TESTS_ROOT &&
   -n $PROVEN_TESTS_SHA && -n $C_ABI_HEADER && -n $C_ABI_CONSUMER &&
   -n $C_ABI_ARCHIVE ]] || void 'all seven explicit inputs must be supplied'
[[ $ZIG_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || void 'ZIG_VERSION is not an exact numeric release'
[[ $PROVEN_TESTS_SHA =~ ^[a-f0-9]{40}$ ]] || void 'PROVEN_TESTS_SHA must be a full immutable commit'
for dir in "$ZIG_PROJECT_DIR" "$PROVEN_TESTS_ROOT"; do
  [[ $dir != /* && $dir != -* && $dir != *'..'* && $dir != *'?'* && $dir != *'*'* ]] ||
    void "project/Proven path must be literal repository-relative: $dir"
done
for file in "$C_ABI_HEADER" "$C_ABI_CONSUMER" "$C_ABI_ARCHIVE"; do
  [[ $file != /* && $file != -* && $file != *'..'* && $file != *'?'* && $file != *'*'* ]] ||
    void "subject path must be literal repository-relative: $file"
done
command -v git >/dev/null 2>&1 || void 'git unavailable'
subject_sha=$(git rev-parse HEAD 2>/dev/null) || void 'subject is not a Git checkout'
[[ $subject_sha =~ ^[a-f0-9]{40}$ ]] || void 'subject revision is not a commit'
actual=$(git -C "$PROVEN_TESTS_ROOT" rev-parse HEAD 2>/dev/null) ||
  void "Proven harness checkout unreadable at $PROVEN_TESTS_ROOT"
[[ $actual == "$PROVEN_TESTS_SHA" ]] ||
  void "Proven harness revision drift: got $actual, expected $PROVEN_TESTS_SHA"
[[ -f $ZIG_PROJECT_DIR/build.zig ]] || void 'native project has no build.zig'
for file in "$C_ABI_HEADER" "$C_ABI_CONSUMER"; do
  [[ -s $file && -r $file ]] || void "ABI consumer source missing or empty: $file"
done
command -v zig >/dev/null 2>&1 || void 'zig compiler missing'
version=$(zig version) || void 'zig compiler cannot run'
[[ $version == "$ZIG_VERSION" ]] ||
  void "Zig version mismatch: got $version, expected $ZIG_VERSION"
[[ -f "$PROVEN_TESTS_ROOT/integrations/contract/c-abi/run.sh" ]] ||
  void 'Proven C ABI harness path is missing'
printf 'Subject: %s\nProven Tests: %s\nZig toolchain: %s\n' "$subject_sha" "$actual" "$version"

if (cd "$ZIG_PROJECT_DIR" && zig build -Doptimize=ReleaseSafe); then
  echo 'ok: Zig native build executed'
else
  fail 'Zig native build failed'
fi
if (cd "$ZIG_PROJECT_DIR" && zig build test); then
  echo 'ok: Zig native unit and linked integration tests executed'
else
  fail 'Zig native test command failed'
fi
mapfile -d '' -t zigfiles < <(find "$ZIG_PROJECT_DIR" -type f -name '*.zig' \
  -not -path '*/zig-cache/*' -not -path '*/zig-out/*' -print0)
[[ ${#zigfiles[@]} -gt 0 ]] || void 'no Zig source files discovered for format check'
if zig fmt --check "${zigfiles[@]}"; then
  echo "ok: Zig format checked ${#zigfiles[@]} files"
else
  fail 'Zig format check failed'
fi
[[ -s $C_ABI_ARCHIVE && -r $C_ABI_ARCHIVE ]] ||
  void "native build emitted no usable ABI archive at $C_ABI_ARCHIVE"
if bash "$PROVEN_TESTS_ROOT/integrations/contract/c-abi/run.sh" \
    "$C_ABI_HEADER" "$C_ABI_CONSUMER" "$C_ABI_ARCHIVE"; then
  echo 'ok: independently compiled and executed Proven C ABI contract'
else
  rc=$?
  [[ $rc == 2 ]] && void 'Proven C ABI contract harness did not execute'
  fail "Proven C ABI consumer rejected the contract (exit $rc)"
fi
echo 'PASS: native build + tests + format + linked ABI contract; NOT A FORMAL PROOF'
