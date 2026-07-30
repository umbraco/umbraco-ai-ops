#!/usr/bin/env bash
# Tests for validate-capability-skills.sh. Hermetic: bash + jq only, no network.
#
# The rule under test is the one a live routine taught us: a capability skill must NOT set
# disable-model-invocation, because that blocks the Skill tool for the model and for subagents
# alike — so the loop cannot call the capability either. The failure is silent: the loop reads
# the file off disk instead and appears to work. Hence a validator rather than a convention.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-capability-skills.sh"
[ -f "$V" ] || { echo "FATAL: validate-capability-skills.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
accepts() { if bash "$V" "$1" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2 — expected accept"; fi; }
rejects() { if bash "$V" "$1" >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL: $2 — expected reject"; else pass=$((pass+1)); fi; }

# A minimal engine: a catalog naming two capabilities, and skills for them.
mkroot() { # mkroot <name> -> prints root
  local r="$TMP/$1"; mkdir -p "$r/plugins/p/skills/ops-branching" "$r/plugins/p/skills/ops-ci"
  cat > "$r/catalog.json" <<'JSON'
{ "version": 1, "reserved_skill_names": [],
  "capabilities": [
    { "capability": "branching", "kind": "behavioral", "visibility": "supporting",
      "framework_default": true, "override_when": "x", "description": "d",
      "operations": [ { "action": "merge", "description": "d", "example": {} } ] },
    { "capability": "ci", "kind": "behavioral", "visibility": "cross-cutting",
      "framework_default": true, "override_when": "x", "description": "d",
      "operations": [ { "action": "status", "description": "d", "example": {} } ] } ] }
JSON
  for c in branching ci; do
    cat > "$r/plugins/p/skills/ops-$c/SKILL.md" <<EOF
---
name: ops-$c
description: >-
  Does the thing. Called by name with (action, context-json). NOT for direct use — never
  select it from a description match.
---
# ops-$c
EOF
  done
  printf '%s' "$r"
}

R="$(mkroot good)"
accepts "$R" "a clean pair of capability skills"

# --- the flag, the whole reason this exists -------------------------------
# IN THE FRONTMATTER, which is the only place it does anything. Appending it after the closing
# `---` would be prose, and the checks are deliberately scoped to frontmatter now.
R="$(mkroot flagged)"
sed -i 's/^name: ops-ci$/name: ops-ci\ndisable-model-invocation: true/' "$R/plugins/p/skills/ops-ci/SKILL.md"
rejects "$R" "a capability that sets disable-model-invocation"

out="$(bash "$V" "$R" 2>&1)"
if printf '%s' "$out" | grep -q "no loop can call it"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the message should say why the flag is banned"; fi

# Naming the flag in the BODY is not setting it. Several skills explain why it is banned, and a
# validator that failed on the explanation would push people into not writing it down.
R="$(mkroot discusses)"
printf '\nWe deliberately do not use:\ndisable-model-invocation: true\n' \
  >> "$R/plugins/p/skills/ops-ci/SKILL.md"
accepts "$R" "a capability that only discusses the flag in its body"

# --- the guard that replaces it -------------------------------------------
R="$(mkroot noguard)"
sed -i 's/NOT for direct use — never/absolutely fine to/' "$R/plugins/p/skills/ops-branching/SKILL.md"
rejects "$R" "a capability missing the do-not-select guard"

# The guard has to be in the DESCRIPTION. In the body it discourages nothing: a description
# match is what it exists to prevent, and only the description is matched.
R="$(mkroot guardinbody)"
sed -i 's/NOT for direct use — never/absolutely fine to/' "$R/plugins/p/skills/ops-branching/SKILL.md"
printf '\nNOT for direct use — never select it from a description match.\n' \
  >> "$R/plugins/p/skills/ops-branching/SKILL.md"
rejects "$R" "the guard in the body instead of the description"

# --- no frontmatter at all -------------------------------------------------
R="$(mkroot nofm)"
printf '# ops-ci\nno frontmatter here\n' > "$R/plugins/p/skills/ops-ci/SKILL.md"
rejects "$R" "a capability skill with no frontmatter"

# --- the name IS the binding ----------------------------------------------
R="$(mkroot misnamed)"
sed -i 's/^name: ops-ci$/name: ops-something-else/' "$R/plugins/p/skills/ops-ci/SKILL.md"
rejects "$R" "a frontmatter name that does not match the directory"

# --- loops and the installer are OUT of scope ------------------------------
# Not because the flag is right there — no skill in this repo sets it, and a flagged loop would
# break in cloud, where a routine's model picks the loop by description. They are out of scope
# because this validator polices the CAPABILITY contract only. If this starts failing, the script
# has begun policing skills it does not own.
R="$(mkroot withloop)"
mkdir -p "$R/plugins/p/skills/ops-issue-loop" "$R/plugins/p/skills/ops-install"
for s in ops-issue-loop ops-install; do
  printf -- '---\nname: %s\ndescription: A loop.\ndisable-model-invocation: true\n---\n' "$s" \
    > "$R/plugins/p/skills/$s/SKILL.md"
done
accepts "$R" "a loop and the installer may still set the flag"

# --- an empty tree is an error, not a silent pass --------------------------
# A validator that passes when it checked nothing is the failure mode this repo keeps hitting.
R="$TMP/empty"; mkdir -p "$R/plugins"; cp "$TMP/good/catalog.json" "$R/catalog.json"
bash "$V" "$R" >/dev/null 2>&1
check_rc=$?
if [ "$check_rc" -eq 2 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: no capability skills at all should exit 2, got $check_rc"; fi

# --- the consumer layout ---------------------------------------------------
# A consumer has no plugins/ and no catalog.json; its skills live in .claude/skills/. This is the
# layout /ops-install checks, and the one that went unchecked while Umbraco.Automate shipped
# three flagged skills that coverage happily reported as `present` (30-07-2026).
mkconsumer() { # mkconsumer <name> -> prints root
  local r="$TMP/$1"; mkdir -p "$r/.claude/skills/ops-change"
  cat > "$r/.claude/skills/ops-change/SKILL.md" <<'EOF'
---
name: ops-change
description: >-
  Build one change in this repo. Called by name with (action, context-json). NOT for direct
  use — never select it from a description match.
---
# ops-change
EOF
  printf '%s' "$r"
}

R="$(mkconsumer consumer_good)"
accepts "$R" "a consumer repo with a clean ops-change"

# That fixture deliberately wraps between "direct" and "use". The description is a YAML folded
# scalar, so the parsed value still reads "NOT for direct use" — where the author's line break
# lands is not a rule violation, and a line-anchored grep called this guard missing.
if bash "$V" "$TMP/consumer_good" >/dev/null 2>&1; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a guard wrapped across two lines should still count"; fi

# The catalog fell back to the engine's, since the consumer has none. If that broke, `change`
# would not be a known capability and the skill would be skipped rather than checked.
R="$(mkconsumer consumer_flagged)"
sed -i 's/^name: ops-change$/name: ops-change\ndisable-model-invocation: true/' \
  "$R/.claude/skills/ops-change/SKILL.md"
rejects "$R" "a consumer's ops-change setting the flag"

out="$(bash "$V" "$R" 2>&1)"
if printf '%s' "$out" | grep -q "ops-change"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the failure should name the offending skill"; fi

# A consumer that owns no capability skill inherits every default. Normal, not an error — the
# opposite of an empty engine tree above.
R="$TMP/consumer_empty"; mkdir -p "$R/.claude/skills"
accepts "$R" "a consumer owning no capability skills"

# Neither layout is a pointing error, and must not pass quietly.
R="$TMP/nothing"; mkdir -p "$R"
bash "$V" "$R" >/dev/null 2>&1
check_rc=$?
if [ "$check_rc" -eq 2 ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a root with neither layout should exit 2, got $check_rc"; fi

# --- the real repo must satisfy its own rule -------------------------------
accepts "$HERE/.." "this repo's own capability skills"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
