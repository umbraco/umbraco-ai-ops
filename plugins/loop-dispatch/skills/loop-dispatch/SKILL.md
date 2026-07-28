---
name: loop-dispatch
description: >-
  Single front door for a repo's automation loops, so one routine per repo can
  handle every loop event instead of one routine per event. Deterministically
  routes each triggering GitHub event (parsed from the trigger block, decided by
  route-event.sh) to the matching loop skill; a non-matching event is a quiet
  no-op. It only routes; each loop owns its own guardrails. Repo-agnostic;
  github-ops required. Trigger from one per-repo routine wired to all the loop
  events.
---

# loop-dispatch

The **front door** to a repo's automation loops. A committed GitHub Action routes each
loop event at the edge (via `route-event.sh`) and fires this routine **only on a match**,
handing it the resolved route. This skill **dispatches that route** to the matching loop —
one routine per repo instead of one per loop/event.

It is a **router, not a worker.** It never builds, merges, or releases anything
itself; it invokes the loop skill that owns that job, and that skill enforces all its
own gates, models, and notifications. loop-dispatch adds no policy of its own.

## The routing table

The mapping is **data, not prose**, in **two layers** that `route-event.sh` merges at the
edge:

| Layer | Where | Who owns it |
|---|---|---|
| **base** | [`route-map.json`](scripts/route-map.json) (schema: [`route-map.schema.json`](scripts/route-map.schema.json)) | the engine — a consumer **never** edits it |
| **overlay** | `.github/ops-routing.json` in the consumer repo (schema: [`ops-routing.schema.json`](scripts/ops-routing.schema.json), [example](scripts/ops-routing.example.json)) | the consumer, optional |

A rule's identity is the pair **`(event, label)`**. An overlay rule with the same key
**wins**; an overlay rule with **`"loop": null` disables** the base rule. Keys in only one
layer are taken as-is. Most repos need no overlay at all.

The base table, rendered:

| event | label | Run |
|---|---|---|
| `issues.labeled` | `ops/ready-for-ai` | **`ops-issue-loop`** (cloud mode) |
| `issues.labeled` | `ops/auto-release` (issue title `release <version>`) | **`ops-release-loop`** |
| `pull_request.labeled` | `ops/auto-merge` | **`ops-merge-loop`** |
| `pull_request.labeled` | `ops/auto-rework` | **`ops-rework-loop`** |

**The event vocabulary is closed**: `issues.labeled`, `pull_request.labeled`,
`issues.opened`, `pull_request.opened`. `pull_request_target.labeled` normalises to
`pull_request.labeled`. A rule using anything else is a **hard error**, not a rule that
quietly never fires.

**`ops-triage-loop` is deliberately absent.** It is a *scheduled* sweep of the learnings
inbox, not an event route, so it has no row here.

Rework is a **label**, not the review event — uniform with the rest, and it works with one
account (you can't fire a `pull_request_review` workflow by reviewing your *own* PR, and
the loop's identity is often the reviewer's). Flow: a reviewer leaves comments, then adds
`ops/auto-rework` to say "address these". Review events are not in the vocabulary at all, so
they route nowhere.

Everything else — a PR labelled `dependencies`/`javascript`, an issue labelled anything
else, any review event — matches **no rule**, so the edge never fires the routine. This is
what kills the wasteful fires: a Dependabot PR labelled `dependencies` woke the merge loop
**4× overnight** under per-event routines; here the edge stops immediately, waking no
routine.

## Config (resolve once)

- **Repo** — identify the current repo (github-ops → *Detect base branch / repo*).
- **github-ops required** — every downstream loop uses it; it must be installed.

## Step 1 — take the resolved loop

Your turn contains the decision the **edge already made** — e.g.
`loop=ops-merge-loop repo=umbraco/… number=269`. The caller workflow ran `route-event.sh`
and only fired you because it matched, so **take that loop as given; don't re-derive it.**
(If a fire ever arrives with no resolved loop, **quiet no-op** — never go looking for work.)

**Cross-repo issues.** When a repo's issues live in a *separate* repo from its code, the
output also carries a `target=<code repo>` distinct from the event's `repo` (where the label
fired). In that case **work against `target`** — check it out and load *its* skills/config —
while reading the issue from the event `repo`. When no `target` is present, event repo ==
work repo (the common case).

**Re-check the entity before acting.** Between the event and this session a label can be
removed or the PR/issue closed. Fetch it (github-ops → `issue_read`/`pull_request_read`,
`method: "get"`, exact `owner`/`repo`/`number`) and confirm it still carries the
triggering label / is still open. If not, **quiet no-op**.

## Step 2 — dispatch the loop

Invoke the matched skill exactly as its own dedicated routine would, scoped to the
specific issue/PR, and **follow that skill's instructions verbatim**:

- `ops/ready-for-ai` issue → **`ops-issue-loop`** (cloud mode) for that issue — the engine
  orchestration commands `ops-change` for the work itself. Local run → its local mode.
- `ops/auto-merge` PR → **`ops-merge-loop`** (it sweeps all `ops/auto-merge` PRs; the event is
  just the wake-up).
- `ops/auto-rework` PR → **`ops-rework-loop`** for that PR.
- `ops/auto-release` issue → **`ops-release-loop`**, version taken from the issue title.

> **Names in flight.** The loops above are the target names (§2 of the migration plan). Until
> Phase 3/4 rename the skills themselves, dispatch to the skill that exists today:
> `ops-issue-loop` → `issue-loop-core`, `ops-merge-loop` → `merge-flow`,
> `ops-release-loop` → `auto-release-loop`, `ops-rework-loop` → `rework-loop`.

**One event → one loop.** Do not chain (don't build *then* merge *then* release in a
single fire) — each of those has its own event that will dispatch its own run. Hand
off and stop.

There is deliberately **no sweep / "check everything" fallback** — routing is only ever
driven by a real event through `route-event.sh`. No event, or an unmatched one, is a
quiet no-op. (Working a whole backlog is a separate, explicit action: run the relevant
loop skill directly.)

## Rules

- **Route, never reimplement.** loop-dispatch only invokes the loop skills. All
  merge/build/release/review policy, models, caps, and notifications live in those
  skills — defer to them completely.
- **Re-check preconditions.** Never act on a stale event; if the label's gone or the
  PR/issue is closed, quiet no-op.
- **One event, one loop.** No chaining within a single fire.
- **Respect each loop's gate** — `ops/ready-for-ai` for building, `ops/auto-merge` as the
  merge approval, `ops/auto-release` to ship. loop-dispatch does not relax any of them.
- **Quiet by default.** Say nothing unless a delegated loop does — don't add a
  dispatch-level notification on top of the loop's own.
- **github-ops for all GitHub work.** Name the operation; it owns the command/tool.
- **Never use `fable`.** The dispatcher runs on a cheap base model (inherit the
  routine's model); the real work — and its model choice — happens inside the loop
  skills and their subagents.

## Wiring it

To stand up the one routine per repo, use the
[`new-loop-routine`](../new-loop-routine/SKILL.md) skill — it owns the standardised
config, the locked prompt template, and the event-wiring steps.
