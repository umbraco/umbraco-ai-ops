---
name: auto-release-loop
description: >-
  Event-triggered release with NO mid-flow human approval, guarded by two automated
  gates: green CI, then an Opus pre-publish review against a (repo-overridable) checklist
  (version correctness, beta-vs-latest, PR scope, conflicts, wrong base, …). When an issue
  titled `release <version>` is labelled `auto-release`, this cuts the release branch, bumps
  version files + changelog, opens the PR to the release base, drives CI green, runs the
  review (a BLOCK finding stops it), then publishes (merge, tag, GitHub Release) and
  back-merges into the integration base, commenting + closing the triggering issue. When
  `branching.release_skill` is set, the loop DELEGATES the cut/bump/tag/back-merge mechanics
  to that applied-repo skill and only orchestrates + gates. Sends a Claude push notification
  at start and on completion. The deliberate act of labelling the issue is the human
  decision. Requires the github-ops skill. Trigger from a routine on Issue: Labeled =
  auto-release, or run manually as "auto-release-loop <version>".
---

# auto-release-loop

The release loop: **issue-triggered and CI-gated, with no mid-flow human approval.** Two
deliberate signals are the go-ahead: (1) a maintainer opened an issue naming the version
and applied the **`auto-release`** label, and (2) **CI on the release PR is green**.
That's it — no approval pause — by design, for fast beta/pre-release cycles.

## Orchestrate at the engine; defer the mechanics

Read the consumer's **`.claude/ai-ops.yml`** (`ai-ops.schema.json`). The loop's job is always
to **orchestrate and gate** — cut → drive CI green → gated pre-publish review → publish/tag →
back-merge — but **who performs the mechanics depends on `branching.release_skill`**:

- **`branching.release_skill` set** → the loop **delegates** the actual cut / version-bump /
  tag / back-merge to that applied-repo skill, and only orchestrates the sequence and enforces
  the two gates (**CI green via github-ops**, the **pre-publish review**). This is the path for
  repos with bespoke release mechanics (auto-versioning tools, manual release tags, versioned
  lines) and is **required** when `branching.model` is `custom`.
- **No `release_skill`** → the engine's built-in mechanics below are the **fallback default**.

Resolve `branching.base` (integration base — where to back-merge) and `branching.release_base`
(where the release lands) via the **`release-and-branching`** skill; it honours
`branching.model` (`gitflow` / `main-only` / `versioned-gitflow` / `custom`). **Never assume
the literal `dev`/`main`** — use the resolved values. (In `main-only` there is no separate
`release_base` and no back-merge step.)

> **Publishing is irreversible.** Once CI is green this ships with no further human
> look, and a published package version can't be cleanly un-published (you'd ship a
> follow-up). Use this only where **CI-green is a sufficient gate** — the deliberate
> `auto-release` label is the one human decision.

## Trigger & input

- Fired by a routine on **Issue: Labeled → `auto-release`** (instant), or run manually
  as "auto-release-loop <version>".
- **Version** = parsed from the triggering issue's **title** (e.g.
  `release 18.0.0-beta3` → `18.0.0-beta3`). If the title has no clear
  `release <version>`, **comment on the issue asking for one and stop** — never guess a
  version.
- **Branch model & bases** via the `release-and-branching` skill — it resolves
  `branching.model` and the `base` / `release_base` from `.claude/ai-ops.yml` (works for
  gitflow, main-only, versioned-gitflow, and custom). Start from an up-to-date `base` (the
  dev-sync contract — see the `sync-dev` skill / `branching.release_skill`).
- All GitHub actions go through the **`github-ops`** skill (required for this loop).

## The `/goal`

```
/goal auto-release <version> of <repo>: release/<version> cut from <base>; version files + changelog bumped; PR to <release_base> is green; pre-publish review passed with no BLOCK; merged to <release_base>; tagged v<version>; GitHub Release published (prerelease if <version> has a pre-release suffix); <release_base> back-merged into <base>; triggering issue commented and closed. (base/release_base resolved from config; mechanics via branching.release_skill when set.)
```

## Step 1 — prepare (autonomous)

**If `branching.release_skill` is set, delegate this whole step to it** — invoke that skill to
cut the release branch, bump versions, and update the changelog its way (auto-versioning,
manual tags, versioned lines, whatever the repo does). The loop then just confirms the branch + PR exist
and continues to gate. Otherwise use the engine default:

1. From an up-to-date `base` (resolved), cut `release/<version>`.
2. Bump the repo's **version-file list** (from its `CLAUDE.md`) and the changelog.
3. Push and open a PR **`release/<version>` → `release_base`** (resolved), referencing the
   triggering issue.

Either way, once the PR to `release_base` is open, send a **Claude push notification** (the
`PushNotification` tool): `auto-releasing v<version> from issue #<n>`.

## Step 2 — drive CI green

Poll the PR's check-run status (github-ops → *Get PR CI / check-run status*) until it
settles, then require **every** check to pass. Fix failures on the release branch (the
issue loop's **8-attempt** cap applies). **CI-green is required** — there is no human
approval step, but the Step 2.5 review is a second, automated gate. If CI can't be made
green, **stop**, comment the blocker on the issue, and leave the PR open. **Never publish
on red**, never trust a bypassing auto-merge.

## Step 2.5 — pre-publish review (second gate)

Once CI is green, and before anything irreversible, run the dedicated **`release-reviewer`
agent** (defined in this plugin — read-only Opus; what it checks and how it judges live
in its own definition). Gather the PR's facts via `github-ops` — PR number / head / base,
target version, triggering issue, the diff (changed files + size), CI status,
mergeability — and pass them to the agent. It scores the PR against the **applied repo's
release-review checklist when the repo provides one** (a repo-shipped file — see the
reviewer agent), otherwise against the engine's **default** checklist
(`references/release-review-checklist.md`); the checklist is a **seam**, not a fixed list.
It returns **VERDICT: PASS** or **VERDICT: BLOCK + findings**; the loop **gates on the
verdict** (the agent is read-only and can't publish itself).

> The routine's `allowed_tools` must include the Agent/Task tool so `release-reviewer`
> can be spawned. If it can't be spawned in the environment, do the review inline on the
> loop's model and **note in the outcome comment that it wasn't the Opus `release-reviewer`**.

- Any **BLOCK** finding → **do not merge/tag/publish.** Leave the release PR open, then:
  1. **Create a new issue** in the repo titled `Release <version> blocked by pre-publish
     review`, detailing the reviewer's BLOCK findings (each: which check / what's wrong /
     why) plus links to the release PR and the triggering issue. Label it
     `release-blocked` if that label exists.
  2. **Send a Claude push notification** (the `PushNotification` tool) summarising the
     block and linking the new issue.
  3. **Comment on the triggering issue** pointing to the blocked issue + PR, and **remove
     its `auto-release` label** so the loop doesn't re-fire until a human fixes the cause
     and re-labels.
- **WARN** findings → proceed, but include them in the completion comment.
- Continue to publish **only** when the checklist passes with no BLOCK.

## Step 3 — publish (once green + review passed)

The **merge** into `release_base` always goes through github-ops (it's a gate). **Tagging is
delegated to `branching.release_skill` when set**; otherwise the engine does it:

1. Merge `release/<version>` → the resolved **`release_base`** per convention (github-ops →
   *Merge a PR*).
2. **Tag `v<version>`** and **create the GitHub Release** — mark it **prerelease** if
   `<version>` has a `-alpha` / `-beta` / `-rc` suffix. **If `branching.release_skill` owns
   tagging** (e.g. an auto-versioning tool / manual release tags), invoke it and confirm the result;
   otherwise do it explicitly (the `release-and-branching` `assets/release-tag.yml` example
   is the fallback if the repo has no automation).
3. Verify: `release_base` contains the release, `v<version>` points at it, the Release is
   published.

## Step 4 — back-merge + close out (autonomous)

1. **Back-merge `release_base` → `base`** so the base carries the bump + any release fixes.
   **Delegate to `branching.release_skill` when set**; otherwise use the engine fallback (the
   `release-and-branching` `assets/sync-main-to-dev.yml` example if installed, else a manual
   back-merge). **Skip this only for `main-only`** (no separate base). **The `/goal` is not
   met until the base is synced** (where one exists).
2. **Comment the outcome on the triggering issue** (Release link, tag, "base synced") and
   **close it**. Also send a **Claude push notification** (the `PushNotification` tool):
   `Released v<version> — published + base synced.` Fall back to the issue comment alone
   if push isn't available.

## Guardrails

- **Two gates before publish: CI-green AND the pre-publish review (Step 2.5).**
  Never publish on red, and never publish with an open **BLOCK** finding. No human
  approval step by design — labelling the issue `auto-release` was the human decision.
  These gates are the engine's job **even when the mechanics are delegated** to
  `branching.release_skill` — delegation never bypasses a gate.
- **A BLOCK is always surfaced, never silent** — file a `Release <version> blocked …`
  issue **and** push-notify, then de-label the triggering issue so it doesn't re-fire.
- **Never force-push; never skip the back-merge** (except `main-only`) — an un-synced base is
  the classic release mistake.
- **One release per triggering issue**; take the version only from that issue's title.
- **Mark pre-releases** (`-alpha` / `-beta` / `-rc`) as GitHub prereleases.
- If the version is ambiguous, or CI won't go green, **stop and report on the issue**
  rather than guessing or shipping something unverified.

## Running as a routine

Set up a routine with trigger **Issue: Labeled**, filtered to **Labels is one of
`auto-release`**, on an environment that has this skill (+ `github-ops`,
`release-and-branching`, `sync-dev`) — then labelling a `release <version>` issue fires
it. The version comes from the issue, so nothing else needs configuring per run.
*(The `auto-release` label must exist on the target repo.)*
