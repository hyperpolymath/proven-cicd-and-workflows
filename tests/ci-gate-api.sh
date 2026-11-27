#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# tests/ci-gate-api.sh - the CI gate's REST layer (scripts/ci-gate-api.sh): conditional reads, pagination,
# rate-limit back-off, and its fail-closed edges. Silence cases (a guard must NOT fire) and Firing cases
# (it must), then one mutant per guard: each mutant must make at least one case fail.
#
# The fake gh answers from a queue: $Q/<n>.resp is the raw `gh api -i` output of the nth request and
# $Q/<n>.rc its exit code. Every request's arguments are logged to $Q/calls (one line each).
# Usage: bash tests/ci-gate-api.sh            run the cases and the mutants
#        API_UNDER_TEST=<file> ... --cases    run the cases only, against <file> (used per mutant)
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
API=${API_UNDER_TEST:-$ROOT/scripts/ci-gate-api.sh}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); [[ -n ${QUIET:-} ]] || echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); [[ -n ${QUIET:-} ]] || echo "  FAIL $1"; }
chk() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1: got '$2', expected '$3'"; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$Q/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$Q/n"
printf '%s\n' "$*" >> "$Q/calls"
[[ -f $Q/$n.resp ]] || { echo "fake gh: no response queued for request $n: $*" >&2; exit 1; }
[[ ! -f $Q/$n.err ]] || cat "$Q/$n.err" >&2
cat "$Q/$n.resp"; exit "$(cat "$Q/$n.rc" 2>/dev/null || echo 0)"
EOF
cat > "$WORK/bin/clock" <<'EOF'
#!/usr/bin/env bash
cat "$Q/clock"
EOF
cat > "$WORK/bin/nap" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "$Q/sleeps"; echo $(( $(cat "$Q/clock") + $1 )) > "$Q/clock"
EOF
chmod +x "$WORK/bin/"*

reset() { Q=$WORK/q.$RANDOM$RANDOM; mkdir -p "$Q"; echo 1000 > "$Q/clock"; : > "$Q/sleeps"; : > "$Q/calls"; export Q; }
# resp <code> <reason> <body> [header lines...]: queue the next response; gh exits 1 for any non-2xx
resp() {
  local code=$1 reason=$2 body=$3; shift 3
  local n=$(( $(ls "$Q"/*.resp 2>/dev/null | wc -l) + 1 ))
  { printf 'HTTP/2.0 %s %s\r\n' "$code" "$reason"; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n%s\n' "$body"; } > "$Q/$n.resp"
  [[ $code == 2?? ]] && echo 0 > "$Q/$n.rc" || echo 1 > "$Q/$n.rc"
}
# api <bash snippet using the layer> -> OUT (stdout+stderr), RC; a fresh WORK per call unless KEEP=1
api() {
  [[ -n ${KEEP:-} ]] || rm -rf "$WORK/w"
  OUT=$(env PATH="$WORK/bin:$PATH" WORK="$WORK/w" CI_GATE_CLOCK="$WORK/bin/clock" CI_GATE_SLEEP="$WORK/bin/nap" \
    "${ENVV[@]}" timeout 20 bash -c 'source "$1" || exit 99; eval "$2"' _ "$API" "$1" 2>&1); RC=$?
}
ENVV=()
SLEEPS() { paste -sd, "$Q/sleeps"; }
NCALLS() { grep -c . "$Q/calls"; }
GET1='api_request GET "repos/o/r/x?per_page=100" && cat "$API_BODY"'

cases() {
  echo "== Silence: no back-off, no retry, nothing cached where it must not be =="
  reset; resp 200 OK '{"a":1}' 'Etag: "e1"'
  api "$GET1"; chk "200: the body is returned" "$RC/$OUT" '0/{"a":1}'
  chk "200: one request, no sleep" "$(NCALLS)/$(SLEEPS)" "1/"
  chk "the first GET is not conditional" "$(grep -c 'If-None-Match' "$Q/calls")" 0

  reset; resp 200 OK '{"a":1}' 'Etag: "e1"'; resp 304 'Not Modified' '' 'Etag: "e1"'
  KEEP=1 api "$GET1; $GET1"
  chk "a repeat GET is sent with the cached ETag" "$(sed -n 2p "$Q/calls" | grep -c 'If-None-Match: "e1"')" 1
  chk "304: the cached body is returned, not an empty one" "$RC/$(tail -n 1 <<< "$OUT")" '0/{"a":1}'

  reset; resp 403 Forbidden '{"message":"Resource not accessible by integration"}' 'X-Ratelimit-Remaining: 4000'
  api "$GET1"; chk "a plain 403 (a missing permission) is not a rate limit: fails at once" "$RC/$(NCALLS)/$(SLEEPS)" "1/1/"

  reset; resp 500 'Server Error' '{"message":"rate limit backend down"}' 'Retry-After: 5'
  api "$GET1"; chk "a 500 is never retried, whatever its body or headers say" "$RC/$(NCALLS)/$(SLEEPS)" "1/1/"

  reset; resp 200 OK '{"a":1}' 'Etag: "e1"'; resp 201 Created '{}' 'Etag: "e2"'; resp 201 Created '{}'
  KEEP=1 api 'api_request GET "repos/o/r/s" >/dev/null; api_request POST "repos/o/r/s" -f a=b; api_request POST "repos/o/r/s" -f a=b'
  chk "a POST is never conditional, even after a GET of the same path" "$RC/$(grep -c 'If-None-Match' "$Q/calls")" "0/0"

  reset; resp 200 OK '{"items":[1,2]}' 'Etag: "p1"'
  api 'api_list "repos/o/r/l?per_page=2" .items'
  chk "one page, no Link: its items" "$RC/$OUT/$(NCALLS)" "0/[1,2]/1"

  reset; ENVV=(API_RETRY_BUDGET_SECONDS=x); api 'true'; ENVV=()
  chk "a malformed retry budget refuses to load" "$RC" 99
  reset; ENVV=(API_MAX_PAGES=0); api 'true'; ENVV=()
  chk "a zero page cap refuses to load" "$RC" 99
  reset; ENVV=(API_MAX_ATTEMPTS=0); api 'true'; ENVV=()
  chk "a zero attempt cap refuses to load" "$RC" 99

  echo "== Firing: rate limits back off and retry; past the budget, fail closed =="
  reset; resp 403 Forbidden '{"message":"API rate limit exceeded for installation ID 1."}' 'X-Ratelimit-Remaining: 0' 'X-Ratelimit-Reset: 1030'
  resp 200 OK '{"a":2}'
  api "$GET1"; chk "primary limit: waits until the reset plus 1 s, then succeeds" "$RC/$(SLEEPS)/$(tail -n 1 <<< "$OUT")" '0/31/{"a":2}'
  grep -q 'ci-gate: rate limited (HTTP 403), attempt 1 of 5; retrying in 31s' <<< "$OUT" && ok "primary limit: a warning names the wait" || bad "no back-off warning"

  reset; resp 403 Forbidden '{"message":"Forbidden"}' 'X-Ratelimit-Remaining: 0' 'X-Ratelimit-Reset: 1010'; resp 200 OK '{}'
  api "$GET1"; chk "remaining 0 alone (a neutral body) is a rate limit" "$RC/$(SLEEPS)" "0/11"

  reset; resp 403 Forbidden '{"message":"Forbidden"}' 'X-Ratelimit-Remaining: 0' 'X-Ratelimit-Reset: 900'; resp 200 OK '{}'
  api "$GET1"; chk "a reset already past waits 1 s, never 0 or a negative" "$RC/$(SLEEPS)" "0/1"

  reset; resp 429 'Too Many Requests' '{"message":"slow down"}' 'Retry-After: 7'; resp 200 OK '{}'
  api "$GET1"; chk "429 with Retry-After: waits exactly that" "$RC/$(SLEEPS)" "0/7"

  reset; resp 403 Forbidden '{"message":"Forbidden"}' 'Retry-After: 9' 'X-Ratelimit-Remaining: 0' 'X-Ratelimit-Reset: 2000'; resp 200 OK '{}'
  api "$GET1"; chk "Retry-After wins over the primary reset" "$RC/$(SLEEPS)" "0/9"

  reset; resp 403 Forbidden '{"message":"Forbidden"}' 'Retry-After: 4' 'X-Ratelimit-Remaining: 4000'; resp 200 OK '{}'
  api "$GET1"; chk "a 403 with only Retry-After (neutral body, quota left) is a rate limit" "$RC/$(SLEEPS)" "0/4"

  reset; resp 403 Forbidden '{"message":"You have exceeded a secondary rate limit."}' 'X-Ratelimit-Remaining: 4000'
  resp 403 Forbidden '{"message":"You have exceeded a secondary rate limit."}' 'X-Ratelimit-Remaining: 4000'; resp 200 OK '{}'
  api "$GET1"; IFS=, read -r s1 s2 <<< "$(SLEEPS)"
  chk "secondary limit with no Retry-After: two waits, then success" "$RC/$(NCALLS)" "0/3"
  { ((s1 >= 60 && s1 <= 90 && s2 >= 120 && s2 <= 180)); } && ok "no headers: starts at the documented minute, then doubles, with jitter (${s1}s in 60..90, then ${s2}s in 120..180)" || bad "back-off out of range: '$(SLEEPS)'"

  reset; for _ in 1 2 3 4 5 6; do resp 403 Forbidden '{"message":"secondary rate limit"}' 'X-Ratelimit-Remaining: 4000'; done; resp 200 OK '{}'
  ENVV=(API_MAX_ATTEMPTS=7 API_RETRY_BUDGET_SECONDS=5000); api "$GET1"; ENVV=()
  IFS=, read -r s1 s2 s3 s4 s5 s6 <<< "$(SLEEPS)"
  { ((s3 >= 240 && s3 <= 360 && s4 >= 240 && s4 <= 360 && s5 >= 240 && s5 <= 360 && s6 >= 240 && s6 <= 360)); } && ok "the back-off is capped at 240 s (plus jitter): ${s3}, ${s4}, ${s5}, ${s6}" || bad "cap out of range: '$(SLEEPS)'"

  # a high attempt count must not wrap the shift negative and collapse the wait to 1 s
  reset; for _ in $(seq 62); do resp 403 Forbidden '{"message":"secondary rate limit"}' 'X-Ratelimit-Remaining: 4000'; done; resp 200 OK '{}'
  ENVV=(API_MAX_ATTEMPTS=70 API_RETRY_BUDGET_SECONDS=999999); api "$GET1"; ENVV=()
  min=$(tr ',' '\n' <<< "$(SLEEPS)" | sort -n | head -n 1)
  { ((RC == 0 && ${min:-0} >= 60)) && [[ $(tr ',' '\n' <<< "$(SLEEPS)" | grep -c .) == 62 ]]; } && ok "62 retries: no wait ever drops below 60 s (the shift cannot overflow)" || bad "overflow: rc=$RC min=${min:-none}"

  reset; for _ in 1 2 3 4 5 6; do resp 429 x '{}' 'Retry-After: 3'; done
  api "$GET1"; chk "rate limited every time: 5 attempts, 4 waits, then fails closed (exit 2)" "$RC/$(NCALLS)/$(SLEEPS)" "2/5/3,3,3,3"
  grep -q '::error::rate limited, no verdict: GET repos/o/r/x' <<< "$OUT" && ok "attempts exhausted: the error says 'rate limited, no verdict'" || bad "no 'rate limited, no verdict' error: $OUT"

  reset; resp 429 x '{}'; resp 200 OK '{"a":3}'
  api "$GET1"; IFS=, read -r s1 <<< "$(SLEEPS)"
  { ((RC == 0 && s1 >= 60 && s1 <= 90)); } && ok "429 with no header at all is a rate limit (${s1}s, then success)" || bad "429 with no headers: rc=$RC sleeps='$(SLEEPS)'"

  reset; resp 403 Forbidden '{}' 'X-Ratelimit-Remaining: 0' 'X-Ratelimit-Reset: 1500'
  ENVV=(API_RETRY_BUDGET_SECONDS=300); api "$GET1"; ENVV=()
  chk "a wait past the budget is not taken: fails closed, no sleep" "$RC/$(SLEEPS)/$(NCALLS)" "2//1"
  grep -q '::error::rate limited, no verdict: GET .* (HTTP 403) not completed after 1 attempt(s), 0s of the 300s retry budget spent (next wait 501s)' <<< "$OUT" \
    && ok "budget exhausted: an error names the wait and the budget" || bad "no budget error: $OUT"

  reset; resp 429 x '{}' 'Retry-After: 200'; resp 200 OK '{}'; resp 429 x '{}' 'Retry-After: 200'
  ENVV=(API_RETRY_BUDGET_SECONDS=300 API_RETRY_LEDGER="$Q/ledger"); api "$GET1"; api "$GET1"; ENVV=()
  chk "the budget is shared across invocations through the ledger: the second 200 s wait is refused" "$RC/$(SLEEPS)/$(cat "$Q/ledger")" "2/200/200"

  echo "== the status writer: one write path, duplicates skipped, a spent budget raises the flag =="
  PS=(REPO=o/r HEAD_SHA=abc CONTEXT=CI/gate SERVER_URL=https://github.com RUN_ID=1)
  reset; resp 200 OK '{"statuses":[]}'; resp 201 Created '{}'
  ENVV=("${PS[@]}"); api 'post_status success "all green"; echo "rc=$? flag=$CI_GATE_RATE_LIMITED"'; ENVV=()
  chk "Silence: a new status is written: 2 requests (read, POST), no wait, flag 0" "$(tail -n 1 <<< "$OUT")/$(NCALLS)/$(SLEEPS)" "rc=0 flag=0/2/"
  grep -q 'POST .*statuses/abc .*description=all green' "$Q/calls" && ok "the POST carries state, context, description and target_url" || bad "POST arguments: $(tail -n 1 "$Q/calls")"
  reset; resp 200 OK '{"statuses":[{"context":"CI/gate","state":"success","description":"all green"}]}'
  ENVV=("${PS[@]}"); api 'post_status success "all green"; echo "rc=$? flag=$CI_GATE_RATE_LIMITED"'; ENVV=()
  chk "Silence: the same status already stands: no POST, written-or-skipped is 0" "$(tail -n 1 <<< "$OUT")/$(NCALLS)" "rc=0 flag=0/1"
  reset; resp 200 OK '{"statuses":[{"context":"CI/gate","state":"pending","description":"all green"}]}'; resp 201 Created '{}'
  ENVV=("${PS[@]}"); api 'post_status success "all green"; echo "rc=$?"'; ENVV=()
  chk "Silence: the same description in another state is written" "$(tail -n 1 <<< "$OUT")/$(NCALLS)" "rc=0/2"
  reset; resp 500 'Server Error' '{"message":"boom"}'; resp 500 'Server Error' '{"message":"boom"}'
  ENVV=("${PS[@]}"); api 'post_status success "x"; echo "rc=$? flag=$CI_GATE_RATE_LIMITED"'; ENVV=()
  chk "Silence: an HTTP 500 is refused (1), never retried, no flag" "$(tail -n 1 <<< "$OUT")/$(NCALLS)/$(SLEEPS)" "rc=1 flag=0/2/"
  reset; resp 200 OK '{"statuses":[]}'; for _ in 1 2 3 4 5; do resp 429 x '{}' 'Retry-After: 3'; done
  ENVV=("${PS[@]}"); api 'post_status success "x"; echo "rc=$? flag=$CI_GATE_RATE_LIMITED"'; ENVV=()
  chk "Firing: a POST rate limited to exhaustion returns 2 and raises the flag (5 POSTs, 4 waits)" "$(tail -n 1 <<< "$OUT")/$(NCALLS)/$(SLEEPS)" "rc=2 flag=1/6/3,3,3,3"
  reset; resp 200 OK '{"statuses":[]}'; resp 429 x '{}' 'Retry-After: 120'; resp 429 x '{}' 'Retry-After: 120'; resp 429 x '{}' 'Retry-After: 120'
  ENVV=("${PS[@]}"); api 'post_status success "x"; echo "rc=$? flag=$CI_GATE_RATE_LIMITED"'; ENVV=()
  chk "Firing: Retry-After 120 twice fits the 300 s budget, a third does not" "$(tail -n 1 <<< "$OUT")/$(SLEEPS)" "rc=2 flag=1/120,120"
  reset; resp 200 OK '{"statuses":[]}'; resp 429 x '{}' 'Retry-After: 3'; resp 201 Created '{}'
  ENVV=("${PS[@]}"); api 'post_status success "x"; echo "rc=$? flag=$CI_GATE_RATE_LIMITED"'; ENVV=()
  chk "Silence: rate limited once, then written: rc 0, no flag" "$(tail -n 1 <<< "$OUT")/$(SLEEPS)" "rc=0 flag=0/3"

  reset
  resp 200 OK '{"items":[1,2]}' 'Etag: "p1"' 'Link: <https://api.github.com/repos/o/r/l?per_page=2&page=2>; rel="next"'
  resp 200 OK '{"items":[3,4]}' 'Etag: "p2"' 'Link: <https://api.github.com/repos/o/r/l?per_page=2&page=3>; rel="next", <https://api.github.com/repos/o/r/l?per_page=2&page=1>; rel="first"'
  resp 200 OK '{"items":[5]}' 'Etag: "p3"' 'Link: <https://api.github.com/repos/o/r/l?per_page=2&page=1>; rel="first"'
  api 'api_list "repos/o/r/l?per_page=2" .items'
  chk "three pages are walked by rel=next and joined in order" "$RC/$OUT" "0/[1,2,3,4,5]"
  chk "the pages asked for are 1, 2, 3" "$(grep -o 'page=[0-9]*$' "$Q/calls" | paste -sd,)" "page=1,page=2,page=3"

  reset
  resp 200 OK '{"items":[1]}' 'Link: <x?page=2>; rel="next"'; resp 200 OK '{"items":[2]}' 'Link: <x?page=3>; rel="next"'
  resp 200 OK '{"items":[3]}'
  ENVV=(API_MAX_PAGES=2); api 'api_list "repos/o/r/l?per_page=1" .items'; ENVV=()
  chk "more pages than the cap fails closed (no partial list)" "$RC/$(grep -c '^\[' <<< "$OUT")" "1/0"

  # a retried read must still hand its caller clean JSON: the notices go to stderr, never into the list
  reset; resp 429 x '{}' 'Retry-After: 3'; resp 200 OK '{"items":[1,2]}'
  api 'api_list "repos/o/r/l?per_page=2" .items 2> /dev/null | jq -c .; echo "rc=${PIPESTATUS[0]}"'
  chk "a retried api_list: stdout is the JSON list alone (notices are on stderr)" "$(paste -sd' ' <<< "$OUT")/$(SLEEPS)" "[1,2] rc=0/3"

  # a 304 may leave out Link: the page's own, cached with its body, keeps the walk going
  reset
  resp 200 OK '{"items":[1,2]}' 'Etag: "p1"' 'Link: <https://api.github.com/repos/o/r/l?per_page=2&page=2>; rel="next"'
  resp 200 OK '{"items":[3]}' 'Etag: "p2"'
  resp 304 'Not Modified' '' 'Etag: "p1"'
  resp 304 'Not Modified' '' 'Etag: "p2"'
  KEEP=1 api 'api_list "repos/o/r/l?per_page=2" .items 2> /dev/null | jq -c .; api_list "repos/o/r/l?per_page=2" .items 2> /dev/null | jq -c .'
  chk "a 304 without Link on page 1: both pages are still walked (no silent truncation)" "$(paste -sd' ' <<< "$OUT")/$(NCALLS)" "[1,2,3] [1,2,3]/4"


  # a 304 that carries Link replaces the cached one; only a 304 without Link keeps the cached value
  reset; resp 200 OK '{"a":1}' 'Etag: "e1"' 'Link: <x?page=2>; rel="next"'
  resp 304 'Not Modified' '' 'Etag: "e1"' 'Link: <x?page=1>; rel="first"'; resp 304 'Not Modified' '' 'Etag: "e1"'
  api 'api_request GET "repos/o/r/x"; api_request GET "repos/o/r/x"; api_request GET "repos/o/r/x"; echo "$API_LINK"'
  [[ $OUT == *'rel="first"'* && $OUT != *'rel="next"'* ]] && ok "a 304 with its own Link replaces the cached Link (the walk ends)" || bad "stale cached Link kept after a 304 with Link: $OUT"

  # gh exits non-zero on a 2xx (a truncated transfer): never cached, never trusted
  reset; resp 200 OK '{"a":1}' 'Etag: "e1"'; echo 1 > "$Q/1.rc"; resp 200 OK '{"a":2}' 'Etag: "e2"'
  api 'api_request GET "repos/o/r/x"; echo "rc1=$?"; api_request GET "repos/o/r/x"; echo "rc2=$?"'
  chk "a 2xx with a non-zero gh exit fails and is not cached (the next GET is not conditional)" "$(grep -o 'rc[12]=[0-9]' <<< "$OUT" | paste -sd' ')/$(grep -c 'If-None-Match' "$Q/calls")" "rc1=1 rc2=0/0"

  # cache writes: a failed write fails the call and leaves no ETag to pair with a half-written entry
  reset; resp 200 OK '{"a":1}' 'Etag: "e1"'; resp 200 OK '{"a":2}' 'Etag: "e2"'
  api 'api_request GET "repos/o/r/x"; k=$(printf "%s %s" GET repos/o/r/x | sha256sum | cut -c1-40); rm -f "$API_CACHE/$k.link"; mkdir "$API_CACHE/$k.link"
       api_request GET "repos/o/r/x"; echo "rc=$? etag=$([[ -e $API_CACHE/$k.etag ]] && echo present || echo absent)"'
  chk "a failed cache write fails the call and leaves no ETag behind" "$(tail -n 1 <<< "$OUT")" "rc=1 etag=absent"

  # a leading zero is decimal, not octal
  reset; resp 429 x '{}' 'Retry-After: 250'; resp 200 OK '{}'
  ENVV=(API_RETRY_BUDGET_SECONDS=0300); api "$GET1"; ENVV=()
  chk "API_RETRY_BUDGET_SECONDS=0300 is 300, not octal 192: a 250 s wait fits" "$RC/$(SLEEPS)" "0/250"

  # the status lookup's errors reach the log, and the write still goes ahead
  reset; resp 500 'Server Error' '{}'; echo 'gh: lookup failed (HTTP 500)' > "$Q/1.err"; resp 201 Created '{}'
  ENVV=("${PS[@]}"); api 'post_status success "x"; echo "rc=$?"'; ENVV=()
  grep -q 'lookup failed (HTTP 500)' <<< "$OUT" && [[ $(tail -n 1 <<< "$OUT") == rc=0 && $(NCALLS) == 2 ]] && ok "a failed status lookup is logged and the write still goes ahead" || bad "lookup error hidden or write skipped: $OUT"

  reset; resp 429 x '{}' 'Retry-After: 3'; resp 200 OK '{}'
  ENVV=(API_RETRY_LEDGER=/nonexistent-dir/ledger); api "$GET1"; ENVV=()
  chk "a retry ledger that cannot be written: fails closed (2) without sleeping" "$RC/$(SLEEPS)/$(NCALLS)" "2//1"
  grep -q 'rate limited, no verdict: the retry ledger' <<< "$OUT" && ok "the unwritable ledger is named in the error" || bad "no ledger error: $OUT"

  reset; resp 200 OK '{"items":"not a list"}'
  api 'api_list "repos/o/r/l?per_page=2" .items'
  chk "a page whose selection is not an array fails closed" "$RC" 1

  reset; resp 200 OK '{"message":"no items key at all"}'
  api 'api_list "repos/o/r/l?per_page=2" .items'
  chk "a page without the list (null) fails closed, never an empty list" "$RC/$OUT" "1/"

  reset; resp 200 OK 'not json'
  api 'api_list "repos/o/r/l?per_page=2" .items'
  chk "a page that is not JSON fails closed" "$RC" 1

  reset; resp 304 'Not Modified' '' 'Etag: "e9"'
  api "$GET1"; chk "a 304 with no cached body fails closed (never an empty success)" "$RC" 1

  reset; resp 200 OK '{"a":1}' 'Etag: "e1"'; resp 403 Forbidden '{"message":"Resource not accessible by integration"}'
  KEEP=1 api "$GET1 >/dev/null; $GET1"
  chk "a cached body never hides a later error" "$RC" 1

  reset; printf 'garbage, no status line\n' > "$Q/1.resp"; echo 1 > "$Q/1.rc"
  api "$GET1"; chk "output with no HTTP status line fails" "$RC/$(SLEEPS)" "1/"

  reset; printf 'HTTP/2.0 200 OK\r\nEtag: "b"\r\n\r\n{"t":"line one"}\n\n{"u":2}\n' > "$Q/1.resp"; echo 0 > "$Q/1.rc"
  api 'api_request GET "repos/o/r/x" && cat "$API_BODY"'
  chk "a blank line inside the body stays in the body" "$RC/$(wc -l <<< "$OUT")" "0/3"
}

if [[ ${1:-} == --cases ]]; then
  QUIET=1 cases; echo "$PASS $FAIL"; exit 0
fi
cases

echo "== mutants: one per guard; each must be caught by at least one case =="
mutant() { # <label> <python-literal old> <python-literal new>
  local m="$WORK/mutant.sh"
  if ! python3 -I -c 'import sys; s=open(sys.argv[1]).read(); o=sys.argv[2]; assert s.count(o)==1, "pattern not unique"; open(sys.argv[3],"w").write(s.replace(o, sys.argv[4]))' \
    "$ROOT/scripts/ci-gate-api.sh" "$2" "$m" "$3" 2> "$WORK/merr"; then
    bad "mutant '$1': could not apply ($(tail -n 1 "$WORK/merr"))"; return
  fi
  read -r p f < <(API_UNDER_TEST="$m" bash "$0" --cases | tail -n 1)
  ((f > 0)) && ok "mutant killed ($f cases fail): $1" || bad "mutant SURVIVED: $1"
}
mutant "429 is always a limit" '[[ $API_CODE == 429 ]] && return 0' 'true'
mutant "403 or 429 only" '[[ $API_CODE == 403 ]] || return 1' 'true'
mutant "remaining 0 signals a limit" '[[ $(api_header x-ratelimit-remaining) == 0 || -n' '[[ $(api_header x-ratelimit-remaining) == -1 || -n'
mutant "Retry-After signals a limit" '|| -n $(api_header retry-after) ]] && return 0' ']] && return 0'
mutant "a 'rate limit' body signals a limit" "grep -qiE 'rate limit'" "grep -qiE 'no such text here'"
mutant "Retry-After is the wait" 'then wait=$((10#$ra))' 'then wait=$((10#$ra + 1))'
mutant "the primary reset is the wait" 'wait=$((10#$reset - now + 1))' 'wait=60'
mutant "exponential back-off" 'else wait=$((60 << (attempt - 1))); fi' 'else wait=60; fi'
mutant "the no-header back-off starts at a minute" 'else wait=$((60 << (attempt - 1))); fi' 'else wait=$((5 << (attempt - 1))); fi'
mutant "the back-off cap" 'if ((attempt > 3)); then wait=240;' 'if false; then wait=240;'
mutant "the shift is clamped, never overflowed" 'if ((attempt > 3)); then wait=240; else wait=$((60 << (attempt - 1))); fi' 'wait=$((60 << (attempt - 1))); ((wait <= 240)) || wait=240'
# No mutant for the jitter: removing it leaves every wait inside the asserted ranges, so it is equivalent here.
mutant "the wait is at least 1 s" '((wait >= 1)) || wait=1' 'true'
mutant "the budget is enforced" 'if ((attempt >= API_MAX_ATTEMPTS || spent + wait > API_RETRY_BUDGET_SECONDS)); then' 'if ((attempt >= API_MAX_ATTEMPTS)); then'
mutant "the attempt cap is enforced" 'if ((attempt >= API_MAX_ATTEMPTS || spent + wait > API_RETRY_BUDGET_SECONDS)); then' 'if ((spent + wait > API_RETRY_BUDGET_SECONDS)); then'
mutant "a spent POST raises the flag" '((rc != 2)) || CI_GATE_RATE_LIMITED=1' 'true'
mutant "a standing status is not rewritten" 'if [[ $(status_matches "$1" "$2") == same ]]; then' 'if false; then'
mutant "retry notices stay off stdout" '(retry budget ${spent}/${API_RETRY_BUDGET_SECONDS}s)" >&2' '(retry budget ${spent}/${API_RETRY_BUDGET_SECONDS}s)"'
mutant "a 304 keeps the cached Link" 'else API_LINK=$(cat "$API_CACHE/$key.link" 2> /dev/null); fi' 'else :; fi'
mutant "a 304 with a Link replaces the cached one" 'if [[ -n $API_LINK ]]; then printf '"'%s\n'"' "$API_LINK" > "$API_CACHE/$key.link" || return 1' 'if [[ -n $API_LINK ]]; then :'
mutant "the Link is cached with the body" '&& printf '"'%s\n'"' "$API_LINK" > "$API_CACHE/$key.link" \' '\'
mutant "the ETag is removed before the entry is rewritten" 'rm -f "$API_CACHE/$key.etag"
' ''
mutant "the ETag is written last, and a failed write fails" '&& mv "$API_CACHE/$key.etag.new" "$API_CACHE/$key.etag" || return 1' '&& mv "$API_CACHE/$key.etag.new" "$API_CACHE/$key.etag" || true'
mutant "a failed gh exit on a 2xx is not trusted" 'if ((gh_rc != 0)); then cat "$raw.err" >&2; return 1; fi' 'true'
mutant "the budget is read as decimal" 'API_RETRY_BUDGET_SECONDS=$((10#$API_RETRY_BUDGET_SECONDS)); ' ''
mutant "the status lookup's errors are not hidden" "'.statuses' \\
    | jq" "'.statuses' 2> /dev/null \\
    | jq"
mutant "an unwritable ledger fails" 'echo $((spent + wait)) > "$API_RETRY_LEDGER" || {' 'echo $((spent + wait)) > "$API_RETRY_LEDGER" 2> /dev/null || true; [[ -n x ]] || {'
mutant "the ledger is written" 'echo $((spent + wait)) > "$API_RETRY_LEDGER"' 'true'
# No mutant for "only GET is conditional": a POST is never cached (no ETag is stored for it), so removing
# `$method == GET` from the condition is an equivalent mutant; the case above still pins the behaviour.
mutant "a 2xx GET body is cached" 'cp "$API_BODY_RAW" "$API_CACHE/$key.body" \' 'true \'
mutant "a 304 needs a cached body" '[[ $method == GET && -f $API_CACHE/$key.body ]] || return 1' 'touch "$API_CACHE/$key.body"'
mutant "rel=next drives the walk" '[[ $API_LINK == *'"'"'rel="next"'"'"'* ]] || break' 'break'
mutant "the page cap" '((page <= API_MAX_PAGES))' '((page <= 999))'
mutant "a page must be an array" 'jq -e "$sel | type == \"array\"" "$API_BODY" > /dev/null 2>&1 || { rm -f "$acc"; return 1; }' 'true'
mutant "config is validated" '&& $API_MAX_PAGES =~ ^[1-9][0-9]{0,5}$ ]]' ']]'
mutant "the attempt cap is validated" '&& $API_MAX_ATTEMPTS =~ ^[1-9][0-9]?$' '&& 1 == 1'
mutant "the body split keeps blank lines" 'if ($0 == "") { if (seen) done = 1; next }' 'if ($0 == "") next'

echo "ci-gate-api: $PASS passed, $FAIL failed"
((FAIL == 0))
