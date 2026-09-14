---
name: ops-rework-loop
description: >-
  Label-triggered loop that acts on PR review feedback. When a reviewer has left comments and
  labels a PR `ops/auto-rework`, it reads every actionable point, commands `ops-change ·
  implement` scoped to that feedback and `ops-change · verify`, pushes, replies on the threads,
  re-requests review, and clears the label — then stops. It never waits for CI and never
  merges: it hands the PR back so there is one merge path behind one human gate. Runs in a
  cloud routine or locally. Trigger: a PR labelled `ops/auto-rework`, or "rework PR #N".
---

# ops-rework-loop

The **review-response half of the issue loop, split out so it can be event-driven.**
[`ops-issue-loop`](../ops-issue-loop/SKILL.md) takes a ready issue to a CI-green PR and stops.
When a reviewer reviews that PR and labels it **`ops/auto-rework`**, this loop addresses the
feedback — closing the write → review → rework → land chain with no long-lived "watch my
review" session.

Like the issue loop, it owns **orchestration, not build steps**. The editing is
**`ops-change`**, which the repo provides. This loop only sequences: read feedback → change,
scoped → verify → push → reply → clear the label.

**It does not land its own fix.** It hands the PR back to the human, who applies the landing
label, and `ops-merge-loop` lands it. One merge path, one human gate — a rework loop that merged
its own work would have quietly created a second of each.

## What it calls

| Capability · action | Why | Visibility |
|---|---|---|
| **`ops-change · implement`** | make the changes the review asked for | service |
| **`ops-change · verify`** | the repo's fast sanity pass over them | service |
| `ops-ci · status` / `log` | **only** if a review points at a CI failure — never to wait for green | cross-cutting (read) |
| `ops-repo-meta · identity` | `labels.rework`, by purpose | cross-cutting (read) |
| `ops-notify · send` | one line when a round completes | cross-cutting (infra) |

**Never `ops-integrate`, never `ops-branching`, never `ops-workspace`.** Landing is not this
loop's, the branch is already chosen (it is the PR's head), and `ops-change` handles its own
workspace.

## Trigger and scope

- Fired when a PR is labelled `labels.rework` (routed by `loop-dispatch`), or run manually as
  "rework PR #N". A **label** rather than the review event, because it fires even when the
  reviewer's account is the PR author's — which is common here, since the loop authored the PR.
  Reviewer flow: leave the comments, then add the label.
- **Read all the feedback first.** The label is an explicit "address these", so read the reviews
  and inline comments and act on every concrete point. A comment that is genuinely unclear gets a
  **reply asking**, not a guess.
- **Act on the labelled PR only.** Never touch another PR.

## CI is asynchronous, and this loop never waits for it

It makes the edits, runs the repo's **fast sanity pass** via `ops-change · verify`, pushes, and
**stops**. It does not poll for green.

Why that is safe: **`ops-integrate` re-checks CI itself before landing**, so CI is enforced at
the gate that actually matters. A rework session sitting on check-runs burns time and tokens to
learn something the lander will verify anyway — and keeping the session short is the entire
point of splitting this out.

## Step 1 — read the feedback

Get the PR with its reviews and review comments (`github-ops` → *Get PR reviews + review
comments*). Collect every **unresolved, actionable** item: requested changes, inline comments,
review-body asks.

**Nothing actionable** (an approval, or praise only) → **clear the label, comment why, and
stop.** Never invent changes to justify the fire.

## Step 2 — change it, scoped

**`ops-change · implement`** with the PR's head branch and the collected feedback as the work to
do, then **`ops-change · verify`**.

**Stay scoped to the feedback.** Resolve what was raised and nothing more — no unrelated
refactor, no growing the PR. A reviewer who asked for one rename and got a restructure has to
review the whole thing again, which is the opposite of what this loop is for.

If a review point is *"CI is failing on X"*, read it with `ops-ci · log` — that is the one
legitimate CI read here.

## Step 3 — push, reply, clear the label

Immediately after `verify` passes, with **no CI wait**:

1. **Push** to the PR branch (inside `ops-change`).
2. **Reply briefly on each addressed thread** — what changed. A reviewer should not have to
   diff to find out whether their point was taken.
3. **Re-request review** from the original reviewer (`github-ops` → *Re-request review*).
4. **Remove `labels.rework`.** The label means "rework pending"; clearing it marks the round
   done **and re-arms the trigger**, so a later review can re-add it for the next round.
5. **Notify** with a stable key per PR and round — reworked PR #N, pushed, review re-requested,
   CI will verify.

## Guardrails

- **Only actionable feedback triggers a rework.** A plain approval is a clear-the-label no-op.
- **Scoped to the review.** Never grow the PR.
- **Always clear the rework label on exit** — on completion *and* on the no-op — so the label
  always means "rework pending" and the trigger stays re-armable. A round that leaves it on
  re-fires on itself.
- **Never merge, and never apply the landing label.** Re-request review and hand back.
- **Never wait on CI.** `ops-integrate` re-checks it at the gate.
- **Never use `fable`.** This loop edits code — Sonnet or better.

## Running as a routine

Trigger: a PR labelled `ops/auto-rework`, routed by `loop-dispatch`, on an environment carrying
this skill, `github-ops`, `ops-capabilities` and the repo's own `ops-change`. One PR per fire.
Use a capable coding model. State cloud vs local explicitly in the routine prompt.

> **Capture is automatic.** The `ops-learnings` hooks analyse the transcript off the critical
> path and file an `ops/proto-learning` issue if the feedback revealed a systemic lesson. You
> file nothing by hand.
