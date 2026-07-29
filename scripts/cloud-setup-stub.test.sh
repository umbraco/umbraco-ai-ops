#!/usr/bin/env bash
# Tests for cloud-setup-stub.sh. Hermetic: bash + git only, no network — git is pointed at a
# dead loopback proxy so every clone fails instantly and identically on any machine.
#
# The stub is pasted by a human into a web form and then almost never looked at again, so the
# things worth testing are the ones a human cannot see failing: that a failed clone says
# something true about why, that the `rebuild:` line — the entire cache-busting mechanism — has
# not been dropped, and that no token handling has crept back in. The engine is public, so a
# token is not part of this any more, and a stub that asks for one sends a human looking for a
# variable that does nothing.
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

# --- the clone is anonymous, and no token handling has come back -----------
# The engine is public. Splicing credentials into a URL is the one thing in here that could leak
# a secret, so the absence is worth asserting rather than assuming.
# Code lines only: the header legitimately explains that the token requirement was removed, and
# a test that banned the word would force that explanation out of the file.
code() { grep -v '^\s*#\|^\s*$' "$STUB"; }
check "no token variable is read" 0 "$(code | grep -c 'OPS_TOKEN\|GH_TOKEN\|GITHUB_TOKEN')"
check "no credential is spliced into the clone URL" 0 "$(code | grep -c 'x-access-token')"
check "it clones \$REPO directly" 1 "$(grep -c 'git clone --depth 1 "\$REPO"' "$STUB")"

# --- a failed clone fails loudly, and blames the right thing ---------------
out="$(nonet bash "$STUB" 2>&1)"; rc=$?
check "a failed clone exits non-zero" 1 "$( [ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "  it says the failure is not an auth problem" 1 \
  "$(printf '%s' "$out" | grep -c 'not an auth one')"
check "  and names what to check instead" 1 "$(printf '%s' "$out" | grep -c 'egress to github.com')"
check "  it does not send anyone looking for a token" 0 \
  "$(printf '%s' "$out" | grep -ci 'token\|private')"

# --- a token in the environment is ignored, not used or echoed -------------
# A leftover OPS_TOKEN from the private-repo era must be inert, and must certainly not appear in
# the output now that nothing consumes it.
out="$(nonet env OPS_TOKEN="$SECRET" GH_TOKEN="$SECRET" bash "$STUB" 2>&1)"
if printf '%s' "$out" | grep -q "$SECRET"; then
  fail=$((fail+1)); echo "FAIL: A STALE TOKEN LEAKED INTO THE OUTPUT"
else pass=$((pass+1)); fi

# --- OPS_REPO still points it at a fork -----------------------------------
out="$(nonet env OPS_REPO="file:///nonexistent-$$" bash "$STUB" 2>&1)"
check "OPS_REPO is honoured in the failure message" 1 \
  "$(printf '%s' "$out" | grep -c "nonexistent-$$")"

# --- it hands off to the real script, and by the right name ---------------
# Match the invocation line only — the filename also appears in the comments.
check "it execs cloud-skill-sync.sh" 1 \
  "$(grep -c '^OPS_SRC=/tmp/ops-boot bash /tmp/ops-boot/scripts/cloud-skill-sync.sh$' "$STUB")"
check "it passes OPS_SRC so nothing clones twice" 1 "$(grep -c 'OPS_SRC=/tmp/ops-boot' "$STUB")"
check "the script it hands off to exists" 1 "$( [ -f "$HERE/cloud-skill-sync.sh" ] && echo 1 || echo 0)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
