#!/usr/bin/env bash
# route-event.sh — deterministic loop-dispatch router.
#
# Decides which framework loop (if any) a GitHub webhook event maps to. A pure function
# of the event fields: same inputs, same output, no model judgement. Runs at the EDGE, in
# a GitHub Action, with no Claude session — so it MUST NOT depend on invoking any skill.
#
# The mapping is DATA, in two layers:
#   BASE     route-map.json             shipped here, versioned by the caller's @ref
#   OVERLAY  .github/ops-routing.json   committed in the consumer repo, optional
# The effective table is base + overlay. A rule's identity is the pair (event, label);
# an overlay rule with the same key WINS, and `"loop": null` DISABLES the base rule.
# A consumer never edits the base table.
#
# Inputs (in priority order):
#   1. flags: --event --action --label --number --repo --target --overlay
#   2. a raw GitHub event JSON on stdin or at $GITHUB_EVENT_PATH (parsed with jq);
#      the event NAME comes from --event or $GITHUB_EVENT_NAME (it's an HTTP header,
#      not part of the JSON body).
#
# Output: one line of `key=value` pairs on stdout:
#   loop=<name|none> repo=<r> number=<n>[ target=<t>]
# loop=none means "not ours — quiet no-op". `none` is a normal outcome, not an error,
# and exits 0.
#
# EXIT CODES
#   0  a loop was resolved, or nothing matched (loop=none)
#   2  the router is broken or misconfigured: no jq, no base table, unreadable JSON, or
#      a rule whose `event` is outside the vocabulary. It fails LOUDLY rather than
#      printing loop=none, because a silent no-op means loops stop firing invisibly.
#
# EVENT VOCABULARY (conformance spec section 6.2) — `<github event>.<action>`, collapsed:
#   issues.labeled . pull_request.labeled . issues.opened . pull_request.opened
# `pull_request_target.labeled` is normalised to `pull_request.labeled`: the PR-label
# triggers use pull_request_target because it runs from the base repo's DEFAULT branch
# with secrets, so it reaches dev-based loop PRs that plain `pull_request` does not.
# An event outside the vocabulary resolves to loop=none; a RULE outside it is an error.
#
# CROSS-REPO ISSUES: when a repo's issues live in a SEPARATE repo from its code (e.g.
# Umbraco.Forms.Issues -> the Forms code repo), the caller workflow committed in the issues
# repo passes --target <code repo> (or sets $TARGET_REPO). `repo` stays the event's repo
# (where the label fired); `target` is the repo the routine should actually work in. When
# no target is given, event repo == work repo and `target=` is omitted from the output.
set -uo pipefail

event="" action="" label="" number="" repo="" target="${TARGET_REPO:-}" overlay="${ROUTE_OVERLAY:-}"
repo_meta="${REPO_META:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --event)     event="${2:-}";     shift 2 ;;
    --action)    action="${2:-}";    shift 2 ;;
    --label)     label="${2:-}";     shift 2 ;;
    --number)    number="${2:-}";    shift 2 ;;
    --repo)      repo="${2:-}";      shift 2 ;;
    --target)    target="${2:-}";    shift 2 ;;
    --overlay)   overlay="${2:-}";   shift 2 ;;
    --repo-meta) repo_meta="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

die() { printf 'route-event.sh: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required at the edge but was not found"

# If the decision fields weren't passed, try a raw event payload (stdin or
# $GITHUB_EVENT_PATH). `action` only ever comes from the payload, so its absence is the
# signal to parse — even when --event was supplied (the event NAME is a header, not body).
if [ -z "$action" ]; then
  payload=""
  if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
    payload="$(cat "$GITHUB_EVENT_PATH")"
  elif [ ! -t 0 ]; then
    payload="$(cat)"
  fi
  if [ -n "$payload" ]; then
    event="${event:-${GITHUB_EVENT_NAME:-}}"
    action="$(printf '%s' "$payload" | jq -r '.action // empty' 2>/dev/null)"
    label="$(printf '%s'  "$payload" | jq -r '.label.name // empty' 2>/dev/null)"
    number="$(printf '%s' "$payload" | jq -r '(.issue.number // .pull_request.number // .number) // empty' 2>/dev/null)"
    repo="$(printf '%s'   "$payload" | jq -r '.repository.full_name // empty' 2>/dev/null)"
  fi
fi

# Normalise pull_request_target, then compose the vocabulary key.
[ "$event" = "pull_request_target" ] && event="pull_request"
key=""
[ -n "$event" ] && [ -n "$action" ] && key="$event.$action"

base="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/route-map.json"
[ -f "$base" ] || die "no base routing table at $base"
jq empty "$base" 2>/dev/null || die "base routing table is not valid JSON: $base"

ov_json='{"routes":[]}'
if [ -n "$overlay" ]; then
  [ -f "$overlay" ] || die "overlay was specified but does not exist: $overlay"
  jq empty "$overlay" 2>/dev/null || die "routing overlay is not valid JSON: $overlay"
  ov_json="$(cat "$overlay")"
fi

# Merge base + overlay and resolve in ONE jq pass, so the merge semantics live in one
# place rather than half in bash:
#   * INDEX by (event, label) gives each layer's rules a stable identity. The key is the
#     JSON encoding of the pair, so no separator character can collide with a label.
#   * `+` on the two objects makes the overlay win on a shared key.
#   * a surviving rule with loop == null is a DISABLE, so it resolves to none.
#   * a rule whose event is outside the vocabulary is FATAL. A typo'd rule that silently
#     never fires is the worst failure this script can have, so it is not tolerated.
# An event outside the vocabulary needs no special case: it cannot match a validated
# rule, so it falls through to none.
loop="$(jq -nr --arg ev "$key" --arg lb "$label" --argjson ov "$ov_json" --slurpfile b "$base" '
  def rules: (.routes // []);
  def ident: [.event, (.label // "")] | tojson;
  def check($vocab): reduce rules[] as $r (.;
    if ($vocab | index($r.event)) == null
    then error("rule event is outside the vocabulary: \($r.event)")
    else . end);

  ["issues.labeled", "pull_request.labeled", "issues.opened", "pull_request.opened"] as $vocab
  | ([$ev, $lb] | tojson) as $want
  | ($b[0] | check($vocab)) as $base
  | ($ov   | check($vocab)) as $overlay
  | (INDEX($base | rules[]; ident) + INDEX($overlay | rules[]; ident)) as $effective
  | ($effective[$want] // null) as $hit
  | if $hit == null or $hit.loop == null then "none" else $hit.loop end
' 2>&1)" || die "$(printf '%s' "$loop" | sed 's/^jq: error[^:]*: //')"
[ -z "$loop" ] && loop="none"

# Derive the cross-repo target from the repo's DECLARED facts when it was not passed in.
#
# The split-topology fact used to live twice: once as `with.target_repo` in the caller workflow,
# and once inside the repo's `ops-repo-meta`. One fact, hand-written in two files in two repos,
# with nothing to catch them disagreeing — the same drift pattern as the old `ci.provider`
# spelling split. So the file is the single source and this reads it.
#
# `topology.code` IS the key to read, and it is the ONLY one. The declared-facts rule is
# "declare the roles that are NOT the repo this file lives in", so the file on the issues repo
# of a split topology names `code` and nothing else — naming `issues` there would be declaring
# what the file is already sitting in. An earlier version required `topology.issues` to be
# present AND to equal the event repo before it would read `code`, which meant the conformant
# file produced no target at all: the routine then ran in the issues repo, silently, and
# nothing failed. Read `code` on its own; the emit below drops it when it is this repo anyway,
# so a code repo that declares its own name redundantly still gets no target.
if [ -z "$target" ] && [ -n "$repo_meta" ] && [ -f "$repo_meta" ] && jq empty "$repo_meta" 2>/dev/null; then
  target="$(jq -r '.topology.code // empty' "$repo_meta" 2>/dev/null | tr -d '\r')"
fi

# Only emit target= when a distinct work-repo was supplied (cross-repo case). Same-repo
# consumers get the unchanged `loop= repo= number=` output.
if [ -n "$target" ] && [ "$target" != "$repo" ]; then
  printf 'loop=%s repo=%s number=%s target=%s\n' "$loop" "$repo" "$number" "$target"
else
  printf 'loop=%s repo=%s number=%s\n' "$loop" "$repo" "$number"
fi
exit 0
