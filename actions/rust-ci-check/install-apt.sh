#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# install-apt.sh — install the system packages a Rust crate's build needs
# (capnp, protobuf-compiler, ...) before any cargo step runs.
#
# Input: APT_PACKAGES, a whitespace-separated list of Debian package names.
# Empty means nothing to do. Names are validated against the Debian package
# name grammar so a caller-supplied string can never smuggle an apt option or
# a shell metacharacter (a leading '-' would be read as an option).
set -euo pipefail

packages="${APT_PACKAGES:-}"
[[ -n "${packages//[[:space:]]/}" ]] || { echo "apt_packages empty; nothing to install"; exit 0; }

list=()
for pkg in $packages; do
  [[ "$pkg" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] \
    || { echo "::error::apt_packages: '$pkg' is not a valid Debian package name"; exit 2; }
  list+=("$pkg")
done

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends "${list[@]}"
