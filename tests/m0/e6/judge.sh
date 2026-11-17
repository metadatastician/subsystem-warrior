#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# judge.sh — decide E6 from the probe's results files.
#
# The workflow exits 0 iff every results file (one per runner image):
#   * is valid I-JSON;
#   * reports harness status `ok`;
#   * has every required step, each with verdict `yes` or `no` and non-empty
#     evidence.
# A missing step, a `not-run: <reason>` verdict, a harness fault or no results
# at all make E6 incomplete (exit 1). `no` is a valid, successful answer.
#
# Usage: judge.sh RESULTS_DIR [RECEIPT_JSON]
# Reads RESULTS_DIR/*/results.json (one directory per matrix leg). Writes the
# combined verdicts, canonical JCS, to RECEIPT_JSON when given.
# Exit: 0 = complete; 1 = incomplete; 2 = setup error.
set -euo pipefail

dir="${1:-}"
receipt="${2:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "judge: usage: judge.sh RESULTS_DIR [RECEIPT_JSON]" >&2
  exit 2
fi
command -v node >/dev/null || { echo "judge: missing tool: node" >&2; exit 2; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
canon="$repo/scripts/ijson-jcs-cli.js"

# The same list as $RequiredSteps in probe.ps1 (judge_test.sh checks this).
REQUIRED_STEPS="virtualisation wsl-present wsl-install import-v2 run-v2 bare-mount e2fsck import-v1 zig-exe"

shopt -s nullglob
files=("$dir"/*/results.json)
if [ "${#files[@]}" -eq 0 ]; then
  echo "judge: incomplete: no results files under $dir" >&2
  exit 1
fi

legs=()
status=0
for f in "${files[@]}"; do
  leg="$(basename "$(dirname "$f")")"
  if ! c="$(node "$canon" canon < "$f")"; then
    echo "judge: $leg: incomplete: results are not valid I-JSON" >&2
    status=1
    continue
  fi
  if ! out="$(LEG="$leg" REQ="$REQUIRED_STEPS" node -e '
    const r = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const req = process.env.REQ.split(" ");
    const problems = [];
    if (!r.harness || r.harness.status !== "ok") problems.push("harness status is " + (r.harness ? r.harness.status : "missing"));
    const steps = r.steps || {};
    const rows = [];
    for (const s of req) {
      const st = steps[s];
      if (!st) { problems.push(s + ": no verdict recorded"); rows.push([s, "MISSING"]); continue; }
      const v = String(st.verdict);
      const ev = st.evidence;
      const hasEv = ev !== null && typeof ev === "object" && Object.keys(ev).length > 0;
      if (v !== "yes" && v !== "no") problems.push(s + ": verdict is " + JSON.stringify(v));
      else if (!hasEv) problems.push(s + ": verdict " + v + " has no evidence");
      rows.push([s, v]);
    }
    const leg = process.env.LEG;
    for (const [s, v] of rows) console.log(leg + "\t" + s + "\t" + v);
    if (problems.length) { for (const p of problems) console.error(leg + ": incomplete: " + p); process.exit(1); }
  ' <<<"$c")"; then
    status=1
  fi
  printf '%s\n' "$out"
  legs+=("$leg")
done

if [ -n "$receipt" ]; then
  node -e '
    const fs = require("fs");
    const files = process.argv.slice(1);
    const legs = {};
    for (const f of files) {
      const leg = require("path").basename(require("path").dirname(f));
      try { legs[leg] = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { legs[leg] = { invalid: String(e) }; }
    }
    process.stdout.write(JSON.stringify({ experiment: "E6", legs }));
  ' "${files[@]}" | node "$canon" canon > "$receipt"
fi

if [ "$status" -ne 0 ]; then
  echo "judge: E6 incomplete" >&2
  exit 1
fi
echo "judge: E6 complete: every required step on ${#legs[@]} runner image(s) has a yes/no verdict with evidence"
