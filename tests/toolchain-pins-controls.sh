#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls: toolchain-pins.sh must fail on each mutant of a good copy.
# Mutation targets come from the copied pin file, so a routine pin bump needs no edit here.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
tpl=$t/r/templates/proven-coverage-collect.yml pins=$t/r/proven/pins/toolchain.tsv
mk() { rm -rf "$t/r"; mkdir -p "$t/r/proven/pins" "$t/r/templates"; cp "$here/proven/pins/toolchain.tsv" "$pins"; cp "$here"/templates/*.yml "$t/r/templates/"; }
pin() { local tool=$1; awk -F'\t' -v k="$tool" '$1 == k { print $2 }' "$here/proven/pins/toolchain.tsv"; }
otp=$(pin otp) yq_v=$(pin yq)
[[ -n $otp && -n $yq_v ]] || { echo "cannot read pins"; exit 2; }
# A mutation value that cannot equal the real pin, whatever the pin becomes.
other=9.9.9; [[ $otp == "$other" ]] && other=9.9.8
fails=0
expect_fail() { local what=$1; bash "$here/tests/toolchain-pins.sh" "$t/r" >/dev/null 2>&1 && { echo "MUTANT SURVIVED: $what"; fails=1; } || echo "ok: $what rejected"; }
expect_pass() { local what=$1; bash "$here/tests/toolchain-pins.sh" "$t/r" >/dev/null 2>&1 && echo "ok: $what accepted" || { echo "WRONGLY REJECTED: $what"; fails=1; }; }
mk; expect_pass "good copy"
mk; sed -i "s/\"$otp\"/\"$other\"/" "$tpl"; expect_fail "template drifted from the OTP pin"
mk; sed -i "s/\"$otp\"/'$otp'/" "$tpl"; expect_pass "single-quoted equal value"
mk; sed -i "s/\"$otp\"/\"${otp%.*}. ${otp##*.}\"/" "$tpl"; expect_fail "internal space in the value"
mk; sed -i "s/PROVEN_COV_OTP_VERSION: \"$otp\"/'PROVEN_COV_OTP_VERSION': \"$other\"/" "$tpl"; expect_fail "quoted-key drift"
mk; sed -i "s/\"$otp\"/\"$otp\\\\n\"/" "$tpl"; expect_fail "trailing newline in the value"
mk; sed -i "s/^otp\t$otp/otp\t$other/" "$pins"; expect_fail "pin moved, template not"
mk; sed -i '/^bun\t/d' "$pins"; expect_fail "required tool removed"
mk; sed -i "s/^yq\t$yq_v/yq\tlatest/" "$pins"; expect_fail "inexact version"
mk; printf 'nickel\t1.18.0\t-\tdup\tx\n' >> "$pins"; expect_fail "duplicate tool"
mk; sed -i 's/^\(otp\t[^\t]*\t\)[^\t]*/\1/' "$pins"; expect_fail "empty env_var field"
mk; rm "$tpl"; expect_fail "no template sets the pinned var"
mk; printf 'foo\tlatest\t-\tsrc\tnote' >> "$pins"; expect_fail "unterminated final row with an inexact version is still checked"
exit $fails
