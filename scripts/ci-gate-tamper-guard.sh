#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-tamper-guard.sh - fail a pull request that touches the gate's own files unless the owner
# approved that change. Reads metadata through `gh` only; never checks out or runs pull request code.
#
# Called per pull request by scripts/ci-gate-publish.sh (the gate's own verdict: docs/CI-GATE.adoc,
# "Tamper guard"), and by the deprecated pull_request_target reusable ci-gate-tamper-guard.yml.
#
# Environment (all through env:, never interpolated into a script):
#   REPO PR_NUMBER        what to inspect
#   APPROVAL_LABEL        default gate-change-approved
#   EXTRA_PROTECTED_FILE  optional: a file of further protected paths, one EXACT path per line (no
#                         glob), each a plain file under .github/workflows (^\.github/workflows/
#                         [A-Za-z0-9_.-]+\.ya?ml$, the profile's own workflow-path rule). The publisher
#                         writes the profile's producer workflows here. Blank lines are ignored; any
#                         other line, or an unreadable file, is an error (fail closed).
#
# Protected files (a rename counts through both its old and its new name):
PROTECTED=(
  '.github/workflows/ci-gate*.yml'
  '.github/workflows/ci-gate*.yaml'
  'scripts/check-required-contexts.sh'
  'scripts/ci-gate-*.sh'
  'scripts/validate-ci-gate-profile.sh'
  'templates/ci-gate*.yml'
  'profiles/ci-gate/*'
)
EXTRA=()   # exact paths from EXTRA_PROTECTED_FILE
#
# Approval = the label is on the pull request NOW (its latest labeled/unlabeled event is `labeled`),
# the actor of that labeled event holds `admin` on the repository (GET collaborators/{login}/permission,
# `.permission == "admin"`; a write or maintain actor, an unreadable or malformed answer, or a missing
# actor all refuse), AND it was applied AFTER the newest commit of the pull request (committer date). So any later
# push needs the label re-applied. THE LIMIT: a commit date is written by the pusher, so a deliberate
# backdating or a force-push of older commits can defeat the comparison; GitHub exposes no reliable
# push time to a read-only job. This is tamper-EVIDENT, not tamper-proof, and AGENTS MUST NEVER APPLY
# THE LABEL: it is the owner's act (docs/CI-GATE.adoc, "Tamper guard").
#
# Exit 0: no gate file touched, or approved. Exit 1: not approved, and EVERY error (fail closed).
# Stdout, for the publisher: a refusal that is a VERDICT (gate files touched, not approved) prints
# `guard-result=unapproved` and `guard-touched=<comma-separated paths>`; an error (no verdict) prints
# neither, so the caller can tell "not approved" from "could not check".
set -uo pipefail
APPROVAL_LABEL=${APPROVAL_LABEL:-gate-change-approved}

fail() { echo "::error::gate tamper guard: $1"; exit 1; }
deny() { echo "guard-result=unapproved"; echo "guard-touched=$list"; fail "$1"; }

if [[ -n ${EXTRA_PROTECTED_FILE:-} ]]; then
  [[ -f $EXTRA_PROTECTED_FILE && -r $EXTRA_PROTECTED_FILE ]] || fail 'EXTRA_PROTECTED_FILE is not a readable file'
  while IFS= read -r x || [[ -n $x ]]; do
    [[ -n $x ]] || continue
    [[ $x =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]] \
      || fail 'EXTRA_PROTECTED_FILE has a line that is not a plain .github/workflows/*.yml path'
    EXTRA+=("$x")
  done < "$EXTRA_PROTECTED_FILE"
fi

protected() { # <path> -> 0 if it is a gate file
  local f=$1 p
  for p in "${PROTECTED[@]}"; do
    # shellcheck disable=SC2053
    [[ $f == $p ]] && return 0
  done
  for p in "${EXTRA[@]}"; do
    [[ $f == "$p" ]] && return 0
  done
  return 1
}

if [[ ${1:-} == --match ]]; then # test hook: print the protected ones among the given paths
  shift; rc=1
  for f in "$@"; do protected "$f" && { echo "$f"; rc=0; }; done
  exit $rc
fi

[[ ${REPO:-} =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && ${REPO#*/} != . && ${REPO#*/} != .. ]] || fail 'REPO is not an owner/name coordinate'
[[ ${PR_NUMBER:-} =~ ^[1-9][0-9]*$ ]] || fail 'PR_NUMBER is not a pull request number'
[[ $APPROVAL_LABEL =~ ^[A-Za-z0-9._-]{1,50}$ ]] || fail 'APPROVAL_LABEL is malformed'

files=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files?per_page=100" --jq '.[] | {filename, previous_filename}') \
  || fail 'could not list the changed files; no verdict'
n=$(jq -s 'length' <<< "$files") || fail 'could not count the changed files'
# The files API stops at 3000 files: a larger pull request cannot be checked, so it is refused.
(( n < 3000 )) || fail 'the pull request has 3000 or more changed files; the guard cannot check it'

touched=()
while IFS= read -r f; do
  [[ -n $f ]] || continue
  protected "$f" && touched+=("$f")
done < <(jq -rs '.[] | .filename, (.previous_filename // empty)' <<< "$files")
if (( ${#touched[@]} == 0 )); then
  echo "gate tamper guard: no gate file is touched by this pull request ($n files checked)"; exit 0
fi
list=$(printf '%s\n' "${touched[@]}" | LC_ALL=C sort -u | paste -sd, -)

events=$(gh api --paginate "repos/$REPO/issues/$PR_NUMBER/events?per_page=100" --jq '.[] | select(.event == "labeled" or .event == "unlabeled") | {event, label: .label.name, at: .created_at, actor: (.actor.login // "")}') \
  || fail 'could not read the label events; no verdict'
latest=$(jq -rs --arg l "$APPROVAL_LABEL" '
  map(select(.label == $l)) | sort_by(.at) | if length == 0 then "" else last | if .event == "labeled" then [.at, .actor] | @tsv else "" end end' <<< "$events") \
  || fail 'could not evaluate the label events'
if [[ -z $latest ]]; then
  deny "this pull request touches gate files ($list) and the label '$APPROVAL_LABEL' is not applied. Only the repository owner may apply it; agents must not."
fi
IFS=$'\t' read -r label_at actor <<< "$latest"
[[ -n $label_at ]] || fail 'the label event has no time'

# The actor of the latest labeled event must hold admin. The login is validated before it is put into
# a URL; a missing actor (a deleted account), a bot, an API error or an unexpected answer all refuse.
[[ $actor =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$ ]] \
  || deny "gate files are touched ($list); the actor of the latest '$APPROVAL_LABEL' event is missing or not a user login, so it cannot be shown to be an admin"
perm=$(gh api "repos/$REPO/collaborators/$actor/permission" --jq '.permission') \
  || fail "could not read the repository permission of '$actor'; no verdict"
[[ $perm == admin ]] \
  || deny "gate files are touched ($list); '$APPROVAL_LABEL' was applied by '$actor' whose repository permission is '${perm:-none}', not admin. Only an admin's label counts."

commits=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/commits?per_page=100" --jq '.[] | .commit.committer.date') \
  || fail 'could not read the pull request commits; no verdict'
nc=$(printf '%s\n' "$commits" | grep -c . || true)
(( nc >= 1 && nc < 250 )) || fail 'the pull request has no commits or 250 or more; the guard cannot check the label against them'
newest=$(printf '%s\n' "$commits" | jq -Rn '[inputs | select(length > 0) | fromdateiso8601] | max') \
  || fail 'could not parse the commit dates'
applied=$(jq -rn --arg t "$label_at" '$t | fromdateiso8601') || fail 'could not parse the label time'
if (( applied > newest )); then
  echo "gate tamper guard: gate files touched ($list); '$APPROVAL_LABEL' applied by admin '$actor' after the newest commit; approved"
  exit 0
fi
deny "gate files are touched ($list) and '$APPROVAL_LABEL' was applied before the newest commit; the owner must re-apply it after every push."
