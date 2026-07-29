#!/usr/bin/env bash
# Tests for check-installed-versions.sh. Hermetic: bash + jq only, fake cache dirs, no network.
#
# The bug this guards against is silent by nature — a stale plugin serves old behaviour with no
# error — so the assertions are about the script NOTICING, and about it not crying wolf.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/check-installed-versions.sh"
[ -f "$C" ] || { echo "FATAL: check-installed-versions.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

cat > "$TMP/marketplace.json" <<'JSON'
{ "name": "umbraco-ai-ops",
  "plugins": [
    { "name": "ops-install", "version": "0.11.0" },
    { "name": "github-ops",  "version": "0.1.0" } ] }
JSON

mkcache() { # mkcache <name> <plugin:version>...
  local d="$TMP/$1"; shift; mkdir -p "$d"
  for spec in "$@"; do mkdir -p "$d/${spec%%:*}/${spec##*:}"; done
  printf '%s' "$d"
}
run() { MARKETPLACE_FILE="$TMP/marketplace.json" OPS_CACHE_DIR="$1" bash "$C" "${2:-}" 2>&1; }
rc()  { MARKETPLACE_FILE="$TMP/marketplace.json" OPS_CACHE_DIR="$1" bash "$C" >/dev/null 2>&1; echo $?; }

# --- everything current ---------------------------------------------------
cur="$(mkcache cur ops-install:0.11.0 github-ops:0.1.0)"
check "current install exits 0" 0 "$(rc "$cur")"
check "  and says so" 1 "$(run "$cur" | grep -c 'all 2 plugin(s) match the marketplace')"
check "  --quiet prints nothing when current" 0 "$(run "$cur" --quiet | grep -c .)"

# --- a clean bill of health must not be a false all-clear ------------------
# The manifest is only as fresh as the marketplace clone it came from, and that clone does not
# refresh itself. Running from a plugin cache against a week-old clone would otherwise report
# "all current" — true, and useless. Caught in practice: from the cache it said all 8 current
# while five were genuinely behind, because the clone predated the pushes.
gitsrc="$TMP/src"; mkdir -p "$gitsrc/.claude-plugin"
cp "$TMP/marketplace.json" "$gitsrc/.claude-plugin/marketplace.json"
git -C "$gitsrc" init -q 2>/dev/null
git -C "$gitsrc" add -A 2>/dev/null
git -C "$gitsrc" -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null
gitrun() { MARKETPLACE_FILE="$gitsrc/.claude-plugin/marketplace.json" OPS_CACHE_DIR="$1" bash "$C" 2>&1; }
check "a clean result names what it compared against" 1 "$(gitrun "$cur" | grep -c 'compared against:')"
check "  and warns the list may be stale"             1 "$(gitrun "$cur" | grep -c 'does not refresh itself')"
check "  and shows how old it is"                     1 "$(gitrun "$cur" | grep -c 'last updated')"
check "  --quiet still says nothing"                  0 \
  "$(MARKETPLACE_FILE="$gitsrc/.claude-plugin/marketplace.json" OPS_CACHE_DIR="$cur" bash "$C" --quiet 2>&1 | grep -c .)"
# A non-git manifest (a plain checkout) must not break the clean path.
check "a non-git source still exits 0" 0 "$(rc "$cur")"

# --- one behind -----------------------------------------------------------
old="$(mkcache old ops-install:0.9.0 github-ops:0.1.0)"
check "a stale plugin exits 1" 1 "$(rc "$old")"
check "  it names the plugin"   1 "$(run "$old" | grep -c 'ops-install  *0.9.0  *0.11.0')"
check "  and not the current one" 0 "$(run "$old" | grep -c '^  github-ops')"
check "  it prints the install command" 1 \
  "$(run "$old" | grep -c '/plugin install ops-install@umbraco-ai-ops')"
check "  and the marketplace update" 1 "$(run "$old" | grep -c '/plugin marketplace update')"
check "  and says to restart" 1 "$(run "$old" | grep -ci 'RESTART the session')"
check "  and mentions the cloud rebuild bump" 1 "$(run "$old" | grep -c '# rebuild:')"

# --- old versions lying around must not count as current -------------------
# The cache never cleans up, so several versions coexist. Only the newest matters — an earlier
# version of this check would have passed on any directory existing.
both="$(mkcache both ops-install:0.9.0 ops-install:0.11.0 github-ops:0.1.0)"
check "the newest cached version wins" 0 "$(rc "$both")"
messy="$(mkcache messy ops-install:0.9.0 ops-install:0.10.0 github-ops:0.1.0)"
check "  and an older newest is still behind" 1 "$(rc "$messy")"
check "  reporting the highest installed, not the first" 1 \
  "$(run "$messy" | grep -c 'ops-install  *0.10.0')"

# double-digit minors must not sort as strings — 0.9.0 vs 0.11.0 is the case that breaks
check "versions sort numerically, not lexically" 1 \
  "$(run "$messy" | grep -c '0.10.0  *0.11.0')"

# --- not installed at all -------------------------------------------------
none="$(mkcache none github-ops:0.1.0)"
check "a missing plugin exits 1" 1 "$(rc "$none")"
check "  and is listed as not installed" 1 "$(run "$none" | grep -c 'not installed: ops-install')"

# --- an empty cache is 'nothing installed', not a crash --------------------
empty="$(mkcache empty)"
check "an empty cache exits 1" 1 "$(rc "$empty")"
check "  without erroring" 0 "$(run "$empty" | grep -ci 'no such file')"

# --- junk in the cache is ignored -----------------------------------------
junk="$(mkcache junk ops-install:0.11.0 github-ops:0.1.0)"; mkdir -p "$junk/ops-install/not-a-version"
check "a non-version directory is ignored" 0 "$(rc "$junk")"

# --- bad input ------------------------------------------------------------
MARKETPLACE_FILE="$TMP/nope.json" bash "$C" >/dev/null 2>&1
check "a missing manifest exits 2" 2 $?
printf '{ not json' > "$TMP/bad.json"
MARKETPLACE_FILE="$TMP/bad.json" bash "$C" >/dev/null 2>&1
check "an unreadable manifest exits 2" 2 $?

# --- it agrees with this repo's own manifest -------------------------------
check "the real manifest parses and every plugin has a version" 0 \
  "$(jq '[.plugins[] | select((.version // "") | test("^[0-9]+\\.[0-9]+\\.[0-9]+$") | not)] | length' \
      "$HERE/../../../../../.claude-plugin/marketplace.json")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
