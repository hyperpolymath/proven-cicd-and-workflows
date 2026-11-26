#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Print the path of the proven-gate binary, building it from tools/proven-gate
# (locked, so the dependency set is exactly the committed Cargo.lock) if absent.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin="$here/tools/proven-gate/target/release/proven-gate"
if [[ ! -x $bin ]]; then
  cargo build --release --locked --quiet --manifest-path "$here/tools/proven-gate/Cargo.toml" >&2
fi
printf '%s\n' "$bin"
