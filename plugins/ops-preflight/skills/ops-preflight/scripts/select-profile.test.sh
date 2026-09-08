#!/usr/bin/env bash
# Tests for select-profile.sh. Hermetic: bash + jq only, no network, nothing created outside TMP.
#
# The rules under test are the three that decide what a repo is even measured against: the base
# always loads, every MATCHING stack profile loads (they are additive, not exclusive), and the
# repo's own file loads last so it can win. Order is part of the contract — it is what "later
# wins" means — so these assert positions, not just membership.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/select-profile.sh"
[ -f "$S" ] || { echo "FATAL: select-profile.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

# A tiny base + two stacks, so the tests do not move every time a real check is added.
FIX="$TMP/fix"; mkdir -p "$FIX/profiles"
cat > "$FIX/checks.json" <<'JSON'
{"version":1,"checks":[{"id":"base-one","consumer":"general","severity":"quality","title":"t","why":"w"}]}
JSON
cat > "$FIX/profiles/alpha.json" <<'JSON'
{"version":1,"profile":"alpha","when":{"any_path":["*.sln"]},"checks":[{"id":"a-one","consumer":"general","severity":"quality","title":"t","why":"w"}]}
JSON
cat > "$FIX/profiles/beta.json" <<'JSON'
{"version":1,"profile":"beta","when":{"any_path":["package.json"]},"checks":[{"id":"b-one","consumer":"general","severity":"quality","title":"t","why":"w"}]}
JSON
# No `when` at all: must NEVER auto-load, or it would apply to every repo on earth.
cat > "$FIX/profiles/nowhen.json" <<'JSON'
{"version":1,"profile":"nowhen","checks":[{"id":"n-one","consumer":"general","severity":"quality","title":"t","why":"w"}]}
JSON
export OPS_PREFLIGHT_CHECKS="$FIX/checks.json"
export OPS_PREFLIGHT_PROFILES="$FIX/profiles"

mkrepo() { local d="$TMP/$1"; mkdir -p "$d"; shift; local f; for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; printf '{}' > "$d/$f"; done; printf '%s' "$d"; }
sel()    { bash "$S" "$1" --json 2>/dev/null; }
stacks() { printf '%s' "$1" | jq -rc '.summary.stacks'; }
layers() { printf '%s' "$1" | jq -rc '[.sources[].layer]'; }

# --- the base always loads, on its own --------------------------------------
r="$(sel "$(mkrepo bare)")"
check "a repo matching nothing still gets the base" 1 "$(printf '%s' "$r" | jq '.summary.total')"
check "  and it is the base layer"        '["base"]' "$(layers "$r")"
check "  with no stacks"                  '[]'       "$(stacks "$r")"
check "  and no repo override"            false      "$(printf '%s' "$r" | jq '.summary.has_repo_override')"

# --- a stack loads when its `when` matches ----------------------------------
r="$(sel "$(mkrepo sln Product.sln)")"
check "a solution loads the alpha stack"  '["alpha"]'        "$(stacks "$r")"
check "  base first, stack second"        '["base","stack"]' "$(layers "$r")"

# A glob crosses `/`, so a solution nested three deep still counts. This is the semantics the
# schema documents and the one bash does NOT give you by default.
r="$(sel "$(mkrepo deep src/dir/sub/Product.sln)")"
check "a nested solution matches too"     '["alpha"]' "$(stacks "$r")"

# --- a `when` is a full detect object, not just any_path --------------------
# The schema says `when` accepts the same shape a check's own `detect` does — any_path AND
# any_file_contains — because it is the same $defs/detect. A profile that gates on file CONTENT
# is legal under the schema and must load exactly like one gating on a path.
cat > "$FIX/profiles/gamma.json" <<'JSON'
{"version":1,"profile":"gamma","when":{"any_file_contains":[{"glob":"marker.txt","pattern":"gamma-stack"}]},"checks":[{"id":"g-one","consumer":"general","severity":"quality","title":"t","why":"w"}]}
JSON
d="$(mkrepo bycontent)"; printf 'this repo needs the gamma-stack\n' > "$d/marker.txt"
r="$(sel "$d")"
check "a when.any_file_contains match loads the profile" '["gamma"]' "$(stacks "$r")"
d2="$(mkrepo bycontentmiss)"; printf 'nothing relevant here\n' > "$d2/marker.txt"
check "  and a file without the pattern does not load it" '[]' "$(stacks "$(sel "$d2")")"
rm -f "$FIX/profiles/gamma.json"

# --- profiles are ADDITIVE, not exclusive -----------------------------------
# The case that matters: a repo with a backend and a front-end has both stacks, and both sets of
# checks are true of it. Nothing picks one winner.
r="$(sel "$(mkrepo both Product.sln package.json)")"
check "both stacks load together"         '["alpha","beta"]'         "$(stacks "$r")"
check "  three sources in all"            3                          "$(printf '%s' "$r" | jq '.summary.total')"
check "  base still first"                '["base","stack","stack"]' "$(layers "$r")"

# --- a profile with no `when` never loads -----------------------------------
# An unconditional stack profile would apply its checks to every repo, which is the one thing
# profiles exist to prevent. It must stay silent even when nothing else matches.
r="$(sel "$(mkrepo bare2)")"
check "a profile with no when never loads" 0 "$(printf '%s' "$r" | jq '[.sources[] | select(.name=="nowhen")] | length')"

# --- the repo's own file loads, and loads LAST ------------------------------
# Last is the whole point: it is what lets a consumer override an engine check rather than only
# add to it. A repo override in the middle would be silently beaten by a stack profile.
d="$(mkrepo over Product.sln)"; mkdir -p "$d/.claude"
printf '%s' '{"version":1,"profile":"mine","checks":[{"id":"base-one","detect":{"any_path":["x"]}}]}' > "$d/.claude/ops-preflight-profile.json"
r="$(sel "$d")"
check "the repo override loads"            true "$(printf '%s' "$r" | jq '.summary.has_repo_override')"
check "  and it is LAST"                   "repo" "$(printf '%s' "$r" | jq -r '.sources[-1].layer')"
check "  after the stack profile"          '["base","stack","repo"]' "$(layers "$r")"

# --- text mode is the paths, one per line -----------------------------------
out="$(bash "$S" "$(mkrepo text Product.sln)" 2>/dev/null | tr -d '\r')"
check "text mode prints one path per line" 2 "$(printf '%s\n' "$out" | grep -c '\.json$')"
# Compared by basename, not by the whole path: MSYS rewrites a POSIX-looking argument into a
# Windows path on its way through jq, so `/tmp/x/checks.json` comes back as `C:/.../checks.json`.
# Both are valid and bash opens either; asserting the literal string only tests which OS we are on.
check "  base is the first line"           "checks.json" "$(basename "$(printf '%s\n' "$out" | head -1)")"

# --- ordering is stable across runs -----------------------------------------
# Two stacks do not override each other today, but "today" is not a guarantee, and a merge order
# that varies between runs produces a report that cannot be reproduced or debugged.
d="$(mkrepo stable Product.sln package.json)"
check "the same repo selects the same order twice" "$(layers "$(sel "$d")")" "$(layers "$(sel "$d")")"

# --- failure modes ----------------------------------------------------------
bash "$S" >/dev/null 2>&1;                check "no argument exits 2" 2 $?
bash "$S" "$TMP/absent" >/dev/null 2>&1;  check "a missing directory exits 2" 2 $?

# Broken repo override: this must be LOUD. It is a file a consumer wrote by hand, and silently
# ignoring it would measure the repo against the engine defaults while the human believes their
# own checks ran.
d="$(mkrepo badover)"; mkdir -p "$d/.claude"; printf '%s' '{ not json' > "$d/.claude/ops-preflight-profile.json"
bash "$S" "$d" >/dev/null 2>&1;           check "an unreadable repo override exits 2" 2 $?

# A broken ENGINE profile is different: it is not the consumer's file, and one bad ship should not
# stop a whole preflight. Warn, skip it, carry on.
printf '%s' '{ not json' > "$FIX/profiles/broken.json"
r="$(sel "$(mkrepo skipbad Product.sln)")"
check "a broken engine profile is skipped, not fatal" '["alpha"]' "$(stacks "$r")"
rm -f "$FIX/profiles/broken.json"

# A missing base is fatal — there is nothing to measure against at all.
OPS_PREFLIGHT_CHECKS="$FIX/nope.json" bash "$S" "$(mkrepo nobase)" >/dev/null 2>&1
check "a missing base catalog exits 2" 2 $?

# --- the shipped files are real ---------------------------------------------
# The fixtures above prove the mechanism; these prove what actually ships works, which the
# fixtures cannot, because they replace it.
unset OPS_PREFLIGHT_CHECKS OPS_PREFLIGHT_PROFILES
check "the shipped base catalog is valid JSON" 0 "$(jq empty "$HERE/checks.json" >/dev/null 2>&1; echo $?)"
for p in "$HERE"/profiles/*.json; do
  check "  $(basename "$p") is valid JSON" 0 "$(jq empty "$p" >/dev/null 2>&1; echo $?)"
  check "  $(basename "$p") declares a when block" true "$(jq -c 'has("when")' "$p")"
  check "  $(basename "$p") is named for a stack, not a product" "$(basename "$p" .json)" "$(jq -r '.profile' "$p")"
done
r="$(sel "$(mkrepo shipped Product.sln)")"
check "the shipped dotnet profile matches a solution" 1 \
  "$(printf '%s' "$r" | jq '[.summary.stacks[] | select(.=="dotnet")] | length')"
r="$(sel "$(mkrepo shippednode package.json)")"
check "the shipped node profile matches a package.json" 1 \
  "$(printf '%s' "$r" | jq '[.summary.stacks[] | select(.=="node")] | length')"
# A front-end living in a subdirectory is the normal shape, not the exception, and a `when` of
# bare `package.json` is an EXACT match — no wildcard, so nothing crosses `/`. A dry run against a
# repo with src/web/package.json loaded the dotnet stack and silently skipped node entirely.
r="$(sel "$(mkrepo nestednode src/web/package.json)")"
check "  and a nested one too" 1 \
  "$(printf '%s' "$r" | jq '[.summary.stacks[] | select(.=="node")] | length')"
r="$(sel "$(mkrepo fullstack Product.sln src/web/package.json)")"
check "a repo with a backend and a nested front-end loads BOTH" '["dotnet","node"]' "$(stacks "$r")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
