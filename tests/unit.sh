#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# unit category for this repository: run every test listed in tests/unit.list.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0 n=0
while IFS= read -r t; do
  [[ -z $t || $t == \#* ]] && continue
  n=$((n+1))
  [[ -f tests/$t.sh ]] || { echo "unit: tests/$t.sh is listed but missing"; fail=1; continue; }
  echo "=== $t"; bash "tests/$t.sh" || { echo "unit: $t FAILED"; fail=1; }
done < tests/unit.list
(( n > 0 )) || { echo "unit: tests/unit.list lists no tests"; exit 1; }
echo "unit: $n tests run"; exit "$fail"
