# Future direction: beyond routines

Status: **direction agreed, exploration not yet started** · Owner: AI team (Phil) · 12-08-2026

This is a direction document, not a plan. It records where we currently believe this engine needs
to go once the capability-model work
(**[`capabilities-migration-plan.md`](capabilities-migration-plan.md)**) has landed, and commits to
a timeboxed exploration rather than a migration. Nothing here changes the engine today — the
**[golden rule](../CLAUDE.md#golden-rule-the-engine-is-product-agnostic)** and the capability
convention hold regardless of which delivery vehicle eventually runs a loop.

## 1. Routines are a stop-gap, not the destination

A Claude Code **routine** (per **[`vocabulary.md`](vocabulary.md)**) is a scheduled or triggered cloud run of a
loop — the delivery vehicle, not the logic. Routines are good for what they've been used for so
far: prototyping the capability model, and running loops without a developer having to sit and
watch. But the team's own risk assessment of the current approach identifies three structural
limits that are not going to be solved by iterating on routines further:

- **They can't be shared between people.** A routine belongs to the account/session that created
  it; there's no notion of a team owning one together.
- **They can't be centrally managed.** There's no fleet view, no way to see or govern every
  routine running across the org's repos from one place.
- **They can't be defined as infrastructure-as-code or source-controlled.** A routine's
  configuration lives in whatever UI created it, not in a file this repo (or any repo) can diff,
  review, or roll back.

None of this is a criticism of routines for what they're currently doing — running loops
end-to-end has been how the capability model got proven out. It's a statement that the delivery
vehicle needs to change before this engine can be operated as shared infrastructure rather than
one person's tooling.

## 2. Direction: managed agents

The direction we want to move in is some form of **managed agent** — an agent definition that is
itself infrastructure: version-controlled, deployable, and governable independently of any one
person's local session. The natural starting point is **Anthropic's managed agents** offering
(server-hosted agents with a managed sandbox, via the Claude API / Agent SDK), since it's the
closest fit to what this engine already assumes (Claude Code, skills, the capability convention)
and would let the engine's existing plugins move across largely unchanged.

A secondary effect of this move is a reduction in **time pressure**. Today, using a local
(interactive) agent means a developer is present and, in effect, paying attention to and gating the
session — coding tasks compete with the fact that a person is waiting on them. Moving completion of
coding tasks to managed agents removes that constraint: no developer needs to be watching, so the
task can run on its own schedule rather than the developer's.

## 3. A second thread: open-weight models

Independently of which managed-agent framework we use, **open-weight models are becoming
capable enough to be worth evaluating for this kind of work.** We want to explore running this
engine's loops against an open-weight model, which necessarily means pairing it with a
**different, open-weight-capable managed agent framework** — Anthropic's managed agents offering
is Claude-only, so this is a genuinely separate track, not a variant of §2.

This is exploratory by design: the goal over winter is to learn whether an open-weight model
plus an alternative managed-agent framework can drive the capability model's loops at all, not to
commit to replacing Claude. The **golden rule** (the engine is product-agnostic) has an
analogue here worth naming explicitly: the engine should not be model-agnostic by accident — if
this track proves out, model/framework choice becomes another seam, not something hard-coded into
the loops.

## 4. The blocker: two different token economies

Routines run on **Claude subscription tokens** — the same pool a developer's interactive Claude
Code usage draws from. Managed agents, by contrast, bill on **API tokens** — a separate, metered
pool with its own budget owner. Moving loops from routines to managed agents doesn't just change
*where* they run, it changes *which budget* pays for them, and today those are two different
plans with two different owners.

This friction would be substantially reduced by moving to an **Anthropic Enterprise plan with
pooled tokens** spanning both subscription and API usage, so the same pool funds interactive
developer sessions and managed-agent runs. **This is not a commitment** — it's a licensing/commercial
decision that needs sign-off from whoever owns that budget, and per this org's standing rules on
pricing and subscription tiers, nothing here should be read as confirming terms, tiers, or cost
with Anthropic. It's named here because it's the blocker that most directly gates §2, and because
knowing the shape of the blocker now means it can be raised as a commercial question early rather
than discovered once a managed-agent pilot is otherwise ready to ship.

## 5. Timeline: winter 2026/27

We're committing to **exploring both threads over this coming winter (roughly December 2026 –
February 2027)**, in parallel, as spikes rather than migrations:

| Track | What "explored" means by end of winter |
|---|---|
| **A — Anthropic managed agents** | A pilot: one existing loop (candidate: a low-risk one, e.g. `ops-triage-loop` or `ops-rework-loop`) ported to run as a managed agent instead of a routine, far enough to know what changes in the plugin/capability boundary and what the API-token cost looks like in practice. |
| **B — open-weight model + alternate framework** | A spike: the same or a simpler loop driven against at least one open-weight model through a non-Anthropic managed-agent framework, far enough to know whether the capability model (skills-by-name, JSON action contracts) survives the switch at all. |

Both tracks end with a decision point, not an automatic continuation: does either approach clear
the bar routines can't (shareable, centrally managed, source-controlled), and at what cost. That
decision is out of scope for this document.

## 6. Open questions carried forward

- Which loop is the right pilot for Track A — needs to be low-risk enough that a failed pilot
  doesn't block real work, but real enough to exercise the capability boundary honestly.
- Which open-weight model and which alternate managed-agent framework Track B targets — not yet
  chosen.
- Whether "model/framework as a seam" (§3) needs a new seam entry in `CLAUDE.md`'s seam table, or
  folds into an existing one (`ops-repo-meta` declared facts is the closest existing shape) —
  decide once Track B has something concrete to seam against.
- The Enterprise pooled-token question (§4) needs an owner outside engineering to actually pursue.
