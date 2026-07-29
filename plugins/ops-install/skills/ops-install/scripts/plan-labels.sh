#!/usr/bin/env bash
# Work out which labels to create, with what name, on which repo.
#
# This used to be a manual step in a list, which was the right call when label names were prose
# in twenty files. It is not any more: the names are `ops/`-namespaced defaults, a repo's
# overrides are declared data, and which repo each label belongs on falls out of the topology
# roles. All three are now readable, so the answer is computable and there is no reason to make
# a human copy label names out of a document.
#
# It PLANS, it does not create. Creating is a write against GitHub and goes through
# `github-ops` → `create-label` from the skill. Keeping the decision here makes it
# deterministic and testable; keeping the write there keeps auth and the forge mechanism in one
# place.
#
# Which repo gets which label follows the operation → role table (conformance spec §7.3): a
# label applied to an issue belongs on the `issues` repo, a label applied to a PR on `code`, and
# the learnings labels on `learnings`. A role that is not declared falls back to the code repo,
# so a single-repo project gets every label on the one repo without special-casing.
#
# Usage:
#   plan-labels.sh <repo-root> [--json]
#   plan-labels.sh <repo-root> --code owner/name [--json]
#
# Output: one row per label — purpose, label, repo, colour, description.
set -uo pipefail

repo="" code="" fmt="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --code) code="${2:-}"; shift 2 ;;
    --json) fmt="json"; shift ;;
    *) [ -z "$repo" ] && repo="$1"; shift ;;
  esac
done

[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root> [--code owner/name] [--json]" >&2; exit 2; }
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# The code repo: given, else the git remote. A declared `topology.code` still wins over both —
# on the issues repo of a split topology the remote is the issues repo, so the declaration is
# the only correct answer there.
if [ -z "$code" ]; then
  origin="$(git -C "$repo" config --get remote.origin.url 2>/dev/null || true)"
  # Trailing slashes come off BEFORE `.git`, not after: a clone URL legitimately ends in one
  # (`https://github.com/owner/name/`), and `owner/name.git/` would otherwise keep its `.git`
  # because the anchor no longer matches. Without any of this, every --repo carries the slash
  # through to `gh` as `owner/name/`. Found dry-running against a real clone whose origin has one.
  code="$(printf '%s' "$origin" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#/+$##; s#\.git$##')"
fi
[ -n "$code" ] || { echo "ERROR: cannot resolve the code repo — pass --code owner/name" >&2; exit 2; }

meta="$repo/.claude/ops-repo-meta.json"
declared='{}'
if [ -f "$meta" ]; then
  jq empty "$meta" 2>/dev/null || { echo "ERROR: $meta is not valid JSON — run validate-repo-meta.sh" >&2; exit 2; }
  declared="$(cat "$meta")"
fi

# purpose | default label | role | colour | description
# Colours carried over from the prototype so a repo onboarded by either looks the same.
plan="$(jq -n --arg code "$code" --argjson d "$declared" '
  def rows: [
    ["ready",            "ops/ready-for-ai",    "issues",    "0e8a16", "Hand this issue to the AI issue loop. The only gate it acts on."],
    ["in_progress",      "ops/in-progress",     "issues",    "1d76db", "A loop is working this issue right now. On while work is in flight, off when it ends."],
    ["done",             "ops/generated-by-ai", "issues",    "c5def5", "Finished by a loop, with a green PR. Provenance, so it stays on after the work is done."],
    ["blocked",          "ops/ai-blocked",      "issues",    "d93f0b", "The loop gave up; the comment says why. Re-add the ready label to retry."],
    ["land",             "ops/auto-merge",      "code",      "0e8a16", "Approved to land. The deliberate human go-signal the merge loop requires."],
    ["rework",           "ops/auto-rework",     "code",      "fbca04", "Address the review feedback on this PR, then hand it back."],
    ["release",          "ops/auto-release",    "issues",    "0e8a16", "Ship the version named in this issue title."],
    ["release_blocked",  "ops/release-blocked", "issues",    "d93f0b", "A release was stopped by the pre-publish review."],
    ["proto_learning",   "ops/proto-learning",  "learnings", "c5def5", "A raw captured lesson, awaiting triage. Filed by a hook, never by hand."],
    ["triaged",          "ops/triaged",         "learnings", "ededed", "Triage has routed this. Written by the triage sweep; never a trigger."],
    ["loop_improvement", "ops/loop-improvement","learnings", "5319e7", "A change to the loop itself, promoted from a lesson."]
  ];
  ($d.topology // {}) as $t
  | ($d.labels // {}) as $l
  | [ rows[]
      | { purpose: .[0],
          label:   ($l[.[0]] // .[1]),
          role:    .[2],
          repo:    ($t[.[2]] // $t.code // $code),
          colour:  .[3],
          description: .[4],
          overridden: (($l[.[0]] // null) != null) } ]
')"

if [ "$fmt" = "json" ]; then
  printf '%s' "$plan" | jq -c '{ labels: ., summary: { total: length, repos: (map(.repo) | unique) } }'
  exit 0
fi

printf 'Labels to create for %s\n\n' "$code"
printf '%s' "$plan" | jq -r '.[] | "\(.repo)\t\(.label)\t\(.colour)\t\(if .overridden then "(override)" else "" end)"' \
  | sort | while IFS=$'\t' read -r r l c o; do printf '  %-34s %-24s #%s %s\n' "$r" "$l" "$c" "$o"; done
printf '\n  %s label(s) across %s repo(s)\n' \
  "$(printf '%s' "$plan" | jq 'length')" \
  "$(printf '%s' "$plan" | jq '[.[].repo] | unique | length')"
printf '\n  Create each with github-ops -> create-label. It is idempotent, so re-running is safe.\n'
