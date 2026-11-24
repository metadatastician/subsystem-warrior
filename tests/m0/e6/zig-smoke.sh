#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# zig-smoke.sh — cross-compile E6's smoke executable for x86_64-windows.
#
# The smallest form of the owner's question: can Linux CI build a Windows
# executable with Zig that a Windows runner then runs? ZIG must point at a
# Zig whose download was checked against its sha256 pin (the workflow does
# this; see .github/workflows/m0-windows-probe.yml).
#
# Usage: ZIG=/path/to/zig zig-smoke.sh OUT_DIR
# Writes OUT_DIR/hello.exe and OUT_DIR/zig.json (I-JSON/JCS).
# Exit: 0 = built; 1 = build failed; 2 = setup error.
set -euo pipefail

out="${1:-}"
[ -n "$out" ] || { echo "zig-smoke: usage: ZIG=... zig-smoke.sh OUT_DIR" >&2; exit 2; }
zig="${ZIG:-}"
if [ -z "$zig" ] || [ ! -x "$zig" ]; then
  echo "zig-smoke: ZIG must name an executable zig" >&2
  exit 2
fi
command -v node >/dev/null || { echo "zig-smoke: missing tool: node" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
( cd "$work" && "$zig" build-exe "$here/zig-smoke/hello.zig" \
    -target x86_64-windows -O ReleaseSmall -femit-bin="$work/hello.exe" ) || exit 1
cp "$work/hello.exe" "$out/hello.exe"
exe_sha="$(sha256sum "$out/hello.exe" | cut -d' ' -f1)"
zig_v="$("$zig" version)"

ZIG_V="$zig_v" EXE_SHA="$exe_sha" node -e '
  const e = process.env;
  process.stdout.write(JSON.stringify({
    zig_version: e.ZIG_V,
    target: "x86_64-windows",
    file: "hello.exe",
    sha256: e.EXE_SHA,
    expected_output: "subsystem-warrior e6 zig smoke"
  }));' | node "$repo/scripts/ijson-jcs-cli.js" canon > "$out/zig.json"

echo "zig-smoke: built hello.exe with zig $zig_v, sha256 $exe_sha"
