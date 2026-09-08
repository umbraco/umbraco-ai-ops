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
  {"id":"has-file","consumer":"ops-change","severity":"blocking","section":"Backend","title":"A build file","why":"w","detect":{"any_path":["build.sh"]},"ask":"q"},
  {"id":"no-detect","consumer":"ops-change","severity":"quality","section":"Testing","title":"Only a human knows","why":"w","ask":"q"},
  {"id":"no-ask","consumer":"general","severity":"quality","section":"Utilities","title":"Reported, never asked","why":"w","detect":{"any_path":["never-there"]}},
  {"id":"by-content","consumer":"ops-branching","severity":"blocking","section":"Best practices","title":"Says branch","why":"w","detect":{"any_file_contains":[{"glob":"DOC.md","pattern":"[Bb]ranch"}]},"ask":"q"},
  {"id":"no-detect-blocking","consumer":"ops-release","severity":"blocking","section":"Release management","title":"Only a human knows, and it blocks","why":"w","ask":"q"}
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

# The core rule from CLAUDE.md — "a gate that cannot run reports blocked, never pass" — applies
# just as much at severity blocking as it does at quality. A BLOCKING check with nothing to detect
# must never resolve to anything but unknown, however clean the repo looks.
check "a BLOCKING check with no detect ALSO stays unknown, never a pass" "unknown" "$(v "$r" no-detect-blocking)"

# --- signal checks: a match means ASK, never pass -----------------------------
# The inversion that a dry run caught. `dotnet-private-feed` found a NuGet.config and reported
# PRESENT for "a restore needs no credential" — a false pass on a BLOCKING check, for exactly the
# repos most likely to fail. A signal match must never resolve anything.
SIG="$(cf signal '{"version":1,"checks":[
  {"id":"risky","consumer":"ops-workspace","severity":"blocking","section":"Environment","title":"t","why":"w","signal":true,"detect":{"any_path":["NuGet.config"]},"ask":"q"}
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
  {"id":"dead","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w","signal":true,"detect":{"any_path":["x"]}}]}')" >/dev/null 2>&1
check "a signal check with no ask exits 2" 2 $?

# --- glob semantics: `*` crosses `/` ------------------------------------------
G="$(cf glob '{"version":1,"checks":[
  {"id":"anywhere","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w","detect":{"any_path":["*.sln"]}},
  {"id":"anchored","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w","detect":{"any_path":["scripts/build.sh"]}}
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

# --- a git worktree is scratch, not the repo (a real dry run's worst finding) -------------------
# `ops-workspace`'s framework default creates one worktree per change under `.claude/worktrees`, so
# every repo using the loops hits this. A real run against a live repo reported evidence paths
# INSIDE `.claude/worktrees/*` — a throwaway checkout answering checks about itself, not the repo.
r="$(run "$(mkrepo wt1 .claude/worktrees/mcp-trigger/Tests.Integration/Foo.cs)" "$G")"
check "a .sln (or any file) inside .claude/worktrees does not count" "unknown" "$(v "$r" anywhere)"
r="$(run "$(mkrepo wt2 .worktrees/some-branch/Product.sln)" "$G")"
check "  nor one inside the alternate .worktrees convention" "unknown" "$(v "$r" anywhere)"
# `.claude` itself is NOT pruned wholesale — .claude/skills/* is legitimate evidence several
# shipped checks depend on, so both facts must hold true in the SAME repo.
d="$(mkrepo wt3 .claude/worktrees/x/Product.sln .claude/skills/release-management/SKILL.md)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a worktree copy is excluded while .claude/skills in the same repo is still found" \
  "unknown" "$(v "$r" verify-build-command)"
check "  release-prepare still finds the real skill in .claude/skills" "signal" \
  "$(src "$r" release-prepare)"
check "  with the skill path as evidence, not anything under .claude/worktrees" \
  ".claude/skills/release-management/SKILL.md" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-prepare") | .evidence[0]')"

# --- layer merge: later wins, BY FIELD ----------------------------------------
# A profile entry carrying only an id and a detect must inherit title/why/severity from the base.
# If it did not, a stack override would silently blank the report row it replaced.
OV="$(cf ov '{"version":1,"checks":[{"id":"has-file","section":"Backend","detect":{"any_path":["other.sh"]}}]}')"
r="$(run "$(mkrepo merged other.sh)" "$BASE" "$OV")"
check "an override replaces the base detect"  "present"     "$(v "$r" has-file)"
check "  and inherits the base title"         "A build file" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="has-file") | .title')"
check "  and the base severity"               "blocking" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="has-file") | .severity')"
r="$(run "$(mkrepo merged2 build.sh)" "$BASE" "$OV")"
check "  and the REPLACED glob no longer matches" "unknown" "$(v "$r" has-file)"

ADD="$(cf add '{"version":1,"checks":[{"id":"extra","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w"}]}')"
check "a later layer can add a new check" 6 \
  "$(printf '%s' "$(run "$(mkrepo addrepo)" "$BASE" "$ADD")" | jq '.findings | length')"

# --- report shape --------------------------------------------------------------
r="$(run "$(mkrepo shape build.sh)" "$BASE")"
check "the summary counts present"        1 "$(printf '%s' "$r" | jq '.summary.present')"
check "  and unknown"                     4 "$(printf '%s' "$r" | jq '.summary.unknown')"
check "  and blocking unknowns separately" 2 "$(printf '%s' "$r" | jq '.summary.blocking_unknown')"
# `interview` must exclude the no-ask check: some misses are worth showing and not worth a
# question, and counting them makes the human expect a question that never comes.
check "  and only the unknowns that have a question" 3 "$(printf '%s' "$r" | jq '.summary.interview')"
check "the sources that produced it are recorded" 1 "$(printf '%s' "$r" | jq '.sources | length')"

# --- grouping order --------------------------------------------------------------
# Not cosmetic: the report is a diagnostic checklist grouped by the nine sections on the source
# checklist, in a FIXED order — release management and testing come first because they are what
# unlock the merge and release parts of the pipeline, misc comes last. This is section order, not
# alphabetical and not consumer order (that grouping is gone).
O="$(cf order '{"version":1,"checks":[
  {"id":"z-gen","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w"},
  {"id":"a-rel","consumer":"ops-release","severity":"quality","section":"Release management","title":"t","why":"w"},
  {"id":"a-ws","consumer":"ops-workspace","severity":"quality","section":"Environment","title":"t","why":"w"},
  {"id":"a-chg","consumer":"ops-change","severity":"quality","section":"Testing","title":"t","why":"w"}
]}')"
check "groups come out in fixed section order, not alphabetically and not by consumer" \
  "Release management Testing Environment Misc" \
  "$(printf '%s' "$(run "$(mkrepo ord)" "$O")" | jq -r '[.findings[].section] | join(" ")')"

S2="$(cf sev '{"version":1,"checks":[
  {"id":"b-quality","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w"},
  {"id":"a-blocking","consumer":"general","severity":"blocking","section":"Misc","title":"t","why":"w"}
]}')"
check "blocking sorts before quality within a section" "a-blocking b-quality" \
  "$(printf '%s' "$(run "$(mkrepo sev)" "$S2")" | jq -r '[.findings[].id] | join(" ")')"

# A section unknown to the fixed nine (an authoring slip, since the schema restricts the enum)
# sorts LAST rather than erroring or vanishing, so a stray value cannot silently drop off the
# report.
S3="$(cf sev3 '{"version":1,"checks":[
  {"id":"weird-section","consumer":"general","severity":"quality","section":"Nonexistent","title":"t","why":"w"},
  {"id":"real-section","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w"}
]}')"
check "an unrecognised section sorts after Misc, not first" "real-section weird-section" \
  "$(printf '%s' "$(run "$(mkrepo sev3)" "$S3")" | jq -r '[.findings[].id] | join(" ")')"

# --- text mode says what unknown means -------------------------------------------
# The one sentence that must never be dropped: a reader who takes `unknown` for a pass has been
# told the opposite of the truth.
out="$(bash "$I" "$(mkrepo text build.sh)" --checks "$BASE" 2>/dev/null)"
check "text mode warns that unknown is not a pass" 1 "$(printf '%s' "$out" | grep -c 'UNKNOWN IS NOT A PASS')"
check "text mode prints the evidence for a present" 1 "$(printf '%s' "$out" | grep -c 'found: build.sh')"
check "text mode prints why an unknown matters"     "yes" \
  "$([ "$(printf '%s' "$out" | grep -c 'why:')" -ge 1 ] && echo yes || echo no)"
# The report is a checklist, not an exam, and must say so up front rather than reading like a
# pass/fail score nobody can actually achieve.
check "text mode says this is a map, not an entry exam" 1 \
  "$(printf '%s' "$out" | grep -c 'not an entry exam')"
check "  and that nobody clears every box"              1 \
  "$(printf '%s' "$out" | grep -c 'nobody clears every box')"
# Release management and Testing are called out as the sections to do first, since they unlock
# the merge and release parts of the pipeline.
check "text mode says release management and testing come first" 1 \
  "$(printf '%s' "$out" | grep -c 'Release management and Testing')"
# Severities read as what they mean for the loops, not as a pass/fail grade. BASE has three
# blocking checks (has-file, by-content, no-detect-blocking) and two quality (no-detect, no-ask).
check "text mode renders blocking as work needed for the loops" 3 \
  "$(printf '%s' "$out" | grep -c 'Needed for the loops to work')"
check "  and quality as what makes the loops better"           2 \
  "$(printf '%s' "$out" | grep -c 'Makes the loops better')"
check "  and never as the bare word BLOCKING"                  0 \
  "$(printf '%s' "$out" | grep -c 'BLOCKING')"

# --- a severity heading is printed ONCE per section, never repeated per row ----------------------
# The actual bug: "[SIGNAL ] Needed for the loops to work, Title (consumer)" glued the severity onto
# every row with a comma, and repeating that long label got worse the more checks a section held.
MANY="$(cf many '{"version":1,"checks":[
  {"id":"m-one","consumer":"general","severity":"blocking","section":"Backend","title":"First one","why":"w"},
  {"id":"m-two","consumer":"general","severity":"blocking","section":"Backend","title":"Second one","why":"w"},
  {"id":"m-three","consumer":"general","severity":"blocking","section":"Backend","title":"Third one","why":"w"}
]}')"
mout="$(bash "$I" "$(mkrepo many)" --checks "$MANY" 2>/dev/null)"
check "three blocking checks in ONE section print the heading only once" 1 \
  "$(printf '%s' "$mout" | grep -c 'Needed for the loops to work')"
check "  and each of the three titles still appears" 3 \
  "$(printf '%s' "$mout" | grep -cE 'First one|Second one|Third one')"
check "  with no row gluing the severity onto the title via a comma" 0 \
  "$(printf '%s' "$mout" | grep -c 'Needed for the loops to work,')"

# --- the closing summary is one exact, unbroken sentence, and matches the rows' own words --------
# A real run against a live repo ended mid-word: "...turns whatever i." — whatever the cause, the
# fix is a message built and printed as ONE piece so no partial write can land inside it. It also
# has to say "needed for the loops to work" like every row does, not the old bare word "blocking".
# BASE against the "text" fixture is the same run already used above: 5 checks, 1 present, 4
# unknown, 2 of them blocking, 3 with a question — pinned here exactly, word for word.
SUM_EXPECT='  5 checks: 1 present, 4 unknown (2 needed for the loops to work)

  UNKNOWN IS NOT A PASS. Detection could not see these; 3 of them have a question
  waiting. Answer them, then plan-issues.sh turns whatever is genuinely missing into work.'
check "the closing summary matches the pinned text exactly, word for word" "$SUM_EXPECT" \
  "$(printf '%s' "$out" | tail -4)"
check "  and uses a colon, not an em dash, after the check count" 1 \
  "$(printf '%s' "$out" | grep -c '[0-9] checks: ')"
check "no em dash anywhere in the text report" 0 \
  "$(printf '%s' "$out" | grep -c $'\xe2\x80\x94')"
check "the report header itself uses a colon, not an em dash" 1 \
  "$(printf '%s' "$out" | grep -c '^ops-preflight: ')"

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
  {"id":"s","consumer":"general","severity":"critical","section":"Misc","title":"t","why":"w"}]}')" >/dev/null 2>&1
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
check "  every consumer is a real capability or plugin" "" \
  "$(jq -r '[.checks[].consumer | select((. | IN("ops-workspace","ops-change","ops-branching","ops-release","ops-learnings","general")) | not)] | unique | join(", ")' "$SHIPPED")"
# A blocking check nobody can be asked about is a dead end: detection may miss it and then there
# is no way to resolve it at all.
check "  every blocking check is either detectable or askable" "" \
  "$(jq -r '[.checks[] | select(.severity=="blocking" and (has("detect")|not) and (has("ask")|not)) | .id] | join(", ")' "$SHIPPED")"

# --- the golden rule, across EVERY file the engine ships, not just checks.json ------------------
# The profiles ship right alongside checks.json and are read the same way a repo reads them, so a
# product name hiding in a stack profile is exactly as much of a golden-rule break as one in the
# base. Only PROSE fields are prose: `title`, `why` and `ask` are read by a human. `detect` (and a
# profile's `when`) are detection patterns, not marketing copy — a NuGet.config or a package.json
# glob legitimately names a stack's own tool-config filenames, and scanning those would flag the
# very thing profiles exist to express. `id`, `consumer`, `action`, `severity` and `section` are
# controlled vocabularies, not prose, so they are excluded too.
PROFILES_DIR="$HERE/profiles"
mapfile -t SHIPPED_CHECK_FILES < <(printf '%s\n' "$SHIPPED" "$PROFILES_DIR"/*.json)
for f in "${SHIPPED_CHECK_FILES[@]}"; do
  check "  $(basename "$f") parses" 0 "$(jq empty "$f" >/dev/null 2>&1; echo $?)"
done
check "  no product name or tool leaks into a PROSE field of any shipped check file" "" \
  "$(jq -rs '
      [ .[] | .checks[] | (.title // "") + " " + (.why // "") + " " + (.ask // "")
        | ascii_downcase
        | select(test("umbraco|npm |yarn |stylecop|nuget"))
      ] | join("; ")
     ' "${SHIPPED_CHECK_FILES[@]}")"
# A ` - ` used as punctuation reads as a broken sentence, same complaint as the row layout; an em
# dash is banned outright. A real hyphenated word (`well-known`) has no surrounding spaces, so this
# pattern only ever catches the punctuation use, never a compound word.
check "  no ' - ' punctuation or em dash in a PROSE field of any shipped check file" "" \
  "$(jq -rs '
      [ .[] | .checks[] | (.title // "") + " | " + (.why // "") + " | " + (.ask // "")
        | select(test(" - ") or test("—"))
      ] | join("; ")
     ' "${SHIPPED_CHECK_FILES[@]}")"

# --- dual-stack merge: two matching STACK profiles are additive, not a winner-take-all ---------
# select-profile.sh's own contract is that stacks are ADDITIVE ("nothing picks one winner"). This
# goes through the REAL auto-discovery path (no --checks), because the additive merge only exists
# there: a repo matching two stack profiles that both override the same check id used to have
# whichever profile sorted last silently erase the other's `detect`, even though a repo genuinely
# holding both stacks needs both sets of evidence.
STACKDIR="$TMP/stackprofiles"; mkdir -p "$STACKDIR"
DUALBASE="$(cf dualbase '{"version":1,"checks":[
  {"id":"shared-check","consumer":"ops-change","severity":"blocking","section":"Backend","title":"t","why":"w","ask":"q"}
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

# --- dual-stack merge, for real: the SHIPPED dotnet + node profiles, together -------------------
# The test above proves the MECHANISM with synthetic a-stack/b-stack fixtures. This proves the
# real thing: a repo with an actual .sln AND an actual package.json genuinely triggers both
# profiles.json, both override verify-build-command / verify-test-command / verify-lint-command,
# and the union has to keep every stack's patterns, not just whichever profile sorts last. No
# --checks override here — this goes through the real profiles/ directory this repo ships.
#
# "App.csproj" and "Weird.Tests.csproj" are matched ONLY by dotnet's overrides (node's build/test
# globs have no *.csproj pattern), so if they still resolve, dotnet's patterns survived the union.
d="$(mkrepo realdual-dotnet App.csproj Weird.Tests.csproj)"
printf '{}' > "$d/package.json"   # bare package.json still loads the node stack, additively
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "both real shipped stack profiles load for a repo with both stacks" 2 \
  "$(printf '%s' "$r" | jq '[.sources[] | select(test("dotnet\\.json$|node\\.json$"))] | length')"
check "verify-build-command: the dotnet-only *.csproj pattern survives the union with node" \
  "unknown" "$(v "$r" verify-build-command)"
check "  and resolves via signal, not a silent present, because it is signal:true" \
  "signal" "$(src "$r" verify-build-command)"
check "  with the dotnet-exclusive file as evidence" "App.csproj" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-build-command") | .evidence[] | select(.=="App.csproj")')"
check "verify-test-command: the dotnet-only *Tests*.csproj pattern survives the union too" \
  "unknown" "$(v "$r" verify-test-command)"
check "  same reason: signal, never present" "signal" "$(src "$r" verify-test-command)"

# "vitest.config.js" is matched ONLY by node's override (dotnet's test globs need a .csproj or a
# Tests/ folder), and the "build" package.json script is matched ONLY by node's any_file_contains
# (dotnet's build override has no content check) — proving node's patterns survive the union too.
d2="$(mkrepo realdual-node Product.sln vitest.config.js .eslintrc.json)"
printf '%s' '{"scripts":{"build":"webpack"}}' > "$d2/package.json"
r2="$(bash "$I" "$d2" --json 2>/dev/null)"
check "verify-test-command: the node-only vitest.config.* pattern survives the union with dotnet" \
  "unknown" "$(v "$r2" verify-test-command)"
check "  with the node-exclusive file as evidence" "vitest.config.js" \
  "$(printf '%s' "$r2" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence[] | select(.=="vitest.config.js")')"
check "verify-build-command: the node-only package.json content signal survives the union too" \
  "unknown" "$(v "$r2" verify-build-command)"
check "  with package.json as the content-match evidence" "package.json" \
  "$(printf '%s' "$r2" | jq -r '.findings[] | select(.id=="verify-build-command") | .evidence[] | select(.=="package.json")')"
# verify-lint-command is `quality` AND `signal` — a linter's config file existing is not the same
# fact as "one command lints, and it fails on error", so a match here asks rather than passes too.
check "verify-lint-command (quality, but signal) still asks rather than a silent PRESENT" \
  "unknown" "$(v "$r2" verify-lint-command)"
check "  and its source says signal, not detected" "signal" "$(src "$r2" verify-lint-command)"
# node-component-tests is the contrast: quality and NOT signal, so a match there resolves to a
# plain PRESENT — proof that `signal` above is doing real work and not just how every check behaves.
d2b="$(mkrepo realdual-node-quality Widget.test.ts package.json)"
r2b="$(bash "$I" "$d2b" --json 2>/dev/null)"
check "node-component-tests (quality, not signal) resolves to a plain PRESENT when matched" \
  "present" "$(v "$r2b" node-component-tests)"
check "  and its source says detected, not signal" "detected" "$(src "$r2b" node-component-tests)"

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


# --- shipped fixes: the release checks find real evidence instead of nothing -------------------
# A real dry run against a consumer repo found none of these, even though the harness fact they
# ask about ("a skill to prepare/trigger/clean up a release", "the file holding the version") was
# demonstrably there. Through the real auto-discovery path (no --checks) against the SHIPPED
# checks.json, so these prove the actual catalog rather than a synthetic fixture.

# release-prepare: was already correct (a signal match, not a silent present) — this pins it so a
# future edit cannot regress it while fixing its two neighbours below.
d="$(mkrepo relprepare .claude/skills/release-management/SKILL.md)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-prepare finds a release-management-style skill by directory name" \
  "unknown" "$(v "$r" release-prepare)"
check "  via signal, not a silent present" "signal" "$(src "$r" release-prepare)"
check "  with the skill file as evidence" ".claude/skills/release-management/SKILL.md" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-prepare") | .evidence[] | select(.==".claude/skills/release-management/SKILL.md")')"

# release-cleanup had NO detect block at all — a post-release-cleanup skill could not have been
# found on any repo, ever, regardless of how the repo looked. It now looks under .claude/skills/
# by directory name, the same harness fact release-prepare already looked for.
d="$(mkrepo relcleanup .claude/skills/post-release-cleanup/SKILL.md)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-cleanup finds a post-release-cleanup-style skill — it used to have no detect at all" \
  "unknown" "$(v "$r" release-cleanup)"
check "  via signal, not a silent present" "signal" "$(src "$r" release-cleanup)"
check "  with the skill file as evidence" ".claude/skills/post-release-cleanup/SKILL.md" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-cleanup") | .evidence[] | select(.==".claude/skills/post-release-cleanup/SKILL.md")')"
r2="$(bash "$I" "$(mkrepo relcleanupmiss)" --json 2>/dev/null)"
check "  and a repo with no such skill stays unknown with no evidence" \
  "unknown" "$(v "$r2" release-cleanup)"

# release-trigger: CI is not always GitHub Actions. Azure Pipelines is a shape the engine already
# supports elsewhere (github-ops has an azure-pipelines CI-provider reference), so an
# azure-pipelines.yml at the root is a base-engine fact, not a product fact.
d="$(mkrepo reltrigger azure-pipelines.yml)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-trigger finds an azure-pipelines.yml CI/release trigger" \
  "unknown" "$(v "$r" release-trigger)"
check "  with the pipeline file as evidence" "azure-pipelines.yml" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-trigger") | .evidence[] | select(.=="azure-pipelines.yml")')"
d2="$(mkrepo reltrigger2 pipelines/ci.yml)"
r2="$(bash "$I" "$d2" --json 2>/dev/null)"
check "  and the pipelines/*.yml shape also counts" "unknown" "$(v "$r2" release-trigger)"

# release-version-source: the bare "version.json" pattern is anchored to the literal repo-relative
# path (detect-lib.sh's glob semantics: no wildcard means no crossing into a subdirectory), so a
# repo whose version.json lives one level down under each product folder was invisible to it.
# "*/version.json" fixes that without needing "**". It is also `signal: true` (see below), so a
# match ASKS rather than passes — evidence stays intact either way, only the verdict changed.
d="$(mkrepo relversion Product/version.json)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-version-source finds a version.json nested under a product folder, not only at the root" \
  "unknown" "$(v "$r" release-version-source)"
check "  via signal, not a silent present" "signal" "$(src "$r" release-version-source)"
check "  with the nested path as evidence" "Product/version.json" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-version-source") | .evidence[] | select(.=="Product/version.json")')"
check "  and a root-level version.json still matches too" "unknown" \
  "$(v "$(bash "$I" "$(mkrepo relversion2 version.json)" --json 2>/dev/null)" release-version-source)"

# --- shipped fix: release-version-source no longer hard-passes on the wrong file ----------------
# A repo publishing packages under version.json, that ALSO happens to have a root package.json
# (a docs toolchain, a front-end demo, anything), used to match package.json first and report
# PRESENT for the wrong file — a real dry run hit this on a .NET repo. `signal: true` turns that
# into a question instead of a guess about which of two matches is the one that matters.
d="$(mkrepo relversion-both version.json)"
printf '{}' > "$d/package.json"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a repo with both version.json and package.json no longer hard-passes on the wrong one" \
  "unknown" "$(v "$r" release-version-source)"
check "  via signal, so a human confirms which file is the published one" \
  "signal" "$(src "$r" release-version-source)"

# --- shipped fix: a test-shaped directory glob requires a plausible source extension -----------
# The bug a real dry run hit: `verify-test-command`'s bare "*[Tt]est/*" matched ANY file under a
# directory whose name contains "test" — so a "pack-test" folder full of build output (a .nupkg and
# its .snupkg) counted as test evidence, right alongside the real thing. The verdict was still
# right (this check is signal:true, so a match only ever asks) but the EVIDENCE shown was wrong,
# which defeats the point of showing evidence at all. Through the real auto-discovery path against
# the shipped checks.json — no dotnet/node profile matches either fixture, so this exercises the
# base check's own detect, the one that was broken.
d="$(mkrepo packartifact pack-test/Product.0.1.0.nupkg pack-test/Product.0.1.0.snupkg)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a package artifact inside a test-shaped directory is NOT test evidence" 0 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="verify-test-command") | .evidence[]] | length')"
check "  so the check still stays unknown, never a false present" "unknown" "$(v "$r" verify-test-command)"
check "  with no source at all — nothing matched" "null" "$(src "$r" verify-test-command)"

d="$(mkrepo realtestsrc Tests/FooTests.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a real .cs test source file inside a Tests directory is still found" "signal" "$(src "$r" verify-test-command)"
check "  with the source file itself as evidence" "Tests/FooTests.cs" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence[] | select(.=="Tests/FooTests.cs")')"

d="$(mkrepo realtestsrcjs Tests/foo.something.js)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "  and a .js source file inside a Tests directory is found too" "Tests/foo.something.js" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence[] | select(.=="Tests/foo.something.js")')"

# The dotnet and node stack profiles override verify-test-command's own detect, so their bare
# directory globs needed the same fix independently — this proves each profile's OWN override,
# through the real profiles/ directory (a repo matching that stack's `when`).
d="$(mkrepo dotnetpackartifact App.csproj pack-test/Product.0.1.0.nupkg)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "dotnet profile: a package artifact in a test-shaped directory still isn't test evidence" 0 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="verify-test-command") | .evidence[] | select(test("nupkg"))] | length')"
d="$(mkrepo dotnettestsrc App.csproj Tests/FooTests.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "  while a real .cs test file in the same shape still is" "Tests/FooTests.cs" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence[] | select(.=="Tests/FooTests.cs")')"

d="$(mkrepo nodepackartifact package.json pack-test/Product.tgz)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "node profile: a package artifact in a test-shaped directory still isn't test evidence" 0 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="verify-test-command") | .evidence[] | select(test("tgz"))] | length')"
d="$(mkrepo nodetestsrc package.json Tests/foo.js)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "  while a real .js test file in the same shape still is" "Tests/foo.js" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence[] | select(.=="Tests/foo.js")')"

# --- shipped fix: evidence beyond the cap says how many more, instead of going silent -------------
# The report caps evidence at 3 paths per row (plenty to answer "is this real"). Before this fix,
# a check matching a dozen files just showed three with no sign anything was cut — reading as "that
# is everything" when it was not. `evidence_more` carries the true count past the cap, and the text
# report renders it as "(+N more)".
d="$(mkrepo manytests Tests/A.cs Tests/B.cs Tests/C.cs Tests/D.cs Tests/E.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "evidence in JSON stays capped at 3 entries" 3 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="verify-test-command") | .evidence[]] | length')"
check "  and evidence_more carries the true remainder" 2 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="verify-test-command") | .evidence_more')"
out="$(bash "$I" "$d" 2>/dev/null)"
check "  the text report renders it as \"(+N more)\"" 1 "$(printf '%s' "$out" | grep -c '(+2 more)')"

d="$(mkrepo onetest Tests/OnlyOne.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "evidence at or under the cap carries evidence_more of 0" 0 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="verify-test-command") | .evidence_more')"
out="$(bash "$I" "$d" 2>/dev/null)"
check "  and the text report prints no \"(+N more)\" suffix at all" 0 \
  "$(printf '%s' "$out" | grep -c '(+.*more)')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
