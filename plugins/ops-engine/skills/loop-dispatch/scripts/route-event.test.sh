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
# What the schema actually tells the ISSUES repo to write: declare the roles that are NOT this
# repo, so `code` alone. The router used to require `issues` to be present and to match the
# event repo before it would read `code`, so this exact file produced NO target and the routine
# ran in the issues repo, silently. Kept as its own case because it is the conformant shape.
cat > "$TMP/meta-codeonly.json" <<'JSON'
{ "version": 1, "topology": { "code": "own/code" } }
JSON

out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-split.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/issues number=5 target=own/code" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: target derived from declared topology — got [$out]"; fi

out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-codeonly.json" --event issues --action labeled --label ops/ready-for-ai --number 5 --repo own/issues </dev/null)"
if [ "$out" = "loop=ops-issue-loop repo=own/issues number=5 target=own/code" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a code-only file (the conformant issues-repo shape) must still resolve a target — got [$out]"; fi

# The same file sitting on the CODE repo names its own repo. That is redundant rather than
# wrong, and it must not emit a self-target.
out="$(bash "$SCRIPT" --repo-meta "$TMP/meta-codeonly.json" --event pull_request --action labeled --label ops/auto-merge --number 9 --repo own/code </dev/null)"
if [ "$out" = "loop=ops-merge-loop repo=own/code number=9" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a redundantly self-declared code repo must emit no target — got [$out]"; fi

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
  '[.routes[].event] | all(. as $e | ["issues.labeled","pull_request.labeled","issues.opened","pull_request.opened","check_suite.completed"] | index($e) != null)'
check_base "every rule has event, label and loop" \
  '.routes | all(has("event") and has("label") and has("loop"))'
check_base "(event,label) is unique" \
  '([.routes[] | [.event, .label]] | length) == ([.routes[] | [.event, .label]] | unique | length)'
check_base 'no rule targets the "none" sentinel' '.routes | all(.loop != "none")'
# A label event's label is ours and namespaced; an event that carries no label (a CI run
# finishing) has "" and must say, by `require_pr_label`, which ops/ label it is for.
check_base "every trigger label is namespaced ops/" \
  '.routes | all(if .label == "" then .event == "check_suite.completed" else (.label | startswith("ops/")) end)'
check_base "a label-less rule names the ops/ label it acts for" \
  '.routes | map(select(.label == "")) | all(.require_pr_label | type == "string" and startswith("ops/"))'
check_base "every rule-named condition label is namespaced ops/" \
  '.routes | all(([.defer_while_open_to, .require_pr_label] | map(select(. != null))) | all(startswith("ops/")))'
# Five label routes plus one that wakes the merge loop when CI finishes. Triage is still
# scheduled rather than routed, which is why there is no sixth label.
check_base "it has exactly six rows: five labels and one CI-finished wake-up" '(.routes | length) == 6'

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

# --- the prose renderings of the base table must not drift from it ---------
# Two documents render this table by hand for a human: loop-dispatch's SKILL.md (which is also
# where the dispatcher reads what to do with each loop) and the locked routine prompt. Both had
# gone stale by one row — the `ops/port` rule was missing from each, so a fire carrying
# `loop=ops-port-loop` reached a dispatcher whose own list did not mention it. A generator for two
# prose tables would be overkill; asserting every row is present is not.
SKILL="$HERE/../SKILL.md"
PROMPT="$HERE/../../new-loop-routine/references/routine-prompts.md.template"
while IFS=$'\t' read -r lbl loop; do
  [ -n "$lbl" ] || continue
  for doc in "$SKILL" "$PROMPT"; do
    if [ ! -f "$doc" ]; then
      fail=$((fail+1)); echo "FAIL: $doc not found (the rendered-table check cannot run)"; continue
    fi
    if grep -qF "$lbl" "$doc" && grep -qF "$loop" "$doc"; then pass=$((pass+1))
    else
      fail=$((fail+1))
      echo "FAIL: $(basename "$doc") does not render the base rule $lbl -> $loop"
    fi
  done
done < <(jq -r '.routes[] | "\(.label)\t\(.loop)"' "$BASE" | tr -d '\r')

# --- every routed event is one the caller workflow actually subscribes to ---
# A rule for an event the caller never listens for is a rule that never fires, and nothing
# errors: GitHub simply does not run the workflow. Adding the CI-finished route meant adding
# `check_suite` to the caller template; this keeps the two from drifting apart again.
CALLER="$HERE/../../new-loop-routine/references/loop-dispatch.yml.template"
if [ -f "$CALLER" ]; then
  while IFS= read -r ev; do
    case "${ev%%.*}" in
      issues)       trig="issues" ;;
      pull_request) trig="pull_request_target" ;;  # labels use _target; see the template header
      *)            trig="${ev%%.*}" ;;
    esac
    if grep -qE "^  ${trig}:" "$CALLER"; then pass=$((pass+1))
    else fail=$((fail+1)); echo "FAIL: the caller template does not subscribe to '$trig', so rule event $ev never fires"; fi
  done < <(jq -r '[.routes[].event] | unique[]' "$BASE" | tr -d '\r')
  if grep -qE '^ +pull-requests: read' "$CALLER"; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: the caller template does not grant pull-requests: read, so the CI-finished route can never see a PR's labels"; fi
else
  fail=$((fail+1)); echo "FAIL: caller template not found at $CALLER"
fi

# --- the port rule defers to the landing label while the PR is open ---------
# 22-09-2026: a maintainer put `ops/auto-merge` and `ops/port` on an open PR in the same second.
# Two labelled events, so two loops fired: the merge loop, which landed the PR and handed it to
# the port loop as designed, AND the port loop straight from the label. The same change was
# ported twice and two v17 PRs were opened, for each of two PRs. The check inside the port loop
# ("not merged yet, stop") could not catch it, because the session read the PR after the merge.
# So the decision moved to the edge, where the payload says what the PR looked like when the
# label went on. These cases are that contract.
pr_event() { # pr_event <label-that-fired> <merged:true|false> <labels on the PR...>
  local fired="$1" merged="$2"; shift 2
  jq -nc --arg f "$fired" --argjson m "$merged" --args '{
    action: "labeled", label: {name: $f},
    pull_request: {number: 309, merged: $m, labels: ($ARGS.positional | map({name: .}))},
    repository: {full_name: "o/r"} }' "$@"
}
expect_json "open PR, port + landing label: port DEFERS to the merge loop" \
  "loop=none repo=o/r number=309" "$(pr_event ops/port false ops/auto-merge ops/port)" pull_request_target
expect_json "  the landing label on the same PR still fires the merge loop" \
  "loop=ops-merge-loop repo=o/r number=309" "$(pr_event ops/auto-merge false ops/auto-merge ops/port)" pull_request_target
expect_json "  and the order the labels went on does not matter" \
  "loop=none repo=o/r number=309" "$(pr_event ops/port false ops/port ops/auto-merge)" pull_request_target
expect_json "open PR, port label alone: the port loop fires (and waits for the merge itself)" \
  "loop=ops-port-loop repo=o/r number=309" "$(pr_event ops/port false ops/port)" pull_request_target
# The case the port rule exists for: a human labels a PR that has already landed. The landing
# label stays on after a merge, so its presence alone must not defer.
expect_json "MERGED PR carrying the landing label: port still fires" \
  "loop=ops-port-loop repo=o/r number=309" "$(pr_event ops/port true ops/auto-merge ops/port)" pull_request_target

err="$(pr_event ops/port false ops/auto-merge ops/port | bash "$SCRIPT" --event pull_request_target 2>&1 >/dev/null)"
if printf '%s' "$err" | grep -q 'deferred: PR #309 is open and carries ops/auto-merge'; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a deferral does not say why on stderr — got [$err]"; fi

# By hand, the same rule, and an UNKNOWN state never defers: better one port too many, caught by
# the port loop's own claim, than a port silently dropped.
expect_loop "flags, open + landing label: defers"   none          -- --event pull_request --action labeled --label ops/port --number 9 --repo o/r --pr-merged false --pr-label ops/auto-merge
expect_loop "flags, no PR state given: fires"       ops-port-loop -- --event pull_request --action labeled --label ops/port --number 9 --repo o/r --pr-label ops/auto-merge
expect_loop "flags, merged: fires"                  ops-port-loop -- --event pull_request --action labeled --label ops/port --number 9 --repo o/r --pr-merged true --pr-label ops/auto-merge

# An overlay rule replaces the base rule whole, including this field. Documented in the overlay
# schema; asserted here so the behaviour is a decision, not an accident.
printf '{"routes":[{"event":"pull_request.labeled","label":"ops/port","loop":"ops-port-loop"}]}' > "$TMP/port-nodefer.json"
out="$(pr_event ops/port false ops/auto-merge ops/port | bash "$SCRIPT" --event pull_request_target --overlay "$TMP/port-nodefer.json")"
if [ "$out" = "loop=ops-port-loop repo=o/r number=309" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: an overlay without defer_while_open_to should fire — got [$out]"; fi
printf '{"routes":[{"event":"pull_request.labeled","label":"ops/port","loop":"ops-port-loop","defer_while_open_to":"land-me"}]}' > "$TMP/port-renamed.json"
out="$(pr_event ops/port false land-me ops/port | bash "$SCRIPT" --event pull_request_target --overlay "$TMP/port-renamed.json")"
if [ "$out" = "loop=none repo=o/r number=309" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: an overlay naming a renamed landing label should defer to it — got [$out]"; fi

# --- a CI run finishing wakes the merge loop, but only for a labelled, green PR -
# The merge loop waits at most 15 minutes for CI in one run, and a Forms build takes longer, so a
# PR labelled while its build ran sat green and labelled until something else woke the loop. The
# check suite finishing is that something. Its payload names the PR but not the PR's labels; the
# edge workflow looks them up and passes --number / --pr-label, which win over the payload.
suite() { # suite <conclusion> [pr-number...]
  local c="$1"; shift
  jq -nc --arg c "$c" --args '{action: "completed",
    check_suite: {conclusion: $c, app: {slug: "azure-pipelines"},
                  pull_requests: ($ARGS.positional | map({number: (. | tonumber)}))},
    repository: {full_name: "o/r"}}' "$@"
}
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
route_suite() { # route_suite <payload> [flags...]
  local p="$1"; shift
  printf '%s' "$p" | bash "$SCRIPT" --event check_suite "$@" 2>/dev/null
}
got="$(route_suite "$(suite success 1540)" --number 1540 --pr-label ops/auto-merge)"
check "green build on a PR labelled to land wakes the merge loop" "loop=ops-merge-loop repo=o/r number=1540" "$got"
got="$(route_suite "$(suite success 1540)" --pr-label ops/auto-merge)"
check "  the PR number comes from the payload when not passed" "loop=ops-merge-loop repo=o/r number=1540" "$got"
got="$(route_suite "$(suite success 1540)" --number 77 --pr-label ops/auto-merge)"
check "  and a passed --number wins over it" "loop=ops-merge-loop repo=o/r number=77" "$got"
got="$(route_suite "$(suite success 1540)" --number 1540 --pr-label ops/port)"
check "green build on a PR NOT labelled to land wakes nothing" "loop=none repo=o/r number=1540" "$got"
got="$(route_suite "$(suite success 1540)" --number 1540)"
check "  nor does one whose labels were never passed" "loop=none repo=o/r number=1540" "$got"
got="$(route_suite "$(suite failure 1540)" --number 1540 --pr-label ops/auto-merge)"
check "a RED build wakes nothing, even on a labelled PR" "loop=none repo=o/r number=1540" "$got"
got="$(route_suite "$(suite success)")"
check "a build on a branch with no PR wakes nothing" "loop=none repo=o/r number=" "$got"

err="$(suite failure 1540 | bash "$SCRIPT" --event check_suite --number 1540 --pr-label ops/auto-merge 2>&1 >/dev/null)"
check "  a red build says why on stderr" 1 "$(printf '%s' "$err" | grep -c 'conclusion is "failure", the rule needs "success"')"
err="$(suite success 1540 | bash "$SCRIPT" --event check_suite --number 1540 2>&1 >/dev/null)"
check "  and so does a missing label" 1 "$(printf '%s' "$err" | grep -c 'PR #1540 does not carry ops/auto-merge')"

# A label event is untouched by the new conditions: it has none.
expect_loop "the ops/auto-merge label still wakes the merge loop on its own" ops-merge-loop \
  -- --event pull_request --action labeled --label ops/auto-merge --number 42 --repo o/r

# A repo that renamed its landing label overrides the rule and names its own.
printf '{"routes":[{"event":"check_suite.completed","label":"","loop":"ops-merge-loop","require_conclusion":"success","require_pr_label":"land-me"}]}' > "$TMP/suite-renamed.json"
got="$(route_suite "$(suite success 5)" --overlay "$TMP/suite-renamed.json" --pr-label land-me)"
check "an overlay's renamed landing label is honoured" "loop=ops-merge-loop repo=o/r number=5" "$got"
printf '{"routes":[{"event":"check_suite.completed","label":"","loop":null}]}' > "$TMP/suite-off.json"
got="$(route_suite "$(suite success 5)" --overlay "$TMP/suite-off.json" --pr-label ops/auto-merge)"
check "  and an overlay can switch the wake-up off" "loop=none repo=o/r number=5" "$got"

echo "----"
echo "route-event tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
