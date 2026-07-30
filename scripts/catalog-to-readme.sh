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
#
# The output is a raw HTML <table>, not a markdown one, for ONE reason: a capability
# with several actions gets a single `rowspan`-ed cell instead of its name repeated
# down the column. Markdown tables have no rowspan, so this is the only way to get it.
# The cost is that GitHub does NOT process markdown inside a raw HTML block, so the
# generator does that work itself: HTML-escape the text first, then turn the catalog's
# `backticks` into <code>. Keep those two in that order — escaping afterwards would
# eat the tags it just wrote. Emit exactly one <tr> per line and no blank lines: the
# tests count action rows with '^<tr>', and a blank line would end the HTML block
# mid-table.
generate() {
  jq -r '
    def first_sentence:
      (. + " ") | capture("^(?<s>[^.]*\\.)") .s // .;
    def cell:
      first_sentence
      | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
      | gsub("`(?<t>[^`]*)`"; "<code>\(.t)</code>");
    "<table>",
    "<thead><tr><th>Capability</th><th>Action</th><th>What it does</th></tr></thead>",
    "<tbody>",
    ( .capabilities[]
      | ("ops-" + .capability) as $cap
      | (.operations | length) as $n
      | (if $n > 1 then " rowspan=\"\($n)\"" else "" end) as $span
      | .operations
      | to_entries[]
      | if .key == 0
        then "<tr><td\($span)><code>\($cap)</code></td><td><code>\(.value.action)</code></td><td>\(.value.description | cell)</td></tr>"
        else "<tr><td><code>\(.value.action)</code></td><td>\(.value.description | cell)</td></tr>"
        end
    ),
    "</tbody>",
    "</table>"
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
  echo "Wrote $(grep -c '^<tr>' "$block") action rows to $readme"
fi
