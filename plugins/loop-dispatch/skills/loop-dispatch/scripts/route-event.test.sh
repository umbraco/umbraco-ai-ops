#!/usr/bin/env bash
#
# Deterministic tests for route-event.sh — the loop-dispatch routing decision.
# Hermetic: bash + jq only, no network, no gh, no claude. Runs in a few ms.
#
# Usage: bash route-event.test.sh   (exits non-zero if any case fails)
set -uo pipefail

# Isolate from any ambient GitHub-event env (GitHub Actions sets these to the
# workflow's OWN event, which would otherwise shadow the stdin payloads we feed in).
unset GITHUB_EVENT_PATH GITHUB_EVENT_NAME ROUTE_OVERLAY TARGET_REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/route-event.sh"
BASE="$HERE/route-map.json"
[ -f "$SCRIPT" ] || { echo "FATAL: route-event.sh not found at $SCRIPT"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# expect_loop <name> <expected-loop> -- <args...>   (args after -- go to route-event.sh)
expect_loop() {
  local name="$1" want="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$(bash "$SCRIPT" "$@" </dev/null)"
  local got="${out#loop=}"; got="${got%% *}"
  if [ "$got" = "$want" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $name — want loop=$want, got: $out"; fi
}

# expect_json <name> <expected-full-line> <payload-json> <event-name>
expect_json() {
  local name="$1" want="$2" json="$3" evt="$4"
  local out; out="$(printf '%s' "$json" | bash "$SCRIPT" --event "$evt")"
  if [ "$out" = "$want" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $name — want [$want], got [$out]"; fi
}

# expect_rc <name> <want-rc> -- <args...>
expect_rc() {
  local name="$1" want="$2"; shift 2; [ "$1" = "--" ] && shift
  bash "$SCRIPT" "$@" </dev/null >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $name — want exit $want, got $got"; fi
}

# --- the base table, by flags ---------------------------------------------
expect_loop "issue ops/ready-for-ai -> ops-issue-loop"   ops-issue-loop   -- --event issues --action labeled --label ops/ready-for-ai --number 5 --repo o/r
expect_loop "issue ops/auto-release -> ops-release-loop" ops-release-loop -- --event issues --action labeled --label ops/auto-release --number 9 --repo o/r
expect_loop "pr ops/auto-merge -> ops-merge-loop"        ops-merge-loop   -- --event pull_request --action labeled --label ops/auto-merge --number 42 --repo o/r
expect_loop "pr ops/auto-rework -> ops-rework-loop"      ops-rework-loop  -- --event pull_request --action labeled --label ops/auto-rework --number 50 --repo o/r

# pull_request_target is what the live caller fires (runs from the default branch with
# secrets, so it reaches dev-based PRs); it normalises to pull_request.
expect_loop "pr_target ops/auto-merge normalises"        ops-merge-loop   -- --event pull_request_target --action labeled --label ops/auto-merge --number 42 --repo o/r
expect_loop "pr_target ops/auto-rework normalises"       ops-rework-loop  -- --event pull_request_target --action labeled --label ops/auto-rework --number 50 --repo o/r

# --- no match is a normal, quiet outcome ----------------------------------
expect_loop "pr dependencies -> none (the 4x bug)"   none -- --event pull_request --action labeled --label dependencies --number 269 --repo o/r
expect_loop "pr_target dependencies -> none"         none -- --event pull_request_target --action labeled --label dependencies --number 269 --repo o/r
expect_loop "issue bug -> none"                      none -- --event issues --action labeled --label bug --number 3 --repo o/r
expect_loop "an in-vocab event with no rule -> none" none -- --event pull_request --action opened --number 42 --repo o/r
expect_loop "an out-of-vocab event -> none"          none -- --event release --action published --number 1 --repo o/r
expect_loop "review submitted -> none (not in the vocabulary at all)" none -- --event pull_request_review --action submitted --number 42 --repo o/r
expect_loop "an event with no action -> none"         none -- --event issues --label ops/ready-for-ai --repo o/r
expect_loop "no input at all -> none"                none --
expect_rc   "no match still exits 0"                 0    -- --event issues --action labeled --label bug --repo o/r

# --- the label must match exactly -----------------------------------------
expect_loop "a label prefix does not match"          none -- --event issues --action labeled --label ready --number 1 --repo o/r
expect_loop "a label suffix does not match"          none -- --event issues --action labeled --label ops/ready-for-ai-too --number 1 --repo o/r

# --- raw-JSON payloads (event name passed separately, as GitHub does) -----
expect_json "raw json ops/auto-merge PR" \
  "loop=ops-merge-loop repo=a/b number=7" \
  '{"action":"labeled","label":{"name":"ops/auto-merge"},"pull_request":{"number":7},"repository":{"full_name":"a/b"}}' \
  pull_request
expect_json "raw json dependencies PR -> none" \
  "loop=none repo=a/b number=269" \
  '{"action":"labeled","label":{"name":"dependencies"},"pull_request":{"number":269},"repository":{"full_name":"a/b"}}' \
  pull_request
expect_json "raw json ops/ready-for-ai issue" \
  "loop=ops-issue-loop repo=a/b number=5" \
  '{"action":"labeled","label":{"name":"ops/ready-for-ai"},"issue":{"number":5},"repository":{"full_name":"a/b"}}' \
  issues
expect_json "raw json ops/auto-rework via pull_request_target" \
  "loop=ops-rework-loop repo=a/b number=8" \
  '{"action":"labeled","label":{"name":"ops/auto-rework"},"pull_request":{"number":8},"repository":{"full_name":"a/b"}}' \
  pull_request_target
expect_json "raw json review submitted -> none" \
  "loop=none repo=a/b number=8" \
  '{"action":"submitted","review":{"state":"changes_requested"},"pull_request":{"number":8},"repository":{"full_name":"a/b"}}' \
  pull_request_review

# --- cross-repo target ----------------------------------------------------
out="$(bash "$SCRIPT" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues --target own/code </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/issues number=5 target=own/code" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: cross-repo target emitted — got [$out]"; fi
out="$(bash "$SCRIPT" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/code --target own/code </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/code number=5" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: same-repo target omitted — got [$out]"; fi

# --- the target derived from declared facts -------------------------------
# The split-topology fact used to live twice: as `with.target_repo` in the caller workflow AND
# inside the repo's ops-repo-meta. One fact in two files in two repos, with nothing catching a
# disagreement. The file is now the single source and the router reads it.
cat > "$TMP/meta-split.json" <<'JSON'
{ "version": 1, "topology": { "code": "own/code", "issues": "own/issues" } }
JSON
cat > "$TMP/meta-single.json" <<'JSON'
{ "version": 1 }
JSON

out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-split.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/issues number=5 target=own/code" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: target derived from declared topology — got [$out]"; fi

# Fired on the CODE repo, the same file must add no target: the work is already here.
out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-split.json" --event pull_request --action labeled --label ops/auto-merge --number 8 --repo own/code </dev/null)"
if [ "$out" = "loop=ops-merge-loop repo=own/code number=8" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: no target when the event fires on the code repo — got [$out]"; fi

expect_loop "a single-repo file adds no target" ops-issue-loop -- --repo-meta "$TMP/meta-single.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/code
out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-single.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/code </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/code number=5" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a single-repo file must add no target — got [$out]"; fi

# An explicit --target still wins, so a manual run can override the file.
out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-split.json" --target other/repo --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/issues number=5 target=other/repo" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: an explicit --target must win over the file — got [$out]"; fi

# $REPO_META is the env equivalent, which is what the caller workflow sets.
out="$(REPO_META="$TMP/meta-split.json" bash "$SCRIPT" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues </dev/null)"
if [ "${out##* }" = "target=own/code" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: \$REPO_META honoured — got [$out]"; fi

# A missing or unreadable file must not break routing — the target is an optimisation, and a
# repo that has no declared facts is the common case.
expect_loop "a missing repo-meta file still routes" ops-issue-loop -- --repo-meta "$TMP/nope.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues
printf '{ not json' > "$TMP/meta-broken.json"
expect_loop "an unreadable repo-meta file still routes" ops-issue-loop -- --repo-meta "$TMP/meta-broken.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues

# --- base + overlay merge -------------------------------------------------
cat > "$TMP/add.json" <<'JSON'
{ "version": 2, "routes": [ { "event": "issues.labeled", "label": "ops/needs-ai", "loop": "ops-issue-loop" } ] }
JSON
cat > "$TMP/disable.json" <<'JSON'
{ "version": 2, "routes": [ { "event": "pull_request.labeled", "label": "ops/auto-rework", "loop": null } ] }
JSON
cat > "$TMP/retarget.json" <<'JSON'
{ "version": 2, "routes": [ { "event": "pull_request.labeled", "label": "ops/auto-merge", "loop": "repo-own-merge" } ] }
JSON
cat > "$TMP/opened.json" <<'JSON'
{ "version": 2, "routes": [ { "event": "issues.opened", "label": "", "loop": "ops-triage-loop" } ] }
JSON
cat > "$TMP/none.json" <<'JSON'
{ "version": 2, "routes": [] }
JSON

expect_loop "overlay ADDS a label"                 ops-issue-loop -- --overlay "$TMP/add.json" --event issues --action labeled --label ops/needs-ai --repo o/r --number 1
expect_loop "overlay leaves the base intact"       ops-issue-loop -- --overlay "$TMP/add.json" --event issues --action labeled --label ops/ready-for-ai --repo o/r --number 1
expect_loop "overlay DISABLES with loop:null"      none           -- --overlay "$TMP/disable.json" --event pull_request --action labeled --label ops/auto-rework --repo o/r --number 1
expect_loop "a disable does not touch its sibling" ops-merge-loop -- --overlay "$TMP/disable.json" --event pull_request --action labeled --label ops/auto-merge --repo o/r --number 1
expect_loop "overlay WINS on a shared key"         repo-own-merge -- --overlay "$TMP/retarget.json" --event pull_request --action labeled --label ops/auto-merge --repo o/r --number 1
expect_loop "an empty label reaches an .opened rule" ops-triage-loop -- --overlay "$TMP/opened.json" --event issues --action opened --repo o/r --number 1
expect_loop "an empty overlay changes nothing"     ops-issue-loop -- --overlay "$TMP/none.json" --event issues --action labeled --label ops/ready-for-ai --repo o/r --number 1

# $ROUTE_OVERLAY is the env equivalent of --overlay (what the caller workflow sets).
out="$(ROUTE_OVERLAY="$TMP/add.json" bash "$SCRIPT" --event issues --action labeled --label ops/needs-ai --repo o/r --number 1 </dev/null)"
if [ "${out%% *}" = "loop=ops-issue-loop" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: \$ROUTE_OVERLAY honoured — got [$out]"; fi

# --- broken config fails LOUDLY, never as a silent none -------------------
printf '{ not json' > "$TMP/broken.json"
cat > "$TMP/badevent.json" <<'JSON'
{ "version": 2, "routes": [ { "event": "issues.label", "label": "x", "loop": "ops-issue-loop" } ] }
JSON
expect_rc "an unreadable overlay exits 2"        2 -- --overlay "$TMP/broken.json" --event issues --action labeled --label ops/ready-for-ai --repo o/r
expect_rc "a missing overlay file exits 2"       2 -- --overlay "$TMP/nope.json"   --event issues --action labeled --label ops/ready-for-ai --repo o/r
expect_rc "an invented event in a rule exits 2"  2 -- --overlay "$TMP/badevent.json" --event issues --action labeled --label ops/ready-for-ai --repo o/r

# --- the base table itself conforms ---------------------------------------
check_base() { # check_base <name> <jq filter yielding true>
  local got; got="$(jq -r "$2" "$BASE" 2>/dev/null)"
  if [ "$got" = "true" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: base table — $1"; fi
}
check_base "version is 2" '.version == 2'
check_base "every event is in the vocabulary" \
  '[.routes[].event] | all(. as $e | ["issues.labeled","pull_request.labeled","issues.opened","pull_request.opened"] | index($e) != null)'
check_base "every rule has event, label and loop" \
  '.routes | all(has("event") and has("label") and has("loop"))'
check_base "(event,label) is unique" \
  '([.routes[] | [.event, .label]] | length) == ([.routes[] | [.event, .label]] | unique | length)'
check_base 'no rule targets the "none" sentinel' '.routes | all(.loop != "none")'
check_base "every trigger label is namespaced ops/" '.routes | all(.label | startswith("ops/"))'
check_base "it has exactly five rows, because triage is scheduled rather than routed" '(.routes | length) == 5'

# Every loop in the base table must be a name the CATALOG reserves. That cross-check is
# the point of catalog.json carrying reserved_skill_names as data instead of prose.
CATALOG="$HERE/../../../../../catalog.json"
if [ -f "$CATALOG" ]; then
  got="$(jq -r --slurpfile c "$CATALOG" '[.routes[].loop] | all(. as $l | $c[0].reserved_skill_names | index($l) != null)' "$BASE" 2>/dev/null)"
  if [ "$got" = "true" ]; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: base table — every loop must be in catalog.json's reserved_skill_names"; fi
else
  fail=$((fail+1)); echo "FAIL: catalog.json not found at $CATALOG (the reserved-name cross-check cannot run)"
fi

echo "----"
echo "route-event tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
