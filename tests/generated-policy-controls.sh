#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls: generated-policy.sh must fail on each mutant of a good copy, and on each
# disagreement with a fixture standing in for Hypatia's rule file.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pol=$t/r/proven/policy/generated.tsv map=$t/r/proven/registry/sq-map.tsv pins=$t/r/proven/pins/toolchain.tsv
mk() { rm -rf "$t/r"; mkdir -p "$t/r/proven/policy" "$t/r/proven/registry" "$t/r/proven/pins"
    cp "$here/proven/policy/generated.tsv" "$pol"; cp "$here/proven/registry/sq-map.tsv" "$map"; cp "$here/proven/pins/toolchain.tsv" "$pins"; }
fails=0
expect_fail() { local what=$1; bash "$here/tests/generated-policy.sh" "$t/r" >/dev/null 2>&1 && { echo "MUTANT SURVIVED: $what"; fails=1; } || echo "ok: $what rejected"; }
mk; bash "$here/tests/generated-policy.sh" "$t/r" >/dev/null 2>&1 && echo "ok: good copy accepted" || { echo "good copy rejected"; fails=1; }
mk; sed -i 's/^\(hypatia\/ci_failure_triage\/repository_map_stale\tSQ-GEN-01\tgenerator\t\)[^\t]*/\1-/' "$pol"; expect_fail "generator rule names no generator"
mk; sed -i 's/^\(hypatia\/ci_failure_triage\/repository_map_stale\tSQ-GEN-01\tgenerator\t\)[^\t]*/\1bash $LOG_COMMAND/' "$pol"; expect_fail "generator read from a log"
mk; sed -i 's/\(kyaml_format\tSQ-GEN-04\tgenerator\t[^\t]*\t\)yq/\1jq/' "$pol"; expect_fail "tool is not pinned"
mk; sed -i 's/\(kyaml_format\tSQ-GEN-04\tgenerator\t[^\t]*\t[^\t]*\t\)owner/\1fixer/' "$pol"; expect_fail "escalation is not the owner"
mk; sed -i 's/\(repository_map_stale\tSQ-GEN-01\t\)generator/\1fixer/' "$pol"; expect_fail "unknown kind"
mk; sed -i 's/\(repository_map_stale\t\)SQ-GEN-01/\1SQ-GEN-04/' "$pol"; expect_fail "sq id disagrees with the map"
mk; sed -i 's/\(repository_map_stale\tSQ-GEN-01\t\)generator/\1referral/' "$pol"; expect_fail "a generator row downgraded to a referral"
mk; sed -i '/repository_map_stale/d' "$pol"; expect_fail "a mapped SQ-GEN rule has no policy row"
mk; sed -i '/generated_file_stale/d' "$pol"; expect_fail "the referral row is missing"
mk; sed -i 's/\(generated_file_stale\thypatia-only\treferral\t\)-/\1scripts\/gen.sh/' "$pol"; expect_fail "a referral row names a generator"
mk; printf 'hypatia/ci_failure_triage/not_a_rule\tSQ-GEN-01\tgenerator\tx\t-\towner\tx\n' >> "$pol"; expect_fail "policy row not in the map"
mk; tail -n 1 "$pol" >> "$pol"; expect_fail "duplicate row"
mk; sed -i 's/^\(hypatia\/ci_failure_triage\/repository_map_stale\tSQ-GEN-01\tgenerator\t[^\t]*\t[^\t]*\towner\t\).*/\1/' "$pol"; expect_fail "empty source field"
mk; printf 'hypatia/ci_failure_triage/not_a_rule\tSQ-GEN-01\tbogus\tx\t-\towner\tx' >> "$pol"; expect_fail "final row with no trailing newline is still checked"
mk; sed -i '/^yq\t/d' "$pins"; expect_fail "the pin file lost yq"
mk; sed -i 's/\(always_after_cancel\tSQ-GEN-03\t\)static/\1generator/' "$pol"; bash "$here/tests/generated-policy.sh" "$t/r" >/dev/null 2>&1 && echo "ok: static and generator are both accepted" || { echo "FAILED: static as generator"; fails=1; }

# Agreement with Hypatia's rule file, read as the retry check reads it. The fixture has the same
# shape: name, action, escalation, fix per rule.
mkrules() { # name|action|fix|escalation ...   (fix "nil" for none)
    : > "$t/h.ex"; local r n a f e
    for r in "$@"; do IFS='|' read -r n a f e <<<"$r"
        printf '    %%{\n      name: "%s",\n      action: :%s,\n      retries: 0,\n' "$n" "$a" >> "$t/h.ex"
        if [[ $f == nil ]]; then printf '      fix: nil,\n' >> "$t/h.ex"; else printf '      fix: "%s",\n' "$f" >> "$t/h.ex"; fi
        printf '      escalation: :%s,\n    },\n' "$e" >> "$t/h.ex"
    done; }
good=('repository_map_stale|fix|bash scripts/gen-repo-map.sh . && commit (SQ-GEN-01)|owner'
      'kyaml_format|fix|scripts/kyaml-format.sh <file> with Go yq (mikefarah), then commit|owner'
      'always_after_cancel|fix|always-to-not-cancelled|owner'
      'generated_file_stale|report|nil|owner')
hyp() { local what=$1 want=$2 rc=0; HYPATIA_RULES=$t/h.ex bash "$here/tests/generated-policy.sh" "$t/r" >/dev/null 2>&1 || rc=$?
    [[ $rc -eq $want ]] && echo "ok: $what" || { echo "FAILED: $what (rc=$rc, want $want)"; fails=1; }; }
mk; mkrules "${good[@]}"; hyp "agreeing Hypatia rules accepted" 0
mk; mkrules "${good[@]/bash scripts\/gen-repo-map.sh \. \&\& commit (SQ-GEN-01)/bash scripts\/other.sh}"; hyp "Hypatia's fix text differs" 1
mk; mkrules 'repository_map_stale|report|nil|owner' "${good[@]:1}"; hyp "Hypatia refers where the table has a generator" 1
mk; mkrules 'repository_map_stale|fix|bash scripts/gen-repo-map.sh . && commit (SQ-GEN-01)|fixer' "${good[@]:1}"; hyp "Hypatia escalation differs" 1
mk; mkrules "${good[@]:1}"; hyp "a rule is missing from the Hypatia file" 1
mk; mkrules "${good[@]:0:3}" 'generated_file_stale|fix|bash x.sh|owner'; hyp "Hypatia fixes where the table refers" 1
mk; HYPATIA_RULES=$t/none.ex bash "$here/tests/generated-policy.sh" "$t/r" >/dev/null 2>&1; [[ $? -eq 2 ]] && echo "ok: a missing Hypatia file is NOT RUN" || { echo "FAILED: missing Hypatia file"; fails=1; }
exit $fails
