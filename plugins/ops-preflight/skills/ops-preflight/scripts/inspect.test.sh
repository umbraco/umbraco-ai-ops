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
check "  and says the match was weak"       "weak"    "$(src "$r" risky)"
check "  but keeps the evidence, to seed the question" "NuGet.config" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="risky") | .evidence[0]')"
check "  and still counts as needing an answer" 1 "$(printf '%s' "$r" | jq '.summary.interview')"
check "  and as a blocking unknown"             1 "$(printf '%s' "$r" | jq '.summary.blocking_unknown')"

r="$(run "$(mkrepo sigmiss other.txt)" "$SIG")"
check "a signal that misses is a plain unknown" "unknown" "$(v "$r" risky)"
check "  with no source"                        "null"    "$(src "$r" risky)"

out="$(bash "$I" "$(mkrepo sigtext NuGet.config)" --checks "$SIG" 2>/dev/null)"
check "text mode labels it ASK, not PRESENT" 1 "$(printf '%s' "$out" | grep -c '\[ASK')"
check "  and never PRESENT"                     0 "$(printf '%s' "$out" | grep -c 'PRESENT')"

# A signal with no `ask` can never reach any verdict but unknown. That is a dead end, not a check.
bash "$I" "$(mkrepo sigdead)" --checks "$(cf sigdead '{"version":1,"checks":[
  {"id":"dead","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w","signal":true,"detect":{"any_path":["x"]}}]}')" >/dev/null 2>&1
check "a signal check with no ask exits 2" 2 $?

# --- pattern-level strength: the fix this file exists to prove --------------------------------
# Evidence strength now lives on the PATTERN, not on the whole check. A check with a genuine mix of
# strong and weak patterns must resolve each match on its own: a strong match passes outright, a
# weak match on the very same check still asks, and no match at all still asks — unchanged.
MIX="$(cf mix '{"version":1,"checks":[
  {"id":"mixed","consumer":"ops-release","severity":"blocking","section":"Release management","title":"t","why":"w","ask":"q",
   "detect":{"any_path":["release.sh",{"glob":"*.yml","strength":"weak"}]}}
]}')"
r="$(run "$(mkrepo strongmatch release.sh)" "$MIX")"
check "a strong pattern match resolves present, no question" "present" "$(v "$r" mixed)"
check "  source says detected" "detected" "$(src "$r" mixed)"
check "  with the strong match as evidence" "release.sh" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="mixed") | .evidence[0]')"

r="$(run "$(mkrepo weakmatch ci.yml)" "$MIX")"
check "a weak-only match on the SAME check still asks" "unknown" "$(v "$r" mixed)"
check "  source says weak" "weak" "$(src "$r" mixed)"
check "  but keeps the weak evidence to seed the question" "ci.yml" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="mixed") | .evidence[0]')"

r="$(run "$(mkrepo nomatch nothing-here.txt)" "$MIX")"
check "no match at all still asks, unchanged" "unknown" "$(v "$r" mixed)"
check "  with no source and no evidence" "null" "$(src "$r" mixed)"
check "  and no evidence at all" 0 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="mixed") | .evidence[]] | length')"

r="$(run "$(mkrepo bothmatch release.sh ci.yml)" "$MIX")"
check "a strong match wins even alongside a weak one on the same check" "present" "$(v "$r" mixed)"
check "  and both still show up as evidence" 2 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="mixed") | .evidence[]] | length')"
check "  strong evidence lives in evidence_strong" "release.sh" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="mixed") | .evidence_strong[0]')"
check "  weak evidence lives separately in evidence_weak" "ci.yml" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="mixed") | .evidence_weak[0]')"

# --- Fix 1: the report shows WHICH match earned a PRESENT, strong first, weak marked plainly -----
# The motivating bug: two weak patterns and one strong pattern all matched on the same check, and
# the report printed all three evidence paths identically, so a reader could not tell which one
# actually earned the PRESENT. Now the strong match prints on its own `found:` line, and any weak
# match prints on a second, clearly-labelled `also seen (weak):` line.
out="$(bash "$I" "$(mkrepo mixedtext release.sh ci.yml)" --checks "$MIX" 2>/dev/null)"
check "text: the found: line carries ONLY the strong match" 1 \
  "$(printf '%s' "$out" | grep -c 'found: release.sh$')"
check "  and the weak match prints on its own labelled line, not mixed into found:" 1 \
  "$(printf '%s' "$out" | grep -c 'also seen (weak): ci.yml$')"

# A row with no strong evidence at all keeps the plain `found:` line it always had. The "also
# seen (weak)" label only ever appears ALONGSIDE a strong match, never on its own.
out2="$(bash "$I" "$(mkrepo weaktextonly ci.yml)" --checks "$MIX" 2>/dev/null)"
check "  a weak-only row has no \"also seen (weak)\" label at all" 0 \
  "$(printf '%s' "$out2" | grep -c 'also seen (weak)')"
check "  it still shows a plain found: line" 1 \
  "$(printf '%s' "$out2" | grep -c 'found: ci.yml$')"

# --- Fix 1: a file matching BOTH a strong and a weak pattern on the SAME check counts once -------
# A real repo's post-release-cleanup skill matched checks.json's release-cleanup both under the
# strong `*post-release*` glob and the weak `*clean*` glob, and briefly printed as if it were TWO
# different pieces of evidence: "found: X" then "also seen (weak): X" naming the identical file.
DUPE="$(cf dupe '{"version":1,"checks":[
  {"id":"dupecheck","consumer":"general","severity":"quality","section":"Misc","title":"t","why":"w",
   "detect":{"any_path":[{"glob":"*post-release*/*","strength":"strong"},{"glob":"*clean*/*","strength":"weak"}]}}
]}')"
d="$(mkrepo dupefile .claude/skills/post-release-cleanup/SKILL.md)"
r="$(run "$d" "$DUPE")"
check "a file matching both a strong and a weak pattern counts once as strong" 1 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="dupecheck") | .evidence_strong | length')"
check "  and is absent from evidence_weak, so it is never shown twice" 0 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="dupecheck") | .evidence_weak | length')"
out3="$(bash "$I" "$d" --checks "$DUPE" 2>/dev/null)"
check "  the text report shows it once, under found:, never under also seen (weak) too" 0 \
  "$(printf '%s' "$out3" | grep -c 'also seen (weak)')"

# --- the exact motivating bug: a workflow named for the job that only labels -------------------
# This is the shape that made `signal: true` necessary in the first place: a `.github/workflows/`
# file named "release" that only applies labels must never silently resolve `release-trigger`, so
# that pattern is WEAK in the shipped catalog (see checks.json) even though its filename contains
# the word "release". Through the real shipped catalog, not a synthetic fixture.
d="$(mkrepo releaseyml .github/workflows/release.yml)"
printf 'name: release\non: push\njobs:\n  label:\n    steps: []\n' > "$d/.github/workflows/release.yml"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a release.yml that only labels still asks release-trigger, never a silent pass" \
  "unknown" "$(v "$r" release-trigger)"
check "  weak: a CI file named for the job is still not proof it does the job" \
  "weak" "$(src "$r" release-trigger)"

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
check "  release-prepare still finds the real skill in .claude/skills" "present" \
  "$(v "$r" release-prepare)"
check "  a release-named skill directory is strong evidence, so it resolves without asking" \
  "detected" "$(src "$r" release-prepare)"
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

# --- Fix 3: whole-product checks moved to Harness, stack-specific checks stayed put --------------
# verify-build-command, verify-test-command, verify-lint-command and verify-warnings-clean ask
# about the WHOLE product, and now live in Harness next to verify-self-check, not in Backend or
# Frontend where a dual-stack repo's evidence for them used to be 100% front-end or 100% back-end.
# dotnet-analyzers and node-component-tests/node-lockfile are genuinely stack-specific and stayed
# exactly where they were.
check "  verify-build-command lives in Harness now, not Backend" "Harness" \
  "$(jq -r '.checks[] | select(.id=="verify-build-command") | .section' "$SHIPPED")"
check "  verify-test-command lives in Harness now, not Backend" "Harness" \
  "$(jq -r '.checks[] | select(.id=="verify-test-command") | .section' "$SHIPPED")"
check "  verify-lint-command lives in Harness now, not Frontend" "Harness" \
  "$(jq -r '.checks[] | select(.id=="verify-lint-command") | .section' "$SHIPPED")"
check "  verify-warnings-clean lives in Harness now, not Backend" "Harness" \
  "$(jq -r '.checks[] | select(.id=="verify-warnings-clean") | .section' "$SHIPPED")"
check "  and all four are marked whole_product" 4 \
  "$(jq '[.checks[] | select(.id | IN("verify-build-command","verify-test-command","verify-lint-command","verify-warnings-clean")) | select(.whole_product==true)] | length' "$SHIPPED")"
check "  dotnet-analyzers stayed in Backend, a genuinely stack-specific check" "Backend" \
  "$(jq -r '.checks[] | select(.id=="dotnet-analyzers") | .section' "$HERE/profiles/dotnet.json")"
check "  node-component-tests stayed in Frontend" "Frontend" \
  "$(jq -r '.checks[] | select(.id=="node-component-tests") | .section' "$HERE/profiles/node.json")"
check "  node-lockfile stayed in Frontend" "Frontend" \
  "$(jq -r '.checks[] | select(.id=="node-lockfile") | .section' "$HERE/profiles/node.json")"
check "  the profiles' OWN section overrides for the four moved checks agree with base, not Backend/Frontend" "" \
  "$(jq -rs '
      [ .[] | .checks[]? | select(.id | IN("verify-build-command","verify-test-command","verify-lint-command"))
        | select((.section? // "Harness") != "Harness") | .id ] | join(", ")
     ' "$HERE/profiles/dotnet.json" "$HERE/profiles/node.json")"

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
check "  and resolves via weak, not a silent present, because a bare .csproj only proves a project exists" \
  "weak" "$(src "$r" verify-build-command)"
check "  with the dotnet-exclusive file as evidence" "App.csproj" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-build-command") | .evidence[] | select(.=="App.csproj")')"
check "verify-test-command: the dotnet-only *Tests*.csproj pattern survives the union too" \
  "unknown" "$(v "$r" verify-test-command)"
check "  same reason: weak, never present" "weak" "$(src "$r" verify-test-command)"

# "vitest.config.js" is matched ONLY by node's override (dotnet's test globs need a .csproj or a
# Tests/ folder), and the "build" package.json script is matched ONLY by node's any_file_contains
# (dotnet's build override has no content check) — proving node's patterns survive the union too.
d2="$(mkrepo realdual-node Product.sln vitest.config.js .eslintrc.json)"
printf '%s' '{"scripts":{"build":"webpack"}}' > "$d2/package.json"
r2="$(bash "$I" "$d2" --json 2>/dev/null)"
check "verify-test-command: the node-only vitest.config.* pattern survives the union with dotnet" \
  "present" "$(v "$r2" verify-test-command)"
check "  a runner-specific config file is strong evidence, so it resolves without asking" \
  "detected" "$(src "$r2" verify-test-command)"
check "  with the node-exclusive file as evidence" "vitest.config.js" \
  "$(printf '%s' "$r2" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence[] | select(.=="vitest.config.js")')"
check "verify-build-command: the node-only package.json content match survives the union too" \
  "unknown" "$(v "$r2" verify-build-command)"
check "  as weak: a bare \"build\" keyword in package.json does not itself prove a command" \
  "weak" "$(src "$r2" verify-build-command)"
check "  with package.json as the content-match evidence" "package.json" \
  "$(printf '%s' "$r2" | jq -r '.findings[] | select(.id=="verify-build-command") | .evidence[] | select(.=="package.json")')"
# verify-lint-command is `quality`, and an eslintrc is config for the tool, not proof of a single
# enforced command that fails on error, so a match here asks rather than passes too.
check "verify-lint-command (quality, but a weak pattern) still asks rather than a silent PRESENT" \
  "unknown" "$(v "$r2" verify-lint-command)"
check "  and its source says weak, not detected" "weak" "$(src "$r2" verify-lint-command)"
# node-component-tests is the contrast: quality and every one of its patterns strong, so a match
# there resolves to a plain PRESENT — proof that pattern strength is doing real work and not just
# how every check behaves.
d2b="$(mkrepo realdual-node-quality Widget.test.ts package.json)"
r2b="$(bash "$I" "$d2b" --json 2>/dev/null)"
check "node-component-tests (quality, not signal) resolves to a plain PRESENT when matched" \
  "present" "$(v "$r2b" node-component-tests)"
check "  and its source says detected, not signal" "detected" "$(src "$r2b" node-component-tests)"

# --- Fix 2: a `whole_product` check needs STRONG evidence from EVERY active stack ---------------
# The bug: a check whose QUESTION covers the whole product (verify-build/test/lint-command,
# verify-warnings-clean) resolved PRESENT off a strong match from just ONE active stack, proving
# that stack, never the product. This is the OR-union problem `signal: true` was built to stop,
# coming back through pattern strength. `whole_product: true` closes it: with 2+ active stacks, a
# strong match tagged to only SOME of them downgrades the check to unknown (source `partial`) and
# names which stack has none.
WPDIR="$TMP/wpprofiles"; mkdir -p "$WPDIR"
WPBASE="$(cf wpbase '{"version":1,"checks":[
  {"id":"wp-check","consumer":"ops-change","severity":"blocking","section":"Harness","title":"t","why":"w","ask":"q","whole_product":true},
  {"id":"wp-check2","consumer":"ops-change","severity":"blocking","section":"Harness","title":"t2","why":"w","ask":"q","whole_product":true,
   "detect":{"any_path":["root-command"]}},
  {"id":"not-wp","consumer":"ops-change","severity":"blocking","section":"Harness","title":"t3","why":"w","ask":"q"}
]}')"
printf '%s' '{"version":1,"profile":"alpha","when":{"any_path":["marker-alpha"]},
  "checks":[
    {"id":"wp-check","detect":{"any_path":["strong-alpha"]}},
    {"id":"not-wp","detect":{"any_path":["strong-alpha"]}}
  ]}' > "$WPDIR/alpha.json"
printf '%s' '{"version":1,"profile":"beta","when":{"any_path":["marker-beta"]},
  "checks":[{"id":"wp-check","detect":{"any_path":["strong-beta",{"glob":"weak-beta","strength":"weak"}]}}]}' > "$WPDIR/beta.json"

wprun() { OPS_PREFLIGHT_CHECKS="$WPBASE" OPS_PREFLIGHT_PROFILES="$WPDIR" bash "$I" "$1" --json 2>/dev/null; }
wptext() { OPS_PREFLIGHT_CHECKS="$WPBASE" OPS_PREFLIGHT_PROFILES="$WPDIR" bash "$I" "$1" 2>/dev/null; }

d="$(mkrepo wponlyalpha marker-alpha strong-alpha)"
r="$(wprun "$d")"
check "one active stack: whole_product changes nothing, a strong match still resolves present" \
  "present" "$(v "$r" wp-check)"
check "  and a NON-whole_product check behaves the same as always too" \
  "present" "$(v "$r" not-wp)"

d="$(mkrepo wpboth marker-alpha marker-beta strong-alpha weak-beta)"
r="$(wprun "$d")"
check "two active stacks, strong for ONE, weak-only for the other: downgrades, not present" \
  "unknown" "$(v "$r" wp-check)"
check "  source is partial: strong evidence for some active stacks, not all" \
  "partial" "$(src "$r" wp-check)"
check "  the stack with no strong evidence is named" "beta" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="wp-check") | .unaccounted[0]')"
check "  the strong evidence that WAS found is still shown" "strong-alpha" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="wp-check") | .evidence_strong[0]')"
out="$(wptext "$d")"
check "  and the text report says which stack is unaccounted for" 1 \
  "$(printf '%s' "$out" | grep -c 'no strong evidence from: beta')"

d="$(mkrepo wpbothstrong marker-alpha marker-beta strong-alpha strong-beta)"
r="$(wprun "$d")"
check "two active stacks, BOTH with strong evidence: resolves present" "present" "$(v "$r" wp-check)"
check "  with an empty unaccounted list" 0 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="wp-check") | .unaccounted | length')"

d="$(mkrepo wpneither marker-alpha marker-beta)"
r="$(wprun "$d")"
check "two active stacks, no strong evidence from either: plain unknown, not partial" \
  "unknown" "$(v "$r" wp-check)"
check "  source is null, not partial: partial means SOME stacks had strong evidence" \
  "null" "$(src "$r" wp-check)"

# A strong match with NO stack tag at all (this check's own base detect, never touched by either
# profile's override) is a real repo-wide command, and counts for every active stack at once. It
# does not need to be repeated once per stack to satisfy this rule.
d="$(mkrepo wpbaseorigin marker-alpha marker-beta root-command)"
r="$(wprun "$d")"
check "a base-origin strong match (no stack override even touches this check) covers every active stack" \
  "present" "$(v "$r" wp-check2)"
check "  with an empty unaccounted list" 0 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="wp-check2") | .unaccounted | length')"

# --- Fix 2, for real: the SHIPPED dotnet + node profiles reproduce (and fix) the exact bug -------
# A real dry run against a Forms-shaped repo found `verify-test-command` PRESENT off a genuine
# front-end npm test script alone, while an equivalent dotnet-only repo reported ASK for the same
# check: the OR-union this fix closes. Through the real profiles/ directory, not a synthetic one.
d="$(mkrepo formsshaped App.csproj Tests/FooTests.cs)"
printf '%s' '{"scripts":{"test":"vitest run"}}' > "$d/package.json"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "dotnet+node repo, only node has a real test script: verify-test-command now ASKS" \
  "unknown" "$(v "$r" verify-test-command)"
check "  source is partial, not a silent present" "partial" "$(src "$r" verify-test-command)"
check "  dotnet is named as the stack with no strong evidence" "dotnet" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-test-command") | .unaccounted[0]')"
check "  the node evidence that DID resolve strongly is still shown" "package.json" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="verify-test-command") | .evidence_strong[] | select(.=="package.json")')"

# A real root-level test.sh is a genuine whole-product answer and resolves present even though
# both stacks are active: a literal repo-wide command needs no per-stack corroboration.
d="$(mkrepo formsshaped-rootcmd App.csproj test.sh)"
printf '{}' > "$d/package.json"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a real root test.sh satisfies both active stacks at once" "present" "$(v "$r" verify-test-command)"

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
check "  its source says weak, so the interview opens with what was found" "weak" \
  "$(src "$r" dotnet-runnable-instance)"


# --- shipped fixes: the release checks find real evidence instead of nothing -------------------
# A real dry run against a consumer repo found none of these, even though the harness fact they
# ask about ("a skill to prepare/trigger/clean up a release", "the file holding the version") was
# demonstrably there. Through the real auto-discovery path (no --checks) against the SHIPPED
# checks.json, so these prove the actual catalog rather than a synthetic fixture.

# release-prepare: a skill directory literally named for releases is STRONG evidence — it is named
# for the job, so it resolves straight to present, not a question. This pins that behaviour so a
# future edit cannot regress it while fixing its two neighbours below.
d="$(mkrepo relprepare .claude/skills/release-management/SKILL.md)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-prepare finds a release-management-style skill by directory name" \
  "present" "$(v "$r" release-prepare)"
check "  strong, not a question, because the skill is named for the job" "detected" "$(src "$r" release-prepare)"
check "  with the skill file as evidence" ".claude/skills/release-management/SKILL.md" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-prepare") | .evidence[] | select(.==".claude/skills/release-management/SKILL.md")')"

# release-cleanup had NO detect block at all — a post-release-cleanup skill could not have been
# found on any repo, ever, regardless of how the repo looked. It now looks under .claude/skills/
# by directory name, the same harness fact release-prepare already looked for, and a
# post-release-named directory is just as strong a match as a release-named one.
d="$(mkrepo relcleanup .claude/skills/post-release-cleanup/SKILL.md)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-cleanup finds a post-release-cleanup-style skill — it used to have no detect at all" \
  "present" "$(v "$r" release-cleanup)"
check "  strong, not a question, because the skill is named for the job" "detected" "$(src "$r" release-cleanup)"
check "  with the skill file as evidence" ".claude/skills/post-release-cleanup/SKILL.md" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-cleanup") | .evidence[] | select(.==".claude/skills/post-release-cleanup/SKILL.md")')"
d="$(mkrepo relcleanupweak .claude/skills/cleanup-temp-files/SKILL.md)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "  but a merely \"clean\"-named skill is weak — it could be unrelated to a release at all" \
  "unknown" "$(v "$r" release-cleanup)"
check "    so it still asks, with the evidence shown" "weak" "$(src "$r" release-cleanup)"
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
# "*/version.json" fixes that without needing "**". A version.json is a dedicated, canonical file
# for exactly this fact, so it is STRONG — it resolves the check without a question.
d="$(mkrepo relversion Product/version.json)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "release-version-source finds a version.json nested under a product folder, not only at the root" \
  "present" "$(v "$r" release-version-source)"
check "  strong, not a question, because version.json is a dedicated version file" \
  "detected" "$(src "$r" release-version-source)"
check "  with the nested path as evidence" "Product/version.json" \
  "$(printf '%s' "$r" | jq -r '.findings[] | select(.id=="release-version-source") | .evidence[] | select(.=="Product/version.json")')"
check "  and a root-level version.json still matches too" "present" \
  "$(v "$(bash "$I" "$(mkrepo relversion2 version.json)" --json 2>/dev/null)" release-version-source)"

# --- shipped fix: a bare package.json never hard-passes release-version-source on its own --------
# package.json PROVES a package exists, not that the published version lives there — it is a
# generic, multi-purpose manifest, unlike version.json's one dedicated job. So it is WEAK: on its
# own it still asks.
d="$(mkrepo relversion-pkgonly)"
printf '{}' > "$d/package.json"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a bare package.json alone does not hard-pass release-version-source" \
  "unknown" "$(v "$r" release-version-source)"
check "  weak, so a human confirms which file is the published one" \
  "weak" "$(src "$r" release-version-source)"

# When a version.json ALSO exists alongside a package.json, version.json is strong enough to
# resolve the question by itself — no need to guess which of the two matters, since one of them
# genuinely settles it. Both still show as evidence, so a human can see package.json was there too.
d="$(mkrepo relversion-both version.json)"
printf '{}' > "$d/package.json"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "a repo with both version.json and package.json resolves on the strong one, not a guess" \
  "present" "$(v "$r" release-version-source)"
check "  detected, because version.json alone is enough to answer it" \
  "detected" "$(src "$r" release-version-source)"
check "  and package.json still appears alongside it as evidence" 1 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="release-version-source") | .evidence[] | select(.=="package.json")] | length')"

# --- shipped fix: a test-shaped directory glob requires a plausible source extension -----------
# The bug a real dry run hit: `verify-test-command`'s bare "*[Tt]est/*" matched ANY file under a
# directory whose name contains "test" — so a "pack-test" folder full of build output (a .nupkg and
# its .snupkg) counted as test evidence, right alongside the real thing. The verdict was still
# right (every pattern here is at best weak, so a match only ever asks) but the EVIDENCE shown was wrong,
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
# A test source file only proves tests exist, not that one command runs them, so it is weak — it
# still asks, but with the real file as evidence rather than nothing.
check "a real .cs test source file inside a Tests directory is still found" "weak" "$(src "$r" verify-test-command)"
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

# --- shipped fix: the JSON evidence cap is GONE; only the TEXT report still caps, weak only --------
# The report used to cap evidence at 3 paths per row IN BOTH outputs. Before this fix, a check
# matching a dozen files just showed three with no sign anything was cut, in the JSON too, reading
# as "that is everything" when it was not, and defeating the point of a machine-readable report at
# all. Now: JSON never caps, either list. TEXT still caps, but only the WEAK list; see the next
# block for proof a STRONG list is never capped in text either.
d="$(mkrepo manytests Tests/A.cs Tests/B.cs Tests/C.cs Tests/D.cs Tests/E.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "evidence in JSON is NOT capped: all 5 weak matches are present" 5 \
  "$(printf '%s' "$r" | jq '[.findings[] | select(.id=="verify-test-command") | .evidence[]] | length')"
check "  evidence_weak alone also carries all 5, uncapped" 5 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="verify-test-command") | .evidence_weak | length')"
check "  evidence_more is still the count TEXT will hide past its own cap" 2 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="verify-test-command") | .evidence_more')"
out="$(bash "$I" "$d" 2>/dev/null)"
check "  the text report still renders the weak overflow as \"(+N more)\"" 1 \
  "$(printf '%s' "$out" | grep -c '(+2 more)')"

d="$(mkrepo onetest Tests/OnlyOne.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "evidence at or under the cap carries evidence_more of 0" 0 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="verify-test-command") | .evidence_more')"
out="$(bash "$I" "$d" 2>/dev/null)"
check "  and the text report prints no \"(+N more)\" suffix at all" 0 \
  "$(printf '%s' "$out" | grep -c '(+.*more)')"

# --- shipped fix: a STRONG list is never capped, in JSON or in TEXT, however many matches ----------
# The motivating bug: four `.claude/skills/...` WEAK entries (alphabetically first) filled a 3-item
# cap and pushed a genuinely STRONG `azure-pipelines.yml` match out of the report: a false claim
# the file was not detected. The fix is that strength, not alphabetical position, decides what can
# ever be hidden: a check with 5 STRONG matches (verify-integration-tests: every one of its patterns
# is strong) must show all 5, in JSON and in the text report, with no "(+N more)" attached to them.
d="$(mkrepo manystrong \
  IntegrationTests/A.cs IntegrationTests/B.cs IntegrationTests/C.cs IntegrationTests/D.cs IntegrationTests/E.cs)"
r="$(bash "$I" "$d" --json 2>/dev/null)"
check "5 strong matches all appear in JSON evidence_strong, uncapped" 5 \
  "$(printf '%s' "$r" | jq '.findings[] | select(.id=="verify-integration-tests") | .evidence_strong | length')"
check "  and the check resolves present, not capped into an ASK" "present" \
  "$(v "$r" verify-integration-tests)"
out="$(bash "$I" "$d" 2>/dev/null)"
check "  the text found: line shows exactly 3 of the 5 strong matches" 1 \
  "$(printf '%s' "$out" | grep -c 'found: IntegrationTests/A.cs, IntegrationTests/B.cs, IntegrationTests/C.cs (+2 more)$')"
check "  a PRESENT check with capped strong matches still shows at least one strong match" 1 \
  "$(printf '%s' "$out" | grep -c 'found: IntegrationTests')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
