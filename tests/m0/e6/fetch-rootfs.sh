#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# fetch-rootfs.sh — the tiny rootfs E6 imports into WSL, pinned by sha256.
#
# Ubuntu Base 24.04.5 (amd64) carries e2fsck (e2fsprogs 1.47.0) and lsblk
# (util-linux), which E6's mount and e2fsck steps need, with no package
# install inside WSL. The pin below is Ubuntu's published SHA256SUMS entry,
# checked here on 2026-11-17 against a download (30028293 bytes).
#
# The archive is gunzipped to a plain .tar, so the Windows job never depends
# on whether `wsl --import` accepts gzip. Network use in CI is outside W5,
# which binds the tool, not its test harness.
#
# Usage: fetch-rootfs.sh OUT_DIR
# Writes OUT_DIR/rootfs.tar and OUT_DIR/rootfs.json (I-JSON/JCS).
# Exit: 0 = fetched and verified; 1 = pin mismatch; 2 = setup error.
set -euo pipefail

out="${1:-}"
[ -n "$out" ] || { echo "fetch-rootfs: usage: fetch-rootfs.sh OUT_DIR" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
for t in curl sha256sum gzip node; do
  command -v "$t" >/dev/null || { echo "fetch-rootfs: missing tool: $t" >&2; exit 2; }
done

url="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz"
pin="e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86"

mkdir -p "$out"
gz="$out/rootfs.tar.gz"
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location \
  --max-time 600 "$url" --output "$gz"
got="$(sha256sum "$gz" | cut -d' ' -f1)"
if [ "$got" != "$pin" ]; then
  echo "fetch-rootfs: sha256 $got does not match the pin $pin" >&2
  exit 1
fi
gzip -dc "$gz" > "$out/rootfs.tar"
rm -f "$gz"
tar_sha="$(sha256sum "$out/rootfs.tar" | cut -d' ' -f1)"

URL="$url" PIN="$pin" TAR_SHA="$tar_sha" node -e '
  const e = process.env;
  process.stdout.write(JSON.stringify({
    source_url: e.URL,
    source_sha256_pin: e.PIN,
    source_sha256_matched: true,
    file: "rootfs.tar",
    sha256: e.TAR_SHA
  }));' | node "$repo/scripts/ijson-jcs-cli.js" canon > "$out/rootfs.json"

echo "fetch-rootfs: verified $url, rootfs.tar sha256 $tar_sha"
