#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# one-off-fixture.sh — E6's stand-in for E1's X-CLEAN fixture.
#
# E1-L has not landed, so E6 makes its own small clean ext4-in-VHDX image
# (card E6, "Method"). A producer's hash only proves the file was not changed
# in transit, so this script also proves the image is X-CLEAN, on the image
# that ships, before it emits anything:
#
#   * `qemu-img check` is clean on the final VHDX;
#   * `e2fsck -fn` is clean on a raw image extracted FROM that final VHDX;
#   * the virtual size and filesystem UUID are read back from the extracted
#     raw image, and must equal the values this script set.
#
# The filesystem UUID and hash seed are ADR-008 profile C ids in the domain
# `subsystem-warrior-fixture`, which is not registered yet
# (docs/plan/UPSTREAM-DRAFTS.adoc, U11).
#
# Usage: one-off-fixture.sh OUT_DIR
# Writes OUT_DIR/X-CLEAN.vhdx and OUT_DIR/fixture.json (I-JSON/JCS).
# Exit: 0 = built and proven X-CLEAN; 1 = a check failed; 2 = setup error.
set -euo pipefail

out="${1:-}"
[ -n "$out" ] || { echo "one-off-fixture: usage: one-off-fixture.sh OUT_DIR" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"

for t in mke2fs e2fsck qemu-img sha256sum blkid node; do
  command -v "$t" >/dev/null || { echo "one-off-fixture: missing tool: $t" >&2; exit 2; }
done

domain="subsystem-warrior-fixture"
fixture_id="X-CLEAN"
size_bytes=$((64 * 1024 * 1024))
fake_time=1767225600 # 2026-01-01T00:00:00Z, fixed so the image is reproducible

# ADR-008 profile C: bytes 0..15 of SHA-256(domain ":" name), with the version
# nibble set to 8 and the variant bits to 10.
profile_c() {
  local h
  h="$(printf '%s:%s' "$domain" "$1" | sha256sum | cut -c1-32)"
  local b6=$(( (0x${h:12:2} & 0x0f) | 0x80 ))
  local b8=$(( (0x${h:16:2} & 0x3f) | 0x80 ))
  h="${h:0:12}$(printf '%02x' "$b6")${h:14:2}$(printf '%02x' "$b8")${h:18:14}"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

fs_uuid="$(profile_c "$fixture_id")"
hash_seed="$(profile_c "$fixture_id/hash_seed")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out" "$work/payload/etc"
printf '[automount]\nenabled = true\n' > "$work/payload/etc/wsl.conf"
find "$work/payload" -exec touch -h -d "@$fake_time" {} +

raw="$work/src.raw"
vhdx="$out/$fixture_id.vhdx"
truncate -s "$size_bytes" "$raw"
E2FSPROGS_FAKE_TIME="$fake_time" mke2fs -q -F -t ext4 -L XCLEAN \
  -U "$fs_uuid" -E "hash_seed=$hash_seed,root_owner=0:0" \
  -d "$work/payload" "$raw"

rm -f "$vhdx"
qemu-img convert -q -f raw -O vhdx -o subformat=dynamic,block_size=1M "$raw" "$vhdx"

fail=0
check_out="$(qemu-img check -f vhdx "$vhdx" 2>&1)" && check_rc=0 || check_rc=$?
case "$check_out" in *"No errors were found"*) check_clean=true ;; *) check_clean=false ;; esac
if [ "$check_rc" -ne 0 ] || [ "$check_clean" != true ]; then
  echo "one-off-fixture: qemu-img check not clean (rc $check_rc): $check_out" >&2
  fail=1
fi

extracted="$work/extracted.raw"
qemu-img convert -q -f vhdx -O raw "$vhdx" "$extracted"
fsck_out="$(E2FSCK_TIME="$fake_time" e2fsck -fn "$extracted" 2>&1)" && fsck_rc=0 || fsck_rc=$?
if [ "$fsck_rc" -ne 0 ]; then
  echo "one-off-fixture: e2fsck -fn on the extracted raw image: rc $fsck_rc" >&2
  echo "$fsck_out" >&2
  fail=1
fi

virtual_size="$(qemu-img info --output=json -f vhdx "$vhdx" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    process.stdout.write(String(JSON.parse(s)["virtual-size"]));
  });')"
read_uuid="$(blkid -p -o value -s UUID "$extracted")"
if [ "$virtual_size" != "$size_bytes" ]; then
  echo "one-off-fixture: virtual size $virtual_size, expected $size_bytes" >&2
  fail=1
fi
if [ "$read_uuid" != "$fs_uuid" ]; then
  echo "one-off-fixture: filesystem UUID $read_uuid, expected $fs_uuid" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1

vhdx_sha="$(sha256sum "$vhdx" | cut -d' ' -f1)"
raw_sha="$(sha256sum "$extracted" | cut -d' ' -f1)"
mke2fs_v="$(mke2fs -V 2>&1 | head -1)"
qemu_v="$(qemu-img --version | head -1)"

FIXTURE_ID="$fixture_id" VHDX_SHA="$vhdx_sha" RAW_SHA="$raw_sha" \
VSIZE="$virtual_size" FS_UUID="$fs_uuid" CHECK_RC="$check_rc" FSCK_RC="$fsck_rc" \
MKE2FS_V="$mke2fs_v" QEMU_V="$qemu_v" DOMAIN="$domain" \
node -e '
  const e = process.env;
  process.stdout.write(JSON.stringify({
    id: e.FIXTURE_ID,
    file: e.FIXTURE_ID + ".vhdx",
    sha256: e.VHDX_SHA,
    extracted_raw_sha256: e.RAW_SHA,
    virtual_size: e.VSIZE,
    fs_uuid: e.FS_UUID,
    fs_uuid_profile: "ADR-008 profile C, domain " + e.DOMAIN + " (pending registration, U11)",
    x_clean: {
      qemu_img_check: { rc: Number(e.CHECK_RC), clean: true },
      e2fsck_fn_on_extracted_raw: { rc: Number(e.FSCK_RC) }
    },
    tools: { mke2fs: e.MKE2FS_V, qemu_img: e.QEMU_V }
  }));' | node "$repo/scripts/ijson-jcs-cli.js" canon > "$out/fixture.json"

echo "one-off-fixture: $fixture_id proven X-CLEAN: sha256 $vhdx_sha, size $virtual_size, uuid $fs_uuid"
echo "one-off-fixture: tools: $mke2fs_v; $qemu_v"
