# shellcheck shell=bash
# SPDX-License-Identifier: MPL-2.0
#
# ci-gate-api.sh - the CI gate's ONE REST layer: conditional reads, page walking, bounded back-off on
# rate limits, and the status writer. SOURCED, never run. It talks to GitHub only through `gh api -i`
# on PATH, so a stub can drive it (tests/ci-gate.sh, tests/ci-gate-api-budget.sh).
#
# Shipped text: .github/workflows/ci-gate.yml writes this file's text, byte for byte, in its step
# "Write the REST layer" (the first step that touches the API, before any suite file is fetched), and
# every later step, the publisher and the sweep source that copy through CI_GATE_STATUS_LIB.
# tests/ci-gate.sh fails when the two texts differ.
#
# Why: the GITHUB_TOKEN of a repository has a REST budget per hour (1000 on github.com), shared by every
# workflow in that repository. The gate re-reads the same lists many times per evaluation (snapshot,
# settle guard, post-write verify, every pull_request poll), and an exhausted budget made it publish
# NO VERDICT ("API rate limit exceeded for installation", HTTP 403). Two measures, no change of meaning:
#
#  1. Conditional reads. Every GET page is sent with the ETag of the last answer for the same URL in
#     this job (If-None-Match). An unchanged page answers 304, which GitHub does not count against the
#     primary rate limit; the cached body is used. Pages are walked by `page=N` while the answer carries
#     a Link rel="next"; more than API_MAX_PAGES pages fails closed.
#  2. Back-off, for reads and writes alike. HTTP 429, or 403 with a rate-limit signal
#     (X-RateLimit-Remaining: 0, a Retry-After header, or a body that says "rate limit"), is retried:
#     after Retry-After seconds, else after the primary reset (X-RateLimit-Reset), else a capped
#     exponential wait with jitter (60, 120, 240 s, then 240, plus up to half again). At most
#     API_MAX_ATTEMPTS tries per request, and at most API_RETRY_BUDGET_SECONDS of waiting in all, kept
#     in API_RETRY_LEDGER so that every step of a job, and every head of a sweep, spends one budget.
#     Past either limit the call FAILS with "rate limited, no verdict", and the caller fails closed: no
#     verdict is a failure, never a pass. Any other error is not retried.
#
# post_status is the only writer of commit statuses (the early pending, the verdicts, the failure
# fallback). It skips a write that repeats the status already standing for the context (same state and
# description; GitHub keeps at most 1000 statuses per SHA and context), and returns 0 written or
# skipped, 1 refused, 2 rate limited. A rate-limited POST that gave up sets CI_GATE_RATE_LIMITED=1,
# which the publisher's die() reads: a failure write would meet the same limit, so it writes nothing.
#
# Environment:
#   REPO HEAD_SHA CONTEXT SERVER_URL RUN_ID   what post_status writes (the sourcing step sets them)
#   API_CACHE                 directory for ETags, bodies and the ledger
#                             (default: ${WORK:-${RUNNER_TEMP:-a fresh mktemp -d}}/api-cache)
#   API_RETRY_BUDGET_SECONDS  total seconds this job may spend waiting on rate limits (default 300)
#   API_RETRY_LEDGER          file holding the seconds already spent (default: $API_CACHE/ledger)
#   API_MAX_ATTEMPTS          tries per request, the first included (default 5)
#   API_MAX_PAGES             page cap per list (default 50)
#   CI_GATE_SLEEP CI_GATE_CLOCK   test hooks: the sleep command, a date command called with +%s
#   API_STATS                 optional file: one line per request, "<code> <method> <path>"

if [[ -z ${API_CACHE:-} ]]; then
  if [[ -n ${WORK:-} ]]; then API_CACHE=$WORK/api-cache
  elif [[ -n ${RUNNER_TEMP:-} ]]; then API_CACHE=$RUNNER_TEMP/api-cache
  else API_CACHE=$(mktemp -d) || return 1
  fi
fi
API_RETRY_BUDGET_SECONDS=${API_RETRY_BUDGET_SECONDS:-300}
API_MAX_ATTEMPTS=${API_MAX_ATTEMPTS:-5}
API_MAX_PAGES=${API_MAX_PAGES:-50}
mkdir -p "$API_CACHE" || return 1
API_RETRY_LEDGER=${API_RETRY_LEDGER:-$API_CACHE/ledger}
[[ $API_RETRY_BUDGET_SECONDS =~ ^[0-9]{1,6}$ && $API_MAX_ATTEMPTS =~ ^[1-9][0-9]?$ && $API_MAX_PAGES =~ ^[1-9][0-9]{0,5}$ ]] \
  || { echo "::error::ci-gate-api: API_RETRY_BUDGET_SECONDS / API_MAX_ATTEMPTS / API_MAX_PAGES malformed" >&2; return 1; }
# Base 10 always: a leading zero (0300) must not be read as octal in the arithmetic below.
API_RETRY_BUDGET_SECONDS=$((10#$API_RETRY_BUDGET_SECONDS)); API_MAX_ATTEMPTS=$((10#$API_MAX_ATTEMPTS)); API_MAX_PAGES=$((10#$API_MAX_PAGES))
# Read by the caller: ci-gate-publish.sh die() exits without reposting.
# shellcheck disable=SC2034
CI_GATE_RATE_LIMITED=0

api_now() { "${CI_GATE_CLOCK:-date}" +%s; }

# <raw file> -> $API_CODE and $API_HDR (headers, CR stripped) and $API_BODY_RAW (body file).
# `gh api -i` prints the status line and headers, a blank line, then the body; on an HTTP error it
# still prints them and exits non-zero, so the exit code is not used, only the status line.
api_split() {
  local raw=$1
  API_HDR="$raw.hdr"; API_BODY_RAW="$raw.body"
  awk -v h="$API_HDR" -v b="$API_BODY_RAW" 'BEGIN { printf "" > h; printf "" > b }
    !done { sub(/\r$/, ""); if ($0 == "") { if (seen) done = 1; next } if ($0 ~ /^HTTP\//) { seen = 1; printf "" > h } print > h; next }
    { print > b }' "$raw"
  API_CODE=$(awk 'NR == 1 && /^HTTP\// { print $2 }' "$API_HDR")
  [[ $API_CODE =~ ^[0-9]{3}$ ]] || API_CODE=000
}
api_header() { # <name, case-insensitive> -> value of the last such header in $API_HDR
  awk -v n="$(tr '[:upper:]' '[:lower:]' <<< "$1")" 'BEGIN { FS = ": *" } { k = tolower($1) } k == n { v = substr($0, index($0, ":") + 1); sub(/^ +/, "", v) } END { print v }' "$API_HDR"
}

# A 429 is a rate limit. A 403 is one only with a rate-limit signal; a plain 403 (a missing permission) is not.
api_is_rate_limited() { # <stderr file>
  [[ $API_CODE == 429 ]] && return 0
  [[ $API_CODE == 403 ]] || return 1
  [[ $(api_header x-ratelimit-remaining) == 0 || -n $(api_header retry-after) ]] && return 0
  grep -qiE 'rate limit' "$API_BODY_RAW" "$1" 2> /dev/null
}

api_backoff() { # <attempt> <method> <path> -> sleeps and returns 0, or returns 1 when the attempts or the budget are spent
  local attempt=$1 wait ra reset spent now
  ra=$(api_header retry-after); reset=$(api_header x-ratelimit-reset); now=$(api_now)
  if [[ $ra =~ ^[0-9]{1,6}$ ]]; then wait=$((10#$ra))
  elif [[ $(api_header x-ratelimit-remaining) == 0 && $reset =~ ^[0-9]{1,12}$ ]]; then wait=$((10#$reset - now + 1))
  else
    # A secondary limit with no header: GitHub says wait at least a minute, so start there and grow.
    # Cap before shifting: 60 << 58 overflows, and API_MAX_ATTEMPTS may be set as high as 99.
    if ((attempt > 3)); then wait=240; else wait=$((60 << (attempt - 1))); fi
    wait=$((wait + RANDOM % (wait / 2 + 1)))
  fi
  ((wait >= 1)) || wait=1
  spent=$(cat "$API_RETRY_LEDGER" 2> /dev/null); [[ $spent =~ ^[0-9]+$ ]] || spent=0
  if ((attempt >= API_MAX_ATTEMPTS || spent + wait > API_RETRY_BUDGET_SECONDS)); then
    echo "::error::rate limited, no verdict: $2 $3 (HTTP $API_CODE) not completed after $attempt attempt(s), ${spent}s of the ${API_RETRY_BUDGET_SECONDS}s retry budget spent (next wait ${wait}s)" >&2
    return 1
  fi
  echo "ci-gate: rate limited (HTTP $API_CODE), attempt $attempt of $API_MAX_ATTEMPTS; retrying in ${wait}s (retry budget ${spent}/${API_RETRY_BUDGET_SECONDS}s)" >&2
  # A budget that cannot be recorded cannot be enforced: fail rather than wait without bound.
  # Written beside the ledger and renamed over it, so a failed write cannot leave the recorded
  # total truncated to nothing (which every later step would read as zero seconds spent).
  { echo $((spent + wait)) > "$API_RETRY_LEDGER.new" && mv -f "$API_RETRY_LEDGER.new" "$API_RETRY_LEDGER"; } 2> /dev/null || {
    rm -f "$API_RETRY_LEDGER.new" 2> /dev/null
    echo "::error::rate limited, no verdict: the retry ledger $API_RETRY_LEDGER is not writable, so the retry budget cannot be kept" >&2
    return 1
  }
  "${CI_GATE_SLEEP:-sleep}" "$wait"
}

# api_request <GET|POST> <path> [gh field args...] -> 0 with $API_BODY (a file: the body, the cached
# one on 304) and $API_LINK (the Link header of the page), 1 on any failure, 2 when rate limited past
# the attempts or the budget. GET is conditional on the cached ETag of that exact path.
api_request() {
  local method=$1 path=$2; shift 2
  local key raw attempt=0 cond=() gh_rc
  key=$(printf '%s %s' "$method" "$path" | sha256sum | cut -c1-40)
  raw="$API_CACHE/$key.raw"
  while :; do
    attempt=$((attempt + 1)); cond=()
    if [[ $method == GET && -s $API_CACHE/$key.etag && -f $API_CACHE/$key.body ]]; then
      cond=(-H "If-None-Match: $(cat "$API_CACHE/$key.etag")")
    fi
    gh_rc=0
    gh api -i -X "$method" "${cond[@]}" "$path" "$@" > "$raw" 2> "$raw.err" || gh_rc=$?
    api_split "$raw"
    [[ -z ${API_STATS:-} ]] || echo "$API_CODE $method $path" >> "$API_STATS"
    case $API_CODE in
      2??)
        # gh exits non-zero on a transport failure or a truncated transfer: never cache or trust that.
        if ((gh_rc != 0)); then cat "$raw.err" >&2; return 1; fi
        API_LINK=$(api_header link)
        if [[ $method == GET ]]; then
          # Etag out first, body and link next, etag last: an interrupted write leaves no etag, so no
          # later 304 can pair an old etag with a half-written body. Any failed write fails the call.
          rm -f "$API_CACHE/$key.etag"
          cp "$API_BODY_RAW" "$API_CACHE/$key.body" \
            && printf '%s\n' "$API_LINK" > "$API_CACHE/$key.link" \
            && api_header etag > "$API_CACHE/$key.etag.new" \
            && mv "$API_CACHE/$key.etag.new" "$API_CACHE/$key.etag" || return 1
          API_BODY="$API_CACHE/$key.body"
        else
          API_BODY=$API_BODY_RAW
        fi
        return 0 ;;
      304)
        [[ $method == GET && -f $API_CACHE/$key.body ]] || return 1
        # A 304 may leave out Link: then the page's own, cached with its body, still holds.
        API_LINK=$(api_header link)
        if [[ -n $API_LINK ]]; then
          # Replace the cached Link whole or not at all. If that fails, the entry's body and Link no
          # longer belong together: drop its ETag, so the next request fetches it afresh.
          { printf '%s\n' "$API_LINK" > "$API_CACHE/$key.link.new" && mv -f "$API_CACHE/$key.link.new" "$API_CACHE/$key.link"; } 2> /dev/null \
            || { rm -f "$API_CACHE/$key.link.new" "$API_CACHE/$key.etag"; return 1; }
        else API_LINK=$(cat "$API_CACHE/$key.link" 2> /dev/null); fi
        API_BODY="$API_CACHE/$key.body"; return 0 ;;
    esac
    if api_is_rate_limited "$raw.err"; then
      api_backoff "$attempt" "$method" "$path" || return 2
      continue
    fi
    cat "$raw.err" >&2
    return 1
  done
}

# api_list <path with ?query, no page=> <jq selecting the array of one page> -> the items of every page
# as one JSON array on stdout. Fails (1) on any page error, a non-array page, or more than API_MAX_PAGES.
api_list() {
  local path=$1 sel=$2 page=1 acc next
  acc=$(mktemp "$API_CACHE/list.XXXXXX") || return 1
  echo '[]' > "$acc"
  while :; do
    api_request GET "$path&page=$page" || { rm -f "$acc"; return 1; }
    jq -e "$sel | type == \"array\"" "$API_BODY" > /dev/null 2>&1 || { rm -f "$acc"; return 1; }
    jq -cs ".[0] + (.[1] | $sel)" "$acc" "$API_BODY" > "$acc.n" && mv "$acc.n" "$acc" || { rm -f "$acc"; return 1; }
    [[ $API_LINK == *'rel="next"'* ]] || break
    page=$((page + 1))
    ((page <= API_MAX_PAGES)) || { echo "::error::ci-gate-api: more than $API_MAX_PAGES pages at $path" >&2; rm -f "$acc"; return 1; }
  done
  cat "$acc"; rm -f "$acc"
}

status_matches() { # <state> <description> -> "same" only if the combined status holds exactly this for $CONTEXT
  local r
  r=$(api_list "repos/$REPO/commits/$HEAD_SHA/status?per_page=100" '.statuses' \
    | jq -r --arg c "$CONTEXT" --arg s "$1" --arg d "$2" \
      'if type == "array" and any(.[]; type == "object" and .context == $c and .state == $s and (.description // "") == $d) then "same" else "differs" end' 2> /dev/null) || return 0
  printf '%s\n' "$r"
}

post_status() { # <state> <description, at most 140 characters>: 0 written or skipped, 1 refused, 2 rate limited
  local rc
  if [[ $(status_matches "$1" "$2") == same ]]; then
    echo "ci-gate: status already $1 with this description on $HEAD_SHA; write skipped (1000-status cap)"
    return 0
  fi
  api_request POST "repos/$REPO/statuses/$HEAD_SHA" \
    -f state="$1" -f context="$CONTEXT" -f description="$2" \
    -f target_url="$SERVER_URL/$REPO/actions/runs/$RUN_ID"
  rc=$?
  # shellcheck disable=SC2034
  ((rc != 2)) || CI_GATE_RATE_LIMITED=1
  return "$rc"
}
