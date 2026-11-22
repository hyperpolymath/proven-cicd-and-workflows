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
#   - A here-document opens only at an unquoted, unescaped << outside
#     arithmetic; a here-string (<<<) and a shift (1<<n) do not open one. Its
#     delimiter is the whole word after quote removal ('EOF-JSON' is EOF-JSON).
#     Several here-documents on one line (cat <<A <<B) are read in order.
#   - Structure-only lines (then, else, do, done, fi, esac, braces, a function
#     header, a bare case pattern such as x | y)) are not statements: xtrace
#     never reports them. A terminator with only redirections after it
#     (done <<< "$x") is structure; one followed by a command (fi; echo x) is not.
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
      # A file without a final newline would glue the next FILE marker to its last line.
      [[ ! -s $root/$file || -z $(tail -c 1 -- "$root/$file") ]] || echo
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
      # heredoc_word(S, J): the shell word at S[J], quotes and backslashes
      # removed; empty when there is none.
      function heredoc_word(s, j,   w, ch, q) {
        w = ""
        while (j <= length(s)) {
          ch = substr(s, j, 1)
          if (ch ~ /[ \t;&|<>()]/) break
          if (ch == "\x27" || ch == "\"") {
            q = index(substr(s, j + 1), ch)
            if (!q) { w = w substr(s, j + 1); break }
            w = w substr(s, j + 1, q - 1); j += q + 1; continue
          }
          if (ch == "\\") { w = w substr(s, j + 1, 1); j += 2; continue }
          w = w ch; j++
        }
        return w
      }
      function structural(t,   r) {
        if (t ~ /^(then|else|do|done|fi|esac|in|\{|\}|\(|\)|;;|;&|;;&)$/) return 1
        # A terminator followed only by redirections and an optional ; or &,
        # with spaces or tabs between tokens
        # (fi; echo x keeps echo x). Quotes, $(...), <(...) and >(...) are
        # folded first, so done <<< "$(cmd | f)" is still a terminator.
        r = t; gsub(/\x27[^\x27]*\x27|"[^"]*"/, "Q", r)
        while (gsub(/[$<>]\([^()]*\)/, "P", r)) ;
        if (r ~ /^(done|fi|esac|\}|\))([ \t]*[0-9]*(<<<|<<?|>>?|<>|<&|>&|&>>?)[ \t]*[^ \t;&|<>]+)*([ \t]*(;|;;|;&|;;&|&))?[ \t]*$/) return 1
        if (t ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\([ \t]*\)[ \t]*\{?$/) return 1
        if (t ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\{?$/) return 1
        # A case pattern list, blanks (spaces or tabs) allowed around | (x | y)),
        # only where a pattern may start (after case ... in or ;;), so a
        # subshell such as (echo) stays a statement.
        if (pat && t ~ /^\(?[ \t]*[^ \t()=|]*[^ \t()=|\\]([ \t]*\|[ \t]*[^ \t()=|]*[^ \t()=|\\])*[ \t]*\)([ \t]*;;)?$/) return 1
        return 0
      }
      /^FILE\t/ {
        flush()
        file = substr($0, 6); lineno = 0; ngroups = 0; total = 0; covered = 0
        open = 0; sp = 0; nh = 0; hc = 0; cont = 0; ncase = 0; pat = 0
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
        # Pending here-documents (hq[hc..nh]) are read in order; shell
        # scanning resumes after the last one ends.
        if (hc <= nh && nh > 0) {
          t = line; if (hstrip[hc]) sub(/^\t+/, "", t)
          if (t == hq[hc]) { hc++; if (hc > nh) nh = 0 }
          gend[ngroups] = lineno
          next
        }
        # Scan characters with a context stack: " (double quote), \x27 (single
        # quote), ( (command substitution or subshell), { (parameter expansion),
        # a (arithmetic, $(( or (( up to its )) ), A (a parenthesis inside
        # arithmetic). plain has one flag per character of code: 1 where the
        # character is shell syntax (not inside quotes, ${ } or arithmetic), so
        # only a plain << can open a here-document.
        code = ""; plain = ""
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1); top = sp ? stack[sp] : ""
          pf = (top == "" || top == "(") ? "1" : "0"
          if (top == "\x27") { if (c == "\x27") sp--; code = code c; plain = plain pf; continue }
          if (c == "\\") { code = code substr(line, i, 2); plain = plain pf "0"; i++; continue }
          two = substr(line, i, 2)
          if (substr(line, i, 3) == "$((") { stack[++sp] = "a"; code = code "$(("; plain = plain pf pf pf; i += 2; continue }
          if (two == "$(" || two == "${") { stack[++sp] = substr(two, 2); code = code two; plain = plain pf pf; i++; continue }
          if (top == "\"") { if (c == "\"") sp--; code = code c; plain = plain pf; continue }
          if (top == "a" && two == "))") { sp--; code = code two; plain = plain "00"; i++; continue }
          if (top != "a" && top != "A" && two == "((") { stack[++sp] = "a"; code = code two; plain = plain pf pf; i++; continue }
          if (top != "a" && top != "A" && c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t;(]/)) break
          if (c == "(" && (top == "a" || top == "A")) stack[++sp] = "A"
          else if (c == "\x27" || c == "\"" || c == "(") stack[++sp] = c
          else if (c == ")" && (top == "(" || top == "A")) sp--
          else if (c == "}" && top == "{") sp--
          code = code c; plain = plain pf
        }
        t = code; gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (!open) { ngroups++; gstart[ngroups] = lineno }
        gend[ngroups] = lineno
        if (t != "" && !(lineno == 1 && line ~ /^#!/) && !structural(t)) exec[lineno] = 1
        # Case context: a pattern may start after case ... in or after ;;, ;&
        # or ;;&, until esac closes the innermost case.
        if (t != "") {
          if (ncase && t ~ /^esac([ \t;&|<>].*)?$/) ncase--
          if (t ~ /^case[ \t].*[ \t]in$/) { ncase++; pat = 1 }
          else pat = (ncase && t ~ /(;;|;&|;;&)$/)
        }
        # A here-document opens at a plain << that no < precedes (<<< is a
        # here-string), that is not escaped and not inside quotes or
        # arithmetic (1<<n). Its delimiter is the whole following word after
        # quote removal, punctuation included (<<\x27EOF-JSON\x27 is EOF-JSON).
        for (at = 1; at < length(code); at++) {
          if (substr(code, at, 2) != "<<" || substr(plain, at, 1) != "1") continue
          if (at > 1 && substr(code, at - 1, 1) == "<") continue
          if (substr(code, at + 2, 1) == "<") { at += 2; continue }
          j = at + 2; strip = 0
          if (substr(code, j, 1) == "-") { strip = 1; j++ }
          while (substr(code, j, 1) ~ /[ \t]/) j++
          word = heredoc_word(code, j)
          if (word == "") continue
          if (!nh) hc = 1
          hq[++nh] = word; hstrip[nh] = strip
          at = j
        }
        cont = (t ~ /(\\|\||&&|\|\|)$/)
        open = (sp > 0 || cont)
        if (nh) open = 0
      }
      END { flush() }
    '
    ;;
  *) usage ;;
esac
