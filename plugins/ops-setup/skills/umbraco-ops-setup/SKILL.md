---
name: umbraco-ops-setup
description: >-
  Interactive onboarding of a repo to the umbraco-ai-ops loops. Investigates the repo
  (branching model from git history, CI host from the tree, release approach), CONFIRMS
  and fills the gaps with you, then GENERATES the consumer files: `.claude/ai-ops.yml`, a
  build-playbook skill scaffold, any override skills the repo needs, and the caller
  workflow(s). Run it once per repo after installing the engine plugins. Local/interactive.
  Trigger on "set up ai-ops", "onboard this repo to the loops", "/umbraco-ops-setup".
---

# umbraco-ops-setup

Turns a bare repo into a working consumer of the engine. **Detect what the repo already
tells us, ask only the rest, then write the files.** Run it **in the target repo** (the
source-code repo), after `/plugin marketplace add umbraco/umbraco-ai-ops` + installing the
loops. It writes; it never pushes — you review and commit.

`github-ops` must be installed (the loops it wires up depend on it).

## Step 1 — investigate (deterministic)

Run the detector and read its JSON:

```bash
bash "$CLAUDE_PLUGIN_ROOT/skills/umbraco-ops-setup/scripts/detect.sh" .
```

It reports, best-effort and read-only: `source` (from `git remote`), `branching`
(`model`/`base`/`release_base`/`default_branch` from the branch layout — `gitflow`,
`main-only`, `versioned-gitflow` like `v18/dev`+`v18/main`, or `custom`), `ci.provider`
(`azure-pipelines` vs `github-checks` from the tree), `release` hints (`nbgv`,
`has_release_tags`, an existing `release-management` skill), and `stack` (`dotnet`/`node`).
Present the findings back plainly before asking anything.

## Step 2 — confirm & fill (interactive)

Use the **`AskUserQuestion` tool** for this step — do not gather answers as free prose. Put
each decision in a question with concrete options, and **make the detector's guess the first
option and mark it "(detected)"** so confirming is one click; the user can always override
via the tool's free-text answer. Batch related decisions into one call (the tool takes up to
4 questions) and use `multiSelect` where a choice isn't exclusive. Never invent a value —
if it wasn't detected, it must come back through a question. Cover:

- **Issues location** — *not detectable.* "Do `ops/ready-for-ai` issues live in this repo, or a
  separate one?" A separate repo (e.g. `Umbraco.Forms.Issues`) sets `repos.inbox` and
  `issue_link: cross-repo-full-url`; same repo leaves both at their defaults.
- **CI** — confirm `ci.provider`. If `azure-pipelines`, ask for `ado_org` and `ado_project`
  (and `gh_repo` if it isn't `repos.source`).
- **Branching** — confirm `model`, `base`, `release_base`. If the repo has its own release
  process (detector saw `nbgv`/`release-*` tags/a `release-management` skill, or `model` is
  `custom`), confirm that releases should **delegate to a repo skill** and capture its name
  in `branching.release_skill` (default `release-management`) — the engine will orchestrate
  and defer the mechanics to it rather than using its own release-flow default.
- **Learning inbox** — where proto-learnings are filed (`learning.inbox`).
- **Playbook name** — default `issue-loop`.

## Step 3 — generate

Write these into the repo (ask before overwriting anything that already exists):

1. **`.claude/ai-ops.yml`** — from the confirmed values. Emit only what differs from the
   engine defaults (keep it lean). **Validate it against `ai-ops.schema.json`** (from the
   engine repo root) before writing — every value must fit.
2. **`.claude/skills/<playbook>/SKILL.md`** — the repo's **build skill** (the override that
   `issue-loop-core` defers to; the name is `playbook`), only if absent. It carries the
   per-issue build steps **only** — orchestration stays in `issue-loop-core`, which locates
   and follows this skill; it does **not** invoke the core. Tune the sanity/build step to
   `stack`: `dotnet` → `dotnet build` + "obey each project's `CLAUDE.md`, CI is the gate";
   `node` → `npm ci` + `npm run build`/`test`. Include `/security-review` + `/code-review`
   and the outcome-label swap. Leave clear TODOs where the repo owner must add product
   specifics — don't fabricate build commands.
3. **Override skills — only where the repo diverges.** If `branching.model: custom`, or a
   `release_skill` is named that doesn't exist yet, scaffold that skill's stub (or point at
   the existing one). Do **not** scaffold overrides the engine defaults already cover.
4. **Caller workflow(s)** — copy the engine's `loop-dispatch.yml.template` to
   `.github/workflows/loop-dispatch.yml`.
   - **Same-repo** issues: one workflow, all loop events, no `target_repo`.
   - **Cross-repo** issues: this repo's workflow handles the PR events; **also emit the
     issues-repo workflow** (subscribing to `issues`, with `target_repo: <this repo>`) and
     tell the user to commit it in the **issues** repo.

## Step 4 — report the manual steps it can't do

Finish with a checklist of what's left (the skill deliberately doesn't touch these):

- **Labels**: create `ops/ready-for-ai`, `ops/generated-by-ai`, `ops/ai-blocked`, `ops/auto-merge`,
  `ops/auto-rework`, `ops/auto-release` on the relevant repo(s).
- **CI auth (azure-pipelines only)**: add a read-only Build-scoped PAT as `AZURE_DEVOPS_PAT`
  in the cloud environment, and allow-list `dev.azure.com` (Custom network access).
- **The routine**: stand it up with `new-loop-routine` (fire-URL + `LOOP_DISPATCH_*`
  secrets), and ensure the env's `cloud-skill-sync` delivers the engine skills.
- **Review** the generated `ai-ops.yml` + playbook, fill the TODOs, and commit.

## Rules

- **Detect first, ask second, generate third.** The "ask" step is the `AskUserQuestion`
  tool, not prose — never write a value you didn't detect or confirm through a question.
- **Read-only investigation.** `detect.sh` never writes; nothing here pushes.
- **Never overwrite without asking.** An existing `ai-ops.yml` or playbook is confirmed
  before replacing — offer to show a diff instead.
- **Validate before writing.** `ai-ops.yml` must satisfy `ai-ops.schema.json`; any JSON you
  emit passes `jq empty`.
- **Lean config.** Omit anything the engine auto-detects/defaults; only record real
  divergence. Anything past the built-in models goes to `branching.release_skill`, not into
  an engine edit.
