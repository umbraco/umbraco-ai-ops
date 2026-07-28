---
name: ops-integrate
description: >-
  Land an approved PR. Owns every piece of merge policy — the four gates (landing label,
  CI green, mergeable, base is a live integration branch), the release-base skip, and the
  merge itself — and returns a structured outcome the caller reports on. A caller hands it a
  PR and reads back what happened; it never holds a branch name or a merge strategy. Called
  by name with (action, context-json) by a framework loop. Not model-invoked.
disable-model-invocation: true
---

# ops-integrate

The service that answers one question: **may this PR land, and if so, land it.**

**Visibility: service.** A framework loop may command it. It is the *only* thing
`ops-merge-loop` commands.

**Why it exists.** The gates used to live in the merge loop, alongside the sweep, the poll
cadence and the caps. That put merge *policy* in the same place as merge *scheduling*, and
made the loop resolve base branches and merge strategies itself — the leak
`ops-branching`'s privacy rule exists to close. Split the two: **policy here, scheduling in
the loop.**

**It is PR-generic.** Nothing below asks who wrote the PR or which issue produced it. Every
gate is a machine-verifiable property of the PR itself, which is why dependabot PRs and
human-authored PRs land through the same path as loop-authored ones.

## Invocation

```
ops-integrate land '<context-json>'
```

| Action | Context | Returns |
|---|---|---|
| `land` | `{ pr: { repo, number } }` | `{ ok, outcome, detail, merge_commit }` |

An absent context is `{}`. **Reject any other action** — do not guess.

## The outcome vocabulary

`outcome` is exactly one of:

| `outcome` | Means | `ok` |
|---|---|---|
| `merged` | It landed. `merge_commit` is set. | `true` |
| `skipped:release-base` | Its base is a release base — the release path owns this, not landing. | `true` |
| `blocked:ci` | CI is red, or still pending. | `false` |
| `blocked:conflict` | Not mergeable against its base. | `false` |
| `blocked:changes-requested` | An unresolved human "no". | `false` |
| `blocked:wrong-base` | Its base is neither an integration branch nor a release base. | `false` |
| `blocked:no-label` | The landing label is not on it. | `false` |

`detail` is one plain-language line naming the *specific* blocker — "check `Build (Release)`
failing", "conflicts with its base" — so the caller can comment it verbatim.

> **Standing: a convention, not a contract.** The conformance spec requires no error
> vocabulary and makes the result shape a SHOULD verified by evals. This list is a **fixed
> set the evals assert on**, not a validated envelope, and it travels inside the recommended
> `{ "ok": … }` shape. It becomes a MUST only if a *non-model* consumer ever parses it — a
> shell step, not a loop. Today every caller is a model deciding what to say.

## Action: `land`

### Step 1 — resolve what you need

- The landing label: `ops-repo-meta · identity` → `labels.land`. **Ask for the purpose, not
  the name** — a repo may have renamed it.
- Nothing else. In particular **do not** resolve a base branch, a release base or a merge
  strategy. You cannot, and that is deliberate: `ops-branching` holds them privately.

### Step 2 — the four gates

All must hold. On the first failure, stop and return that outcome — **do not merge**.

1. **The landing label is present.** Read the PR (`github-ops` → *Get a PR*) and confirm it
   still carries `labels.land`. A caller that swept for the label a minute ago is not
   evidence: a human may have pulled it since. → `blocked:no-label`.

   The label **is** the human approval. A GitHub review "approve" is not used as the signal,
   because a maintainer cannot approve a PR they authored and these PRs are commonly theirs.
   As a second safeguard, an **unresolved "changes requested"** review is a human veto that
   outranks the label → `blocked:changes-requested`.

2. **CI is genuinely green.** `ops-ci · status`. Require `state == "green"`, which means
   every check passed — not "nothing failed yet". `pending` → `blocked:ci`, same as red;
   waiting is the loop's business, not this service's.

   **Re-check it even though the loop already polled.** That duplication is deliberate:
   neither current consumer has branch protection and native auto-merge is disabled, so this
   check is the *only* gate that actually holds. A service that trusts its caller has no gate
   at all.

3. **Mergeable, no conflicts.** From the same PR read. If it is merely **behind** its base,
   update the branch and **go back to gate 2** — updating restarts CI, and the green you saw
   was for different code. If it genuinely conflicts → `blocked:conflict`.

4. **The base is a live integration branch.** You cannot compare branch names, so **ask**:
   hand the PR to `ops-branching · merge` and let the owner of the model decide. It refuses a
   base that is not a merge target, and a release base is such a refusal. Map its answer:
   a release base → `skipped:release-base`; any other refusal → `blocked:wrong-base`.

   A release-base PR is **not an error**. It is the release path doing its job, and
   `ops-release` owns it. Return `ok: true` and let the caller stay quiet.

### Step 3 — land it

`ops-branching · merge`, which picks the strategy and deletes the head branch. Return
`merged` with the `merge_commit` it gives back.

### Idempotency

**An already-merged PR MUST return `merged` with the existing commit, never a second merge
attempt.** This is not theoretical: the landing label stays on the PR after it lands, so a
sweeping caller hands you the same PR on its next run. `ops-branching · merge` is idempotent
for the same reason; check the PR's merged state at gate 1 and short-circuit.

### On failure

**Leave the system safe.** Never a partial merge, never a force, never a branch deleted
without a merge. If the merge call itself fails, return `{ ok: false }` with the reason and
change nothing else — a failed landing must be safe to retry on the next sweep.

## Rules

- **Never merge with an unmet gate.** No exceptions, no "it's probably fine", no override
  context. The four gates are the whole reason this service exists.
- **Never use GitHub's native auto-merge**, and never treat a mergeable state as evidence of
  green — with no branch protection, GitHub will land a red PR.
- **Never force-merge, never force-push.**
- **Never resolve or return a branch name or a merge strategy.** Ask for an outcome.
- **Never label, comment or notify.** The caller reports; this service decides. Two things
  commenting on one PR is how a loop starts arguing with itself.
- **Never touch the release path.** A release-base PR is skipped, not landed, not flagged.
- **One PR per call.** Sweeping is the loop's job.
