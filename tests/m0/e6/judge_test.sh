#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# judge_test.sh — E6's completeness rule, tested both ways, offline.
#
# A complete results file (all yes, or a mix of yes and no) must pass. The
# card's mutations must fail: a dropped verdict, a `not-run` verdict, a
# harness fault, a verdict without evidence, invalid JSON and no results at
# all. The judge's required-step list must equal probe.ps1's.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
judge="$here/judge.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
# check LABEL COMMAND...: pass if the command succeeds, fail otherwise.
check() {
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

steps="virtualisation wsl-present wsl-install import-v2 run-v2 bare-mount e2fsck import-v1 zig-exe"

# The judge's list and the probe's list must be the same steps in the same order.
judge_list="$(sed -n 's/^REQUIRED_STEPS="\(.*\)"$/\1/p' "$judge")"
probe_list="$(awk '/^\$RequiredSteps = @\(/{f=1;next} f&&/^\)/{exit} f' "$here/probe.ps1" \
  | grep -o "'[a-z0-9-]*'" | tr -d "'" | tr '\n' ' ' | sed 's/ $//')"
check "judge lists the expected steps" [ "$judge_list" = "$steps" ]
check "probe.ps1 lists the same steps ($probe_list)" [ "$probe_list" = "$steps" ]

# Every Set-Verdict in probe.ps1 names a required step.
while IFS= read -r id; do
  case " $steps " in *" $id "*) ;; *) fail "probe.ps1 sets an unknown step: $id" ;; esac
done < <(grep -o "Set-Verdict '[a-z0-9-]*'" "$here/probe.ps1" | cut -d"'" -f2 | sort -u)
pass "every Set-Verdict in probe.ps1 names a required step"

# make CASE HARNESS VERDICT_FOR_STEP... : write one leg's results.json.
make() {
  local case="$1" harness="$2"; shift 2
  mkdir -p "$tmp/$case/windows-2025"
  CASE_HARNESS="$harness" STEPS="$steps" OVERRIDES="$*" node -e '
    const e = process.env, steps = {};
    const over = Object.fromEntries((e.OVERRIDES || "").split(" ").filter(Boolean).map(kv => kv.split("=")));
    for (const s of e.STEPS.split(" ")) {
      const v = over[s] === undefined ? "yes" : over[s];
      if (v === "DROP") continue;
      if (v === "NOEVIDENCE") { steps[s] = { verdict: "yes", evidence: {} }; continue; }
      steps[s] = { verdict: v.replace(/_/g, " "), evidence: { rc: 0, output: "x" } };
    }
    process.stdout.write(JSON.stringify({ experiment: "E6", harness: { status: e.CASE_HARNESS, checks: [] }, steps }));
  ' > "$tmp/$case/windows-2025/results.json"
}

expect() {
  local want="$1" case="$2" got=0
  bash "$judge" "$tmp/$case" >/dev/null 2>&1 || got=$?
  check "$case -> exit $got, expected $want" [ "$got" = "$want" ]
}

make all-yes ok;                                         expect 0 all-yes
make wsl1-only ok run-v2=no bare-mount=no e2fsck=no import-v2=no; expect 0 wsl1-only
make drop-verdict ok zig-exe=DROP;                       expect 1 drop-verdict
make not-run ok virtualisation=not-run:_mutation;        expect 1 not-run
make harness-incomplete incomplete;                      expect 1 harness-incomplete
make no-evidence ok e2fsck=NOEVIDENCE;                   expect 1 no-evidence
make ambiguous ok bare-mount=not-run:_harness_ambiguous_device_match e2fsck=not-run:_harness; expect 1 ambiguous
mkdir -p "$tmp/invalid/windows-2022"; printf '{"steps":' > "$tmp/invalid/windows-2022/results.json"; expect 1 invalid
mkdir -p "$tmp/empty";                                   expect 1 empty

# Two legs: one complete and one incomplete must still fail.
make mixed ok; mkdir -p "$tmp/mixed/windows-2022"
cp "$tmp/drop-verdict/windows-2025/results.json" "$tmp/mixed/windows-2022/results.json"
expect 1 mixed

# The receipt it writes is canonical JCS.
bash "$judge" "$tmp/all-yes" "$tmp/receipt.json" >/dev/null
jcs_check() { node "$here/../../../scripts/ijson-jcs-cli.js" check < "$1"; }
check "receipt is canonical JCS" jcs_check "$tmp/receipt.json"

if [ "$fails" -ne 0 ]; then echo "FAIL: $fails E6 judge check(s)"; exit 1; fi
echo "PASS: E6 judge checks"
