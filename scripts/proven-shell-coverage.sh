#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# proven-shell-coverage.sh run TRACE CMD [ARG...]
# proven-shell-coverage.sh lcov ROOT TRACE FILE...
#
# Bash line coverage without kcov.
#   run   runs CMD with BASH_ENV pointing at a hook that turns on xtrace in every
#         bash process it starts, appending to TRACE through fd 197. Normal
#         stderr is untouched. CMD's exit status is passed through.
#   lcov  writes an LCOV report (DA lines only) for FILE... (paths relative to
#         ROOT) from TRACE, for proven-coverage-gate.sh.
#
# Limits, stated so nobody mistakes this for kcov:
#   - The unit is a statement, not a line. Lines joined by an open quote, an
#     open $( or ( , a trailing \ | && || or a here-document form one statement;
#     it is hit when bash reports any of its lines (bash reports a multi-line
#     command at one of them, not always the first). DA uses its first line.
#   - Structure-only lines (then, else, do, done, fi, esac, braces, a function
#     header, a bare case pattern) are not statements: xtrace never reports them.
#   - A process started with env -i, by sh, or by bash -c loses the hook and
#     reports nothing; its lines show as uncovered, never as falsely covered.
#   - Trace paths are matched to FILE by suffix, so an unmodified copy of a
#     script run from a temporary directory counts for the original. A test
#     that runs a modified copy (sed on the script) must use a different file
#     name, or its hits are credited to the original.
set -euo pipefail
usage() { echo "usage: proven-shell-coverage.sh run TRACE CMD... | lcov ROOT TRACE FILE..." >&2; exit 2; }
(($# >= 3)) || usage
mode=$1; shift
case $mode in
  run)
    trace=$(realpath -m -- "$1"); shift
    hook=$(mktemp)
    trap 'rm -f -- "$hook"' EXIT
    cat >"$hook" <<'HOOK'
if [ -n "${PROVEN_SHELL_TRACE:-}" ]; then
  exec 197>>"$PROVEN_SHELL_TRACE"
  BASH_XTRACEFD=197
  PS4='+\x1e${BASH_SOURCE[0]:-?}\x1e${LINENO}\x1e '
  set -x
fi
HOOK
    rc=0
    PROVEN_SHELL_TRACE=$trace BASH_ENV=$hook "$@" || rc=$?
    exit "$rc"
    ;;
  lcov)
    root=$1 trace=$2; shift 2
    [[ -d $root && -f $trace ]] || usage
    for file in "$@"; do
      [[ -f $root/$file ]] || { echo "proven-shell-coverage: no file $file" >&2; exit 2; }
      printf 'FILE\t%s\n' "$file"
      cat -- "$root/$file"
    done | awk -v trace="$trace" '
      BEGIN {
        # hit[path suffix, line]: every (source, line) bash reported.
        while ((getline row < trace) > 0) {
          n = split(row, f, /\\x1e/)
          if (n < 4) continue
          src = f[2]; sub(/^(\.\/)+/, "", src)
          if (!(src in seen)) { seen[src] = 1; srcs[++nsrc] = src }
          hit[src, f[3]] = 1
        }
      }
      function flush(   i, first, any) {
        if (file == "") return
        print "SF:" file
        for (g = 1; g <= ngroups; g++) {
          first = 0; any = 0
          for (i = gstart[g]; i <= gend[g]; i++) {
            if (exec[i] && !first) first = i
            for (s = 1; s <= nmatch; s++) if ((match_src[s], i) in hit) any = 1
          }
          if (first) { print "DA:" first "," any; total++; covered += any }
        }
        print "LF:" total; print "LH:" covered; print "end_of_record"
      }
      function structural(t) {
        if (t ~ /^(then|else|do|done|fi|esac|in|\{|\}|\(|\)|;;|;&|;;&)$/) return 1
        if (t ~ /^(done|fi|esac|\}|\))( *[;&<>].*)?$/) return 1
        if (t ~ /^(function +)?[A-Za-z_][A-Za-z0-9_:.-]* *\( *\) *\{?$/) return 1
        if (t ~ /^function +[A-Za-z_][A-Za-z0-9_:.-]* *\{?$/) return 1
        if (t ~ /^\(?[^ ()=]*[^ ()=\\]\)( *;;)?$/) return 1
        return 0
      }
      /^FILE\t/ {
        flush()
        file = substr($0, 6); lineno = 0; ngroups = 0; total = 0; covered = 0
        open = 0; sp = 0; heredoc = ""; cont = 0
        delete exec
        nmatch = 0
        for (s = 1; s <= nsrc; s++) {
          if (srcs[s] == file || substr(srcs[s], length(srcs[s]) - length(file)) == "/" file)
            match_src[++nmatch] = srcs[s]
        }
        next
      }
      {
        lineno++
        line = $0
        if (heredoc != "") {
          t = line; if (heredoc_strip) sub(/^\t+/, "", t)
          if (t == heredoc) heredoc = ""
          gend[ngroups] = lineno
          next
        }
        # Scan characters with a context stack: " (double quote), \x27 (single
        # quote), ( (command substitution or subshell), { (parameter expansion).
        code = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1); top = sp ? stack[sp] : ""
          if (top == "\x27") { if (c == "\x27") sp--; code = code c; continue }
          if (c == "\\") { code = code substr(line, i, 2); i++; continue }
          two = substr(line, i, 2)
          if (two == "$(" || two == "${") { stack[++sp] = substr(two, 2); code = code two; i++; continue }
          if (top == "\"") { if (c == "\"") sp--; code = code c; continue }
          if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;(]/)) break
          if (c == "\x27" || c == "\"" || c == "(") stack[++sp] = c
          else if (c == ")" && top == "(") sp--
          else if (c == "}" && top == "{") sp--
          code = code c
        }
        t = code; gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (!open) { ngroups++; gstart[ngroups] = lineno }
        gend[ngroups] = lineno
        if (t != "" && !(lineno == 1 && line ~ /^#!/) && !structural(t)) exec[lineno] = 1
        if (match(code, /<<-?[ \t]*[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?/) && substr(code, RSTART, 3) != "<<<") {
          heredoc = substr(code, RSTART, RLENGTH)
          heredoc_strip = (heredoc ~ /^<<-/)
          sub(/^<<-?[ \t]*/, "", heredoc); gsub(/[\x27"]/, "", heredoc)
        }
        cont = (t ~ /(\\|\||&&|\|\|)$/)
        open = (sp > 0 || cont)
        if (heredoc != "") open = 0
      }
      END { flush() }
    '
    ;;
  *) usage ;;
esac
