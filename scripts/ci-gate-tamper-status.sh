#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-tamper-status.sh - run the gate tamper guard (scripts/ci-gate-tamper-guard.sh) for the pull
# requests whose head is HEAD_SHA, and publish ONE commit status, context `CI/gate-tamper-guard`, on that
# commit. It replaces the former `pull_request_target` caller: an Actions event policy blocks that event
# (it startup-failed on every run), and from 2 Dec 2026 GitHub blocks it by default in public repositories.
# It runs only from the default-branch evaluators of the reusable gate (the `workflow_run` job, and the
# sweep on `schedule` and `workflow_dispatch`), never from the `pull_request` job, which runs from the pull
# request's own branch and so could be edited by it. AGENTS MUST NEVER APPLY THE APPROVAL LABEL.
#
# Environment (all through env:, never interpolated into a script):
#   REPO HEAD_SHA          the commit to publish on
#   PR_NUMBERS             SET (the sweep, which already holds the list): the space-separated open pull request
#                          numbers whose head is HEAD_SHA; empty = nothing to do. UNSET (the workflow_run job): the
#                          publisher lists the open pull requests itself (repos/REPO/pulls?state=open, every page) and
#                          judges each one whose head is HEAD_SHA, forks included. The workflow_run payload must not
#                          supply the list: GitHub names only same-repository pull requests there, so an unapproved
#                          fork pull request sharing the head would go unjudged and a later success could mask the
#                          sweep's failure. A listing that fails or is malformed publishes failure (fail closed).
#   SUITE                  directory holding scripts/ci-gate-tamper-guard.sh at the suite's pinned commit
#   SERVER_URL RUN_ID      for target_url
#
# State: success when every listed pull request passes the guard (no gate file touched, or approved);
# failure otherwise, and on EVERY guard error (the guard fails closed). A write that would repeat the
# standing status for this context is skipped (GitHub keeps at most 1000 statuses per SHA and context);
# a failed or malformed read of the current status falls toward writing.
# Exit: 0 when a status was published (or already stood), whatever its state; 1 when none could be.
# The status is advisory until a profile or ruleset requires it (docs/CI-GATE.adoc, "Tamper guard").
set -uo pipefail
TAMPER_CONTEXT='CI/gate-tamper-guard'
SERVER_URL=${SERVER_URL:-https://github.com}; RUN_ID=${RUN_ID:-0}
fail() { echo "::error::ci-gate-tamper-status: $1; NO TAMPER VERDICT WAS PRODUCED"; exit 1; }

[[ ${REPO:-} =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && ${REPO#*/} != . && ${REPO#*/} != .. ]] || fail 'REPO is not an owner/name coordinate'
[[ ${HEAD_SHA:-} =~ ^[0-9a-f]{40}$ ]] || fail 'HEAD_SHA is not a 40-hex commit'
GUARD="${SUITE:-}/scripts/ci-gate-tamper-guard.sh"
[[ -n ${SUITE:-} && -s $GUARD ]] || fail 'the guard script is missing from the suite'

listfail=''; prs=()
if [[ -z ${PR_NUMBERS+x} ]]; then
  # List mode: judge every open pull request headed by HEAD_SHA, forks included (one listing per run).
  # Any failure of the listing, or an entry that is not {number, head.sha}, fails closed below.
  if listing=$(gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" --jq '.[] | {number: .number, sha: .head.sha}' 2> /dev/null) \
    && picked=$(jq -rs --arg h "$HEAD_SHA" 'if all(.[]; type == "object" and (.number | type) == "number" and (.sha | type) == "string")
        then (.[] | select(.sha == $h) | .number | tostring) else error("malformed") end' <<< "$listing" 2> /dev/null); then
    mapfile -t prs <<< "$picked"
    [[ -n $picked ]] || prs=()
  else
    listfail='could not list the open pull requests'
  fi
else
  read -r -a prs <<< "${PR_NUMBERS:-}"
fi
if [[ -z $listfail ]] && ((${#prs[@]} == 0)); then
  echo "ci-gate-tamper-status: no pull request has $HEAD_SHA as its head; nothing to judge"
  exit 0
fi
if [[ -z $listfail ]]; then
  for n in "${prs[@]}"; do
    if [[ ! $n =~ ^[1-9][0-9]{0,9}$ ]]; then
      # A malformed number from our own listing is a failed listing; from the caller it is a refused input.
      [[ -n ${PR_NUMBERS+x} ]] || { listfail='the pull request listing held a malformed number'; break; }
      fail "pull request number '$n' is malformed"
    fi
  done
  [[ -n $listfail ]] || mapfile -t prs < <(printf '%s\n' "${prs[@]}" | sort -un)
fi

# By characters: a character outside the BMP becomes '?' (GitHub answers HTTP 422 to it), then 140 at most.
clip() { jq -rn --arg d "$1" '($d | explode | map(if . > 65535 then 63 else . end) | implode) | if length > 140 then .[0:139] + "…" else . end'; }

state=success; failed=() first='' judged=()
if [[ -n $listfail ]]; then
  # Fail closed: without the list nothing can be called clean, and a standing success must not stand.
  echo "::error::gate tamper guard: $listfail; failing closed"
  state=failure; prs=(); first=$listfail
fi
for n in "${prs[@]}"; do
  out=$(env REPO="$REPO" PR_NUMBER="$n" bash "$GUARD" 2>&1); rc=$?
  printf '%s\n' "$out"
  # The guard reads the pull request as it is NOW, not as of HEAD_SHA. Read the head after the guard: if it
  # is no longer HEAD_SHA the verdict may describe another commit, and this pull request no longer heads
  # HEAD_SHA, so it is left out (its new head gets its own verdict). A failed read fails closed. This does
  # not see a head that moves away and back during the guard.
  now=$(gh api "repos/$REPO/pulls/$n" --jq .head.sha 2> /dev/null) || now=''
  if [[ $now =~ ^[0-9a-f]{40}$ && $now != "$HEAD_SHA" ]]; then
    echo "ci-gate-tamper-status: #$n now heads $now, not $HEAD_SHA; its verdict is not published here"
    continue
  fi
  judged+=("$n")
  if [[ $now != "$HEAD_SHA" ]]; then
    ((rc != 0)) || out="::error::gate tamper guard: could not read the head of #$n after judging it"; rc=1
  fi
  if ((rc != 0)); then
    state=failure; failed+=("#$n")
    if [[ -z $first ]]; then
      first=$(grep -h '^::error::' <<< "$out" | tail -n 1); first=${first#::error::gate tamper guard: }
      first=${first:-the guard failed with no message}
    fi
  fi
done
if [[ -z $listfail ]] && ((${#judged[@]} == 0)); then
  echo "ci-gate-tamper-status: no listed pull request still has $HEAD_SHA as its head; nothing to judge"
  exit 0
fi
# The failing pull requests come first, so the clip can only shorten the reason, never drop a number.
if [[ -n $listfail ]]; then
  desc="$first"
elif [[ $state == success ]]; then
  desc="no unapproved gate-file change in PR $(printf '#%s ' "${judged[@]}" | sed 's/ $//')"
else
  desc="$(printf '%s ' "${failed[@]}" | sed 's/ $//'): $first"
fi
desc=$(clip "$desc") || fail 'could not shape the description'

same=$(gh api --paginate "repos/$REPO/commits/$HEAD_SHA/status?per_page=100" --jq '.statuses[]' 2> /dev/null \
  | jq -rs --arg c "$TAMPER_CONTEXT" --arg s "$state" --arg d "$desc" \
    'if type == "array" and any(.[]; type == "object" and .context == $c and .state == $s and (.description // "") == $d) then "same" else "differs" end' 2> /dev/null) || same=differs
if [[ $same == same ]]; then
  echo "$TAMPER_CONTEXT = $state: $desc (already standing; write skipped)"
  exit 0
fi
gh api -X POST "repos/$REPO/statuses/$HEAD_SHA" \
  -f state="$state" -f context="$TAMPER_CONTEXT" -f description="$desc" \
  -f target_url="$SERVER_URL/$REPO/actions/runs/$RUN_ID" > /dev/null \
  || fail "could not publish the $TAMPER_CONTEXT status"
echo "$TAMPER_CONTEXT = $state: $desc"
exit 0
