#!/usr/bin/env bash
# Tests for scaffold-capability.sh. Hermetic: bash + jq only, no network.
#
# The point of a generated stub is that it cannot disagree with the catalog about which
# actions exist, so most of these assert exactly that.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/scaffold-capability.sh"
CATALOG="$HERE/../../../../../catalog.json"
[ -f "$SC" ] || { echo "FATAL: scaffold-capability.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }
has()   { if grep -qF "$3" "$2"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — [$3] not found in $2"; fi; }

# --- generate every catalogued capability ---------------------------------
while IFS= read -r cap; do
  bash "$SC" "$cap" "$TMP/all" >/dev/null 2>&1
  f="$TMP/all/ops-$cap/SKILL.md"
  if [ ! -f "$f" ]; then fail=$((fail+1)); echo "FAIL: no stub generated for $cap"; continue; fi
  pass=$((pass+1))

  # the frontmatter every stub must carry
  check "  $cap: name is ops-$cap" "name: ops-$cap" "$(sed -n '2p' "$f")"
  has   "  $cap: disables model invocation" "$f" "disable-model-invocation: true"

  # exactly the catalog's actions, no more and no fewer
  want="$(jq -r --arg c "$cap" '.capabilities[]|select(.capability==$c)|.operations[].action' "$CATALOG" | sort | tr -d '\r')"
  got="$(sed -n 's/^## Action: `\([a-z0-9-]*\)`$/\1/p' "$f" | sort)"
  check "  $cap: the stub's actions match the catalog exactly" "$want" "$got"
done < <(jq -r '.capabilities[].capability' "$CATALOG" | tr -d '\r')

# --- the contract every stub teaches --------------------------------------
f="$TMP/all/ops-change/SKILL.md"
has "the stub states the reject-unknown-action rule" "$f" "Reject any action not listed below"
has "the stub states that absent context is {}"      "$f" 'absent context is `{}`'
has "the stub states idempotency as a MUST"          "$f" "Idempotency (a MUST)"
has "the stub states safe-on-failure"                "$f" "leaves a safe state"
has "the stub states the ok/detail shape"            "$f" '"ok": false'
has "the stub routes GitHub work through github-ops" "$f" 'through `github-ops`'
has "the stub carries the catalog's worked example"  "$f" '"number":4211'
has "the stub says the action names are not the author's to change" "$f" "Do not add, rename or remove one"

# --- visibility and kind come through -------------------------------------
has "a supporting capability says only a service calls it" \
  "$TMP/all/ops-branching/SKILL.md" "never a loop directly"
has "a data capability states the §4.4 carve-out" \
  "$TMP/all/ops-repo-meta/SKILL.md" "structure it returns"

# --- safety ---------------------------------------------------------------
printf 'mine\n' > "$TMP/all/ops-change/SKILL.md"
bash "$SC" change "$TMP/all" >/dev/null 2>&1
check "never overwrites an existing stub" "mine" "$(cat "$TMP/all/ops-change/SKILL.md")"

bash "$SC" not-a-capability "$TMP/x" >/dev/null 2>&1
check "refuses a capability the catalog does not declare" 2 $?
check "  and writes nothing" 0 "$( [ -d "$TMP/x" ] && echo 1 || echo 0)"

bash "$SC" >/dev/null 2>&1;         check "no arguments exits 2" 2 $?
bash "$SC" change >/dev/null 2>&1;  check "a missing destination exits 2" 2 $?
CATALOG_FILE="$TMP/nope.json" bash "$SC" change --stdout >/dev/null 2>&1
check "a missing catalog exits 2" 2 $?

# --- --stdout writes nothing to disk --------------------------------------
out="$(bash "$SC" notify --stdout 2>/dev/null)"
check "--stdout emits the stub" "name: ops-notify" "$(printf '%s' "$out" | sed -n '2p')"
check "--stdout creates no directory" 0 "$( [ -d "$TMP/all/ops-notify-x" ] && echo 1 || echo 0)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
