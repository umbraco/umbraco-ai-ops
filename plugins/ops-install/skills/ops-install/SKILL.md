---
name: ops-install
description: >-
  Onboard a repo to the engine, and prove it is covered. Detects the repo's branching, CI and
  release setup, reports capability coverage against the catalog (present / inherited /
  missing), scaffolds a stub for every missing capability from its catalog entry, installs the
  caller workflow on every repo that emits routed events, validates the routing overlay, and
  lists the manual steps a human must do. Writes no central config: a capability is found by
  its name. Interactive, run once per repo. Trigger on "onboard this repo", "install the ops
  engine", "check capability coverage".
---

# ops-install

Onboarding, and the answer to one question: **will the loops actually run in this repo?**

It is **not a loop** — a human invokes it, once per repo, and it takes no `-loop` suffix for
that reason. It is interactive: it detects what it can, asks about what it cannot, and never
guesses at a fact a human had to decide.

**It writes no central config.** There is no `ai-ops.yml` to fill in. Capabilities are found by
name, so onboarding is: make sure the named skills exist, make sure the events reach the router,
and prove it.

## What it does, in order

| Step | Deterministic? |
|---|---|
| 1. Detect the repo's setup | `scripts/detect.sh` |
| 2. Report capability coverage | `scripts/coverage.sh` |
| 3. Scaffold a stub per missing capability | `scripts/scaffold-capability.sh` |
| 4. Install the caller workflow — on **every** repo that emits routed events | you, with the human |
| 5. Validate the routing overlay, if there is one | `scripts/validate-overlay.sh` |
| 6. List the manual steps | you |

**Four of the six are scripts, deliberately.** A coverage report a model produces by reading
directories is a report that can be quietly wrong, and "you are covered" is exactly the claim
nobody re-checks. Run the script and show its output.

## Step 1 — detect

`scripts/detect.sh <repo>` reads git branches and repo settings and returns the repo name, the
branch model with its bases, the CI provider, release signals and the stack. It is a **seed, not
an authority**: everything a human had to decide — the primary line, the port direction, which
repo holds issues — is a **declared** fact, and detection cannot know it.

Ask about exactly those, and only those. Do not ask about anything detection already answered.

## Step 2 — report coverage

```
scripts/coverage.sh <repo-root>
```

Per capability in the catalog:

| State | Means |
|---|---|
| **present** | the repo ships `.claude/skills/ops-<cap>/SKILL.md` |
| **inherited** | the repo ships none, and the engine has a framework default |
| **missing** | the repo ships none and there is no default — **nothing will run** |

It exits non-zero when anything is missing. **`ops-change` and `ops-release` are always
missing on a fresh repo**, because those two are always the repo's own: no generic default could
know how a product builds or ships. Everything else should read `inherited`.

**Show the report verbatim.** It is the honest answer to "is this repo onboarded?", and a
summary of it is not.

## Step 3 — scaffold what is missing

For each missing capability:

```
scripts/scaffold-capability.sh <capability> <repo>/.claude/skills
```

The stub is **generated from the catalog entry**, so it can never disagree with the catalog
about which actions exist — and the action names *are* the invocation contract. It arrives
carrying `disable-model-invocation: true`, the reject-unknown-action rule, absent-context-is-`{}`,
the per-action idempotency requirement, and the catalog's worked example. Every `TODO` is the
author's.

It **never overwrites** an existing skill. A repo that already has one keeps it.

Tell the human plainly: **the loops cannot run until the TODOs in these stubs are filled in.**
A scaffold is not an implementation.

## Step 4 — install the caller workflow

Copy the caller workflow template (see
[`new-loop-routine`](../../../loop-dispatch/skills/new-loop-routine/SKILL.md), which owns the
routine wiring and the locked templates) to `.github/workflows/` — and get the topology right,
because this is the step that silently half-works:

- **Single repo** — issues and PRs together. One workflow, subscribing to both `issues` and
  `pull_request_target`. No `target_repo`.
- **Split topology** — issues in a separate repo from the code. **The workflow goes on BOTH
  repos**, wired differently:
  - on the **issues** repo: subscribe to `issues`, and set `with.target_repo` to the **code**
    repo, so the router emits a `target` and the routine works there while reading the issue here.
  - on the **code** repo: subscribe to `pull_request_target`, no `target_repo` — those events
    fire where the PRs live.

**Install it on every repo that emits an event the router consumes.** Miss one and half the
loops never fire, with nothing failing to tell you: issue labels on a repo with no workflow are
simply ignored.

## Step 5 — validate the overlay

Most repos need no overlay: the framework base table is the point. If the repo has one at
`.github/ops-routing.json`:

```
scripts/validate-overlay.sh <repo>/.github/ops-routing.json <engine>/plugins <repo>/.claude/skills
```

It checks the shape, that every event is in the framework vocabulary, that `(event, label)` is
unique, and that **every loop resolves to an installed skill** — a routed loop that does not
exist means firing a routine that cannot run. It also warns when a `loop: null` disable matches
no base rule, which does nothing at all and is always a mistake.

Pass the repo's own skills directory too, so a repo-provided loop resolves.

## Step 6 — the manual steps

List these; do not try to do them.

1. **Create the labels.** Every engine label is namespaced `ops/`:
   `ops/ready-for-ai`, `ops/generated-by-ai`, `ops/ai-blocked`, `ops/auto-merge`,
   `ops/auto-rework`, `ops/auto-release`, `ops/release-blocked`. Plus, on the **learnings** repo:
   `ops/proto-learning`, `ops/triaged`, `ops/loop-improvement`.
   **Nothing routes until they exist**, and the triage sweep needs `ops/triaged` before its first
   run because that is how it skips its own work.
2. **The two routine secrets** — `LOOP_DISPATCH_FIRE_URL` and `LOOP_DISPATCH_TOKEN`, per repo or
   per org.
3. **CI credentials and egress**, if CI is not GitHub checks. An Azure Pipelines repo needs a
   read-only ADO PAT.
4. **Repo settings.** Turn `allow_update_branch` **on**, so a stale branch can be refreshed
   before the merge gate. Leave GitHub's **native auto-merge off** — landing is
   `ops-integrate`'s decision, and native auto-merge would race it.
5. **Declare the facts detection cannot reach**, in the repo's own `ops-repo-meta`: the live
   lines, which is primary, the port direction, and the `learnings` role where it is not the
   code repo.
6. **Stand up the routine** with `new-loop-routine`.

## Rules

- **Never write a central config file.** No `ai-ops.yml`, no pointers. If you find yourself
  wanting a config key, the answer is a capability.
- **Never overwrite a repo's own skill or workflow.** Confirm first, every time.
- **Never report coverage from memory.** Run `coverage.sh` and show it.
- **Never scaffold a capability the catalog does not declare.** The script refuses; do not work
  around it.
- **Never claim a repo is onboarded while anything is `missing`, or while a stub still has
  TODOs.** A scaffold is not an implementation, and saying otherwise is the one failure mode of
  this skill that costs a real debugging session later.
- **Ask about declared facts; never infer them.** The primary line is not the newest line and not
  the default branch.
