#!/usr/bin/env bash
# Generate the per-capability eval suites from catalog.json.
#
# Evals are the ONLY behavioural guard this engine has. There are no static types and no
# payload validation — the conformance spec makes that trade explicitly, and the plan's
# "coverage ≠ correctness" hazard is the consequence: `ops-install` can report full coverage
# for a repo whose capabilities are wrong in every action.
#
# The suites are GENERATED, for the same reason the README's action table is: a hand-written
# eval set drifts from the catalog, and a drifted eval set fails on the wrong thing or, worse,
# passes while testing an action that no longer exists.
#
# Every action gets four cases, because these are the four MUSTs of the invocation contract
# that a capability can silently get wrong:
#
#   example        the catalog's worked context -> a well-formed, unambiguous result
#   empty-context  no context at all -> treated as {}, NOT an error
#   unknown-action -> rejected, never guessed at and never silently succeeded
#   idempotency    the same action twice with the same context -> no second side effect
#
# Data capabilities get a fifth: the output must be structured, not prose (spec §4.4).
#
# Usage:
#   build-evals.sh [--check]     # --check fails if the suites are out of date
#
# Env: CATALOG_FILE, EVALS_DIR override the resolved defaults.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
catalog="${CATALOG_FILE:-$here/../catalog.json}"
evals="${EVALS_DIR:-$here/../evals}"
mode="${1:-write}"
case "$mode" in write|--check) ;; *) echo "usage: $(basename "$0") [--check]" >&2; exit 2 ;; esac

[ -f "$catalog" ] || { echo "ERROR: no catalog at $catalog" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
jq empty "$catalog" 2>/dev/null || { echo "ERROR: catalog is not valid JSON" >&2; exit 2; }

suite() { # suite <capability> -> the generated suite on stdout
  jq --arg c "$1" '
    .capabilities[] | select(.capability == $c) |
    { capability: .capability,
      skill: ("ops-" + .capability),
      kind: .kind,
      visibility: .visibility,
      framework_default: .framework_default,
      generated_from: "catalog.json",
      cases:
        ( [ .operations[] as $op
            | { id: ($op.action + "/example"),
                action: $op.action,
                context: $op.example,
                asserts: [
                  "The result makes success or failure unambiguous — it ends with a single JSON object carrying `ok`.",
                  "It reports the facts the catalog lists as this action'"'"'s output, so the next action in a hand-off is not left guessing.",
                  "It did not silently do nothing."
                ] },
              { id: ($op.action + "/empty-context"),
                action: $op.action,
                context: {},
                asserts: [
                  "An absent context is treated as `{}` rather than raising a malformed-input error.",
                  "It either does the sensible default thing or explains what it needed — it does NOT invent a value it was not given."
                ] },
              { id: ($op.action + "/idempotency"),
                action: $op.action,
                context: $op.example,
                repeat: 2,
                asserts: [
                  "The second invocation produced NO second side effect — no duplicate PR, branch, issue, comment, merge or notification.",
                  "The second invocation reported the EXISTING state rather than failing."
                ] }
          ] )
        + [ { id: "unknown-action",
              action: "definitely-not-an-action",
              context: {},
              asserts: [
                "The action was REJECTED. Not guessed at, not mapped to a similar one, not silently succeeded.",
                "The rejection says which actions are valid, or at least that this one is not."
              ] } ]
        + ( if .kind == "data" then
              [ { id: "structured-output",
                  action: (.operations[0].action),
                  context: {},
                  asserts: [
                    "The output is well-formed structured data, not prose. A caller can parse it without interpreting a sentence.",
                    "This is a data capability, so the structure IS the deliverable (conformance spec §4.4)."
                  ] } ]
            else [] end )
    }
  ' "$catalog"
}

caps="$(jq -r '.capabilities[].capability' "$catalog" | tr -d '\r')"

if [ "$mode" = "--check" ]; then
  rc=0
  # The generator is jq, so its version is part of the output contract. Printed on every check
  # so a CI log answers "was it the same jq?" without a second run.
  echo "build-evals --check: jq $(jq --version 2>/dev/null || echo '?'), $(uname -s 2>/dev/null || echo '?')" >&2
  while IFS= read -r cap; do
    [ -n "$cap" ] || continue
    f="$evals/$cap.eval.json"
    if [ ! -f "$f" ]; then echo "ERROR: missing suite for $cap — run scripts/build-evals.sh" >&2; rc=1; continue; fi
    if ! diff -q <(suite "$cap") "$f" >/dev/null 2>&1; then
      # Say WHY, not just that. This gate failed three CI runs in a row while passing on the
      # author's machine, and "is out of date" told nobody anything — the whole investigation
      # went into reproducing a message that should have printed the answer.
      #
      # Byte counts and the first differing offset come first deliberately: the likeliest
      # causes here are invisible in a text diff (a CR, a trailing newline, an encoding
      # difference between jq versions), and a unified diff of those looks like two identical
      # lines. If the sizes differ by exactly the line count, it is line endings.
      gen="$(mktemp)"; suite "$cap" > "$gen"
      {
        echo "ERROR: $f is out of date — run scripts/build-evals.sh"
        printf '  generated: %s bytes\n' "$(wc -c < "$gen" | tr -d ' ')"
        printf '  committed: %s bytes\n' "$(wc -c < "$f" | tr -d ' ')"
        printf '  first differing byte: %s\n' "$(cmp "$gen" "$f" 2>&1 | head -1 || true)"
        echo "  --- diff (generated vs committed), first 20 lines ---"
        diff "$gen" "$f" 2>&1 | head -20 | sed 's/^/  /'
        echo "  --- end diff ---"
      } >&2
      rm -f "$gen"
      rc=1
    fi
  done <<< "$caps"
  # A suite for a capability the catalog no longer declares is worse than a missing one: it
  # would keep passing while testing nothing that exists.
  for f in "$evals"/*.eval.json; do
    [ -f "$f" ] || continue
    cap="$(basename "$f" .eval.json)"
    printf '%s\n' "$caps" | grep -qx "$cap" \
      || { echo "ERROR: $f has no capability in the catalog — delete it" >&2; rc=1; }
  done
  [ "$rc" -eq 0 ] && echo "OK: eval suites are current"
  exit "$rc"
fi

mkdir -p "$evals"
n=0
while IFS= read -r cap; do
  [ -n "$cap" ] || continue
  suite "$cap" > "$evals/$cap.eval.json"
  n=$((n + 1))
done <<< "$caps"
total="$(jq -s '[.[].cases | length] | add' "$evals"/*.eval.json 2>/dev/null | tr -d '\r')"
printf 'Wrote %d suites (%s cases) to %s\n' "$n" "${total:-?}" "$evals"
