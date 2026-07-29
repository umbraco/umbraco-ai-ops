---
name: ops-branching
description: >-
  This repo's branch model, and the only holder of it. Merges a PR with whichever strategy
  the model calls for, opens a PR onto the correct base for its line, and starts a work
  branch rooted correctly. The integration branches, the release base and the merge
  strategy are PRIVATE — a caller asks for an outcome and never learns a branch name or a
  strategy. Command-only: it answers no reads. Called by name with (action, context-json)
  by a service, never by a loop. NOT for direct use — never select it from a description match.
---

# ops-branching

The repo's branch model lives here and **nowhere else**. Before this capability existed,
base-branch knowledge lived in four places — a config schema, a detection skill, the merge
loop's own resolve-and-compare, and a forge operation that deferred back to the detection
skill. They drifted. Collapsing them into one owner is the point of this skill.

**Visibility: supporting primitive.** A **service** (`ops-integrate`, `ops-release`,
`ops-change`) may call it. A **framework loop must never call it directly** — if a loop
holds a branch name, this capability has failed.

## The privacy rule

**The integration branches, the release base and the merge strategy never leave this
skill.** There is no `resolve-base`, no `merge-strategy`, and no `classify-pr`. A caller
says "merge this PR" and reads back what happened; it does not ask "what is the base?" and
then compare.

Why it is worth the inconvenience: the moment a caller can read the base, two callers can
disagree about it, and the drift is back. An outcome cannot drift.

**Command-only.** Every action below *does* something. This skill answers no questions.

## Invocation

```
ops-branching <action> '<context-json>'
```

| Action | Context | Returns |
|---|---|---|
| `merge` | `{ pr }` | `{ ok, merged, merge_commit }` |
| `open-pr` | `{ branch, line, title, body }` | `{ ok, pr_number, url }` |
| `start-branch` | `{ line, slug }` | `{ ok, branch }` |

An absent context is `{}`. **Reject any other action** — do not guess. All three are
idempotent: see each action.

All GitHub work goes through **`github-ops`** by operation name. This skill decides *what*
and *onto what*; `github-ops` owns *how*.

## What it knows, privately

Resolve these **once per invocation**, and never return them:

1. **The live lines** — from `ops-repo-meta · lines`. **Read it every time; never cache
   it.** A major-version cutover adds a line, and no engine change may be needed for that.
2. **The branch model** — one of `gitflow`, `main-only`, `versioned-gitflow`, `custom`.
   Detect it from the branches when the repo has not declared it:

   | Branches present | Model | Reference |
   |---|---|---|
   | a `vN/dev` **and** a `vN/main` | `versioned-gitflow` | [`versioned-gitflow.md`](references/versioned-gitflow.md) |
   | a `dev` **and** a `main` | `gitflow` | [`gitflow.md`](references/gitflow.md) |
   | only `main`, no `dev` | `main-only` | [`main-only.md`](references/main-only.md) |
   | anything else | **ask** — never invent a `dev` branch | — |

3. **The integration branches — a SET, not a branch.** One entry per live line: `vN/dev`
   under versioned-gitflow, `dev` under gitflow, `main` under main-only. **Every base check
   is set membership.** A repo with v13, v17 and v18 live has three legitimate bases, and
   equality against one of them would flag the other two as wrong-base.
4. **The release bases** — `vN/main` per live line under versioned-gitflow, `main` under
   gitflow, **none** under main-only (releases land on the integration branch itself).
5. **The merge strategy** — `squash` by default; `merge-commit` where the model calls for
   it (a release branch into a release base preserves history). The caller never passes it.

For a **`custom`** model this skill decides nothing: the repo must ship its own
`ops-branching`, and the presence of a custom model with no override is a configuration
error worth reporting rather than guessing around.

## Action: `merge`

Merge the PR in front of you, using this repo's strategy.

1. Read the PR (`github-ops` → *Get a PR*): base, mergeable state, head branch.
2. **Check the base is one of the integration branches** — membership, not equality. It is
   not this skill's job to decide *whether* the PR should land (that is `ops-integrate`'s
   gates); it is this skill's job to refuse to merge into a branch the model says is not a
   merge target. Return `{ ok: false, detail: … }` rather than merging somewhere plausible.
3. Merge with the resolved strategy and **delete the head branch** (`github-ops` → *Merge a
   PR (+ delete branch)*).

**Idempotent:** a PR that is **already merged MUST** return `{ ok: true, merged: true }`
with the existing `merge_commit`, not attempt a second merge. The landing label stays on a
PR after it lands, so a sweeping caller *will* hand you the same PR twice.

**Never** force-merge, never use GitHub's native auto-merge (it would land without the
caller's gates), never merge into a release base here — a release lands through
`ops-release`.

## Action: `open-pr`

Open a PR from a work branch onto the right base for its line.

1. Resolve the integration branch **for that line** — the caller names the line (`v17`), not
   the branch (`v17/dev`). A caller that knows the branch already has the leak this skill
   exists to prevent.
2. Open it (`github-ops` → *Create a PR*) with the given title and body.

**Idempotent:** an open PR from that head branch onto that base **MUST** be returned as-is,
not duplicated.

## Action: `start-branch`

Create a work branch, named this repo's way, rooted on the right base.

1. Resolve the integration branch for the named line.
2. Name the branch to the repo's convention — by default `<type>/<slug>` with type from
   `feature` / `fix` / `chore` / `docs` / `refactor` / `test`.
3. Create it from that base (`github-ops` → *Create a branch*).

**Idempotent:** if the branch exists, return it.

## Rules

- **Never return a branch name or a strategy** except the head branch a caller just asked
  you to create (`start-branch`) — that one is the caller's own handle on its work, not
  knowledge of the model.
- **Never commit directly to an integration branch or a release base.** Always a branch,
  always a PR.
- **Base checks are membership over the live-line set**, re-read every invocation.
- **Never force-push.**
- **A red PR is not this skill's problem.** It merges what it is told to merge, once the
  base is legitimate. Gating is `ops-integrate`'s job, and duplicating it here would put
  merge policy back in two places.
- **`custom` model with no repo override is an error, not an improvisation.**
