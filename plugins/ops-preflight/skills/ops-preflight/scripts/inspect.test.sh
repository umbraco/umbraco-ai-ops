#!/usr/bin/env bash
# Tests for inspect.sh. Hermetic: bash + jq only, no network, no build ever run.
#
# The rule under test is the one the whole tool rests on: THERE ARE THREE VERDICTS. Detection
# produces `present` or `unknown` and can never produce a `gap`, because only a human can say
# something is missing. Most of these assert that a miss stays `unknown` — a silent downgrade to
# a pass is the failure this file exists to catch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
I="$HERE/inspect.sh"
[ -f "$I" ] || { echo "FATAL: inspect.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

mkrepo() { local d="$TMP/$1"; mkdir -p "$d"; shift; local f; for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf 'x\n' > "$d/$f"; done; printf '%s' "$d"; }
cf()     { printf '%s' "$2" > "$TMP/$1.json"; printf '%s' "$TMP/$1.json"; }
run()    { local r="$1"; shift; local a=(); local f; for f in "$@"; do a+=(--checks "$f"); done; bash "$I" "$r" --json "${a[@]}" 2>/dev/null; }
v()      { printf '%s' "$1" | jq -r --arg id "$2" '.findings[] | select(.id==$id) | .verdict'; }
src()    { printf '%s' "$1" | jq -r --arg id "$2" '.findings[] | select(.id==$id) | .source // "null"'; }

BASE="$(cf base '{"version":1,"checks":[
  {"id":"has-file","consumer":"ops-change","severity":"blocking","title":"A build file","why":"w","detect":{"any_path":["build.sh"]},"ask":"q"},
  {"id":"no-detect","consumer":"ops-change","severity":"quality","title":"Only a human knows","why":"w","ask":"q"},
  {"id":"no-ask","consumer":"general","severity":"quality","title":"Reported, never asked","why":"w","detect":{"any_path":["never-there"]}},
  {"id":"by-content","consumer":"ops-branching","severity":"blocking","title":"Says branch","why":"w","detect":{"any_file_contains":[{"glob":"DOC.md","pattern":"[Bb]ranch"}]},"ask":"q"}
]}')"

# --- detection: present vs unknown -------------------------------------------
r="$(run "$(mkrepo hit build.sh)" "$BASE")"
check "a matched glob is present"          "present"  "$(v "$r" has-file)"
check "  and its source says it was detected" "detected" "$(src "$r" has-file)"
check "  with the matching path as evidence" "build.sh" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="has-file") | .evidence[0]')"

r="$(run "$(mkrepo miss other.sh)" "$BASE")"
check "a glob that misses is UNKNOWN, never a pass" "unknown" "$(v "$r" has-file)"
check "  and carries no source"            "null" "$(src "$r" has-file)"
check "  and no evidence"                  0      "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="has-file") | .evidence[]] | length')"

# The heart of it: inspect.sh can never produce a `gap`. Only the interview can.
check "NOTHING is ever reported as a gap" 0 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.verdict=="gap")] | length')"
check "  and every verdict is one of the two it may set" 0 \
  "$(printf '%s' "$r" | jq '[.findings[] | select((.verdict | IN("present","unknown")) | not)] | length')"

# A check with no detect block can only ever be unknown here, however the repo looks.
check "a check with no detect stays unknown" "unknown" "$(v "$r" no-detect)"

# --- signal checks: a match means ASK, never pass -----------------------------
# The inversion that a dry run caught. `dotnet-private-feed` found a NuGet.config and reported
# PRESENT for "a restore needs no credential" — a false pass on a BLOCKING check, for exactly the
# repos most likely to fail. A signal match must never resolve anything.
SIG="$(cf signal '{"version":1,"checks":[
  {"id":"risky","consumer":"ops-workspace","severity":"blocking","title":"t","why":"w","signal":true,"detect":{"any_path":["NuGet.config"]},"ask":"q"}
]}')"
r="$(run "$(mkrepo sighit NuGet.config)" "$SIG")"
check "a signal match is NOT a pass"        "unknown" "$(v "$r" risky)"
check "  and says it was a signal"          "signal"  "$(src "$r" risky)"
check "  but keeps the evidence, to seed the question" "NuGet.config" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="risky") | .evidence[0]')"
check "  and still counts as needing an answer" 1 "$(printf '%s' "$r" | jq '.summary.interview')"
check "  and as a blocking unknown"             1 "$(printf '%s' "$r" | jq '.summary.blocking_unknown')"

r="$(run "$(mkrepo sigmiss other.txt)" "$SIG")"
check "a signal that misses is a plain unknown" "unknown" "$(v "$r" risky)"
check "  with no source"                        "null"    "$(src "$r" risky)"

out="$(bash "$I" "$(mkrepo sigtext NuGet.config)" --checks "$SIG" 2>/dev/null)"
check "text mode labels it SIGNAL, not PRESENT" 1 "$(printf '%s' "$out" | grep -c 'SIGNAL')"
check "  and never PRESENT"                     0 "$(printf '%s' "$out" | grep -c 'PRESENT')"

# A signal with no `ask` can never reach any verdict but unknown. That is a dead end, not a check.
bash "$I" "$(mkrepo sigdead)" --checks "$(cf sigdead '{"version":1,"checks":[
  {"id":"dead","consumer":"general","severity":"quality","title":"t","why":"w","signal":true,"detect":{"any_path":["x"]}}]}')" >/dev/null 2>&1
check "a signal check with no ask exits 2" 2 $?

# --- glob semantics: `*` crosses `/` ------------------------------------------
G="$(cf glob '{"version":1,"checks":[
  {"id":"anywhere","consumer":"general","severity":"quality","title":"t","why":"w","detect":{"any_path":["*.sln"]}},
  {"id":"anchored","consumer":"general","severity":"quality","title":"t","why":"w","detect":{"any_path":["scripts/build.sh"]}}
]}')"
r="$(run "$(mkrepo nested a/b/c/Product.sln)" "$G")"
check "a bare *.sln finds one nested deep"  "present" "$(v "$r" anywhere)"
r="$(run "$(mkrepo anch scripts/build.sh)" "$G")"
check "an anchored glob matches at the root" "present" "$(v "$r" anchored)"
r="$(run "$(mkrepo anch2 deep/scripts/build.sh)" "$G")"
check "  and does NOT match the same name nested" "unknown" "$(v "$r" anchored)"

# --- content detection --------------------------------------------------------
d="$(mkrepo doc)"; printf 'we use a branch per line\n' > "$d/DOC.md"
check "a file whose content matches is present" "present" "$(v "$(run "$d" "$BASE")" by-content)"
d="$(mkrepo doc2)"; printf 'nothing relevant here\n' > "$d/DOC.md"
check "  the same file without the pattern is unknown" "unknown" "$(v "$(run "$d" "$BASE")" by-content)"
check "  and a missing file is unknown, not an error"  "unknown" "$(v "$(run "$(mkrepo doc3)" "$BASE")" by-content)"

# --- noisy directories are pruned --------------------------------------------
# Without this, a build output folder or a vendored dependency answers checks about YOUR repo.
# A `.sln` inside node_modules is somebody else's, and counting it is a false present.
r="$(run "$(mkrepo pruned node_modules/dep/Product.sln)" "$G")"
check "a match inside node_modules does not count" "unknown" "$(v "$r" anywhere)"
r="$(run "$(mkrepo pruned2 obj/Debug/Product.sln)" "$G")"
check "  nor one inside obj"                       "unknown" "$(v "$r" anywhere)"

# --- layer merge: later wins, BY FIELD ----------------------------------------
# A profile entry carrying only an id and a detect must inherit title/why/severity from the base.
# If it did not, a stack override would silently blank the report row it replaced.
OV="$(cf ov '{"version":1,"checks":[{"id":"has-file","detect":{"any_path":["other.sh"]}}]}')"
r="$(run "$(mkrepo merged other.sh)" "$BASE" "$OV")"
check "an override replaces the base detect"  "present"     "$(v "$r" has-file)"
check "  and inherits the base title"         "A build file" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="has-file") | .title')"
check "  and the base severity"               "blocking" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="has-file") | .severity')"
r="$(run "$(mkrepo merged2 build.sh)" "$BASE" "$OV")"
check "  and the REPLACED glob no longer matches" "unknown" "$(v "$r" has-file)"

ADD="$(cf add '{"version":1,"checks":[{"id":"extra","consumer":"general","severity":"quality","title":"t","why":"w"}]}')"
check "a later layer can add a new check" 5 \
  "$(printf '%s' "$(run "$(mkrepo addrepo)" "$BASE" "$ADD")" | jq '.findings | length')"

# --- report shape --------------------------------------------------------------
r="$(run "$(mkrepo shape build.sh)" "$BASE")"
check "the summary counts present"        1 "$(printf '%s' "$r" | jq '.summary.present')"
check "  and unknown"                     3 "$(printf '%s' "$r" | jq '.summary.unknown')"
check "  and blocking unknowns separately" 1 "$(printf '%s' "$r" | jq '.summary.blocking_unknown')"
# `interview` must exclude the no-ask check: some misses are worth showing and not worth a
# question, and counting them makes the human expect a question that never comes.
check "  and only the unknowns that have a question" 2 "$(printf '%s' "$r" | jq '.summary.interview')"
check "the sources that produced it are recorded" 1 "$(printf '%s' "$r" | jq '.sources | length')"

# --- grouping order --------------------------------------------------------------
# Not cosmetic: the skill asks its questions in printed order, and the order is the order a repo
# hits the problems — no workspace, then no verify, then no release.
O="$(cf order '{"version":1,"checks":[
  {"id":"z-gen","consumer":"general","severity":"quality","title":"t","why":"w"},
  {"id":"a-rel","consumer":"ops-release","severity":"quality","title":"t","why":"w"},
  {"id":"a-ws","consumer":"ops-workspace","severity":"quality","title":"t","why":"w"},
  {"id":"a-chg","consumer":"ops-change","severity":"quality","title":"t","why":"w"}
]}')"
check "groups come out in consumer order, not alphabetically" \
  "ops-workspace ops-change ops-release general" \
  "$(printf '%s' "$(run "$(mkrepo ord)" "$O")" | jq -r '[.findings[].consumer] | join(" ")')"

S2="$(cf sev '{"version":1,"checks":[
  {"id":"b-quality","consumer":"general","severity":"quality","title":"t","why":"w"},
  {"id":"a-blocking","consumer":"general","severity":"blocking","title":"t","why":"w"}
]}')"
check "blocking sorts before quality within a group" "a-blocking b-quality" \
  "$(printf '%s' "$(run "$(mkrepo sev)" "$S2")" | jq -r '[.findings[].id] | join(" ")')"

# --- text mode says what unknown means -------------------------------------------
# The one sentence that must never be dropped: a reader who takes `unknown` for a pass has been
# told the opposite of the truth.
out="$(bash "$I" "$(mkrepo text build.sh)" --checks "$BASE" 2>/dev/null)"
check "text mode warns that unknown is not a pass" 1 "$(printf '%s' "$out" | grep -c 'UNKNOWN IS NOT A PASS')"
check "text mode prints the evidence for a present" 1 "$(printf '%s' "$out" | grep -c 'found: build.sh')"
check "text mode prints why an unknown matters"     "yes" \
  "$([ "$(printf '%s' "$out" | grep -c 'why:')" -ge 1 ] && echo yes || echo no)"

# --- failure modes ------------------------------------------------------------
bash "$I" >/dev/null 2>&1;                                check "no argument exits 2" 2 $?
bash "$I" "$TMP/absent" >/dev/null 2>&1;                  check "a missing directory exits 2" 2 $?
bash "$I" "$(mkrepo f1)" --checks "$TMP/nope.json" >/dev/null 2>&1
check "a missing check file exits 2" 2 $?
bash "$I" "$(mkrepo f2)" --checks "$(cf bad '{ not json')" >/dev/null 2>&1
check "an unreadable check file exits 2" 2 $?
bash "$I" "$(mkrepo f3)" --checks "$(cf empty '{"version":1,"checks":[]}')" >/dev/null 2>&1
check "an empty checks array exits 2" 2 $?

# A duplicate id inside ONE file is always an authoring mistake: the second silently wins and the
# first check is never evaluated, which looks exactly like it passed.
bash "$I" "$(mkrepo f4)" --checks "$(cf dup '{"version":1,"checks":[
  {"id":"same","consumer":"general","severity":"quality","title":"t","why":"w"},
  {"id":"same","consumer":"general","severity":"quality","title":"t","why":"w"}]}')" >/dev/null 2>&1
check "a repeated id in one file exits 2" 2 $?

# A NEW check that arrives without the fields the report needs would render as a blank row.
bash "$I" "$(mkrepo f5)" --checks "$(cf incomplete '{"version":1,"checks":[{"id":"thin","detect":{"any_path":["x"]}}]}')" >/dev/null 2>&1
check "an incomplete check exits 2" 2 $?
bash "$I" "$(mkrepo f6)" --checks "$(cf badsev '{"version":1,"checks":[
  {"id":"s","consumer":"general","severity":"critical","title":"t","why":"w"}]}')" >/dev/null 2>&1
check "a severity outside blocking|quality exits 2" 2 $?

# --- the shipped catalog holds to its own rules ---------------------------------
SHIPPED="$HERE/checks.json"
check "the shipped catalog parses"        0 "$(jq empty "$SHIPPED" >/dev/null 2>&1; echo $?)"
check "  every check has the required fields" 0 \
  "$(jq '[.checks[] | select((.consumer//"")=="" or (.title//"")=="" or (.why//"")=="" or ((.severity//"") | IN("blocking","quality") | not))] | length' "$SHIPPED")"
check "  ids are unique"                  0 \
  "$(jq '[.checks[].id] | length - (unique | length)' "$SHIPPED")"
check "  ids are kebab-case slugs"        0 \
  "$(jq '[.checks[].id | select(test("^[a-z][a-z0-9-]*$") | not)] | length' "$SHIPPED")"
# The golden rule, enforced rather than trusted. A product name or a product's tool in the ENGINE
# base is exactly the thing a repo's own override file exists to hold instead.
check "  no product name or tool leaks into the engine base" "" \
  "$(jq -r '[.checks[] | (.title + " " + .why + " " + (.ask // "")) | ascii_downcase
            | select(test("umbraco|npm |yarn |stylecop|nuget"))] | join("; ")' "$SHIPPED")"
check "  every consumer is a real capability or plugin" "" \
  "$(jq -r '[.checks[].consumer | select((. | IN("ops-workspace","ops-change","ops-branching","ops-release","ops-learnings","general")) | not)] | unique | join(", ")' "$SHIPPED")"
# A blocking check nobody can be asked about is a dead end: detection may miss it and then there
# is no way to resolve it at all.
check "  every blocking check is either detectable or askable" "" \
  "$(jq -r '[.checks[] | select(.severity=="blocking" and (has("detect")|not) and (has("ask")|not)) | .id] | join(", ")' "$SHIPPED")"

# --- dual-stack merge: two matching STACK profiles are additive, not a winner-take-all ---------
# select-profile.sh's own contract is that stacks are ADDITIVE ("nothing picks one winner"). This
# goes through the REAL auto-discovery path (no --checks), because the additive merge only exists
# there: a repo matching two stack profiles that both override the same check id used to have
# whichever profile sorted last silently erase the other's `detect`, even though a repo genuinely
# holding both stacks needs both sets of evidence.
STACKDIR="$TMP/stackprofiles"; mkdir -p "$STACKDIR"
DUALBASE="$(cf dualbase '{"version":1,"checks":[
  {"id":"shared-check","consumer":"ops-change","severity":"blocking","title":"t","why":"w","ask":"q"}
]}')"
printf '%s' '{"version":1,"profile":"a-stack","when":{"any_path":["marker-a"]},
  "checks":[{"id":"shared-check","detect":{"any_path":["only-in-a"]}}]}' > "$STACKDIR/a-stack.json"
printf '%s' '{"version":1,"profile":"b-stack","when":{"any_path":["marker-b"]},
  "checks":[{"id":"shared-check","detect":{"any_path":["only-in-b"]}}]}' > "$STACKDIR/b-stack.json"

dualrun() { OPS_PREFLIGHT_CHECKS="$DUALBASE" OPS_PREFLIGHT_PROFILES="$STACKDIR" bash "$I" "$1" --json 2>/dev/null; }

d="$(mkrepo dualstack marker-a marker-b only-in-a)"
r="$(dualrun "$d")"
check "both matching stack profiles are recorded as sources" 2 \
  "$(printf '%s' "$r" | jq '[.sources[] | select(test("-stack\\.json$"))] | length')"
check "  the FIRST stack's glob alone still detects present — nothing erased" "present" "$(v "$r" shared-check)"
check "  with its own evidence intact" "only-in-a" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="shared-check") | .evidence[0]')"

r2="$(dualrun "$(mkrepo dualstack2 marker-a marker-b only-in-b)")"
check "  and the SECOND stack's glob alone also still detects present" "present" "$(v "$r2" shared-check)"

# --- shipped false-pass fixes, on a blocking check, through the real auto-discovery path -------
# Both reproduce a false PRESENT this PR fixes: a match that used to skip the interview question
# on the check most likely to matter is now, at worst, `unknown` — never a silent pass.
d="$(mkrepo npmplaceholder)"
printf '%s' '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}' > "$d/package.json"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "npm's own placeholder test script is not mistaken for a real one" "unknown" "$(v "$r" verify-test-command)"

d="$(mkrepo dotnetrun Directory.Build.props scripts/run-evals.sh)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a script merely named *run* does not silently pass the runnable-instance check" "unknown" \
  "$(v "$r" dotnet-runnable-instance)"
check "  its source says signal, so the interview opens with what was found" "signal" \
  "$(src "$r" dotnet-runnable-instance)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
