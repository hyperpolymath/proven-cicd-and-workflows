#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Canonical positive, firing and calibration specimens for the *real adapter*.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/docs"
git -C "$tmp" init -q repo
git -C "$repo" remote add origin https://github.com/example/documentation.git
cat >"$repo/README.md" <<'DOC'
# Valid Markdown
[Local documentation](docs/index.adoc)
[External resource, not checked offline](https://example.org/)
DOC
cat >"$repo/docs/index.adoc" <<'DOC'
= Local AsciiDoc
A valid local document.
DOC
profile="$tmp/profile.json"
jq '.slots.documents=["README.md","docs/index.adoc"]' \
  "$root/tests/fixtures/ci-profiles/docs-data.json" >"$profile"

commit_source() {
  git -C "$repo" add README.md docs/index.adoc
  if [[ -f "$repo/mise.toml" ]]; then git -C "$repo" add mise.toml; fi
  git -C "$repo" -c user.name=Tester -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit --quiet -m 'fixture source'
  sha=$(git -C "$repo" rev-parse HEAD)
}
assert_outcome() {
  expected=$1; label=$2; shift 2
  rc=0
  "$@" >"$tmp/output" 2>&1 || rc=$?
  if [[ $rc != "$expected" ]]; then
    printf 'BAD %s expected=%s actual=%s\n' "$label" "$expected" "$rc" >&2
    cat "$tmp/output" >&2
    exit 1
  fi
  printf 'ok: %s -> %s\n' "$label" "$rc"
}
commit_source
checker="$root/scripts/check-docs-data.sh"
assert_outcome 0 'silent: valid markdown + valid AsciiDoc, local links' \
  bash "$checker" "$profile" "$repo" "$sha"
grep -q '"documents_checked":2' "$tmp/output" || {
  echo "BAD: no executed-document receipt" >&2; exit 1;
}
# The repository must not be permitted to choose the verifier's tools.
# A malicious/untrusted per-repo mise.toml must not load on the host.
cat >"$repo/mise.toml" <<'DOC'
[tools]
lychee = "0.0.1"
DOC
commit_source
assert_outcome 0 'silent: repository cannot switch the verifier toolchain' \
  bash "$checker" "$profile" "$repo" "$sha"
assert_outcome 2 'calibration: missing profile' \
  bash "$checker" "$tmp/absent.json" "$repo" "$sha"
assert_outcome 2 'calibration: wrong subject SHA' \
  bash "$checker" "$profile" "$repo" "0000000000000000000000000000000000000000"
assert_outcome 2 'calibration: no link checker' \
  env PATH=/usr/bin:/bin bash "$checker" "$profile" "$repo" "$sha"
cat >"$repo/README.md" <<'DOC'
# Broken relative link
[Not present](docs/no-such-file.adoc)
DOC
commit_source
assert_outcome 1 'firing: broken local Markdown target' \
  bash "$checker" "$profile" "$repo" "$sha"
cat >"$repo/README.md" <<'DOC'
# Correct link again
[Local documentation](docs/index.adoc)
DOC
cat >"$repo/docs/index.adoc" <<'DOC'
= Bad AsciiDoc
include::missing-include.adoc[]
DOC
commit_source
assert_outcome 1 'firing: missing AsciiDoc include' \
  bash "$checker" "$profile" "$repo" "$sha"
echo "ok: all 7 docs-data admission controls executed"