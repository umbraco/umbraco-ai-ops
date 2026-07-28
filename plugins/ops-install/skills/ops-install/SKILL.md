---
name: ops-install
description: >-
  Onboard a repo to the engine, and prove it is covered. Detects the repo's setup, writes the
  facts detection cannot reach to `.claude/ops-repo-meta.json`, reports capability coverage
  against the catalog (present / inherited / missing), scaffolds a stub for every missing
  capability from its catalog entry, creates every `ops/` label on the repo its role implies,
  installs the caller workflow on every repo that emits routed events, and validates the routing
  overlay. Six of its eight steps are deterministic scripts. Interactive, run once per repo.
  Trigger on "onboard this repo", "install the ops engine", "check capability coverage".
---

# ops-install

Onboarding, and the answer to one question: **will the loops actually run in this repo?**

It is **not a loop** — a human invokes it, once per repo, and it takes no `-loop` suffix for
that reason. It is interactive: it detects what it can, asks about what it cannot, and never
guesses at a fact a human had to decide.

**There is no central config to fill in.** Capabilities are found by name, so onboarding is:
declare the handful of facts nothing can detect, make sure the named skills exist, make sure the
events reach the router, and prove all three.

## What it does, in order

| Step | Deterministic? |
|---|---|
| 1. Detect the repo's setup | `scripts/detect.sh` |
| 2. Write the repo's declared facts | you + `scripts/validate-repo-meta.sh` |
| 3. Report capability coverage | `scripts/coverage.sh` |
| 4. Scaffold a stub per missing capability | `scripts/scaffold-capability.sh` |
| 5. Create the labels | `scripts/plan-labels.sh` + `github-ops` |
| 6. Install the caller workflow — on **every** repo that emits routed events | you, with the human |
| 7. Validate the routing overlay, if there is one | `scripts/validate-overlay.sh` |
| 8. List what is genuinely left for a human | you |

**Six of the eight are scripts, deliberately.** A coverage report a model produces by reading
directories is a report that can be quietly wrong, and "you are covered" is exactly the claim
nobody re-checks. Run the script and show its output.

## Step 1 — detect

`scripts/detect.sh <repo>` reads git branches and repo settings and returns the repo name, the
branch model with its bases, the CI provider, release signals and the stack. It is a **seed, not
an authority**: everything a human had to decide — the primary line, the port direction, which
repo holds issues — is a **declared** fact, and detection cannot know it.

Ask about exactly those, and only those. Do not ask about anything detection already answered.

## Step 2 — write the declared facts

Write what the human just told you to **`.claude/ops-repo-meta.json`**, shaped by
`ops-repo-meta.schema.json` in the `ops-capabilities` plugin. This is the file every loop and
the edge router read, so getting it right is the whole of onboarding's data half.

| Ask when | Key |
|---|---|
| issues live in another repo | `topology.issues` |
| you publish from another repo | `topology.releases` |
| proto-learnings go somewhere other than the code repo | `topology.learnings` |
| the repo has version lines | `lines.live`, `lines.primary`, `lines.port_order` |
| the repo already has a label meaning one of ours | `labels.<purpose>` |

**Every key is optional.** A single-repo project on one line needs **no file** — say so rather
than writing an empty one.

**A role left out means "this repo".** So on the **issues** repo of a split topology, write
`topology.code`: that is the only place the code repo can be named, because detection there
reads the issues repo's own remote, and it is what lets the router send the routine to the right
place. Get this wrong and issue labels fire a routine that works in the wrong repo.

**Never write a fact you inferred.** The primary line is not the newest line and not the default
branch. If the human does not know, leave it out and say the default applies.

Then validate it:

```
scripts/validate-repo-meta.sh <repo-root>
```

It enforces the rule a JSON Schema cannot: **`primary` must be a member of `live`**. It also
rejects any retired config key, so an attempt to put `ci.provider` or a base branch back fails
here rather than being silently ignored later.

## Step 3 — report coverage

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

## Step 4 — scaffold what is missing

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

## Step 5 — create the labels

```
scripts/plan-labels.sh <repo-root>
```

It returns every label with its name, its colour and **which repo it belongs on** — issue labels
to `issues`, PR labels to `code`, the learnings labels to `learnings`, per the operation-to-role
table. Overrides from Step 2 are already applied.

Then create each one with **`github-ops` → `create-label`**, on the repo the plan names.

This used to be a manual step telling a human to copy label names out of a document. It is not
any more, and it should not be: the names, the overrides and the target repos are all readable
now, so the only reason to make a person do it would be that we had not bothered to work it out.

**`create-label` is idempotent**, so re-running the installer is safe. Nothing routes until the
labels exist, so do not defer this and do not report success without it.

**In a split topology the labels land on two different repos.** Check you have write access to
both before starting, and say which repo each label went to.

## Step 6 — install the caller workflow

Copy the caller workflow template (see
[`new-loop-routine`](../../../loop-dispatch/skills/new-loop-routine/SKILL.md), which owns the
routine wiring and the locked templates) to `.github/workflows/` — and get the topology right,
because this is the step that silently half-works:

- **Single repo** — issues and PRs together. One workflow, subscribing to both `issues` and
  `pull_request_target`. No `target_repo`.
- **Split topology** — issues in a separate repo from the code. **The workflow goes on BOTH
  repos**, wired differently:
  - on the **issues** repo: subscribe to `issues`. No `target_repo`: that repo's
    `ops-repo-meta.json` declares `topology.code`, and the router reads it. Which means the
    issues repo needs a copy of that file too — it is the repo the workflow runs in.
  - on the **code** repo: subscribe to `pull_request_target` — those events fire where the PRs
    live, and the work is already there.

  `with.target_repo` still exists but is **deprecated**: it was a second hand-written copy of a
  fact the file already holds, in a different file in a different repo, with nothing to catch
  the two disagreeing.

**Install it on every repo that emits an event the router consumes.** Miss one and half the
loops never fire, with nothing failing to tell you: issue labels on a repo with no workflow are
simply ignored.

## Step 7 — validate the overlay

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

## Step 8 — what is genuinely left for a human

List these; do not try to do them.

1. **The two routine secrets** — `LOOP_DISPATCH_FIRE_URL` and `LOOP_DISPATCH_TOKEN`, per repo or
   per org.
3. **CI credentials and egress**, if CI is not GitHub checks. An Azure Pipelines repo needs a
   read-only ADO PAT.
4. **Repo settings.** Turn `allow_update_branch` **on**, so a stale branch can be refreshed
   before the merge gate. Leave GitHub's **native auto-merge off** — landing is
   `ops-integrate`'s decision, and native auto-merge would race it.
5. **Stand up the routine** with `new-loop-routine`.

The labels and the declared facts are **not** on this list any more. Steps 2 and 5 do both.

## Rules

- **Never write a central config file.** `.claude/ops-repo-meta.json` is not one: it holds only
  facts nothing can detect and nothing else owns, and its schema refuses the rest. If you find
  yourself wanting to add a branch name, a CI provider or a pointer to a skill, the answer is a
  capability.
- **Never write a fact you inferred.** A guessed primary line silently sends work to the wrong
  branch, and nothing about the failure points back here.
- **Never overwrite a repo's own skill or workflow.** Confirm first, every time.
- **Never report coverage from memory.** Run `coverage.sh` and show it.
- **Never scaffold a capability the catalog does not declare.** The script refuses; do not work
  around it.
- **Never claim a repo is onboarded while anything is `missing`, or while a stub still has
  TODOs.** A scaffold is not an implementation, and saying otherwise is the one failure mode of
  this skill that costs a real debugging session later.
- **Ask about declared facts; never infer them.** The primary line is not the newest line and not
  the default branch.
