#!/usr/bin/env bash
# Regenerate the README's action table from catalog.json.
#
# The capability level in the README is hand-written prose (the eight, who may call
# what, which two are always the repo's). The ACTION level is generated, because a
# hand-maintained copy of the catalog is exactly the second source of truth the
# capability migration exists to kill.
#
# Usage:  catalog-to-readme.sh            rewrite the block in README.md
#         catalog-to-readme.sh --check    exit 1 if the block is out of date
#         catalog-to-readme.sh --print    print the block to stdout and stop
#
# Env: CATALOG_FILE, README_FILE override the defaults resolved next to this script.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
catalog="${CATALOG_FILE:-$here/../catalog.json}"
readme="${README_FILE:-$here/../README.md}"
begin='<!-- BEGIN GENERATED: catalog-actions'
end='<!-- END GENERATED: catalog-actions'

mode="${1:-write}"
case "$mode" in write|--check|--print) ;; *) echo "usage: $(basename "$0") [--check|--print]" >&2; exit 2 ;; esac

[ -f "$catalog" ] || { echo "ERROR: no catalog at $catalog" >&2; exit 2; }
[ -f "$readme" ]  || { echo "ERROR: no README at $readme" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# One row per action. The table cell takes the description's FIRST SENTENCE — the
# full text carries per-action MUSTs that belong in the catalog, not the README.
generate() {
  jq -r '
    def first_sentence:
      (. + " ") | capture("^(?<s>[^.]*\\.)") .s // .;
    def cell:
      first_sentence | gsub("\\|"; "\\|");
    "| Capability | Action | What it does |",
    "|---|---|---|",
    ( .capabilities[]
      | ("ops-" + .capability) as $cap
      | .operations[]
      | "| `\($cap)` | `\(.action)` | \(.description | cell) |"
    )
  ' "$catalog"
}

if [ "$mode" = "--print" ]; then generate; exit 0; fi

grep -q "$begin" "$readme" || { echo "ERROR: $readme has no '$begin' marker" >&2; exit 2; }
grep -q "$end"   "$readme" || { echo "ERROR: $readme has no '$end' marker" >&2; exit 2; }

tmp="$(mktemp)"; block="$(mktemp)"
trap 'rm -f "$tmp" "$block"' EXIT

generate > "$block"
awk -v blockfile="$block" -v b="$begin" -v e="$end" '
  index($0, b) == 1 { print; while ((getline line < blockfile) > 0) print line; skip = 1; next }
  index($0, e) == 1 { skip = 0 }
  !skip { print }
' "$readme" > "$tmp"

if [ "$mode" = "--check" ]; then
  if cmp -s "$tmp" "$readme"; then
    echo "OK: README action table is current"
    exit 0
  fi
  echo "ERROR: README action table is out of date — run scripts/catalog-to-readme.sh" >&2
  command -v diff >/dev/null 2>&1 && diff -u "$readme" "$tmp" >&2
  exit 1
fi

if cmp -s "$tmp" "$readme"; then
  echo "OK: README action table already current"
else
  cat "$tmp" > "$readme"
  echo "Wrote $(grep -c '^| `ops-' "$block") action rows to $readme"
fi
