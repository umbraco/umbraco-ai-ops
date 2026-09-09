#!/usr/bin/env bash
# Tests for check_plugin_bump, the pure decision function in check-plugin-versions.sh.
# Hermetic: bash only. No git, no jq, no fixture repos — the function under test never
# touches git itself, so the test drives it with plain string arguments instead. The
# git-driven half (main(), which gathers those arguments from `git diff`) runs for real
# every time CI runs this check against this repo's own history; it is not re-simulated
# here, on purpose — that would mean building a fixture git repo just to re-prove that
# `git diff` and `git show` work, which is not this file's job.
#
# Usage: bash check-plugin-versions.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/check-plugin-versions.sh"
[ -f "$S" ] || { echo "FATAL: check-plugin-versions.sh not found at $S"; exit 2; }
# shellcheck source=/dev/null
. "$S"

pass=0 fail_n=0

# check <name> <want-rc> <want-substring-or-empty> -- <args to check_plugin_bump>
check() {
  local name="$1" want_rc="$2" want_sub="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local out rc
  out="$(check_plugin_bump "$@" 2>&1)"
  rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail_n=$((fail_n + 1)); echo "FAIL: $name — want rc $want_rc, got $rc (output: $out)"
    return
  fi
  if [ -n "$want_sub" ]; then
    case "$out" in
      *"$want_sub"*) ;;
      *) fail_n=$((fail_n + 1)); echo "FAIL: $name — expected output to contain '$want_sub', got: $out"; return ;;
    esac
  fi
  pass=$((pass + 1))
}

# --- the bug this exists to catch: content changed, version did not --------------
check "same version, files changed -> FAIL" 1 "still 0.1.0" \
  -- ops-preflight "0.1.0" "0.1.0" "$(printf 'plugins/ops-preflight/skills/ops-preflight/scripts/score.sh')"

check "same version, multiple files changed -> FAIL, all listed" 1 "score.sh" \
  -- ops-preflight "0.1.0" "0.1.0" "$(printf 'plugins/ops-preflight/skills/ops-preflight/scripts/score.sh\nplugins/ops-preflight/.claude-plugin/plugin.json')"

# --- properly bumped: version changed alongside the files -------------------------
check "version bumped alongside changed files -> pass" 0 "" \
  -- ops-preflight "0.1.0" "0.2.0" "$(printf 'plugins/ops-preflight/skills/ops-preflight/scripts/score.sh')"

# --- nothing changed: never a failure, regardless of version ----------------------
check "no files changed, same version -> pass" 0 "" \
  -- ops-issue-loop "0.5.0" "0.5.0" ""

check "no files changed, version differs anyway -> pass (not this check's job)" 0 "" \
  -- ops-issue-loop "0.5.0" "0.6.0" ""

# --- newly added plugin: no prior version to have skipped bumping -----------------
check "newly added plugin, files present -> pass" 0 "" \
  -- ops-new "" "0.1.0" "$(printf 'plugins/ops-new/.claude-plugin/plugin.json\nplugins/ops-new/skills/ops-new/SKILL.md')"

check "newly added plugin, no prior version, no new version either -> pass" 0 "" \
  -- ops-new "" "" "$(printf 'plugins/ops-new/.claude-plugin/plugin.json')"

# --- return code doubles as the fail-counter signal main() relies on --------------
fails=0
check_plugin_bump "demo" "0.1.0" "0.1.0" "some/file" >/dev/null 2>&1
if [ "$fails" = 1 ]; then pass=$((pass + 1)); else fail_n=$((fail_n + 1)); echo "FAIL: fails counter increments on a real failure"; fi

# --- --help is a plain, hermetic smoke test of the executed (not sourced) path ----
if out="$(bash "$S" --help 2>&1)" && printf '%s' "$out" | grep -q "^Usage: check-plugin-versions.sh"; then
  pass=$((pass + 1))
else
  fail_n=$((fail_n + 1)); echo "FAIL: --help should print usage and exit 0"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail_n"
[ "$fail_n" -eq 0 ]
