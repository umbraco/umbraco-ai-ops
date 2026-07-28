---
name: ops-triage-loop
description: >-
  The weekly sweep that turns captured proto-learnings into reviewed work. Reads the open
  `ops/proto-learning` issues on the learnings repo, clusters them by lesson, applies a
  promotion threshold, and routes each cluster to its home — an issue on the repo that owns
  it, a drafted PR against shared skills, a `ops/loop-improvement` issue against the engine,
  or closed with a reason. Files issues rather than editing product repos, and nothing
  auto-merges. Scheduled, not event-triggered: `ops/triaged` is a marker it writes, never a
  trigger. Trigger on "triage the learnings", "run the triage sweep".
---

# ops-triage-loop

The **triage half** of the self-learning system. The capture half — read-only `SubagentStop` /
`SessionEnd` hooks in this plugin — files **proto-learnings** as issues off the critical path.
This loop turns that raw backlog into reviewed work by routing each lesson to whoever owns it.

**It is scheduled, not routed.** There is no triage label and no route row: it wakes weekly and
sweeps. `ops/triaged` is a marker **this loop writes**, so the next run skips what it has already
handled — it is an output, never a trigger.

Why weekly and not per-issue: **the threshold needs a population.** A lesson earns a shared-skills
PR by *recurring*, and you cannot see recurrence one issue at a time. Capture is continuous;
triage is periodic; a weekly cadence keeps the inbox from growing without flooding anyone.

**It never hand-edits a product repo.** For anything specific to one repo it files an **issue**
there and lets that repo's own process implement it. It drafts an actual **PR** only for shared
tooling. Everything is gated; nothing auto-merges.

## What it calls

| Capability · action | Why | Visibility |
|---|---|---|
| `ops-repo-meta · topology` | the `learnings` inbox, and the `code` repo a lesson belongs to | cross-cutting (read) |
| `ops-repo-meta · identity` | `labels.proto_learning`, `labels.triaged`, `labels.loop_improvement`, by purpose | cross-cutting (read) |
| `ops-notify · send` | one line per run, only when something was routed | cross-cutting (infra) |

All GitHub work goes through **`github-ops`** by operation name. This loop commands **no
services**: it reads, files and closes, which is forge work, not product work.

## Config

| Thing | Value |
|---|---|
| Inbox | the **`learnings`** repo from `topology` (defaults to `code`) |
| Inbox filter | open issues, labelled `labels.proto_learning`, **not** labelled `labels.triaged` |
| Routed items per run | **≤ 10** total, of which **≤ 5** may be PRs |
| Cadence | **weekly**, as a scheduled routine |

> **The numbers are inherited defaults, not measurements.** The threshold of 2 and the caps of
> 10/5 come from the prototype, which ran over a family of many small repos where the same lesson
> recurred quickly. Over two large repos a cluster fills more slowly. Adopt them, watch real inbox
> volume, and change them deliberately — do not re-derive them from nothing.

## The routing table

`guessedHome` on the record is a **hint**; you decide. The deciding question is
***"would a different repo benefit from this?"***

| Home | Where it goes | Mechanism | When |
|---|---|---|---|
| **`code`** | the repo named by the cluster's `sourceRepo` | **Issue**, titled `[from-learnings] …` | The lesson is specific to that repo — a quirk of its own code, content or config. Only here when it affects *that* repo and no other. |
| **`shared-skills`** | the shared consumer repo of a repo family | **PR**, drafted | Generalizable: it recurs across repos, or would help any repo. **Requires the threshold.** |
| **`loop-self`** | this engine | **Issue** labelled `labels.loop_improvement` | About how a loop or the orchestration itself behaves. The loop must not rewrite its own definition unreviewed. |
| *discard* | — | **Close** with a one-line reason | Not actionable, stale, or wrong. |

**That fourth outcome is normal, not a failure.** "Not actionable, stale or wrong" is a legitimate
result, and a triage run that never discards anything is not being honest with the inbox.

**Domain-specific versus generalizable is the core judgement.** A lesson goes to one repo **only**
when it affects that repo and no other. The moment it would help a second repo it belongs in
`shared-skills`, not duplicated into one repo's skills. When genuinely unsure: prefer
`shared-skills` if it is a tooling or pattern lesson, otherwise **hold it** (leave the
proto-learning open, uncommented) rather than mis-filing.

> **`shared-skills` may not be reachable in your topology.** It only means anything for a repo
> **family** with a shared consumer repo. For a single-product consumer there are only two live
> destinations, `code` and `loop-self` — and since a shared-skills PR is the *only* thing the
> threshold gates, **the threshold gates nothing there.** Say so in the run summary rather than
> pretending to apply it.

## Step 1 — gather the inbox

**List** the open issues on the inbox repo carrying `labels.proto_learning` and **not**
`labels.triaged`. For each, parse the fenced `json` record from the body (see
[`references/proto-learning-schema.md`](references/proto-learning-schema.md)).

- **Malformed record** → comment asking for a reformat and skip it. Never guess at fields; a
  guessed `category` clusters wrongly and is worse than a skip.
- **Empty inbox** → report "nothing to triage" and stop. A normal outcome.

## Step 2 — cluster and dedupe

Group issues expressing the **same lesson**: same `sourceRepo` + same `category` + a
**semantically equivalent** `lesson`. Each cluster becomes **one** routed item and carries the
full list of source issue numbers as **provenance**.

**Dedupe across the whole open set, here, in reasoning — not per issue.** That is the entire point
of a batch sweep, and it is the one part of this mechanism that is genuine judgement rather than
arithmetic. Two records describing the same gap in different words are one cluster.

## Step 3 — apply the threshold

Compounding means **a pattern**, not a one-off:

- **Recurred** — a cluster with **≥ 2** distinct source issues, *or* the same lesson seen across
  **≥ 2** `sourceRepo`s → eligible for **`shared-skills`**.
- **Single occurrence**, repo-specific → a **`code`** issue, or **hold** it (leave open,
  uncommented) if it is too thin to act on yet. **Never promote a single incident into a shared
  skill.**
- **`loop-self` clusters are not threshold-gated** — route them whenever they are actionable. A
  loop that wastes a wake-up wastes it every week; waiting for a second sighting buys nothing.

## Step 4 — route each cluster

**`code`** — an issue on the owning repo:

1. Confirm the lesson truly affects only that repo. If it would help another, re-route to
   `shared-skills`.
2. **Create an issue** there: a clear title prefixed `[from-learnings] `, what should change and
   why, and — from the record's notes — a hint whether it belongs in that repo's `CLAUDE.md` or in
   one of its skills. Let that repo's process decide the final placement.
3. **Do not apply the ready label.** A human decides whether to feed it to the issue loop. That is
   the compounding gate, and a loop that self-feeds has removed it.

**`shared-skills`** — a drafted PR:

1. Create a branch and push the **smallest** edit to the shared skill that *should have* surfaced
   the lesson.
2. Open the PR. **Threshold and provenance are required, no exceptions.**

**`loop-self`** — an issue on the engine:

1. **Create an issue** labelled `labels.loop_improvement`: what the loop does today, what should
   change, and why.
2. **Do not draft a PR editing a loop skill.** A human frames a change to the loop's own
   definition.

**Every routed item carries provenance**: the source issue numbers linked, the
`sourceRepo#issue` / PR each came from, and the occurrence count as threshold evidence.
**Reviewers approve facts, not vibes** — a routed item without its evidence is unreviewable.

## Step 5 — mark processed

**The rule differs by destination, and the difference matters:**

- **`shared-skills` (a PR)** — comment the PR link on each source issue and add
  `labels.triaged` so the next run skips it, **but leave it open** until the PR merges. **Never
  close a proto-learning just because you opened a PR for it** — a rejected PR would silently lose
  the lesson.
- **`code` and `loop-self` (issues)** — **close** each source proto-learning with a comment
  linking the new issue. Safe, because the lesson now lives in that issue.
- **Discarded** — close with a one-line reason.

## Caps and guardrails

- **≤ 10 routed items per run, of which ≤ 5 are PRs.** If more clusters are ready, route the
  highest-value ones, **`log` how many were deferred**, and leave the rest for next week —
  **never silently drop them.**
- **Never hand-edit a product repo's content.** File an issue there instead.
- **A shared-skills PR requires the threshold and provenance.** No exceptions.
- **Never auto-merge, never force-push, never edit a protected branch directly.**
- **One cluster → one routed item → one home.** Never bundle unrelated lessons.
- **Never apply a ready label to anything you file.** The human gate is what makes this compound
  safely.
- **Never use `fable`.**

## Running as a routine

Schedule this **weekly** as a cloud routine. It wakes, runs Steps 1–5 against the current inbox,
routes up to 10 clusters, and stops — the issues sit in their owning repos and any shared PR sits
for review. `ops/triaged` keeps the next run from re-doing the same work.

It needs this skill, `github-ops`, and `ops-capabilities`. The three labels
(`ops/proto-learning`, `ops/triaged`, `ops/loop-improvement`) must exist on the inbox repo before
the first sweep — the filter is label-based, and `ops/triaged` is written by this loop.
