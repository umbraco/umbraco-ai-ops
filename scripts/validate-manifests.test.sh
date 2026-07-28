#!/usr/bin/env bash
# Tests for validate-manifests.sh, plus the live check: this repo's manifests agree.
# Hermetic: bash + jq only, no network.
#
# Usage: bash validate-manifests.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-manifests.sh"
[ -f "$V" ] || { echo "FATAL: validate-manifests.sh not found at $V"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

status() { # status <name> <want-rc> <root>
  bash "$V" "$3" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$2" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $1 — want exit $2, got $got"; fi
}

# --- the live repo ---------------------------------------------------------
status "this repo's manifests agree" 0 "$HERE/.."

# --- a synthetic repo we can break ----------------------------------------
mkrepo() { # mkrepo <dir>
  local r="$1"
  mkdir -p "$r/.claude-plugin" "$r/plugins/demo/.claude-plugin"
  cat > "$r/plugins/demo/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "demo",
  "version": "0.1.0",
  "description": "A demo plugin.",
  "author": { "name": "Umbraco", "url": "https://github.com/umbraco" },
  "homepage": "https://github.com/umbraco/umbraco-ai-ops/tree/main/plugins/demo",
  "license": "MIT"
}
JSON
  cat > "$r/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "t",
  "plugins": [
    { "name": "demo", "source": "./plugins/demo", "version": "0.1.0", "description": "A demo plugin." }
  ]
}
JSON
}

mkrepo "$TMP/good"
status "a well-formed synthetic repo" 0 "$TMP/good"

# each mutation gets its own copy
mut() { # mut <name> -> prints a broken repo dir
  rm -rf "$TMP/$1"; cp -r "$TMP/good" "$TMP/$1"; printf '%s' "$TMP/$1"
}

r="$(mut nodir)"
jq '.plugins[0].source = "./plugins/ghost"' "$r/.claude-plugin/marketplace.json" > "$r/m" && mv "$r/m" "$r/.claude-plugin/marketplace.json"
status "an entry pointing at a missing directory" 1 "$r"

r="$(mut version)"
jq '.plugins[0].version = "9.9.9"' "$r/.claude-plugin/marketplace.json" > "$r/m" && mv "$r/m" "$r/.claude-plugin/marketplace.json"
status "a version that differs from plugin.json" 1 "$r"

r="$(mut desc)"
jq '.plugins[0].description = "Something else."' "$r/.claude-plugin/marketplace.json" > "$r/m" && mv "$r/m" "$r/.claude-plugin/marketplace.json"
status "a description that differs from plugin.json" 1 "$r"

r="$(mut undeclared)"
mkdir -p "$r/plugins/orphan/.claude-plugin"
cp "$r/plugins/demo/.claude-plugin/plugin.json" "$r/plugins/orphan/.claude-plugin/plugin.json"
status "a plugin on disk that nobody declared" 1 "$r"

r="$(mut nomanifest)"
mkdir -p "$r/plugins/bare"
status "a plugin directory with no plugin.json" 1 "$r"

r="$(mut license)"
jq '.license = "Apache-2.0"' "$r/plugins/demo/.claude-plugin/plugin.json" > "$r/m" && mv "$r/m" "$r/plugins/demo/.claude-plugin/plugin.json"
status "a licence that is not MIT" 1 "$r"

r="$(mut author)"
jq '.author.name = "Someone"' "$r/plugins/demo/.claude-plugin/plugin.json" > "$r/m" && mv "$r/m" "$r/plugins/demo/.claude-plugin/plugin.json"
status "an author that is not Umbraco" 1 "$r"

r="$(mut homepage)"
jq '.homepage = "https://example.com"' "$r/plugins/demo/.claude-plugin/plugin.json" > "$r/m" && mv "$r/m" "$r/plugins/demo/.claude-plugin/plugin.json"
status "a homepage off the convention" 1 "$r"

r="$(mut brokenjson)"
printf '{ not json' > "$r/.claude-plugin/marketplace.json"
status "an unreadable marketplace.json" 1 "$r"

status "a root with no marketplace at all" 1 "$TMP/nothing-here"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
