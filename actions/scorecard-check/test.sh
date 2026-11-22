#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# test.sh: the Scorecard checks must be able to FAIL. Covers the caller
# permission check (0/1/2), the vendored helper's provenance, the reconciler
# with a fake `gh`, and the reusable's no-foreign-source rules. No network.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }

for tool in yq jq ruby sha256sum; do
  command -v "$tool" >/dev/null || { echo "$tool is required"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
USES="hyperpolymath/proven-cicd-and-workflows/.github/workflows/scorecard-reusable.yml@$SHA"

# expect NAME CODE FILE: run permissions.sh under the composite-step shell.
expect() {
  local name=$1 want=$2 file=$3 rc=0
  bash --noprofile --norc -e -o pipefail "$here/permissions.sh" "$file" >"$WORK/out" 2>&1 || rc=$?
  if [[ $rc == "$want" ]]; then ok "$name (exit $rc)"; else bad "$name: want $want, got $rc"; cat "$WORK/out"; fi
}
caller() { # caller NAME WORKFLOW_PERMS JOB_PERMS [USES]
  local f="$WORK/$1.yml"
  { echo 'name: t'; echo 'on: workflow_dispatch'
    [[ -n "$2" ]] && printf '%s\n' "$2"
    echo 'jobs:'; echo '  scorecard:'; echo "    uses: ${4:-$USES}"
    [[ -n "$3" ]] && printf '%s\n' "$3"
  } > "$f"
  printf '%s' "$f"
}
ALL4='    permissions:
      actions: read
      contents: read
      security-events: write
      id-token: write'
TOP4='permissions:
  actions: read
  contents: read
  security-events: write
  id-token: write'

echo "permissions.sh"
sed "s/__CICD_SUITE_SHA__/$SHA/" "$root/templates/scorecard-caller.yml" > "$WORK/template.yml"
expect 'shipped template passes' 0 "$WORK/template.yml"
expect 'job grants all four' 0 "$(caller all4 '' "$ALL4")"
expect 'workflow-level only, all four' 0 "$(caller top4 "$TOP4" '')"
expect 'job write-all' 0 "$(caller wall '' '    permissions: write-all')"
expect 'actions: write satisfies read' 0 "$(caller awrite '' "${ALL4/actions: read/actions: write}")"
expect 'job lacks id-token' 1 "$(caller noid '' "${ALL4/      id-token: write/}")"
expect 'job lacks actions (the usual omission)' 1 "$(caller noact '' "${ALL4/      actions: read/}")"
expect 'security-events read only' 1 "$(caller secread '' "${ALL4/security-events: write/security-events: read}")"
expect 'job block replaces a complete workflow block' 1 "$(caller replace "$TOP4" '    permissions:
      contents: read')"
expect 'job read-all' 1 "$(caller rall '' '    permissions: read-all')"
expect 'no permissions anywhere' 1 "$(caller none '' '')"
expect 'no Scorecard job' 2 "$(caller other '' "$ALL4" "hyperpolymath/proven-cicd-and-workflows/.github/workflows/rust-ci.yml@$SHA")"
expect 'foreign owner is not counted' 2 "$(caller foreign '' "$ALL4" "metadatastician/standards/.github/workflows/scorecard-reusable.yml@$SHA")"
expect 'missing file' 2 "$WORK/absent.yml"
printf 'jobs: [unclosed\n' > "$WORK/broken.yml"
expect 'unparseable file' 2 "$WORK/broken.yml"

echo "provenance"
rows=0
while IFS=$'\t' read -r path _repo commit _src sum; do
  [[ -z "$path" || "$path" == \#* ]] && continue
  rows=$((rows+1))
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || bad "$path: source commit is not a full SHA"
  got=$(sha256sum "$here/$path" | cut -d' ' -f1)
  if [[ "$got" == "$sum" ]]; then ok "$path matches its recorded hash"; else bad "$path drifted from PROVENANCE.tsv"; fi
done < "$here/PROVENANCE.tsv"
[[ $rows -ge 1 ]] || bad 'PROVENANCE.tsv lists no files'
drift="$WORK/drift.rb"; cp "$here/reconcile-scorecard-actions-lock.rb" "$drift"; echo '# edit' >> "$drift"
[[ $(sha256sum "$drift" | cut -d' ' -f1) != $(awk -F'\t' '$1=="reconcile-scorecard-actions-lock.rb"{print $5}' "$here/PROVENANCE.tsv") ]] \
  && ok 'a one-line edit changes the hash (drift is detectable)' || bad 'drift not detectable'

echo "reconcile (fake gh)"
R="$WORK/repo"; mkdir -p "$R/.github/workflows" "$WORK/bin"
cat > "$R/.github/workflows/ci.yml" <<'YML'
name: ci
on: push
jobs:
  a:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7.0.1
YML
printf 'version: v0.0.2\nworkflows: {}\ndependencies: {}\n' > "$R/.github/workflows/actions.lock"
cat > "$WORK/in.sarif" <<'JSON'
{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"Scorecard"}},"results":[
 {"ruleId":"PinnedDependenciesID","message":{"text":"score is 0: GitHub-owned GitHubAction not pinned by hash\nClick Remediation"},
  "locations":[{"physicalLocation":{"artifactLocation":{"uri":".github/workflows/ci.yml"},"region":{"startLine":7}}}]},
 {"ruleId":"TokenPermissionsID","message":{"text":"score is 0: other"},
  "locations":[{"physicalLocation":{"artifactLocation":{"uri":".github/workflows/ci.yml"},"region":{"startLine":1}}}]}]}]}
JSON
fake_gh() { printf '#!/bin/sh\necho %s\nexit %s\n' "'$1'" "$2" > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"; }
reconcile() { # reconcile WANT NAME KEPT
  local rc=0
  PATH="$WORK/bin:$PATH" ruby "$here/reconcile-scorecard-actions-lock.rb" "$WORK/in.sarif" "$WORK/out.sarif" "$WORK/audit.json" "$R" \
    >"$WORK/out" 2>&1 || rc=$?
  if [[ $rc != "$1" ]]; then bad "$2: want $1, got $rc"; cat "$WORK/out"; return; fi
  if [[ -n "${3:-}" ]]; then
    local n; n=$(jq '.runs[0].results | length' "$WORK/out.sarif")
    [[ $n == "$3" ]] && ok "$2 (exit $rc, $n kept)" || bad "$2: kept $n, want $3"
  else ok "$2 (exit $rc)"; fi
}
fake_gh '{"valid":true,"findings":[]}' 0
reconcile 0 'verified workflow: pin finding removed, others kept' 1
fake_gh '{"valid":false,"findings":[{"category":"missing"}]}' 1
reconcile 3 'unverified workflow keeps its findings and fails' 2
fake_gh 'not json' 0
reconcile 3 'verifier garbage is a failure, not a pass' 2
echo '{"version":"2.0.0","runs":[]}' > "$WORK/in.sarif"
reconcile 2 'malformed SARIF writes nothing'

echo "reusable rules"
wf="$root/.github/workflows/scorecard-reusable.yml"
# foreign FILE: print every uses:/repository: value that names metadatastician.
# A yq failure is a failure (exit 2), never an empty, passing answer.
foreign() {
  local refs
  refs=$(yq -r '[.. | select(tag == "!!map") | (.uses, .repository) | select(. != null)] | .[]' "$1") || return 2
  grep metadatastician <<< "$refs" || true
}
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@x\n        with:\n          repository: metadatastician/standards\n' > "$WORK/mutant.yml"
[[ -n $(foreign "$WORK/mutant.yml") ]] && ok 'rule catches a metadatastician checkout (mutant)' || bad 'rule missed the mutant'
if out=$(foreign "$wf") && [[ -z "$out" ]]; then ok 'no metadatastician uses: or repository:'; else bad "reusable references: $out"; fi
grep -q 'job.workflow_sha' "$wf" && bad 'reusable uses job.workflow_sha' || ok 'no job.workflow_sha'
pins=$(yq -r '[.. | select(tag == "!!map") | .uses | select(. != null)] | .[]' "$wf") || pins='unreadable@x'
[[ -n "$pins" ]] || bad 'no uses: found (rule would pass vacuously)'
bad_pins=$(grep -Ev '@[0-9a-f]{40}$' <<< "$pins" || true)
[[ -z "$bad_pins" ]] && ok 'every action pinned by full SHA' || bad "unpinned: $bad_pins"
[[ $(yq -r '.jobs.scorecard.name + "|" + .jobs."pull-request".name' "$wf") == 'Run Scorecard|Run Scorecard PR' ]] \
  && ok 'context names unchanged' || bad 'context names changed'

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
