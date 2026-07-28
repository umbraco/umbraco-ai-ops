#!/usr/bin/env bash
# Check every marketplace entry against the plugin manifest it points at.
#
# CLAUDE.md requires each plugin to have .claude-plugin/plugin.json AND to be declared in
# .claude-plugin/marketplace.json with a matching name, version and description. Two entries
# once pointed at directories that did not exist, which would make `/plugin marketplace add`
# fail on the whole marketplace — silently, from a reader's point of view, because the
# marketplace file looked complete.
#
# Also checks the reverse direction: a plugin on disk that nobody declared is invisible.
#
# Usage: validate-manifests.sh [repo-root]
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$here/..}"
mp="$root/.claude-plugin/marketplace.json"

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq required"; exit 1; }
[ -f "$mp" ] || { fail "no marketplace at $mp"; exit 1; }
jq empty "$mp" 2>/dev/null || { fail "marketplace.json is not valid JSON"; exit 1; }

# jq on some platforms writes CRLF to a pipe, which would end up inside these values.
strip_cr() { tr -d '\r'; }

declared="$(jq -r '.plugins[].name' "$mp" | strip_cr | sort)"

# --- forward: every declared entry resolves and matches -------------------
n="$(jq '.plugins | length' "$mp" | strip_cr)"
[ "$n" -gt 0 ] || fail "marketplace declares no plugins"

i=0
while [ "$i" -lt "$n" ]; do
  name="$(jq -r ".plugins[$i].name" "$mp" | strip_cr)"
  src="$(jq -r ".plugins[$i].source" "$mp" | strip_cr)"
  pj="$root/${src#./}/.claude-plugin/plugin.json"

  if [ ! -f "$pj" ]; then
    fail "$name declares source '$src' but there is no plugin.json there — /plugin marketplace add would fail"
    i=$((i + 1)); continue
  fi
  jq empty "$pj" 2>/dev/null || { fail "$name: plugin.json is not valid JSON"; i=$((i + 1)); continue; }

  for key in name version description; do
    a="$(jq -r ".plugins[$i].$key // \"\"" "$mp" | strip_cr)"
    b="$(jq -r ".$key // \"\"" "$pj" | strip_cr)"
    [ "$a" = "$b" ] || fail "$name: $key differs between marketplace.json and plugin.json"
  done

  # Manifest conventions from CLAUDE.md.
  [ "$(jq -r '.author.name // ""' "$pj" | strip_cr)" = "Umbraco" ] || fail "$name: author.name must be Umbraco"
  [ "$(jq -r '.license // ""' "$pj" | strip_cr)" = "MIT" ] || fail "$name: license must be MIT"
  want_home="https://github.com/umbraco/umbraco-ai-ops/tree/main/${src#./}"
  got_home="$(jq -r '.homepage // ""' "$pj" | strip_cr)"
  [ "$got_home" = "$want_home" ] || fail "$name: homepage should be $want_home (got $got_home)"

  i=$((i + 1))
done

# --- reverse: every plugin on disk is declared ----------------------------
for d in "$root"/plugins/*/; do
  [ -d "$d" ] || continue
  pn="$(basename "$d")"
  printf '%s\n' "$declared" | grep -qx "$pn" \
    || fail "plugins/$pn exists on disk but is not declared in marketplace.json — nobody can install it"
  [ -f "$d/.claude-plugin/plugin.json" ] \
    || fail "plugins/$pn has no .claude-plugin/plugin.json"
done

if [ "$fails" -gt 0 ]; then
  printf '\n%d manifest problem(s)\n' "$fails" >&2
  exit 1
fi

printf 'OK: %s plugins, marketplace and manifests agree\n' "$n"
