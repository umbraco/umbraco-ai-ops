#!/usr/bin/env bash
# Tests for cloud-setup-stub.sh. Hermetic: bash + git only, no network — git is pointed at a
# dead loopback proxy so every clone fails instantly and identically on any machine.
#
# The stub is pasted by a human into a web form and then almost never looked at again, so the
# things worth testing are the ones a human cannot see failing: that the token never reaches
# the output, that a missing token produces the message that names the actual fix, and that
# the `rebuild:` line — the entire cache-busting mechanism — has not been dropped.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB="$HERE/cloud-setup-stub.sh"
[ -f "$STUB" ] || { echo "FATAL: cloud-setup-stub.sh not found"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

SECRET="ghp_STUBTESTdonotuse0987654321"
nonet() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:1 "$@"; }

# --- the cache-busting line must exist ------------------------------------
# Without it there is no way to make an environment pick up a newer engine, and the failure is
# invisible: the env just keeps serving an old snapshot.
check "the rebuild line is present" 1 "$(grep -c '^# rebuild: [0-9]' "$STUB")"
check "it explains that only this field's text busts the cache" 1 \
  "$(grep -c 'busted ONLY by the text of this field' "$STUB")"

# --- it must stay short ---------------------------------------------------
# A human pastes this. The moment it grows logic, that logic is unversioned in a web form.
lines="$(grep -vc '^\s*#\|^\s*$' "$STUB")"
check "the stub is under 25 lines of actual code" 1 "$( [ "$lines" -lt 25 ] && echo 1 || echo 0)"

# --- token never appears in the output ------------------------------------
out="$(nonet env OPS_TOKEN="$SECRET" bash "$STUB" 2>&1)"; rc=$?
check "a failed clone exits non-zero" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0)"
if printf '%s' "$out" | grep -q "$SECRET"; then
  fail=$((fail+1)); echo "FAIL: THE TOKEN LEAKED INTO THE OUTPUT"
else pass=$((pass+1)); fi
check "  a token failure blames the token, not the setup" 1 \
  "$(printf '%s' "$out" | grep -c 'has not expired')"

# --- no token: the message must name the actual fix -----------------------
out="$(nonet env OPS_TOKEN= GH_TOKEN= GITHUB_TOKEN= bash "$STUB" 2>&1)"
check "a missing token says the repo is private" 1 "$(printf '%s' "$out" | grep -c 'repo is private')"
check "  and names the variable to set" 1 "$(printf '%s' "$out" | grep -c 'OPS_TOKEN')"

# --- the fallbacks a runner may already have ------------------------------
for var in GH_TOKEN GITHUB_TOKEN; do
  out="$(nonet env "$var=$SECRET" OPS_TOKEN= bash "$STUB" 2>&1)"
  check "$var is accepted as a token" 1 "$(printf '%s' "$out" | grep -c 'has not expired')"
  if printf '%s' "$out" | grep -q "$SECRET"; then
    fail=$((fail+1)); echo "FAIL: $var LEAKED INTO THE OUTPUT"
  else pass=$((pass+1)); fi
done

# --- a non-github remote must not have a token spliced in -----------------
out="$(nonet env OPS_REPO="file:///nonexistent-$$" OPS_TOKEN="$SECRET" bash "$STUB" 2>&1)"
if printf '%s' "$out" | grep -q "$SECRET"; then
  fail=$((fail+1)); echo "FAIL: token leaked on a non-github remote"
else pass=$((pass+1)); fi

# --- it hands off to the real script, and by the right name ---------------
# Match the invocation line only — the filename also appears in the comments.
check "it execs cloud-skill-sync.sh" 1 \
  "$(grep -c '^OPS_SRC=/tmp/ops-boot bash /tmp/ops-boot/scripts/cloud-skill-sync.sh$' "$STUB")"
check "it passes OPS_SRC so nothing clones twice" 1 "$(grep -c 'OPS_SRC=/tmp/ops-boot' "$STUB")"
check "the script it hands off to exists" 1 "$( [ -f "$HERE/cloud-skill-sync.sh" ] && echo 1 || echo 0)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
