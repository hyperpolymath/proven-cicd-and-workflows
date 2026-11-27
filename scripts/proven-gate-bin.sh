#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Print the path of the proven-gate binary. It always runs the locked build (so the dependency set is
# exactly the committed Cargo.lock and a stale binary can never stand in for changed source; cargo
# reuses unchanged output) into a fixed target dir that no caller .cargo/config.toml can redirect.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target="$here/tools/proven-gate/target"
cargo build --release --locked --quiet --target-dir "$target" --manifest-path "$here/tools/proven-gate/Cargo.toml" >&2
printf '%s\n' "$target/release/proven-gate"
