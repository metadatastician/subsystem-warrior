#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Acceptance tests for the docs-only WSL plan. Run from any directory with:
#   bash tests/workflows/wsl_plan_test.sh
# No experiment commands are executed: their implementations are future work.
# Requires asciidoctor, as does scripts/check-adoc-renders.sh.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plan="$repo/docs/plan"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
checks=0
fails=0

check() {
  local label=$1
  shift
  checks=$((checks + 1))
  if "$@"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label" >&2
    fails=$((fails + 1))
  fi
}

rejects() { ! "$@"; }

# Read one level-2 section, stopping at the next peer. A mention elsewhere in
# the card must not satisfy a missing acceptance criterion or receipt.
section() {
  awk -v heading="$2" '
    /^== / { selected = ($0 ~ "^== " heading "([ :].*)?$"); next }
    selected { print }
  ' "$1"
}

has_section_body() {
  section "$1" "$2" | grep -q '[^[:space:]]'
}

section_contains() {
  section "$1" "$2" | grep -Fq -- "$3"
}

brief_is_verbatim() {
  local digest
  digest=$(sha256sum < "$1")
  [ "${digest%% *}" = f9331df2dc097a7f472c2fed2aa2cee036ba8514e66cf1a0cb7c64113ab9aa34 ]
}

# Check navigable AsciiDoc links and explicit same-document anchors. Paths in
# code spans describe proposed files and deliberately need not exist yet.
local_links_resolve() {
  local doc=$1 token target anchor
  while IFS= read -r token; do
    target=${token#*:}
    target=${target%\[}
    case "$target" in *://*) continue ;; esac
    anchor=''
    if [[ "$target" == *#* ]]; then
      anchor=${target#*#}
      target=${target%%#*}
    fi
    target="$(dirname "$doc")/$target"
    [ -f "$target" ] || return 1
    if [ -n "$anchor" ]; then
      grep -Fq -- "[[$anchor]]" "$target" || return 1
    fi
  done < <(grep -oE '(link|xref):[^[:space:][]+\.adoc(#[^[:space:][]+)?\[' "$doc" || true)
  while IFS= read -r token; do
    anchor=${token#<<}
    anchor=${anchor%>>}
    anchor=${anchor%%,*}
    grep -Fq -- "[[$anchor]]" "$doc" || return 1
  done < <(grep -oE '<<[^>]+>>' "$doc" || true)
}

fault_ids() {
  section "$1" 'Fault catalogue' | sed -n 's/^| `\([RCFUKX]-[A-Z0-9-]*\)`$/\1/p'
}

fault_references_resolve() {
  local id
  while IFS= read -r id; do
    grep -Fxq -- "$id" "$scratch/fault-ids" || return 1
  done < <(grep -oE '`[RCFUKX]-[A-Z][A-Z0-9-]*`' "$1" | tr -d '`' | sort -u)
}

cards=(
  E1-fixtures.adoc E2-baseline.adoc E3-vhdx-reader.adoc
  E4-ext4-probe.adoc E5-registration-probe.adoc E6-windows-ci.adoc
)
docs=("$plan/README.adoc" "$plan/LAYOUT.adoc" "$plan/WSL-HANDOFF.adoc")
for card in "${cards[@]}"; do docs+=("$plan/m0/$card"); done
for doc in "${docs[@]}"; do check "${doc#"$repo"/} exists and is nonempty" test -s "$doc"; done
# Missing subjects must not become a successful render over an empty tree.
[ "$fails" -eq 0 ] || exit 1

check 'revision-1 handoff is preserved byte for byte' brief_is_verbatim "$plan/WSL-HANDOFF.adoc"
check 'index records the handoff checksum' grep -Fq \
  f9331df2dc097a7f472c2fed2aa2cee036ba8514e66cf1a0cb7c64113ab9aa34 "$plan/README.adoc"

fault_ids "$plan/m0/E1-fixtures.adoc" > "$scratch/fault-ids"
check 'fault catalogue has no duplicate identifiers' test -z "$(sort "$scratch/fault-ids" | uniq -d)"
# The original nine faults plus P7 and the clean control are the baseline.
for id in X-CLEAN C-HDR-TORN C-HDR-TORN-BOTH C-LOG-UNREPLAYED C-BAT-BAD \
  C-HOST-COMPRESSED F-SB-PRIMARY F-HTREE F-FEATURE-UNKNOWN K-WSLCONF-BAD R-ORPHAN-DISK; do
  check "catalogue declares $id" grep -Fxq -- "$id" "$scratch/fault-ids"
done

for doc in "${docs[@]}"; do
  check "${doc#"$plan"/}: local links resolve" local_links_resolve "$doc"
  check "${doc#"$plan"/}: named faults exist in E1" fault_references_resolve "$doc"
done

for card in "${cards[@]}"; do
  doc="$plan/m0/$card"
  id=${card%%-*}
  check "$id: title identifies the experiment" grep -q "^= $id " "$doc"
  for heading in Goal Acceptance 'Falsifiers?' Mutations Aspects 'Beyond this repo' Receipt; do
    check "$id: $heading has content" has_section_body "$doc" "$heading"
  done
  check "$id: acceptance defines success by exit status" section_contains "$doc" Acceptance 'exits 0 iff'
  check "$id: receipt uses its own experiment ID" section_contains "$doc" Receipt \
    "verification/tests/m0/$id-receipt.adoc"
  check "$id: receipt includes machine-readable evidence" section_contains "$doc" Receipt '.json'
done

# These are contract checks on the documented entry points, not claims that
# those commands already exist. E6 defines workflow acceptance instead.
for entry in 'E1-fixtures.adoc|just fixtures-check' 'E2-baseline.adoc|just baseline-check' \
  'E3-vhdx-reader.adoc|just e3' 'E4-ext4-probe.adoc|just e4' \
  'E5-registration-probe.adoc|tests/m0/e5_lxss_test.ps1'; do
  check "${entry%%|*}: acceptance names its entry point" section_contains \
    "$plan/m0/${entry%%|*}" Acceptance "${entry#*|}"
done

# Negative controls: make sure the document checks detect regressions rather
# than merely finding a matching word somewhere in the plan. Only scratch
# copies are mutated, and the EXIT trap removes them on success or failure.
cp "$plan/WSL-HANDOFF.adoc" "$scratch/brief.adoc"
printf '\n' >> "$scratch/brief.adoc"
check 'even an extra newline breaks verbatim preservation' rejects brief_is_verbatim "$scratch/brief.adoc"

cat > "$scratch/broken-link.adoc" <<'ADOC'
= Link control

link:missing.adoc[Missing task card]
ADOC
check 'a missing task-card link is rejected' rejects local_links_resolve "$scratch/broken-link.adoc"

cat > "$scratch/broken-anchor.adoc" <<'ADOC'
= Anchor control

See <<sequence>>.
ADOC
check 'a missing sequence anchor is rejected' rejects local_links_resolve "$scratch/broken-anchor.adoc"

printf '`C-UNDECLARED`\n' > "$scratch/unknown-fault.adoc"
check 'a mistyped fault identifier is rejected' rejects fault_references_resolve "$scratch/unknown-fault.adoc"

cat > "$scratch/empty-card.adoc" <<'ADOC'
= Card control

== Acceptance

== Receipt

The command exits 0 iff the checks pass.
ADOC
check 'an empty acceptance section is rejected' rejects has_section_body "$scratch/empty-card.adoc" Acceptance
check 'success wording in another section cannot satisfy acceptance' rejects section_contains \
  "$scratch/empty-card.adoc" Acceptance 'exits 0 iff'

# Reuse the repository gate: WARN is a failure, and any diagnostic is a
# finding even if asciidoctor exits 0. Limit rendering to the changed plan.
render_rc=0
bash "$repo/scripts/check-adoc-renders.sh" "$plan" || render_rc=$?
if [ "$render_rc" -eq 2 ]; then
  echo 'BLOCKED: WSL plan rendering could not run' >&2
  exit 2
fi
check 'all nine plan documents render without diagnostics' test "$render_rc" -eq 0

if [ "$fails" -ne 0 ]; then
  printf 'FAIL: %s of %s WSL plan checks\n' "$fails" "$checks" >&2
  exit 1
fi
printf 'PASS: %s WSL plan checks (including negative controls)\n' "$checks"
