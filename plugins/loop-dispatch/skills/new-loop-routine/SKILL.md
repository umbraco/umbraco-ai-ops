---
name: new-loop-routine
description: >-
  Stand up the standardised loop automation for a repo — one loop-dispatch routine per
  repo, fired by a committed GitHub Action (not UI event triggers), with identical env,
  model, tools, connections, and a thin prompt every time. The Action routes at the edge
  and only fires the routine on a real match. Use when onboarding a new repo to the
  loops, or to standardise/rewrite existing routines. Interactive/local.
---

# new-loop-routine

The **single source of truth** for a repo's loop automation. Every repo gets **one
`loop-dispatch` routine** plus **one committed caller workflow** — identical except for
the repo. The routine is fired by the GitHub Action (via its Fire URL), so there are **no
UI event triggers** and none of the event-type-mixing limits they impose.

Why a GitHub Action, not UI triggers: the routines UI can't put different GitHub event
types (issue + PR + PR-review) on one routine, and each is a separate manual, un-scriptable
setup. A committed Actions workflow subscribes to all event types at once, routes at the
edge (`route-event.sh`), and fires the routine **only when the event maps to a loop** — so
non-matching events (a Dependabot `dependencies` label) cost nothing.

## Standard routine config (identical for every repo)

| Field | Value |
|---|---|
| `environment_id` | your ops cloud env — the one running the `cloud-skill-sync` setup script (from `/schedule`; account-specific, not written here). |
| `model` | `claude-sonnet-5` — the dispatcher base; the loops pick their own subagent tier. |
| `allowed_tools` | `["Bash","Read","Write","Edit","Glob","Grep","Skill","Task"]`. |
| `sources` | the target repo, e.g. `https://github.com/umbraco/<repo>`. |
| `mcp_connections` | Slack + Claude_Code_Remote (for push) — connector UUIDs from `/schedule` (account-specific, not written here). |
| trigger | **none / disabled cron placeholder** — the routine is fired by the Action's Fire URL, not a schedule or UI event. |

The routine's stored prompt is the **Consolidated routine** block in
[`references/routine-prompts.md.template`](references/routine-prompts.md.template) (copy
verbatim, replace `{{OWNER_REPO}}`, no rewording). The Action appends the edge-resolved
route to each fire.

Never use `fable`. Never put secrets in the prompt or config.

## Procedure

**Preconditions (once per repo):**
1. **The labels exist.** Do not hand-write the list: **`/ops-install` creates every one of them**,
   on the repo each one's role implies, from `plan-labels.sh`. If you are standing up a routine on
   a repo that has not been onboarded, run the installer first. (This step used to carry a
   six-name list of its own, which had gone stale by six labels — `ops/in-progress`,
   `ops/auto-rework`, `ops/port`, `ops/proto-learning`, `ops/triaged` and `ops/loop-improvement`
   were all missing — and cited a `self-learning-system.md` that does not exist in this repo. A
   copy of a list is a list that rots; the planner is the source.)
2. **Skills reach the env** — paste `scripts/cloud-setup-stub.sh` into the environment's **Setup
   script** field. No variables and no token: the engine is public, so the clone is anonymous.
   On an environment that already exists, **bump the `# rebuild:` number** as well, or it keeps
   serving its cached snapshot. There is no list to add a skill to: `cloud-skill-sync.sh` delivers
   **every** skill and agent in the repo, precisely so that adding one needs no second edit.
3. **Org Actions policy** allows calling a reusable workflow from `umbraco/umbraco-ai-ops`
   (if the org restricts actions to "selected", allowlist it). Nothing else is needed: the engine
   is public, so Actions resolves the reusable workflow without an access grant.

**Stand it up:**
1. **Create the routine** (via `RemoteTrigger` `create`) with the [Standard config](#standard-routine-config-identical-for-every-repo),
   `enabled: false`, a cron placeholder, and the consolidated prompt. One per repo.
2. **Generate its token + Fire URL** in the routines UI (*Call via API* → *Generate
   token*). These are per-routine.
3. **Set two secrets** on the repo (or the org, to share): `LOOP_DISPATCH_FIRE_URL` (the
   Fire URL) and `LOOP_DISPATCH_TOKEN` (the token) — `gh secret set …`.
4. **Commit the caller workflow** — copy [`references/loop-dispatch.yml.template`](references/loop-dispatch.yml.template)
   **verbatim** to the repo as `.github/workflows/loop-dispatch.yml` (open a PR).
5. **Smoke-test** — label a throwaway issue `ops/ready-for-ai` (Action fires → routine builds
   a PR), and label a PR `dependencies` (Action computes `loop=none` → routine never fires).

### Cross-repo consumers (issues and PRs in different repos)

When a product's issues live in a **separate repo** from its source (e.g.
`Umbraco.Forms.Issues` → the Forms code repo), the caller workflow is **split across the two
repos** — the same template, wired to different events in each:

- In the **issues repo**: subscribe to `issues` (labelled `ops/ready-for-ai` / `ops/auto-release`)
  and commit a `.claude/ops-repo-meta.json` there declaring **`topology.code`**. The router reads
  it and emits `target=<code repo>`, so the routine works there while reading the issue here.
  **`with.target_repo` also does this and is deprecated** — it was the same fact hand-written a
  second time, in another file in another repo, with nothing to catch the two disagreeing.
- In the **code repo**: subscribe to `pull_request_target` (labelled `ops/auto-merge` /
  `ops/auto-rework` / `ops/port`) — those events fire where the PRs live, and the work is
  already there, so nothing needs declaring.

A same-repo consumer (issues and PRs together) keeps a single workflow subscribing to both,
with no `target_repo`.

## Rules

- **One routine + one caller workflow per repo.** The routine is fired by the Action's
  Fire URL — no UI event triggers.
- **Both templates are locked** — the routine prompt (`routine-prompts.md.template`) and the
  caller workflow (`loop-dispatch.yml.template`) are copied **verbatim**; changing them means
  editing those files **in a PR**, never hand-editing a live routine or repo workflow.
- **Thin prompt.** The routine prompt only invokes the skill; loop policy lives in the
  loop skills and must not drift per repo.
- **Standard config always.** Don't hand-tune per repo beyond `sources`/name and the two
  secrets.
- **Never use `fable`.**
