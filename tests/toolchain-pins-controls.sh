#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Negative controls: toolchain-pins.sh must fail on each mutant of a good copy.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mk() { rm -rf "$t/r"; mkdir -p "$t/r/proven/pins" "$t/r/templates"; cp "$here/proven/pins/toolchain.tsv" "$t/r/proven/pins/"; cp "$here"/templates/*.yml "$t/r/templates/"; }
fails=0
expect_fail() { bash "$here/tests/toolchain-pins.sh" "$t/r" >/dev/null 2>&1 && { echo "MUTANT SURVIVED: $1"; fails=1; } || echo "ok: $1 rejected"; }
mk; bash "$here/tests/toolchain-pins.sh" "$t/r" >/dev/null 2>&1 || { echo "good copy fails"; fails=1; }
mk; sed -i 's/27\.3\.4\.19/28.0.1/' "$t/r/templates/proven-coverage-collect.yml"; expect_fail "template drifted from the OTP pin"
mk; sed -i 's/^otp\t27\.3\.4\.19/otp\t28.0.1/' "$t/r/proven/pins/toolchain.tsv"; expect_fail "pin moved, template not"
mk; sed -i '/^bun\t/d' "$t/r/proven/pins/toolchain.tsv"; expect_fail "required tool removed"
mk; sed -i 's/^yq\tv4\.53\.3/yq\tlatest/' "$t/r/proven/pins/toolchain.tsv"; expect_fail "inexact version"
mk; printf 'nickel\t1.18.0\t-\tdup\tx\n' >> "$t/r/proven/pins/toolchain.tsv"; expect_fail "duplicate tool"
exit $fails
