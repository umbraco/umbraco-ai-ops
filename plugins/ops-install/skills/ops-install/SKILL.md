---
name: ops-install
description: >-
  Onboard a repo to the engine, and prove it is covered. Detects the repo's setup, writes the
  facts detection cannot reach to `.claude/ops-repo-meta.json`, reports capability coverage
  against the catalog (present / inherited / missing), scaffolds a stub for every missing
  capability from its catalog entry, asks whether each INHERITED default actually fits (coverage
  matches names, not behaviour), interviews the human to fill that stub's TODOs, creates every
  `ops/` label on the repo its role implies, installs the caller workflow on every repo that
  emits routed events, and validates the routing overlay. Six of its nine steps are
  deterministic scripts. Interactive, run once per repo.
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
| 5. **Fill the stub's TODOs** with the human | you, by interview |
| 6. Create the labels | `scripts/plan-labels.sh` + `github-ops` |
| 7. Install the caller workflow — on **every** repo that emits routed events | you, with the human |
| 8. Validate the routing overlay, if there is one | `scripts/validate-overlay.sh` |
| 9. List what is genuinely left for a human | you |

**Six of the nine are scripts, deliberately.** A coverage report a model produces by reading
directories is a report that can be quietly wrong, and "you are covered" is exactly the claim
nobody re-checks. Run the script and show its output.

## Asking the human: batch, and seed from detection

Two rules govern **every** question this skill asks, in Step 2 and Step 5 alike.

**Batch them.** `AskUserQuestion` takes **up to four questions in a single call** and the human
tabs through them. Ask four at a time. Do **not** make four calls with one question each — that
turns one screen into four round trips, and it is the single most common complaint about this
installer. "One question per fact" means do not cram two facts into one question; it does not
mean one call per question.

**Seed every option from what you already know.** Step 1's output, the repo's existing skills,
its build files. A question whose first option is the detected value, marked recommended, is one
click. The same question asked blind is homework. Never ask what detection already answered.

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

Ask with `AskUserQuestion`, **batched and seeded** per the two rules above. Everything below fits
in **one call**: pick the four that apply and send them together. Step 1 gives you
`branching.lines_seen`, `branching.default_branch`, `ci.provider`, `release.nbgv`,
`release.has_release_tags` and `release.release_skill` — use them as the options.

| Ask when | Key | Seed the options with |
|---|---|---|
| `lines_seen` is non-empty | `lines.live` | the detected lines, multi-select, all pre-selected — a line can exist and be **finished**, so the human is removing, not adding |
| `lines.live` has more than one | `lines.primary` | each live line as an option. **Never** pre-pick the newest or the default branch: Forms' primary is v17 while its default is `v15/dev` |
| `lines.live` has more than one | `lines.port_order` | `upward` / `downward`, with no recommendation — the engine cannot infer it and a wrong guess ports every change the wrong way |
| always, unless the repo plainly holds its own issues | `topology.issues` | "this repo" first, then ask for `owner/name` |
| you publish from another repo | `topology.releases` | "this repo" first |
| proto-learnings go somewhere other than the code repo | `topology.learnings` | "this repo" first. Warn if `topology.issues` is set and **public** — a proto-learning is an internal note |
| the repo already has a label meaning one of ours | `labels.<purpose>` | the existing label names, read from the repo |

**Skip any question whose answer is forced.** A single-line repo is asked nothing about lines. A
repo with one live line has no primary to choose and no port order. If that leaves fewer than
four questions, send fewer — in one call, not one each.

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

> **It needs the `ops-capabilities` plugin.** The script here is a thin wrapper; the real
> validator ships beside the schema it enforces, in `ops-capabilities`. If that plugin is not
> installed the wrapper exits 2 and tells you so. **Do not hand-check the file instead** — the
> cross-field rule above is the one a human reading JSON is most likely to miss, and a wrong
> primary line silently sends every change to the wrong branch. Install the plugin and re-run.

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

### `inherited` is a name match, not a fitness check

This is the gap that lets a repo finish onboarding green and fail on its first real run.
Coverage compares **skill names**. It cannot tell a default that suits this repo from one that
does not, so an inherited-but-wrong capability reads exactly like a pass.

So **ask**. The report prints an `override <trigger>` line per inherited capability, straight
from the catalog's `override_when`. Turn those into one batched `AskUserQuestion` — four at a
time — and **seed each from Step 1's `override_signals`**:

| Signal | Means | Ask about |
|---|---|---|
| `workspace` | a compose file, a Dockerfile, a demo/seed script, or existing worktrees | `ops-workspace` — the default is a bare worktree with no database, port or container |
| `private_feed` | a `NuGet.config` or `.npmrc` | `ops-workspace` again — a restore needing credentials fails inside a fresh worktree |
| `branching` | more than one live line | `ops-branching` — per-line strategy, or a major-version cutover that creates a line |
| `notify` | a Slack or Teams skill in the repo | `ops-notify` — the default comments on the issue |

A signal is a **hint, not a verdict**: a repo with a Dockerfile may still be fine on the
default. Recommend **keeping** the default in every case. The point is that the human sees the
six and gets one chance to say "not that one" — not that they are pushed into writing six skills.

**When they do want to override**, scaffold from the default rather than from a blank stub:

```
scripts/scaffold-capability.sh <capability> <repo>/.claude/skills --from-default
```

That writes a copy of the framework default with a header explaining what it is. Overriding is
almost always a one-action change, and a copy is a diff where a stub is a rewrite. Then treat it
as `present`, not `inherited`, and include it in Step 5.

**Do not record the answers anywhere.** A "confirmed" flag that something later reads is the
central config this design deleted, arriving by the back door. Onboarding runs once; ask again
if it runs again.

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

Then go straight to Step 5. **Do not hand over a file full of the word `TODO` and call the
install done** — that is the point at which onboarding stalls.

## Step 5 — fill the stub's TODOs

A scaffold is not an implementation, and leaving the human to face a wall of `TODO` is leaving
them the hardest part with the least context. You have just detected the stack, the CI provider,
the release tooling and every skill the repo already ships. Use it.

**Interview once per capability**, batching four questions per `AskUserQuestion` call, then
write the answers into the stub as real steps. Seed every option from Step 1 and from a look at
the repo.

**For `ops-change`:**

| Ask | Seed the options with |
|---|---|
| the build command | what the stack implies and what the repo actually contains — the solution/project files, a `package.json` script, a build script in `scripts/` |
| what `verify` runs before it reports pass | the test command, and the **scope**: only what changed, what changed plus its dependents, or everything. In a multi-project repo, offer dependents as the recommendation and say why |
| how a PR says which issue it closes | the convention visible in recent merged PRs (`Fixes #N`, a trailer, a branch-name convention) |
| when a change is ported to another line | only there are several live lines. Offer: only when the issue asks, always, or ask a human. Never recommend "always" |

**For `ops-release`:**

| Ask | Seed the options with |
|---|---|
| whether to **delegate to skills the repo already has** | `release.release_skill` from Step 1, plus any changelog/version/cleanup skills you can see. If they exist this is usually the answer, and it is the first question because it can answer most of the others |
| where the version lives | `release.nbgv` from Step 1 — a `version.json` per project, a single props file, a tag |
| what `publish` does | `ci.provider`. If CI publishes, the honest answer is usually "wait for the pipeline and report", not "tag and push yourself" |
| what `sync` puts back in step | the branch model from Step 1 — typically the release branch back into `vN/main` and `vN/dev` |

**Then write it.** Replace each `TODO` with the steps the answers imply, in the file. For
idempotency, say concretely what the action looks for to know it already ran — an existing PR
for this version, a tag that exists, a branch already pushed. "Check if it ran" is not an answer.

**What you must not do:**

- **Do not invent a build command you have not seen.** If nothing in the repo shows one, ask,
  and if the human does not know, leave that one `TODO` with a note saying so.
- **Do not silently leave a `TODO`.** Every one you cannot fill gets named in Step 9, with why.
- **Do not delegate to a skill you have not confirmed exists.** Check the path.
- **Do not touch the action names or the frontmatter.** Those come from the catalog.

End by telling the human plainly which actions are now written and which are still stubs, and
that **the loops cannot run until the stubs are done.**

## Step 6 — create the labels

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

## Step 7 — install the caller workflow

> **First, the prerequisite that makes it run at all.** The caller does
> `uses: umbraco/umbraco-ai-ops/.github/workflows/loop-dispatch.yml@main`, and that repo is
> **private**. GitHub Actions will not read a reusable workflow out of a private repo unless
> that repo has granted access, so without it **every** run fails instantly with:
>
> ```
> error parsing called workflow ... workflow was not found.
> ```
>
> It fails **before any job starts**, so there are no logs and no annotations on the run — just
> a red tick. Nothing about it points at the engine repo, which is why it is worth naming here
> rather than leaving someone to find it.
>
> Two ways out, both one-time and both on the **engine** repo, not the consumer:
>
> 1. **Make `umbraco/umbraco-ai-ops` public.** This also removes the need for `OPS_TOKEN` in
>    the cloud environment, so it fixes both private-repo problems at once.
> 2. **Keep it private and grant access:** its *Settings → Actions → General → Access* →
>    **"Accessible from repositories in the `umbraco` organization"**.
>
> Say which one is in place. If neither is, stop and say so — installing the workflow is
> pointless until one is, and a red run with no logs is a bad thing to hand someone.
>
> **This is not the same as the cloud `OPS_TOKEN`.** Different runtime, different failure: the
> token is read by the environment's Setup script, which this failure never reaches. Do not
> let one be offered as the fix for the other.

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

## Step 8 — validate the overlay

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

## Step 9 — what is genuinely left for a human

List these **in this order**, and say why the order matters; do not try to do them.

1. **Repo settings.** Turn `allow_update_branch` **on**, so a stale branch can be refreshed
   before the merge gate. Leave GitHub's **native auto-merge off** — landing is
   `ops-integrate`'s decision, and native auto-merge would race it. Independent of the rest,
   so it can be done now.
2. **The cloud environment.** A routine runs in one, and the engine only exists inside it
   because a **Setup script** put it there. Only a human can edit that field, so your job is to
   make the paste trivial — **never to send them looking for a file.**

   **Print the stub inline, in a fenced block, ready to copy.** Read
   `scripts/cloud-setup-stub.sh` from the engine root (resolve it the way the other scripts do)
   and output its contents. It is ~15 lines and it clones the engine and runs
   `cloud-skill-sync.sh` itself, so the paste never changes even as the real script does. If
   you genuinely cannot read it, say so and give the resolved path — a wrong path is worse than
   an honest "I could not find it".

   Then say which of the two cases applies:

   - **No environment yet** → a human creates one, pastes the stub into **Setup script**, and
     sets **`OPS_TOKEN`** in the environment's variables. Say this part plainly:
     `umbraco/umbraco-ai-ops` is **private**, so with no token the clone fails and the
     environment comes up with **no skills at all** — which presents as the loops silently
     doing nothing, not as a setup error. `GH_TOKEN` or `GITHUB_TOKEN` work too.
   - **An environment already exists** → it is almost certainly serving an **older snapshot**.
     Tell them to **bump the `# rebuild:` number in the stub and re-save**. This is the entire
     mechanism and it is not guessable: the snapshot is busted **only** by the text of that
     field changing, so a stub that always clones `main` does *not* re-run just because this
     repo moved on. One digit is the whole fix. Without it, a change pushed here never reaches
     the routine, and the symptom is behaviour that does not match the code.

   Name the case out loud. "Set up the cloud environment", read as done-if-it-exists, is how a
   stale environment survives an onboarding.

3. **CI credentials and egress**, if CI is not GitHub checks. An Azure Pipelines repo needs a
   read-only ADO PAT. Needed *by* the environment, so it goes in alongside step 2.
4. **Stand up the routine** with `new-loop-routine`. **This is what produces the Fire URL and
   the token** — they do not exist until it does.
5. **Add the two routine secrets** — `LOOP_DISPATCH_FIRE_URL` and `LOOP_DISPATCH_TOKEN`, per
   repo or per org, using the two values step 3 just gave you. In a split topology they go on
   **every** repo that has a caller workflow, not only the code repo.
6. **Smoke-test before writing any capability.** Open a throwaway PR whose base is **not** one
   of the live lines and label it with the landing label. The whole chain should fire and
   `ops-integrate` should refuse with `blocked:wrong-base`. That exercises the router, the
   workflow, the secrets, the routine and the gates while making a merge impossible — refusing
   *is* the pass. Only then label something real.

**Order is causal, not cosmetic.** An earlier version of this list asked for the secrets first
and created the routine last, which cannot be followed: the routine is what mints them.
Reported from a real install (28-07-2026).

The labels and the declared facts are **not** on this list. Steps 2 and 5 do both.

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
- **Never treat `inherited` as proven.** It is a name match. Ask whether each default fits,
  seeded from `override_signals`, before calling coverage good.
- **Never persist the answers to the override questions.** A flag something later reads is the
  central config this design deleted, coming back in disguise.
- **Ask about declared facts; never infer them.** The primary line is not the newest line and not
  the default branch.
