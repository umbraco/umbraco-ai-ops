#!/usr/bin/env bash
# Tests for plan-labels.sh. Hermetic: bash + jq only, no network, nothing created.
#
# The rule under test is that a label lands on the repo the role implies (conformance §7.3):
# issue labels on `issues`, PR labels on `code`, learnings labels on `learnings`, and any
# undeclared role collapsing onto `code`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$HERE/plan-labels.sh"
[ -f "$P" ] || { echo "FATAL: plan-labels.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

mkrepo() { # mkrepo <name> [meta-json] -> prints the dir
  local d="$TMP/$1"; mkdir -p "$d/.claude"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$d/.claude/ops-repo-meta.json"
  printf '%s' "$d"
}
plan() { bash "$P" "$1" --code "${2:-owner/code}" --json 2>/dev/null; }
repo_of() { printf '%s' "$1" | jq -r --arg p "$2" '.labels[] | select(.purpose==$p) | .repo'; }
name_of() { printf '%s' "$1" | jq -r --arg p "$2" '.labels[] | select(.purpose==$p) | .label'; }

# --- single repo: everything collapses onto code --------------------------
p="$(plan "$(mkrepo single '{"version":1}')")"
check "ten labels are planned"            10 "$(printf '%s' "$p" | jq '.labels | length')"
check "single repo means one target"      1  "$(printf '%s' "$p" | jq '.summary.repos | length')"
check "  ready lands on code"       "owner/code" "$(repo_of "$p" ready)"
check "  proto_learning too"        "owner/code" "$(repo_of "$p" proto_learning)"

# --- with no file at all --------------------------------------------------
mkdir -p "$TMP/nofile"
check "a repo with no ops-repo-meta.json still plans ten" 10 \
  "$(bash "$P" "$TMP/nofile" --code owner/code --json 2>/dev/null | jq '.labels | length')"

# --- split topology: the role decides the repo ---------------------------
p="$(plan "$(mkrepo split '{"version":1,"topology":{"issues":"owner/issues"}}')")"
check "issue labels go to the issues repo" "owner/issues" "$(repo_of "$p" ready)"
check "  in_progress too"                  "owner/issues" "$(repo_of "$p" in_progress)"
check "  blocked too"                      "owner/issues" "$(repo_of "$p" blocked)"
check "  the release trigger too"          "owner/issues" "$(repo_of "$p" release)"
check "  and release_blocked"              "owner/issues" "$(repo_of "$p" release_blocked)"
check "PR labels stay on the code repo"    "owner/code"   "$(repo_of "$p" land)"
check "  rework too"                       "owner/code"   "$(repo_of "$p" rework)"
check "learnings follow the code repo when undeclared" "owner/code" "$(repo_of "$p" proto_learning)"
check "split topology means two targets"   2 "$(printf '%s' "$p" | jq '.summary.repos | length')"

# --- a declared learnings repo ------------------------------------------
p="$(plan "$(mkrepo learn '{"version":1,"topology":{"issues":"owner/issues","learnings":"owner/notes"}}')")"
check "a declared learnings repo is used"  "owner/notes" "$(repo_of "$p" proto_learning)"
check "  and triaged with it"              "owner/notes" "$(repo_of "$p" triaged)"
check "  and loop_improvement"             "owner/notes" "$(repo_of "$p" loop_improvement)"
check "  but not the ready label"          "owner/issues" "$(repo_of "$p" ready)"

# --- label overrides ----------------------------------------------------
p="$(plan "$(mkrepo over '{"version":1,"labels":{"ready":"needs-ai","land":"shipit"}}')")"
check "an overridden name is used"    "needs-ai" "$(name_of "$p" ready)"
check "  and another"                 "shipit"   "$(name_of "$p" land)"
check "a non-overridden name defaults" "ops/auto-rework" "$(name_of "$p" rework)"
check "overrides are flagged"         2 "$(printf '%s' "$p" | jq '[.labels[] | select(.overridden)] | length')"
check "the rest are not"              8 "$(printf '%s' "$p" | jq '[.labels[] | select(.overridden | not)] | length')"

# --- every label has what create-label needs ----------------------------
p="$(plan "$(mkrepo full '{"version":1}')")"
check "every label has a name, repo, colour and description" 0 \
  "$(printf '%s' "$p" | jq '[.labels[] | select((.label|length)==0 or (.repo|length)==0 or (.colour|test("^[0-9a-f]{6}$")|not) or (.description|length)==0)] | length')"
check "purposes are unique" 10 "$(printf '%s' "$p" | jq '[.labels[].purpose] | unique | length')"
check "the default names are all ops/-namespaced" 10 \
  "$(printf '%s' "$p" | jq '[.labels[] | select(.label | startswith("ops/"))] | length')"

# --- the code repo is never taken from the file -------------------------
p="$(plan "$(mkrepo nocode '{"version":1,"topology":{"issues":"owner/issues"}}')" "given/code")"
check "--code wins for the code role" "given/code" "$(repo_of "$p" land)"

# --- text mode + usage ---------------------------------------------------
out="$(bash "$P" "$(mkrepo text '{"version":1}')" --code owner/code 2>/dev/null)"
check "text mode lists ten labels" 10 "$(printf '%s' "$out" | grep -c '#[0-9a-f]\{6\}')"
check "text mode says how to create them" 1 "$(printf '%s' "$out" | grep -c 'create-label')"

# --- the git-remote path --------------------------------------------------
# Every case above passes --code, which is why a trailing-slash bug in the remote parser
# survived 32 tests and was only found dry-running against a real clone. These exercise the
# fallback: no --code, so the repo comes off `remote.origin.url`. Hermetic — git init is local.
gitrepo() { # gitrepo <name> <origin-url> -> prints the dir
  local d="$TMP/$1"; mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" remote add origin "$2" 2>/dev/null
  printf '%s' "$d"
}
repo1() { bash "$P" "$1" --json 2>/dev/null | jq -r '.summary.repos[0]'; }

if command -v git >/dev/null 2>&1; then
  check "https origin resolves to owner/name" "owner/name" \
    "$(repo1 "$(gitrepo g1 https://github.com/owner/name)")"
  check "  a trailing slash is stripped" "owner/name" \
    "$(repo1 "$(gitrepo g2 https://github.com/owner/name/)")"
  check "  .git is stripped" "owner/name" \
    "$(repo1 "$(gitrepo g3 https://github.com/owner/name.git)")"
  check "  and both together" "owner/name" \
    "$(repo1 "$(gitrepo g4 https://github.com/owner/name.git/)")"
  check "  an ssh origin resolves too" "owner/name" \
    "$(repo1 "$(gitrepo g5 git@github.com:owner/name.git)")"
  check "a declared topology.code still beats the remote" "owner/declared" \
    "$(d="$(gitrepo g6 https://github.com/owner/remote/)"; mkdir -p "$d/.claude"; \
       printf '%s' '{"version":1,"topology":{"code":"owner/declared"}}' > "$d/.claude/ops-repo-meta.json"; \
       repo1 "$d")"
fi

bash "$P" >/dev/null 2>&1;                     check "no argument exits 2" 2 $?
bash "$P" "$TMP/absent" >/dev/null 2>&1;       check "a missing directory exits 2" 2 $?
d="$(mkrepo broken '{ not json')"
bash "$P" "$d" --code owner/code >/dev/null 2>&1; check "an unreadable file exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
