# Capabilities-model migration plan

Status: **Engine complete — Phases 0–5, 7, 8 landed; Phase 6 is consumer-side** (28-07-2026) · Author: audit of `umbraco-ai-ops@main`
against the two design docs, both now committed here:

- **[`ops-capability-skills.md`](ops-capability-skills.md)** — Layer 1, the informative explainer.
  Numbered **§01–§10**. Cited below as *layer 1*.
- **[`ops-capability-skills-conformance-spec.md`](ops-capability-skills-conformance-spec.md)** —
  Layer 2, the **normative** contract. Numbered **§1–§9**. Cited below as *conformance spec*.

> **Cite by document, never bare "spec §N".** The two use overlapping numbering for different
> things — the installer is layer 1 **§08** while conformance spec **§8** is the conformance
> clauses; evals are layer 1 **§09** while conformance spec **§9** is the non-normative list. An
> earlier draft of this plan wrote both as "spec §N" and mislabelled two citations as a result.

Layer 2 also names a **Layer 3** — "reference skills + scaffolder templates (`ops-release`,
`ops-repo-meta`, catalog)" — which does not exist in either repo. That absence is why this plan's
phase order departs from layer 1 §10 (§4).

**The engine is done. Phases 0–5, 7 and 8 have landed; Phase 6 is work in the consumer repos, not
here.**

| | |
|---|---|
| §6 decisions | all ten resolved, §6.8a with them — §6.10 **defers** the repo-family shape by ruling |
| §9a conformance gaps | all seven closed |
| The catalog | **[`catalog.json`](../catalog.json)** — 8 capabilities, 19 actions, with `--check`-gated generation of everything derived from it |
| Routing | the spec's `{event,label,loop}` shape, base ⊕ overlay merged at the edge, five base rows |
| Framework loops | all **six**, under their reserved names, commanding capabilities by name |
| Framework defaults | all six, in `ops-capabilities` |
| The installer | `ops-install` — conformance §8's three clauses, each by a tested script |
| Evals | 8 suites, 66 cases, generated from the catalog; opt-in |
| The old config model | **deleted** — no pointer, no CI key, no branch name, no transitional read |
| Declared facts | `.claude/ops-repo-meta.json` — the undetectable few, schema'd and validated |
| Tests | 19 hermetic files in the CI gate |

> **Counts in this document are as-of-writing, and the engine has moved since.** Where a number
> here disagrees with the repo, the repo is right: `catalog.json`, `route-map.json` and the test
> files are the sources, and each has a `--check`-gated generator or a test asserting its own
> count. The one-line rule for a reader: this plan records *what was decided*, never *what is
> currently true*.

**The four-way base-branch drift is closed**, the `ci.provider` spelling split is gone, and every
engine label is namespaced `ops/`. What remains is per-consumer: Forms' and Automate's own
`ops-change` and `ops-release`, against the prerequisites table in Phase 6.

**Nothing is open in the engine.** One thing is **deferred by ruling** rather than closed: the
**repo-family consumer shape** — one `ops-change` serving many repos — is out of scope for this plan
and needs input from whoever owns the MCP family (**§6.10**). It fails safe while deferred.

> **Where execution changed the plan, read [§10](#10-deviations-log--what-execution-changed-about-this-plan).**
> Three logs, three jobs: **§6** is what we decided before building, **§9b** is where we knowingly
> diverge from the *spec*, and **§10** is where we diverged from *this plan* while carrying it out.
> Every phase appends to §10 before it is called done.

The two design docs are headed **"Repo: umbraco-mcp-ops"** — they describe the target for the
prototype. This plan ports that target onto the **`umbraco-ai-ops`** engine we shipped, whose
current design is the **config-pointer** model. Closing that gap *is* the migration.

---

## 0. The shift, in one paragraph

Today a consumer plugs into the engine through a **config file + skill-name pointers**:
`.claude/ai-ops.yml` (nested keys) tells generic loops where the repo's *build skill* (`playbook`)
and *release skill* (`branching.release_skill`) live, plus a pile of `ci.*` / `branching.*` /
`learning.*` facts. The target replaces all of that with **convention**: every seam becomes a
standard skill named `ops-<capability>`, a loop reaches a seam by *invoking that skill by name*
with `(action, context-json)`, a **catalog** declares the capability/action interface, an
**installer** proves coverage, and **evals** prove behaviour. Most of `ai-ops.yml` evaporates —
its keys become capability skills or move into `ops-repo-meta`.

Two structural wins fall out of the move, both flagged in the audit as current hazards:

- **`ci.provider` vs `ci_provider` spelling split** (schema/detector say `ci.provider`; the
  github-ops references read `ci_provider`) → *disappears*: CI becomes the `ops-ci` capability, no
  central config key.
- **`branching.merge_strategy` / `branching.base` are in the schema, re-detected at runtime** via
  `release-and-branching`, re-resolved *again* inside `merge-flow`, and pointed at a fourth time by
  `operation-catalog`'s `detect-base-branch` (§7) → *collapses* to one: the values become **private
  to `ops-branching`**, which decides squash-vs-merge and checks the base itself. Callers ask for an
  outcome ("merge this PR"); nothing else ever holds a strategy or a branch name.

---

## 1. Seam audit — current → target

Kind legend: **B** = behavioral capability (a caller invokes its actions) · **D** = data capability ·
**F** = framework mechanics (stays in the engine) · **—** = key/behaviour removed.

### Capability roster — kind + visibility

Mapping each seam to a capability (below) says *what* varies; it doesn't say *who may call it*.
**Visibility** records that second fact. It is not a new layer or any new machinery — just an
exposure note per capability, carried in the catalog (§3.1) and held by review, not by code.
(Framing adopted from review on PR #4.)

Rule of thumb: **loops command services only · supporting primitives are wrapped by a service ·
reads and notifications are cross-cutting.**

| Capability | Kind | Visibility | May be called by |
|---|---|---|---|
| `ops-change` | B | **service** | framework loops |
| `ops-release` | B | **service** | framework loops |
| `ops-integrate` | B | **service** | framework loops |
| `ops-branching` | B | **supporting** | services only — **never a loop** |
| `ops-workspace` | B | **supporting** | `ops-change` only |
| `ops-repo-meta` | D | **cross-cutting** (read) | any layer |
| `ops-ci` | B | **cross-cutting** (read) | loops (to gate) + services |
| `ops-notify` | B | **cross-cutting** (infra) | any layer |
| `ops-learnings` | F + D | **framework mechanism + data** | capture is framework-wide (§4 P4) |

Two consequences bite this plan directly: `ops-branching`'s strategy/base values become
**private** — no loop and no service reads `merge_strategy` or `base`, they ask for an *outcome*
(§1a, §2) — and `ops-workspace` is prepared/torn down by `ops-change`, not by the issue loop.

A third follows from §6 settling as it did: because the **service owns the merge gates**,
`ops-integrate` is confirmed and `ops-branching` stays **command-only** — no `classify-pr`, no read
of any kind on that primitive.

Terms used throughout — *service*, *supporting primitive*, *cross-cutting*, *action* vs
*operation*, *capability catalog* vs *operation catalog* — are defined in
[`vocabulary.md`](vocabulary.md).

### Action inventory — **superseded by the catalog**

The draft table that used to sit here was the *input* to the capability catalog. That catalog now
exists — **[`catalog.json`](../catalog.json)**, shaped by
**[`catalog.schema.json`](../catalog.schema.json)** — so the table is deleted rather than kept in
parallel. A second list of action names is exactly the drift this migration exists to kill.

**8 capabilities, 19 actions.** What changed as the draft rows became real entries:

| Change | Why |
|---|---|
| **`ops-change · land` dropped** — §6.8a resolved *against* the delegating tail | A change lands N times at N moments and a human gate splits delivery, so there is no single "tail of `ops-change`" for it to be. Every merge enters through `ops-merge-loop → ops-integrate · land`, and `ops-change` ends at `close-issue`. |
| **`ops-repo-meta · lines` added** — settles §9c | The live-line set, the primary line and the port order are **data a repo declares**, not branching behaviour, so there is no `ops-branching · resolve-line`. `ops-branching` *reads* this action and never caches it, which is what makes a major-version cutover an `ops-repo-meta` edit rather than an engine change. |
| **`ops-repo-meta · topology` kept to exactly the spec's shape** | Conformance §7.1 fixes its return as `{repos: {role: …}}`. Folding the line facts in there would have quietly broken that — the second reason `lines` is its own action. |
| **`ops-notify · send` gained a `key`** | Idempotency (§2b) is a MUST, and a notification's only sane identity is a caller-supplied key. |
| **`ops-repo-meta` actions take no context** | Their `example` is `{}`, which also demonstrates §2b's rule that an absent context is `{}` rather than an error. |
| **`feeds` and `protected-branches` still absent** | Both come from the superseded artifact in §9c and neither has a consumer: `ops-integrate` re-checks CI *regardless* of branch protection, and feed setup is internal to a repo's own `ops-workspace`. Deferred deliberately, not overlooked. |

Every entry also carries `description` (per capability *and* per operation), a worked `example`, and
guidance-only `input` / `output` field lists. The additions beyond the spec are recorded in §9b.

### 1a. Config-pointer seams (`ai-ops.yml` / `ai-ops.schema.json`)

| Current key | Kind | Target capability · action | Migration note |
|---|---|---|---|
| `repos.source` | D | `ops-repo-meta` · `topology` (role `code`) + `identity` | source = the `code` role |
| `repos.inbox` | D | `ops-repo-meta` · `topology` (role `issues`) | issues = the `issues` role; single-repo collapses to `code` |
| `repos.issue_link` | — | *removed* → `ops-change` · `close-issue` | enum disappears; cross-repo close is behaviour ([conformance spec](ops-capability-skills-conformance-spec.md) §7.4), not config |
| `ci.provider` | B | `ops-ci` (provider internal to the consumer's skill) | **kills the `ci.provider`/`ci_provider` split** |
| `ci.ado_org` / `ci.ado_project` / `ci.gh_repo` | B | internal to consumer `ops-ci` | out of central config |
| `branching.model` | B | `ops-branching` (internal knowledge / framework default) | model becomes skill logic, not an enum |
| `branching.base` | B | `ops-branching` — **private**; callers get outcomes, never the value | **single source of truth** (ends the four-way drift in §7). Internally a **set** of live integration branches (§8) |
| `branching.release_base` | B | `ops-branching` (private) — **never reaches a caller at all** | §6.9 = (b): `ops-integrate` asks and declines release-base PRs itself; no classification is exposed |
| `branching.merge_strategy` | B | `ops-branching` · `merge` picks it internally | **single source of truth**; no caller passes a strategy |
| `branching.branch_naming` | B | internal to `ops-branching` / `ops-change` | |
| `branching.release_skill` | B | `ops-release` (whole capability) | the *pointer* becomes the *convention* (`ops-release`) |
| `learning.inbox` | D | `ops-repo-meta` · `topology` (role **`learnings`**), declared in `.claude/ops-repo-meta.json` | **Decided (§9a.1): a fourth canonical role.** Declarable per consumer, and — like every unspecified role (conformance §7.2) — resolving to `code` when absent. Needs the spec amendment recorded in §9b.8 |
| `learning.routing` | — | *removed* → framework capture + `ops-triage-loop` | today a free-form prose string in the schema — never a machine-readable seam (§6.2) |
| `playbook` (build-skill pointer) | B | `ops-change` · `implement` / `verify` / `close-issue` | the central pointer becomes the convention (`ops-change`) |
| `version` (schema pin) | F | catalog/spec version | replaced by catalog + spec versioning |

Net: `ai-ops.yml`'s normative content is absorbed by `ops-repo-meta` (identity/topology) + the
per-capability skills. See §5 for what, if anything, remains.

**The four roles.** `topology` carries `code` (required), `issues`, `releases` and `learnings`,
and **any unspecified role resolves to `code`** (conformance §7.2). Two of them have no row in the
table above because `ai-ops.yml` never had a key for them:

- **`releases`** — where publication happens. Both consumers publish from the repo the code
  lives in, so for Forms and Automate alike this resolves to `code` and is never declared. It is
  in the plan now only because §9a.1 caught its total absence.
- **`learnings`** — where proto-learning issues are filed. The one role a consumer will
  actually want to set, and **not** simply "the issues repo": Forms' issues repo
  (`Umbraco.Forms.Issues`) is **public**, and a proto-learning is an internal note about how a
  build went, so Forms declares `learnings: umbraco/Forms` — the private code repo. In a
  single-repo consumer like Automate every role is the same repo anyway, which is why "learnings
  sit alongside issues" is the usual outcome without anyone declaring it.

### 1b. Behavioral / skill-reference seams (prose deferrals)

| Current deferral (where) | Target capability · action |
|---|---|
| build/test commands, sanity pass (repo `CLAUDE.md`; `playbook` skill) | `ops-change` · `implement` / `verify` (internal) |
| version-file list + changelog bump (repo `CLAUDE.md`; `auto-release-loop:51`) | `ops-release` · `cut` (internal) |
| worktree / DB cleanup ("repo's own `/cleanup`"; `gitflow.md:37`) | `ops-workspace` · `prepare` / `teardown` — wrapped by `ops-change`, not called by a loop |
| human push notifications (loops emit "Reworked PR #N…") | `ops-notify` · `send` |
| base-branch + merge-strategy detection via `release-and-branching` | `ops-branching` **internals** — not a caller-visible action (§6.9) |
| cross-repo issue close (can't use `Closes #N`) | `ops-change` · `close-issue` ([conformance spec](ops-capability-skills-conformance-spec.md) §7.4 — MUST be explicit) |
| CI status reads (`github-ops` → `ci_provider`) | `ops-ci` · `status` |
| failing check / build log reads (`operation-catalog` → `read-failing-ci-log`) | `ops-ci` · `log` (the `ci` axis is **read-only** — both its operations are reads) |
| forge mechanism (gh CLI vs GitHub MCP), PR/label/merge by role | **F** — stays framework; target resolved by `ops-repo-meta` · `topology` role |
| release-tag automation version-source per stack (`release-tag.yml`) | `ops-release` · `cut` / `publish` (internal) |

### 1c. Routing seams (`route-map.json` / `route-event.sh`)

| Current | Target ([conformance spec](ops-capability-skills-conformance-spec.md) §6) |
|---|---|
| Whole-file replacement (`$ROUTE_MAP` swaps the entire map) | **base ⊕ per-repo overlay** merged live at the edge; identity key `(event,label)`; overlay wins; `loop:null` disables |
| Rule shape `{event:"issues", action:"labeled", route}` | `{event:"issues.labeled", label, loop}` — collapse event+action into the event vocab (`issues.labeled`, `pull_request.labeled`, `issues.opened`, `pull_request.opened`), rename `route`→`loop` |
| Route targets `issue-loop-core` / `auto-release-loop` / `merge-flow` / `rework-loop` | reserved loop names `ops-issue-loop` / `ops-release-loop` / `ops-merge-loop` / `ops-rework-loop`, **plus a fifth row for `ops-triage-loop`** (§2a) |
| Built-in `case` fallback duplicating the 4 rules ("keep in sync") | base table is the single source; drop the dup (or generate the fallback from base) |
| Overlay = ad-hoc `$ROUTE_MAP` file | overlay in the caller workflow input block **or** a committed `.github/ops-routing.yml` |
| `new-loop-routine` scaffolds caller workflow | evolves into the loop-scaffolder that *writes overlay rows* (§6) |

`route-event.sh`'s cross-repo `--target`/`$TARGET_REPO` dispatch and `pull_request_target`
normalisation already match the spec — keep them.

### 1d. Installer seam (`ops-setup` / `umbraco-ops-setup`)

| Current | Target (`ops-install`, [layer 1](ops-capability-skills.md) §08 + [conformance spec](ops-capability-skills-conformance-spec.md) §8) |
|---|---|
| `detect.sh` pre-fills a config guess | keep — feeds the pre-fill + topology defaults |
| `AskUserQuestion` confirm/fill of config keys | shrinks to what `ops-repo-meta` can't auto-detect |
| Writes `ai-ops.yml` (schema-validated) | writes/updates `ops-repo-meta` facts + overlay; validates overlay per §6 |
| Scaffolds `<playbook>` build skill + release override | scaffolds a standard **capability-skill stub per catalog entry** for each MISSING capability |
| **No coverage check** (only schema-conformance) | **coverage report**: each catalogued capability `present / inherited / missing` by matching `ops-<capability>` skill names |

---

## 2. Framework-skill → framework-loop map

### Naming rule for framework loops

**A framework loop is named `ops-<noun>-loop`, where `<noun>` is a single word.** The plan named
five; the engine ships **six**, `ops-port-loop` having been added after this section was written
(§10.43). The rule is what binds, not the count:

| Loop | Fires on | Was called |
|---|---|---|
| `ops-issue-loop` | an issue labelled ready for work | `ops-issue-loop` (unchanged) |
| `ops-merge-loop` | a PR labelled for landing | `ops-merge-flow` |
| `ops-port-loop` | a merged PR labelled for porting | *(new — not in the prototype)* |
| `ops-release-loop` | a release trigger | `ops-ops/auto-release` |
| `ops-rework-loop` | a PR labelled for rework | `ops-rework` |
| `ops-triage-loop` | a proto-learning labelled for triage | `ops-triage` |

Three reasons it is worth fixing rather than living with:

1. **The old names had three different shapes** — a `-loop` suffix on one, `-flow` on another, an
   `auto-` prefix on a third. Nothing told you which was which.
2. **The `-loop` suffix is what keeps loops out of the capability namespace.** A capability is
   `ops-<capability>`, so `ops-release` is already the release *capability*. The old
   `ops-ops/auto-release` avoided the clash only by accident, and any tidy-up that shortened it to
   `ops-release` would have collided head-on. `ops-release-loop` cannot.
3. **The reader can tell the layer from the name**, which is the same argument the visibility
   roster makes for capabilities.

**Two reserved names are deliberately exempt**, because neither is a loop: **`loop-dispatch`** is
the edge router that *chooses* a loop and runs in bash before any session exists, and
**`ops-install`** is the installer, invoked by a human. Renaming either to `-loop` would claim
something untrue about what it does.

This **diverges from [conformance spec](ops-capability-skills-conformance-spec.md) §2.3**, which
fixes the reserved list as `ops-merge-flow` / `ops-ops/auto-release` / `ops-rework` / `ops-triage`.
Recorded as a deliberate divergence in §9b.7 — the spec needs amending, not this plan bending.
It also answers the loop-naming question raised in review on PR #4.

| Today | Becomes | Calls (by name) |
|---|---|---|
| `issue-loop-core` *(placeholder)* | `ops-issue-loop` | `ops-change` (implement/verify/close-issue) · `ops-ci`, `ops-repo-meta` (reads). **Not** `ops-workspace` — `ops-change` wraps it |
| `rework-loop` *(placeholder)* | `ops-rework-loop` | `ops-change` · `ops-ci` (status/log), `ops-repo-meta` (reads). **Does not land its own fix** — hands the PR back to `ops-merge-loop` so there is one merge path behind one human gate (§8) |
| `merge-flow` | `ops-merge-loop` | `ops-integrate` · `land` (§6.8 = A) · `ops-ci` (status), `ops-repo-meta` (topology). **Never `ops-branching` directly** |
| `auto-release-loop` | `ops-release-loop` | `ops-release` (plan/cut/publish/sync) · `ops-ci`. Reaches `ops-branching` **only through `ops-release`** |
| `release-and-branching` | *demoted* → `ops-branching` (framework default) | — (becomes a capability, repo may override) |
| `sync-dev` | folded into `ops-release` · `sync` | — |
| `github-ops` | split: `ops-ci` (capability) + forge mechanics stay **F** | forge target resolved via `ops-repo-meta` topology |
| `loop-dispatch` | `loop-dispatch` (unchanged name) | gains base⊕overlay merge + event vocab |
| `new-loop-routine` | loop-scaffolder (writes overlay rows) | — |
| `ops-setup` / `umbraco-ops-setup` | `ops-install` | reads catalog; coverage + scaffold + overlay-validate |
| `learning` *(placeholder)* | framework capture hook + `ops-triage-loop` (loop); destinations are `ops-repo-meta` data | uniform across repos so lessons compound (§6.2, detailed in §2a) |
| `release-reviewer` (agent) | stays (orchestration internal to `ops-release-loop`) | non-normative |

### 2a. `ops-triage-loop` — what it inherits

`ops-triage-loop` is a reserved framework loop name (§2) that nothing in this repo implements:
`plugins/learning/` does not exist on disk, despite `marketplace.json` declaring it (§7). But it is
**not undefined**. Two sources describe it, and the second is far more complete than the first:

1. **This repo**, where the `triage-learnings` design it renames is stated across four files, all
   from `633a2a7` ("scaffold engine foundation and generic plugins") — descriptions and passing
   references, no mechanism.
2. **The `umbraco-mcp-ops` prototype**, which *shipped the whole thing*:
   `docs/self-learning-system.md`, `plugins/mcp-issue-loop/skills/triage-learnings/SKILL.md`,
   `.../references/proto-learning-schema.md`, and `.../hooks/capture-proto-learning.sh`. Read
   27-07-2026 at `hifi-phil/umbraco-mcp-ops@HEAD`.

**An earlier revision of this section called the threshold, the dedupe key and the trigger
"genuinely open, not recoverable from history".** That was wrong: it searched this repo only, and
all three are specified in the prototype. They are recorded below as inherited, not open.

**Canonical statement** — the `learning` plugin's description, `.claude-plugin/marketplace.json:96`:

> read-only capture hooks (SubagentStop/SessionEnd) that file proto-learning issues off the critical
> path, the proto-learning schema, and **triage-learnings (dedupe + threshold + route to owning repo
> / shared-skills PR / loop-improvement issue)**.

**The contract** — this repo names the parts, the prototype supplies the mechanism:

| | | Source |
|---|---|---|
| **Input** | `ops/proto-learning` issues in the inbox repo, filed by read-only `SubagentStop` / `SessionEnd` hooks that analyse transcripts **off the critical path**. No loop and no subagent ever files one by hand. | `issue-loop-core/SKILL.md:269-277`, `rework-loop/SKILL.md:104-106` |
| **Inbox filter** | Open issues labelled `ops/proto-learning` and **not** labelled `ops/triaged`. Malformed records get a comment asking for a reformat, not a guess. Empty inbox → report and stop. | prototype `triage-learnings` Step 1 |
| **The record** | Body = one fenced `json` block plus a freeform **Notes** section. Fields: `sourceRepo`, `sourceIssue`, `pr`, `category` (a closed 9-value set), `lesson`, `detail`, `fix`, `guessedHome`, `modelTier`, `phase`. `guessedHome` is a **hint**; triage decides for real. The capture hook skips an exact-title duplicate itself, so the analyzer needs no dedupe. | prototype `references/proto-learning-schema.md` |
| **Operations** | **cluster/dedupe** → **threshold** → **route** → **mark processed**. | `marketplace.json:96`; prototype `triage-learnings` Steps 1–5 |
| **Dedupe key** | Same `sourceRepo` + same `category` + a **semantically equivalent** `lesson`. One cluster = one routed item, carrying **every** source issue number as provenance. Judgement, done across the whole open set at once, not per-issue. | prototype `triage-learnings` Step 2 |
| **Threshold** | **≥ 2** distinct source issues in a cluster, *or* the same lesson seen on **≥ 2** `sourceRepo`s, to earn a shared-skills PR. A single occurrence gets an owning-repo issue or is **held** (left open, uncommented). `loop-self` items are **not** threshold-gated. | prototype `triage-learnings` Step 3 |
| **Output** | **One routed item per cluster**, and the mechanism differs by destination: an **issue** on the owning repo, a drafted **PR** for shared skills only, a **`ops/loop-improvement` issue** for the loop itself, or close-with-reason. `issue-loop-core/SKILL.md:274`'s "turns those into PRs" is true of exactly one destination in four. | prototype `triage-learnings` routing table |
| **Cadence** | **Weekly, scheduled** — a batch sweep of the open inbox, capped at **10** routed items per run of which **≤ 5** may be PRs; overflow is logged and deferred, never dropped. | prototype `triage-learnings`, "Running as a scheduled routine" + Caps |
| **The compounding gate** | A routed issue re-enters the work loop **only when a human adds `ops/ready-for-ai`**. Triage must not apply it. | prototype `docs/self-learning-system.md` §2 |

**The destinations** — named three ways across the two repos, and reconciling cleanly once the
prototype supplies the mechanism column this plan was missing:

| `marketplace.json:96` | `ai-ops.schema.json:58` | prototype key | Mechanism | Post-migration home |
|---|---|---|---|---|
| owning repo | `product-repo` | `mcp-repo` | **Issue** on the repo the work was done in, titled `[from-learnings] …`, hinting `CLAUDE.md` vs a project-local skill and letting that repo decide placement. **Never a PR** — "Loop B does not hand-edit product repos." | `ops-repo-meta` role `code` |
| shared-skills PR | `shared-skills` | `shared-mcp-skills` | **Drafted PR** carrying the *smallest* edit to the shared skill that should have surfaced the lesson. Threshold + provenance required, no exceptions. | the shared **consumer** repo of a repo family — **still no role for it** (§7) |
| loop-improvement issue | `loop-self` | `loop-self` | **Issue** labelled `ops/loop-improvement`. The loop must not rewrite its own definition unreviewed, so never a PR. | a fixed engine fact, not repo data |
| — | — | *discard* | **Close** the source issue with a one-line reason. | — |

That fourth outcome matters: a plan that only lists three destinations implies every proto-learning
is actionable, and the prototype is explicit that "not actionable, stale, or wrong" is a normal
result.

Also normative in the prototype and worth carrying: **provenance on every routed item** (the source
issue numbers linked, the `sourceRepo#issue` / PR each came from, and the occurrence count as
threshold evidence) — "reviewers approve facts, not vibes". And **marking processed differs by
destination**: a shared-skills PR labels each source `ops/triaged` but leaves it **open** until the PR
merges, so a rejected PR can't silently lose the lesson; issue destinations close the source, since
the learning now lives in the new issue.

This is consistent with §6.2 rather than in tension with it: `learning.routing` dies because it was
prose in the schema, while the **destinations** were always real and become `ops-repo-meta` data.
Where `learning.inbox` lands is now **settled** — `topology` role **`learnings`**, resolving to
`code` when unspecified (§1a, §9b.8).

**Not open any more: the trigger.** Triage is a **weekly scheduled sweep**, not an event route. The
prototype schedules it as a cloud routine and filters the inbox on `ops/proto-learning` +
not-`ops/triaged`; **`ops/triaged` is an output marker written by triage**, not an input label a human or a
hook applies. So there is no triage label, no fifth route row, and nobody to decide who labels. The
per-run caps only make sense for a batch, and a sweep is what `issue-loop-core:274`'s "a separate
triage routine **later**" was describing all along.

One consequence survives that correction: **triage's destination is chosen by triage**, not known at
dispatch, so it could never have been carried as a `--target` (§7). A schedule has no `--target`,
which is one more reason the sweep is the right shape.

**What Phase 4 still has to decide** — everything above it is inherited:

1. **Whether the prototype's numbers survive two consumers.** The threshold (≥ 2) and the caps (10
   per run, ≤ 5 PRs) were tuned for a family of many small MCP repos, where the same lesson recurs
   across repos quickly. Forms and Automate are two large ones, so a cluster fills up more slowly.
   Adopt the prototype's values as the framework default and revisit on real inbox volume rather
   than re-deriving them from nothing.
2. **Dedupe is the eval target, not the threshold.** The key is defined, but "semantically
   equivalent `lesson`" is a judgement an LLM makes over prose. The threshold is arithmetic once
   clustering is right, so clustering is where Phase 7 should aim.
3. **Whether the `shared-skills` destination is reachable at all**, since the repo-family consumer
   shape is never migrated by this plan (§7). For Forms and Automate only two of the four
   destinations exist (`code` and `loop-self`) — and a shared-skills PR is the **only** thing the
   threshold gates, so with that destination absent the threshold gates nothing. Phase 4 should say
   so plainly rather than build a gate with no consumer.

### 2b. The capability contract — what `(action, context-json)` actually means

This plan shorthands the invocation as `(action, context-json)` throughout. The normative
version is more specific, and both the Phase 1 catalog and the Phase 5 scaffold have to encode
it, so it is written out once here rather than restated per phase. Every row is from the
[conformance spec](ops-capability-skills-conformance-spec.md).

| Rule | Standing | Source |
|---|---|---|
| **Two positional arguments** — `action` (`$1` / `$action`) and `context` (`$2` / `$context`). | MUST | §3.1 |
| **`context` is a single JSON object encoded as a string**, which the skill parses as JSON. An **absent context is `{}`**, not an error. | MUST | §3.3 |
| **`action` must be one the catalog declares** for that capability — the catalog's action names *are* the validation set. | MUST | §3.2, §5.4 |
| **An unimplemented action is rejected** — never silently succeeded, never guessed at. The rejection SHOULD use the result convention. | MUST | §3.4 |
| **Every action is idempotent** — the same action twice with the same context MUST NOT produce a second side effect. | MUST | §3.5 |
| **A failed action leaves a safe state** — no partial publish, no dangling branch it created and cannot resume. | MUST | §4.3 |
| **A data capability returns well-formed structured data.** For `ops-repo-meta` the structure *is* the deliverable, not an envelope imposed on it. | MUST | §4.4 |
| ~~**`disable-model-invocation: true`** on every capability skill~~ **REVERSED — see §9b.9.** The flag blocks the Skill tool outright, so a loop cannot call the capability either. A description sentence replaces it. | SHOULD | §2.4 |
| **Success vs failure is unambiguous** — the recommended shape is a single closing JSON object, `{"ok": true, …}` / `{"ok": false, "detail": "…"}`. No required error vocabulary. | SHOULD | §4.2 |

**Idempotency is the rule with teeth here**, because three of this plan's actions are re-invoked
by design and none of the old config-pointer skills ever had to think about it:

- **`ops-integrate · land`** — `ops-merge-loop` sweeps labelled PRs on a cadence and the label
  stays on the PR after landing, so an already-merged PR gets handed to `land` again. It must
  report the existing merge, not attempt a second one.
- **`ops-release · cut`** — a re-run MUST return the existing release PR rather than open a
  second. That is the spec's own worked example (§3.5).
- **`ops-change · close-issue`** — one change lands on N lines at N moments (§8), so the action
  is reachable after the issue is already closed and must tolerate that.

Idempotency has no config and no framework enforcement — it is behaviour, so **Phase 7's evals
are the only thing that can check it**. Every capability's eval suite gets a double-invoke case.

The two SHOULDs are not optional in practice for *this* engine: `disable-model-invocation` is
what stops a capability firing outside a loop (Phase 1 scaffold, Phase 5 stubs, Phase 6 consumer
skills all carry it), and the `ok`/`detail` shape is what Phase 7 asserts on.

---

## 3. New artifacts to create in the engine

1. **The catalog** — **done in Phase 1.** ([conformance spec](ops-capability-skills-conformance-spec.md)
   §5 for structure, [layer 1](ops-capability-skills.md) §05 for its role.)
   **[`catalog.json`](../catalog.json) + [`catalog.schema.json`](../catalog.schema.json)** at the repo
   root, beside `ai-ops.schema.json` — the seam it replaces (§6.6: JSON, which conformance §5.1
   permits alongside YAML, and which matches this repo's existing data-seam convention). One entry per
   capability, all eight: `change, release, integrate, branching, workspace, repo-meta, ci, notify`.

   Two engine-wide scripts come with it, in top-level `scripts/` because neither belongs to one skill:

   - **`validate-catalog.sh`** re-expresses the schema's rules in jq, since hermetic CI has no
     JSON-Schema validator, and adds the two things JSON Schema cannot express — capability names
     unique, action names unique within a capability.
   - **`catalog-to-readme.sh`** generates the README's action table from the catalog, with a
     `--check` mode its test asserts, so the two cannot drift.

   **How normative it is, precisely** — the plan previously flattened this and overstated it:

   | Part | Status | Source |
   |---|---|---|
   | Entry keys `capability` / `description` / `operations` | **MUST** | conformance §5.2 |
   | Per operation: `action`, `description`, `example` | **MUST** | conformance §5.3 |
   | The `action` *names* — they are the invocation contract and the validation set | **normative** | conformance §5.4 |
   | Per operation: `input` / `output` field lists | **guidance — MUST NOT be enforced at runtime** | conformance §5.4 |
   | Anything about behaviour or payload shape | **non-normative**, verified by evals only | layer 1 §05, conformance §9 |

   So layer 1's "the catalog — guidance, not a contract" and conformance §5's "normative structure"
   are not in conflict: **the shape is normative, the contents are guidance.** That is the same
   distinction as this plan's "coverage ≠ correctness" hazard (§7).

   `catalog.schema.json` carries **four fields beyond the spec** — `visibility`, `kind`,
   `framework_default` and top-level `reserved_skill_names` — so it is a deliberate superset of
   conformance §5.2–5.3 and none of the four may be presented as a spec requirement (§9b.4).
   `example` stays normative because it seeds *both* the installer's scaffold and the eval.
   `learnings` is deliberately absent as a capability (§6.2) — a knowing divergence recorded in §9b.1.
2. **Base routing table** in the spec's `{event,label,loop}` shape, shipped beside `route-event.sh`,
   versioned by the caller's `@ref`.
3. **Overlay-merge logic** in `route-event.sh` (base ⊕ overlay, `(event,label)` identity,
   `loop:null` disable) + updated tests.
4. **Framework-default ("inherited") capability skills** for the capabilities that *can* have a
   sensible generic default — `ops-branching`, `ops-ci`, `ops-workspace`, `ops-notify`,
   `ops-repo-meta` (backed by `detect.sh`), and **`ops-integrate`**, which is new code rather than a
   demotion: nothing implements the gates-plus-merge service today (Phase 3 builds it). `ops-change`
   and `ops-release` are **always repo-specific** (no framework default).
5. **Eval harness** ([layer 1](ops-capability-skills.md) §09) — per-capability suites seeded from catalog examples, LLM-judged,
   opt-in. Later phase.
6. **The spec itself, in-repo** — **done in Phase 0.** Both design docs are `docs/` companions, so the
   catalog and the installer have a normative reference to cite.

---

## 4. Phased migration plan

**This ordering deliberately departs from [layer 1](ops-capability-skills.md) §10.** §10's "First
build" says: *"Stand up `ops-release` + `ops-repo-meta` first — behavioral and ambient-data — then
write `/ops-install` against the catalog."* That assumes the greenfield `umbraco-mcp-ops` case and
assumes Layer 3 (reference skills + scaffolder templates) is where those two get written. Neither
holds here: Layer 3 was never produced, and this engine already ships loops that resolve base
branches four different ways (§7). So we author the catalog first (Phase 1) and let the reference
implementations arrive as framework defaults (§3.4) and consumer skills (Phase 6).

The cost of departing is real and worth naming: **nothing exercises the catalog until Phase 3**, so
an interface mistake made in Phase 1 stays undetected for two phases. §10's order front-loads that
feedback. If Phase 1 feels speculative, the mitigation is to write one reference `ops-repo-meta`
alongside the catalog rather than to reorder the whole plan.

Otherwise adapted for migrating a live engine whose central loop (`issue-loop-core`) is still a
placeholder. **Key sequencing insight:** the placeholder loops (`issue-loop-core`, `rework-loop`,
`learning`) do **not** exist yet — build them *directly* in capability-model form so we never build
them twice.

**Phase 0 — Ratify (docs + charter).** **Complete.** Three things, all documents, no behaviour
change:

- ~~Commit both design docs to `docs/`.~~ Done — see the two links at the top.
- ~~Rewrite the `CLAUDE.md` "seam doctrine" from config-pointer/override-defer to
  convention/`ops-<capability>`, and point it at [`vocabulary.md`](vocabulary.md).~~ Done — the
  glossary is ratified, and "seam" now means **only** a data+schema extension point.
- ~~Close the §9a conformance gaps.~~ Done — all seven; see the §9a table for where each landed.
  One of them (§9a.1) turned out to be a decision rather than a slip and moved to §9b.8.

Phase 0 also picked up an unplanned correction: reading the `umbraco-mcp-ops` prototype's shipped
learnings mechanism showed that three things §2a called "genuinely open, not recoverable from
history" were in fact fully specified there. §2a is rewritten around them, and Phase 2 loses a task
(there is no triage route row).

**Phase 1 — Author the catalog. Complete.** The interface pivot: everything downstream conforms to
what this phase wrote. *Prerequisite §9a closed in Phase 0*, which mattered — the catalog is where
those gaps would have become permanent.

- ~~Create `catalog.json` + `catalog.schema.json` for all 8 capabilities.~~ Done: **8 capabilities,
  19 actions**, each with `description` per capability and per operation, a worked `example`,
  guidance-only `input` / `output`, and the four extra fields in §9b.4. Those `action` names are the
  **validation set** every capability rejects against (§2b), so authoring them *was* authoring the
  invocation contract.
- ~~Reserve the framework loop names.~~ Done, and **machine-readable** rather than prose:
  `reserved_skill_names` in the catalog, so Phase 2's router and Phase 5's installer validate against
  one source.
- ~~Argue the inventory's `proposed` rows, then delete the table.~~ Done — see §1's replacement
  block for what changed and why. §6.8a resolved (no delegating `land`) and §9c's
  `resolve-line`-vs-`topology` question settled (`ops-repo-meta · lines`).
- ~~Extend the README with the **action** level, derived from the catalog rather than
  hand-maintained.~~ Done via `scripts/catalog-to-readme.sh`, whose `--check` mode its test asserts,
  so the README cannot drift from the catalog. The README's "config contract" section is Phase 8's to
  delete and was left alone.
- Also added, unplanned: **`scripts/validate-catalog.sh`** plus tests, and `tests.yml` widened to
  find `*.test.sh` anywhere rather than only under `plugins/` — otherwise neither new test would
  have run in CI.

**What Phase 1 could not verify.** Nothing exercises the catalog until Phase 3, exactly as §4's
preamble warned. The action names, the `example` shapes and the `input`/`output` guidance are all
unexercised by a caller. The mitigation §4 suggested — write one reference `ops-repo-meta` alongside
the catalog — was **not** taken, so an interface mistake here still surfaces two phases later.

**Phase 2 — Routing to spec (edge). Complete.**

- ~~Convert `route-map` to the `{event,label,loop}` shape + event vocab.~~ Done, `version: 2`.
  `action` folded into the event string, `route` renamed `loop`, and the `state` field **deleted** —
  no rule used it, and review events aren't in the vocabulary, so it was dead weight that implied a
  matching mode the spec doesn't have.
- ~~Add base⊕overlay merge to `route-event.sh`.~~ Done, in **one jq pass** so the semantics aren't
  half in bash. Identity is `(event, label)` encoded as JSON, so no separator can collide with a
  label; overlay wins; `loop: null` disables.
- ~~Rename route targets to reserved loop names.~~ Done, and the test now cross-checks every
  `loop` against **`catalog.json`'s `reserved_skill_names`** rather than a second hard-coded list.
  The loop *skills* still have their old names until Phase 3/4, so `loop-dispatch`'s SKILL.md
  carries an explicit translation table for the interim.
- ~~Remove the duplicated `case` fallback.~~ Done, and replaced by the opposite behaviour: a
  missing/unreadable table, absent jq, or a rule with an invented event now **exits 2** rather than
  printing `loop=none`. The old fallback silently kept working while drifting from the map; a silent
  `none` means loops stop firing and nobody notices.
- ~~Move the overlay to a committed file.~~ Done, as `.github/ops-routing.json` —
  **JSON, not the `.yml` §6.4 recorded**, for the reason amended there. `loop-dispatch.yml` gained a
  checkout of the caller repo, without which the overlay simply isn't on disk at the edge.
- ~~Update `route-event.test.sh`.~~ Done: **42 cases**, up from 21, covering the merge semantics,
  the closed vocabulary, exact-label matching, the cross-repo `target`, every loud-failure path, and
  the base table's own conformance.
- **No route row for `ops-triage-loop`** — it is a weekly scheduled sweep, not an event (§2a), so
  the base table stays at **four** rows, and a test asserts that count. *(It is five now: the
  fifth row is `ops/port` → `ops-port-loop`, added with that loop in §10.43. Still no triage row,
  which is what this bullet was about.)*

**Left for Phase 5**, deliberately: full schema validation of a consumer's overlay. The router does
the checks it must do to route correctly (valid JSON, events in the vocabulary) and no more; proving
an overlay conforms to `ops-routing.schema.json` is the installer's job per conformance §8.

**Phase 3 — Framework loops invoke *services* by name. Complete.** The first phase where the
catalog is exercised by a caller rather than only declared.

- ~~Rewrite `merge-flow`→`ops-merge-loop` to command `ops-integrate · land` and stop resolving
  `base` / `release_base` / `merge_strategy`.~~ Done. The loop is now **scheduling only** — sweep,
  CI-poll cadence, the 15-minute cap, the cap of 10, the comment. It has no merge path at all.
- ~~Build `ops-integrate`.~~ Done: the four gates **plus** the release-base skip, returning a
  structured outcome. It re-checks CI itself rather than trusting the loop's poll, because with no
  branch protection that check is the only gate that holds.
- ~~Rewrite `auto-release-loop`→`ops-release-loop` to call `ops-release` only.~~ Done, and it never
  calls `ops-branching`.
- ~~Extract `ops-ci` (`status` + `log`) from `github-ops`.~~ Done. Forge mechanics stay framework;
  the CI **provider** is now internal to `ops-ci`, which is what kills the
  `ci.provider`/`ci_provider` spelling split.
- ~~Demote `release-and-branching`→`ops-branching`, values private, command-only.~~ Done. Base is
  **set membership over the live lines**, re-read from `ops-repo-meta · lines` every invocation and
  never cached, so a major-version cutover needs no engine change.
- ~~Fold `sync-dev` into `ops-release · sync`.~~ Done — the skill is gone; its contract survives as
  a reference for whoever writes a repo's `ops-release`, since that capability has no framework
  default.

**The four-way base-branch drift (§7) is closed.** All four holders are gone: `merge-flow`'s
resolve-and-compare (the loop no longer resolves anything), `release-and-branching` (demoted),
`operation-catalog.json`'s `detect-base-branch` (**deleted**), and `ai-ops.schema.json`'s
`branching.*` (still on disk until Phase 8, but now read by exactly one skill —
`ops-repo-meta` — as a transitional bridge, not by any loop).

**Phase 4 — Build the placeholder loops directly in capability form. Complete.** Built once, in
capability form, rather than built then migrated.

- ~~`ops-issue-loop`, commanding `ops-change` and reading `ops-ci` / `ops-repo-meta`.~~ Done. It
  **stops at a green PR**: the old long-lived review phase is gone, because it existed only to
  serve a merge this loop no longer performs (§10.23).
- ~~`ops-rework-loop`.~~ Done. It pushes and **hands the PR back** rather than landing its own
  fix, so there is still one merge path behind one human gate.
- ~~The learnings mechanism as a uniform framework capture hook + `ops-triage-loop`.~~ Done, as
  the **`ops-learnings`** plugin. The capture side is ported whole — the two read-only analyzer
  prompts, the fenced-JSON record with its closed 9-value `category` set, the exact-title de-dup,
  the re-entry guard and the once-per-session marker — with every `hifi-phil/umbraco-mcp-ops`
  hard-coding replaced.
- ~~`ops-triage-loop` to the inherited contract.~~ Done: cluster/dedupe → threshold → route →
  mark processed, on a **weekly schedule**, with the prototype's dedupe key, threshold (≥ 2) and
  caps (10 per run, ≤ 5 PRs) adopted as **defaults marked as inherited rather than measured**.
- Also built **`ops-workspace`** — the last framework default, and unavoidable here (§10.21).

**§2a's three residual questions are answered where they belong** — inside `ops-triage-loop`
rather than in this plan (§10.24). The one that matters: on a single-product consumer only two of
the four destinations exist, so **the threshold gates nothing**, and the skill says so rather than
pretending to apply it.

**All five framework loops of this plan now exist under their reserved names** (six today, with
`ops-port-loop`), so `loop-dispatch` no longer
carries a translation table.

**Phase 5 — Rebuild the installer as `ops-install`. Complete.** All three conformance §8 clauses
are met, and each by a **script** rather than by prose, because a coverage report a model
produces by reading directories can be quietly wrong and "you are covered" is exactly the claim
nobody re-checks.

- ~~Coverage report (present / inherited / missing by `ops-<cap>` name).~~ `scripts/coverage.sh`,
  with `--json`. It exits non-zero when anything is missing, so a caller can gate on it, and it
  reads the defaults **off disk** rather than trusting the catalog's `framework_default` flag —
  a flag saying a default exists is a claim, and checking claims is the point. 15 tests.
- ~~Scaffold a stub per missing capability, carrying `disable-model-invocation` and the §2b
  guards.~~ `scripts/scaffold-capability.sh`, **generated from the catalog entry**, so a stub can
  never disagree with the catalog about which actions exist. It refuses a capability the catalog
  does not declare, and never overwrites. 50 tests.
- ~~Validate the routing overlay per conformance §6.~~ `scripts/validate-overlay.sh`: shape, the
  event vocabulary, `(event,label)` uniqueness, and that **every routed loop resolves to an
  installed skill**. It also warns when a `loop: null` disable matches no base rule — which does
  nothing at all and is always a mistake. 27 tests.
- ~~Install the caller workflow on **both** repos in a split topology.~~ Written into the skill as
  its own step, with the wiring per repo spelled out, because this is the step that silently
  half-works: issue labels on a repo with no workflow are simply ignored.
- ~~Keep `detect.sh`.~~ Kept, and re-described as a **seed, not an authority** — it writes
  nothing now.

**Phase 6 — Consumer capability skills (Forms, then Automate).** **Out of scope for this repo** —
it is work in the two consumer repos, not the engine. Everything the engine owes it is done: the
catalog declares the interface, `ops-install` scaffolds both skills and proves coverage, and the
prerequisites table below is the checklist.

**Phase 6 detail, for whoever does it.** Provide Forms' implementations:
`ops-change` (dotnet build/verify + cross-repo close to `Umbraco.Forms.Issues`), `ops-release`
(nbgv/version bump/tag/back-merge across `vN/dev`↔`vN/main`), `ops-repo-meta` (topology: public
issues repo + internal code repo, `releases` and `learnings` both resolving to `code`; **live lines +
primary line** per §8), `ops-branching` (versioned-gitflow, values private), `ops-ci`
(azure-pipelines), `ops-workspace` (worktree + SQLite DB, wrapped by `ops-change`), `ops-notify`.
Learnings needs no Forms-specific capability — only the `learnings` role, and for Forms that is
**`umbraco/Forms`, not `Umbraco.Forms.Issues`**: the issues repo is public and a proto-learning is an
internal note about how a build went (§1a). Then Automate, which differs only in
`ops-change` (port direction) and
topology (in-repo issues). Every one of these skills honours the **§2b contract** — two positional
arguments, `{}` for an absent context, unknown actions rejected, each action idempotent, and
the do-not-select guard in its description (**not** `disable-model-invocation` — see §9b.9). Run `/ops-install` and prove full coverage on
both.

**Onboarding prerequisites** — repo-side changes both consumers need before a loop can run; see §8
for the evidence:

| Prerequisite | Forms | Automate | Why |
|---|---|---|---|
| Create the trigger labels (`ops/ready-for-ai`, `ops/auto-merge`, …) | **`/ops-install` does it** | **`/ops-install` does it** | none exist in either repo today; nothing routes without them. Step 5 of the installer creates them on the repo each one's role implies |
| Declare **live lines** + the **primary line** | `.claude/ops-repo-meta.json` | same | multiple majors are live at once, and neither is inferable from version numbers. `/ops-install` writes the file and `validate-repo-meta.sh` checks it — including that `primary` is one of `live` |
| Create the **learnings** labels (`ops/proto-learning`, `ops/triaged`, `ops/loop-improvement`) | **`/ops-install` does it** | **`/ops-install` does it** | the inbox filter is label-based (§2a); `ops/triaged` is written by triage, so it must exist before the first sweep |
| Declare the **`learnings`** role | nothing to declare — omitting it resolves to `code`, i.e. `umbraco/Forms`, which is what Forms wants | same | a proto-learning is an internal note and Forms' issues repo is public (§1a). The default is already correct here |
| Move the default branch off `v15/dev` | needed | — | routines clone the **default branch** (`README.md` caveat), and Forms' default is a line no longer worked on |
| `allow_update_branch` → true | needed | needed | both `false`; the loop can't refresh a stale branch before the merge gate |
| Leave native auto-merge **disabled** | keep off | keep off | landing is the service's decision; native auto-merge would race it |
| Document per-PR labelling for ports | needed | needed | landing is per-PR (§8), so each line's PR carries its own label |
| Branch protection on live lines | recommended | recommended | not required, but with none (the case today) `ops-integrate`'s own CI re-check is the **only** real gate |
| Install the caller workflow on **both** repos | needed — code **and** `Umbraco.Forms.Issues`, and the issues repo also needs an `ops-repo-meta.json` declaring `topology.code` | single repo, one install | conformance §7.5 requires it on every repo emitting consumed events. The issues repo's file is how the router learns where the routine should work (§10.37) |

**Phase 7 — Evals. Complete.** `evals/` holds **8 suites, 66 cases**, and they are
**generated** — `scripts/build-evals.sh`, with a `--check` mode a test asserts, so they cannot
drift from the catalog. A hand-written eval set drifts, and a drifted one either fails on the
wrong thing or passes while testing an action that no longer exists.

Every action gets the four cases that correspond to the four MUSTs a capability can silently get
wrong: the catalog's **worked example**, an **empty context** (must be `{}`, not an error), an
**unknown action** (must be rejected), and **idempotency** (same action twice, no second side
effect). A data capability gets a fifth for structured output (§4.4).

`scripts/run-evals.sh` runs a suite, LLM-judged against the asserts. It needs `claude` and a real
repo, so it is **opt-in and not in the CI gate** — and deliberately not named `*.test.sh`, or the
gate would try to run it. `--list` and `--plan` are hermetic and tested.

**Phase 8b — Give the declared facts a home. Complete.** Added after Phase 8, on review: deleting
the config file left the handful of *undetectable* facts with nowhere to live but prose inside a
repo-authored skill, and `CLAUDE.md`'s own rule says a declared thing is a data seam. See §10.36.

**`.claude/ops-repo-meta.json`** + `ops-repo-meta.schema.json` + `validate-repo-meta.sh` (43
tests). A **strict subset** of what `ai-ops.yml` held: topology roles, the live lines with the
primary and the port order, and label overrides. `additionalProperties: false` at every level, so
a branch name, a CI provider or a skill pointer fails loudly rather than creeping back.

It also collapses a duplication nobody had noticed: the split-topology fact used to live **twice**
— as `with.target_repo` in the caller workflow *and* inside the repo's `ops-repo-meta` — in two
files in two repos with nothing to catch a disagreement. `route-event.sh` now reads
`topology.code` at the edge, and `target_repo` is deprecated.

**Phase 8 — Retire the config-pointer model. Complete.** `ai-ops.schema.json` and
`ai-ops.example.yml` are **deleted** (§6.7 — no remnant; `ai-ops.yml` only ever existed in a
consumer). The transitional read inside `ops-repo-meta` is gone with them, so nothing anywhere
reads a config file. The README's config-contract section is removed and its opening rewritten;
`CLAUDE.md` now says plainly that if you want a config key, the answer is a capability.

Safe to do now precisely because **no consumer is onboarded yet** — §8 records that neither repo
has any trigger label, so there is no live `ai-ops.yml` to break. Had one existed, this phase
would have had to wait for Phase 6.

---

## 5. What survives of `ai-ops.yml`?

If `ops-repo-meta` (`identity` + `topology`) owns repo identity and the capabilities own everything
else, `ai-ops.yml`'s normative content is fully absorbed and the file can be **removed**.
**Decided (§6.7): remove it** — no thin remnant. A second source of the same facts is exactly the
drift this migration exists to kill. Phase 8 does the deletion.

---

## 6. Decisions — settled

The first nine were resolved in review on PR #4 (27-07-2026); **§6.10 was added 28-07-2026**, after
the register sweep surfaced the last open item. The arguments are kept as the decision log; the
**Decided** line is what binds. The resolution of 8 opened one sub-question, §6.8a, which **Phase 1
closed** while writing the catalog entry it turned on.

1. **Coexistence vs clean break.** → **Decided: clean break per phase.** The placeholders let us
   build the central loops fresh rather than migrate them, so there is nothing to run in parallel.
2. **Which capabilities ship a framework default (`inherited`).** → **Decided:** defaults for
   `ops-branching`, `ops-ci`, `ops-workspace`, `ops-notify`, `ops-repo-meta` and — once §6.8 settled
   as A — `ops-integrate`, whose merge gates are engine policy and should be identical everywhere.
   Always-repo-provided:
   `ops-change` and `ops-release` — **those two only**. Learnings is *not* a per-repo capability:
   capture is uniform framework machinery (+ `ops-triage-loop`) so lessons compound, with destinations as
   `ops-repo-meta` data. Evidence it was never a real seam: `ai-ops.schema.json` types
   `learning.routing` as a free-form prose string ("Free-form note on where triage routes
   learnings"), so there is nothing behavioural to override.
3. **Build the placeholders directly in capability form?** → **Decided: yes.** `issue-loop-core`,
   `rework-loop` and `learning` don't exist, so build once as `ops-issue-loop` / `ops-rework-loop` /
   framework capture + `ops-triage-loop`.
4. **Overlay home.** → **Decided: a committed `.github/ops-routing.json`.** Both candidate homes
   were spec-legal; the committed file is auditable and reviewable in the consumer repo.

   **Amended in Phase 2: JSON, not YAML.** The decision was recorded as `.yml`, which does not
   survive contact with the edge. `route-event.sh` runs in a GitHub Action *before any session
   exists*, with bash and jq and nothing else — the same hermetic constraint `CLAUDE.md` puts on
   every test. jq cannot read YAML, and requiring `yq` would either break the hermetic rule or make
   the router depend on what a runner happens to have installed. This is the same reasoning that
   already chose JSON over the spec's YAML examples for the catalog (§6.6), so the two seams now
   agree. Nothing else about the decision changes: same home, same shape, same merge semantics.
5. **Delivery mechanics.** → **Decided: stacked PRs into `main`, one per phase**, as with the engine
   baseline. Keeps CI green and each phase reviewable on its own.
6. **Catalog format.** → **Decided: JSON** — `catalog.json` + `catalog.schema.json`, matching the
   repo's existing data-seam convention (`route-map.json`, `operation-catalog.json`) rather than the
   spec's YAML examples.
7. **Remove `ai-ops.yml` entirely** (§5) or keep a thin remnant? → **Decided: remove it entirely**,
   in Phase 8.
8. **`ops/auto-merge` scope — does `ops-integrate` exist?** → **Decided: A — it exists.**

   **The status quo is PR-generic, not undecided.** `merge-flow` Step 1 (`SKILL.md:63`) lists open
   PRs filtered by the label alone — no author check, no `ops/generated-by-ai` filter, no issue link —
   and every gate in Step 2 (`:70-94`) is a machine-verifiable property of the PR itself: label
   present, CI green, mergeable, base correct. Nothing in the loop needs to know who wrote the PR
   or which issue produced it. `README.md:46` describes it the same way.

   - **Option A — keep it PR-generic.** `ops-integrate` exists: a service owning "land an approved
     PR" (the gates + the merge), wrapping `ops-branching · merge`. Dependabot and human-authored
     PRs stay in the loop.
   - **Option B — narrow to change-only.** `land` becomes the tail of `ops-change`
     (implement → verify → close-issue → land) and `ops-integrate` doesn't exist. Dependabot and
     human PRs leave the loop with no replacement, and `ops-change · land` would have to handle PRs
     it never created, reconstructing change context it doesn't have.

   **Resolution: A.** Narrowing would drop working dependabot and human auto-merges, and the
   evidence for the general case is stronger than "it's the status quo": Automate has eight merged
   dependabot PRs and one open into `v18/dev` right now, one of which was merged by hand — exactly
   the work the label automates (§8). None of the four gates depends on the PR's provenance, so the
   operation doesn't belong to the thing that produced the PR.

   **Follow-on this settles:** `ops-integrate` owns merge *policy* (the four gates + the
   release-base skip); `ops-merge-loop` keeps *orchestration* — sweeping labelled PRs, the CI poll
   cadence and 15-minute cap, the per-run cap of 10, and reporting. Policy in the service,
   scheduling in the loop.

   **8a. Does `ops-change` also keep a *delegating* `land`?** → **Decided in Phase 1: no.**

   The original recommendation was "A, with `ops-change · land` delegating to `ops-integrate`" —
   one merge path, two entry points — and that is what review agreed to. Two facts found afterwards
   argue against the delegating tail:

   - **A change lands N times at N moments.** Forms ships one logical fix across v13/main, v17 and
     v18 (§8); v17 can be green while v18 is still being adapted. "The tail of `ops-change`" implies
     one tail, and there isn't one.
   - **A human gate splits delivery in two.** `implement → verify → land` isn't a single run, so the
     tail isn't reachable from the same invocation anyway.

   Under that reading `ops-change` ends at `close-issue`, which fires when **all** target lines have
   landed, and every merge enters through `ops-merge-loop → ops-integrate`.

   **Resolution: no delegating tail.** Writing the catalog entries made the case decisive rather
   than balanced. A delegating `land` would have to be reachable from an invocation that has already
   ended (the human gate sits between `verify` and any merge), and it would need a context naming
   *which* of N lines to land — at which point it is `ops-integrate · land` with an extra hop and a
   second place for merge policy to leak into. `ops-change` declares three actions:
   `implement`, `verify`, `close-issue`.

9. **If `base` is private, who skips a release-base PR?** → **Decided: (b) — the service.**

   `merge-flow` currently decides this itself, comparing the PR's base against the resolved
   `release_base` (`SKILL.md:87-94`, guardrail `:118`) and skipping release PRs as
   `ops-release-loop`'s job. A private `ops-branching` forbids that comparison.

   - **Option (a) — a classification read.** `ops-branching · classify-pr` returns
     `integration | release | wrong-base`; the loop routes on the classification and never sees a
     branch name. Satisfies the privacy rule (a classification is not a branch name) but adds a
     read to a primitive we just defined as command-only, and leaves merge policy split across loop
     and service.
   - **Option (b) — the skip lives in the service.** `ops-merge-loop` hands every labelled PR to
     `ops-integrate`, which asks `ops-branching` and declines release-base PRs. All merge policy in
     one place, and the wrong-base flag is authored by the thing that knows what right looks like.

   **Resolution: (b), with `ops-integrate` returning a structured outcome** —
   `merged | skipped:release-base | blocked:ci | blocked:conflict | blocked:changes-requested` — so
   the loop can still comment the specific blocker (Step 4's behaviour) and stays observable without
   holding branch names. That gets (a)'s legibility without the leak, keeps `ops-branching`
   command-only, and puts all merge policy in one place. **`classify-pr` is dropped.**

   **Standing of that vocabulary: a convention, not a contract.** The spec requires *no* error
   vocabulary and makes the result shape a SHOULD verified by evals
   ([conformance spec](ops-capability-skills-conformance-spec.md) §4.2). It is promotable to a MUST
   only if a **non-model** consumer parses the output (§4.5) — and `ops-merge-loop` is a model
   reading a result to decide what to comment, not a shell step branching on a string. So the five
   outcomes are a **fixed set the Phase 7 evals assert on**, not a validated envelope, and they
   travel inside the recommended `{"ok": …}` shape (§2b) rather than replacing it. If a later
   deterministic step ever parses them, invoke §4.5 and promote it *then* — explicitly, for that
   capability only.

   The service re-checks CI even though the loop already polled it. That duplication is deliberate:
   native auto-merge is disabled and there is **no branch protection on either consumer repo** (§8),
   so the service's own check is the only gate that actually holds. A service that trusts its caller
   has no gate at all.

**8 and 9 were coupled**, through one question neither named: **do the merge gates belong to the
loop or the service?** All four lived in the loop (`merge-flow` Step 2). **Review settled it: the
gates belong to the service** — which gives 8 its `ops-integrate` and answers 9 as (b) in one move.
That was the last thing blocking Phase 3.

### 6.10. The repo-family consumer shape — **deferred, not designed**

Added 28-07-2026, after the register sweep (§10.40) surfaced it as the last open item.

**The question.** `README.md` names three consumer shapes; Phase 6 covers two. The third — **one
`ops-change` serving many repos**, the MCP server family with its shared consumer repo — was never
migrated onto the convention model, even though the two design docs this plan ports were written
*for* that repo.

**Decided: out of scope for this plan. Deferred, and it needs input from whoever owns the MCP
family** — not a decision this engine repo can make alone. Recorded rather than quietly dropped,
because it is a shape we advertise.

**The prototype already solved this, and its answer does not survive the port.** Checked
28-07-2026 rather than assumed — the deviations log records this exact mistake twice (§10.2,
§10.3). `hifi-phil/umbraco-mcp-ops` ships **`mcp-issue-loop`**, which serves the whole
`@umbraco-cms/mcp-*` family, and `scripts/cloud-skill-sync/` delivers it to every member repo. So:

- **Delivery is a solved problem, not an open question.** `cloud-skill-sync.sh` is how a shared
  skill reaches each member repo's session, and we have **already ported it** (§10.34). Do not
  re-litigate this part.
- **The prototype's actual mechanism is illegal here.** It puts the product knowledge *inside the
  loop skill* — `mcp-issue-loop` resolves "the current repo" at runtime, hard-codes `ready-for-ai`
  and `dev`, and refuses to run unless the repo "looks like an MCP repo" (`src/umbraco-api/tools/`,
  worktree hooks). That is precisely what `CLAUDE.md`'s golden rule forbids: a framework loop
  carrying one family's facts. The convention model would push all of that down into `ops-change` —
  and *that* is the part nobody has designed.

So what is genuinely unsettled is narrower than "the whole shape", and it is two things:

1. **Name collision.** A capability is found **by name**. If the family's shared skill is called
   `ops-change` and a member repo also has one, there is no defined precedence — the very problem
   §1 cites as the reason the engine binds by convention rather than by shadowing.
2. **`ops-repo-meta · topology` when `code` varies per run.** Today the file answers "what is this
   repo". A shared skill needs "which of my N repos am I in", which may be a new action.

And the reason to defer even those: **neither single-repo consumer has run end to end yet.**
Designing the harder shape before the simple one has proved itself is guessing at requirements.

**What it costs while deferred.** `ops-triage-loop`'s `shared-skills` destination never fires. On a
single-repo consumer the skill names only two live destinations, `code` and `loop-self`, says the
threshold therefore gates nothing and to say so in the run summary (§10.24), and tells the triager
to **hold** a lesson — leave the proto-learning open and uncommented — rather than mis-file it. So a
family lesson is **not lost**; it waits as an open issue for a human. But the skill does not say
where a generalizable lesson *should* go on a single repo, which is a small unspecified gap rather
than a designed fallback. Worth closing when the shape is. Nothing else in the engine assumes a
family exists.

**When to re-open.** After Forms has run a full issue → PR → merge → release cycle, and with the MCP
family owner in the room.

---

## 7. Risk / hazard register

**Read the strikethroughs.** Execution closed most of this register; the rows below are kept with
their original wording so the reasoning survives, because a closed hazard that leaves no trace gets
re-discovered. **Nothing below is still open.** Of what remains: the **repo-family shape is deferred
by ruling** (§6.10),
**no-static-typing is permanent by design**, and the rest are **live Phase 6 hazards** — facts about
Forms and Automate that whoever writes their two skills has to hold, not engine work.

- ~~**Central loop is a placeholder.** `issue-loop-core` (and `rework-loop`) are routed-to but
  unbuilt; the whole issue→PR path is not exercisable today. Migration and first-build are the same
  work here — plan accordingly.~~ **Closed in Phase 4** — `ops-issue-loop` and `ops-rework-loop`
  are built, and the review phase was dropped as a second merge path (§10.23). Still unexercised
  end to end, which is what the first consumer run proves, not this repo.
- ~~**Base-branch knowledge lives in *four* places**, not two: `ai-ops.schema.json`
  (`branching.base` / `release_base`), runtime detection in `release-and-branching`, `merge-flow`'s
  own resolve-and-compare (`SKILL.md:40-59`, `:87-94`), and `operation-catalog.json`'s
  `detect-base-branch` (a `forge`-axis operation whose title is "defer to release-and-branching").
  Making the values private to `ops-branching` is the only move that collapses all four; migrating
  them into a caller-visible `resolve-base` action would just relocate the leak.~~ **All four
  closed** — the schema is deleted (Phase 8), `release-and-branching` and `merge-flow` are replaced
  by `ops-branching` + `ops-integrate` with the values private (§9b.3), and `detect-base-branch` is
  deleted from the operation catalog (§10.20).
- ~~**`ci.provider` vs `ci_provider` spelling split** (schema/detector vs the github-ops references).
  Don't carry it forward; the capability is the source.~~ **Closed** — the provider is **internal to
  `ops-ci`**, so there is no spelling to agree on. `ops-repo-meta.schema.json` refuses the key
  outright.
- ~~**Route-map lives in two places** (`route-map.json` + the `case` fallback in `route-event.sh`).
  Collapse to one during Phase 2.~~ **Closed in Phase 2**, and the fallback's behaviour inverted: a
  missing table now **exits 2** rather than silently resolving to `loop=none` (§10.11).
- ~~**Two marketplace entries point at directories that don't exist.**~~ **Fixed in Phase 3.**
  `learning` and `dotnet-web-runtime` were **removed from `marketplace.json`** — an entry whose
  `source` resolves to nothing makes `/plugin marketplace add` fail for the *whole* marketplace,
  so a placeholder entry is worse than no entry. Phase 4 re-declares `learning` when it exists.
  `scripts/validate-manifests.sh` now fails CI on a phantom entry, an undeclared plugin, or a
  name/version/description that drifts between the two manifests. Original note kept below.
- ~~`learning` and `dotnet-web-runtime` have a `source` path but
  no directory and no `plugin.json`, which `CLAUDE.md` requires of every declared plugin — so
  `/plugin marketplace add` would fail on them. They read as shipped rather than as placeholders.~~
  Either scaffold them or mark them unreleased. (An earlier revision warned that `learning`'s
  description was the **only** written spec for `ops-triage-loop`; the prototype's `triage-learnings`
  skill is a far fuller one (§2a), so the entry is no longer load-bearing.)
- **DEFERRED BY RULING — the repo-family consumer shape is never migrated.** `README.md` names three consumer
  shapes — Forms, Automate, and the MCP server family with its shared consumer repo
  (`umbraco-mcp-ops`) — and this plan covers only the first two (Phase 6). The
  one-`ops-change`-serving-many-repos case is neither migrated nor tested against the convention
  model, even though the design docs this plan ports were written *for* that repo. It also strands
  `ops-triage-loop`'s `shared-skills` destination (§2a), which only means anything for a repo family.
  **Ruled 28-07-2026: deferred, out of scope for this plan, and it needs input from whoever owns the
  MCP family — see [§6.10](#610-the-repo-family-consumer-shape--deferred-not-designed)** for the
  reasoning, what it costs while deferred (one destination that fails safe), and when to re-open it.
- ~~**`ops-triage-loop` has no route row, and its destination can't be a dispatch input.**~~
  **Withdrawn** — it needs no route row. Triage is a weekly scheduled sweep and `ops/triaged` is an
  output marker, not a trigger label (§2a). The other half was true but is now moot: triage picks its
  own destination, so nothing could have passed it as `--target`, and a schedule has none to pass.
- ~~**Label names are prose in twenty-odd files.** The `ops/` prefix sweep (§10.13) had to touch every
  skill, template and doc that names a trigger label, because the only machine-readable copy is the
  four labels in `route-map.json`. The next label change will be the same sweep. The durable fix is
  already promised by the catalog — `ops-repo-meta · identity` returns "the trigger labels this repo
  uses, by purpose" — so **Phase 3 should make that the single source and have the loops read it**
  rather than restating names in prose. Until then, a renamed label silently half-lands.~~ **Closed
  where it matters.** Every loop now resolves labels **by purpose** off
  `ops-repo-meta · identity` — `labels.ready`, `labels.land`, `labels.rework`, `labels.release`,
  `labels.proto_learning` — and none hard-codes a name at a decision point. `plan-labels.sh` (§10.39)
  is a second reader of the same table, for creation. Literal names still appear in prose *as
  illustration*, and the two enforced copies are `route-map.json` (patterns + a test) and the
  defaults in `ops-repo-meta`. A rename now touches those two and the docs, not the behaviour.
- ~~**`scripts/cloud-skill-sync.sh` does not exist.** Both `README.md` and `CLAUDE.md` name it as the
  mechanism that delivers the engine into a cloud routine — the **main runtime** — and the file was
  never ported from the prototype (which has it, as `scripts/cloud-skill-sync/cloud-skill-sync.sh`).
  Found in Phase 1 while writing the layout section. Nothing can run as a routine until it lands, so
  it is a **Phase 6 blocker**, not a documentation nit.~~ **Ported and fixed in Phase 5** (§10.34) —
  it now delivers **every** skill and agent rather than a hand-maintained list, and wires the capture
  hooks into `settings.json`, without which proto-learning capture silently does nothing in cloud.
  29 hermetic tests.
- ~~**The prototype is the only real spec for the learnings mechanism, and it is a different repo.**
  Everything in §2a beyond the destination names comes from `hifi-phil/umbraco-mcp-ops`, which this
  engine does not track and which can change or disappear. Phase 4 must **port** that design into
  this repo rather than cite it, and Phase 4's own skill becomes the spec afterwards.~~ **Ported in
  Phase 4.** `ops-triage-loop`, `capture-proto-learning.sh`, the two analyzer prompts and
  `references/proto-learning-schema.md` are the spec now; the prototype is history, not a dependency.
- ~~**`README.md` references a "topology map" that doesn't exist.**~~ **Fixed** — the dangling
  sentence was removed and the README now links this plan instead.
- **"The base branch" is a single value in a repo with several.** Both consumers have **two live
  integration branches at once** and Forms still takes security merges into `v13/main` (§8). Any
  `resolve-base` that returns one branch will flag a legitimate PR as wrong-base. `ops-branching`
  must hold base as **set membership over live lines**, and the wrong-base gate must test membership,
  not equality.
- **Primary line ≠ newest line ≠ default branch.** Forms' primary line is v17, which is neither its
  newest (v18) nor its default branch (`v15/dev`) (§8). Inferring either from version numbers will
  pick wrong; both are `ops-repo-meta` facts a repo declares.
- **A line-port is a real change, not a cherry-pick.** Forms ports may need adapting, so a ported PR
  needs its own `implement` / `verify` / CI cycle. Treating ports as mechanical would land unbuilt
  code.
- **Neither consumer repo has branch protection, and native auto-merge is disabled** (observed
  27-07-2026 — recheck at Phase 6). Nothing outside `ops-integrate` will stop a red merge, which is
  why the service re-checks CI itself (§6.9) rather than trusting the loop's poll.
- **No static typing (deliberate).** A capability that returns the wrong shape is caught at runtime
  or by an eval, never statically (spec's explicit trade). Coverage ≠ correctness — Phase 7 evals
  are the only behavioural guard.

---

## 8. Consumer reality check — Forms and Automate

Gathered 27-07-2026 from the two repos themselves (settings, branches, recent merges) except the
**primary line** and **port direction** rows, which are stated by the maintainers — they aren't
inferable from the repos and that is precisely why they must be declared facts. This section exists
because three of the corrections in §7 were only visible by looking at how the repos actually run;
Phase 6 should re-verify rather than trust it.

| Fact | `umbraco/Forms` | `umbraco/Umbraco.Automate` |
|---|---|---|
| Visibility | private | public |
| Issues | separate public repo (`Umbraco.Forms.Issues`) | in-repo |
| Default branch | `v15/dev` — **not** an actively worked line | `v18/dev` |
| Lines live at once | v13/main (security), v17, v18 | v17, v18 |
| Primary line | **v17** | v18 |
| Port direction | **upward** — v17 → v18, cherry-picked, "may need some changes" | **downward** — v18 → v17 |
| Port shape | one PR per line (e.g. a v18 forward-port of a v17 fix, cherry-picked from the v17 commit) | one PR per line |
| CI | azure-pipelines, **zero** GitHub Actions | azure-pipelines, **zero** GitHub Actions |
| Branch protection | none | none |
| Native auto-merge (`allow_auto_merge`) | disabled | disabled |
| `allow_update_branch` | false | false |
| `delete_branch_on_merge` | true | false |
| Bot PRs | — | 8 dependabot merged, 1 open into `v18/dev`; at least one merged by hand |
| AI trigger labels | none exist | none exist |

**What it forces on the engine:**

1. **Landing is per-PR, never per-port-set.** Forms cherry-picks upward and Automate ports downward;
   a set-lander would have to encode direction in engine code and would block every line on the
   slowest one. `ops-integrate` lands the PR in front of it.
2. **Direction needs no engine support.** `ops-change` is repo-provided, so Forms encodes "up" and
   Automate encodes "down" in their own skills. This is the convention model working as intended —
   the engine never learns either direction.
3. **`ops-change · implement` takes port context.** A port is a change with its own verify and CI
   (§7), so `implement` needs to know it is porting and from where.
4. **`close-issue` waits for the whole set.** One logical change lands on N lines at N moments; the
   issue closes when all target lines have landed — which is the argument behind §6.8a.
5. **`ops-repo-meta` carries the line facts** — live lines, primary line, port order — because none
   of them is derivable from the default branch or from version numbers.
6. **Onboarding is not zero-touch.** No trigger labels exist in either repo, and `allow_update_branch`
   is off in both; see the Phase 6 prerequisites table.

7. **The live-lines set changes over time.** The `automate-branch-migration` design (shared artifact
   `e7cf21bc`) specifies a **major-version cutover** that creates `v19/dev` + `v19/main` when a new
   CMS major ships. So base is not merely a set (§7) but a *moving* one — `ops-branching` must read
   it, never cache it, and a new line must not require an engine change.
8. **A fourth family member exists.** That same document names **`Umbraco.AI`** as having already
   adopted the `vN/` convention, and Automate as adopting it from there. Worth confirming at Phase 6
   whether it is a fourth consumer or out of scope.

---

## 9. Conformance gaps

Committing the two design docs (Phase 0) made the plan checkable against them for the first time,
and it did not conform. These are split by kind, because the two need opposite treatment:
**accidental** divergences are bugs in this plan, **deliberate** ones are decisions that need
recording in the spec rather than silently contradicting it.

### 9a. Accidental — fix the plan · **all seven closed in Phase 0**

| # | Gap | Source | Closed by |
|---|---|---|---|
| 1 | **`learnings` is not a canonical role.** Roles are fixed at `code` (required), `issues`, `releases`, with an unspecified role resolving to `code`. This plan routed `learning.inbox` to a `learnings` role, and `releases` appeared nowhere in the plan at all — even though Forms/Automate publish from the code repo, which is exactly what the role is for. | conformance §7.2, §7.3 | **Promoted to a deliberate divergence, §9b.8** — `learnings` becomes a fourth canonical role, unspecified resolving to `code` like the other three. `releases` written into §1a and Phase 6. |
| 2 | **Idempotency is a MUST and the plan never mentions it.** "Invoking the same action twice with the same context MUST NOT produce a second side effect" — `cut` re-run must return the existing PR, not open a second. Directly load-bearing for `ops-integrate · land` and `ops-release · cut`. | conformance §3.5 | **§2b**, with the three re-invoked actions named and evals as the only check |
| 3 | **Catalog entries need a `description` per capability *and* per operation.** The plan's §3.1 listed actions, `visibility` and `example`, and omitted the required `description` fields. | conformance §5.2–5.3 | **§3.1** normativity table + **Phase 1** |
| 4 | **Capability skills SHOULD set `disable-model-invocation: true`**, so a loop is the only caller. Nothing in the plan said so, and it is exactly what stops a capability auto-firing on a `description` match. | conformance §2.4, layer 1 §03 | **§2b** + **Phase 5** scaffold + **Phase 6** skills |
| 5 | **The caller workflow must be installed on *both* repos in a split topology.** Forms' issues live in `Umbraco.Forms.Issues`, so the router needs installing there *and* on the code repo — issue-label rules to the public repo, PR-label rules to the private one. | conformance §7.5, layer 1 §07 | **Phase 5** + the **Phase 6 prerequisites** table |
| 6 | **`ops-integrate`'s outcome vocabulary is a convention, not a contract.** §6.9 specified `merged \| skipped:release-base \| blocked:ci \| …` as though it were enforced; the spec says there is *no* required error vocabulary and the result shape is a SHOULD verified by evals. Promotable to a MUST only if a non-model consumer parses it. | conformance §4.2, §4.5 | **§6.9** — recorded as a fixed set the evals assert on; `ops-merge-loop` is a model, so §4.5 does not apply and nothing is promoted |
| 7 | **The invocation contract is more specific than the plan's `(action, context-json)`.** Two positional arguments, `context` MUST be a single JSON object as a string, absent context MUST be treated as `{}`, and an unknown action MUST be rejected rather than guessed. | conformance §3.1–3.4 | **§2b**, written out once as a table rather than restated per phase |

### 9b. Deliberate — amend the spec, don't drift from it

| # | Divergence | Standing |
|---|---|---|
| 1 | **`learnings` is not a capability here.** Both design docs list `ops-learnings` with `route` / `file` actions; this plan demotes capture to framework mechanics + `ops-triage-loop`, with destinations as data. Reviewed and agreed on PR #4 (§6.2), and the schema evidence supports it. | agreed — needs writing back into the spec |
| 2 | **`ops-integrate` does not exist in either design doc.** It comes out of §6.8, and adds a capability the catalog must declare (conformance §2.2 forbids a capability skill absent from the catalog, so the catalog is where it becomes legal). | agreed — §6.8 |
| 3 | **`ops-branching` is command-only.** Both docs expose `resolve-base` and `merge-strategy` as caller-visible actions; §0 and §6.9 make those values private. This is the single biggest departure from the design docs, and the one with the most evidence behind it (§7's four-way drift). | agreed — PR #4 |
| 4 | **Five extra catalog fields** (four when this row was written; `override_when` came later, with §10.44), none of which the spec requires or forbids: **`visibility`** (§3.1); **`kind`** (`behavioral` / `data`, which is what selects whether conformance §4.4's data carve-out applies to a capability); **`framework_default`** (so the installer can report `inherited` rather than `missing` — without it, coverage cannot distinguish the two); and top-level **`reserved_skill_names`** (conformance §2.3's prose list, made machine-readable so the router and the installer validate against one source instead of two restatements); and **`override_when`** (the trigger that tells a repo an inherited default probably does not fit it, which is what turns a coverage row from a claim into a question). `catalog.schema.json` is therefore a deliberate **superset** of conformance §5.2–5.3, and none of the five may be presented as a spec requirement. | additive, low risk |
| 5 | **`ops-ci` has a `log` action**; both docs list `status` only. | additive, agreed on PR #4 |
| 6 | **The spec relies on same-name shadowing; this repo found it doesn't work.** Conformance §2.3 permits a repo to take a reserved name "if it intends to *shadow*", §6.6 states a same-named repo loop "**shadows**" a core loop, and layer 1 §06 offers shadowing as a customisation route. `CLAUDE.md:18` records the opposite from experience: plugin skills are namespaced, project skills are not, cloud delivers both flat into overlapping locations with undocumented precedence — which is *why* this engine binds by config pointer today and why §1's whole model is convention-by-name. **The spec's customisation story is unsound on this point**; overlay-plus-a-differently-named-loop is the mechanism that actually works. Needs correcting in the spec, not worked around here. | **conflict — spec is wrong** |
| 7 | **Framework loops are renamed to `ops-<noun>-loop`** (§2). Conformance §2.3 fixes the reserved list as `ops-merge-flow` / `ops-ops/auto-release` / `ops-rework` / `ops-triage`; we use `ops-merge-loop` / `ops-release-loop` / `ops-rework-loop` / `ops-triage-loop`. One consistent shape, and the suffix keeps loops out of the `ops-<capability>` namespace, so a loop can never collide with the capability of the same name. `loop-dispatch` and `ops-install` stay as they are, being a router and an installer rather than loops. | agreed — raised in review on PR #4 |
| 9 | **Capability skills MUST NOT set `disable-model-invocation`** — the reverse of conformance §2.4, which makes it a SHOULD. Not a preference: the flag **blocks the Skill tool outright**, for the model and for subagents, so a loop cannot invoke a capability either. Proven in a live routine on Umbraco.Automate (29-07-2026): `Skill ops-change cannot be used with Skill tool due to disable-model-invocation`. The loop then read the SKILL.md off disk and followed it as prose — which produced a good PR and looked like success, while being **not invocation at all**: no arguments passed, no result returned, no unknown-action rejection, because none of §2b's MUSTs exist without a call boundary. The spec's own §3.1–3.4 invocation contract is therefore unimplementable while §2.4 is followed; the two clauses contradict each other and §2.4 must give way. What §2.4 was protecting — a capability auto-firing on a `description` match — is now a required sentence in every capability description (*"NOT for direct use — never select it from a description match."*), enforced by `scripts/validate-capability-skills.sh`. Weaker, and the only option that leaves a capability callable. **Corrected 29-07-2026: nothing keeps the flag, loops included.** This row said "loops and `ops-install` keep the flag: a human invokes those deliberately", and no skill in the repo ever set it, so the rule described nothing. It is also wrong on the merits: the main runtime fires a loop with a *prompt*, and a model selecting the loop by description is precisely what the flag blocks, so a flagged loop would fail in cloud the way a flagged capability failed in a routine. `CLAUDE.md` now says so. | **conflict — spec is unimplementable as written** |
| 8 | **`learnings` is a fourth canonical topology role.** Conformance §7.2 fixes the roles at `code` / `issues` / `releases`; we add **`learnings`** — the repo proto-learning issues are filed on — carrying the same "an unspecified role resolves to `code`" rule and needing one new §7.3 row (file / label / close proto-learnings → `learnings`). It is a role in substance: it answers "what is this repo *to* a loop". It **cannot** collapse into `issues`, because Forms' issues repo is public while a proto-learning is an internal note about how a build went (§1a) — and it cannot be a fixed engine fact either, because the prototype filed into its *own* ops repo and neither consumer would want that. Rides along with the §9b.1 amendment the spec already owes. | agreed — closes §9a.1 |

### 9c. Worth mining, not yet decided

Two superseded design artifacts name things this plan lacks. They predate the privacy ruling — their
`branching` exposes `resolve-base`/`merge-strategy` — so they are not authoritative, but they were
written by people thinking about the same problem:

- **Ops Capability Interfaces** (`5aed3369`) lists `repo-meta · feeds` and
  `repo-meta · protected-branches`, neither of which the catalog has. **Both deliberately deferred in
  Phase 1**, for the same reason: no consumer. `ops-integrate` re-checks CI *whether or not* a branch
  is protected (§6.9), so knowing protection status changes no behaviour; feed setup is internal to a
  repo's own `ops-workspace · prepare`, so it needs no cross-capability read. Revisit if a caller
  ever appears — an action with no caller is a guess about the future, and the catalog's action names
  are the one part of it that is normative.
- ~~It also has `branching · resolve-line`.~~ **Settled in Phase 1: line resolution is data, not
  branching behaviour.** The artifact treated it as `branching`; §8 makes live-lines/primary-line
  facts a repo declares. The catalog follows §8 with **`ops-repo-meta · lines`**, and `ops-branching`
  reads it. That also keeps `ops-branching` command-only (§9b.3) — a `resolve-line` on it would have
  been the read that ruling forbids.
- **Release Provider Contract** (`8983efd4`) is an earlier release-only design (fixed lifecycle
  `plan → cut → CI gate → review gate → publish → sync`, verbs discovered as files under
  `.release-flow/`). Its lifecycle ordering and its idempotency requirement are worth reusing when
  `ops-release` is written; its file-discovery mechanism is superseded by the naming convention.

Neither is committed to `docs/` — they are superseded, and committing them as "the spec" would
create exactly the second source of truth this migration exists to kill.

---

## 10. Deviations log — what execution changed about this plan

**Every phase appends to this table before it is called done.** A phase that changes nothing
adds a row saying so.

The plan is written before the work; the work always knows more. Two failure modes this table
exists to prevent: silently doing something other than what was agreed, and re-arguing a
question that was already settled with evidence nobody wrote down. §6 is the *decision* log
(what we chose, and why, before building). §9b records where we knowingly diverge from the
**spec**. This is the third thing: where we diverged from **this plan**, while carrying it out.

Kind: **added** = did more than the plan asked · **changed** = did it differently ·
**dropped** = did less, on purpose · **corrected** = the plan was factually wrong.

| # | Phase | Kind | The plan said | What we did, and why |
|---|---|---|---|---|
| 1 | 0 | **changed** | §9a listed seven "accidental" gaps to fix *in the plan*. | Six were slips and were fixed. The seventh (§9a.1, the `learnings` role) was not a slip but an unmade decision, so it was **promoted to §9b.8** as a deliberate spec divergence rather than papered over. A gap list that can only ever be "fixed" hides decisions inside corrections. |
| 2 | 0 | **corrected** | §2a: the learnings threshold, dedupe key and trigger were "genuinely open, not recoverable from history". | All three are fully specified in the `umbraco-mcp-ops` prototype, which the audit never read. §2a is rewritten from it. The plan had searched one repo and concluded the design didn't exist. |
| 3 | 0 | **corrected** | §2a: triage's output is "a PR, not a comment". | True of exactly one destination in four. The owning-repo and loop-self destinations file **issues** — the prototype is explicit that triage never hand-edits a product repo. |
| 4 | 2 | **dropped** | Phase 2: "Add the fifth base route row for `ops-triage-loop`." | **No fifth row.** Triage is a weekly *scheduled* sweep and `ops/triaged` is an output marker, not a trigger label. The instruction rested on an assumption the prototype disproves, so the base table stays at four rows and a test asserts the count. *(Five rows now — the port loop added one, and the test asserts five. There is still no triage row.)* |
| 5 | 1 | **added** | The §1 inventory had no line-resolution action; §9c left `resolve-line` open. | Added **`ops-repo-meta · lines`** (live lines, primary line, port order). Settles §9c *as data*, which §8 already implied, and avoids putting a read on `ops-branching` after §9b.3 made it command-only. |
| 6 | 1 | **added** | §3.1 named one extra catalog field, `visibility`. | **Four**: `visibility`, `kind`, `framework_default`, `reserved_skill_names`. Each earns its place — `kind` selects the §4.4 data carve-out, `framework_default` is the only way coverage can say `inherited` rather than `missing`, and `reserved_skill_names` turns conformance §2.3's prose list into something the router and installer can both check. Recorded in §9b.4. |
| 7 | 1 | **added** | Phase 1 asked for the catalog, the loop-name reservation and a generated README section. | Also built **`validate-catalog.sh`** (the schema's rules in jq, because hermetic CI has no JSON-Schema validator) and **`catalog-to-readme.sh`** with a `--check` mode, and widened `tests.yml` to find `*.test.sh` anywhere. Without the last one neither new test would have run in CI. |
| 8 | 1 | **dropped** | §4 offered a mitigation: "write one reference `ops-repo-meta` alongside the catalog" so something exercises the interface before Phase 3. | **Not taken.** The catalog is unexercised until Phase 3, exactly the risk §4 named. Recorded rather than quietly skipped; the cost is that an interface mistake surfaces two phases late. |
| 9 | 1 | **dropped** | §9c: `repo-meta · feeds` and `repo-meta · protected-branches` were "worth mining". | Both **deliberately deferred**: neither has a caller. `ops-integrate` re-checks CI whether or not a branch is protected, and feed setup is internal to a repo's own `ops-workspace · prepare`. An action with no caller is a guess about the future, and action names are the normative part of the catalog. |
| 10 | 2 | **changed** | §6.4: the overlay is a committed `.github/ops-routing.yml`. | **`.json`.** `route-event.sh` runs at the CI edge with bash and jq only; jq cannot read YAML, and requiring `yq` would either break the hermetic-test rule or make routing depend on what a runner happens to have installed. §6.6 chose JSON over the spec's YAML for the catalog on the same grounds. §6.4 is amended in place with this reasoning. |
| 11 | 2 | **changed** | Phase 2: "remove the duplicated `case` fallback." | Removed, and its *behaviour inverted*. A missing table, absent jq, or a rule with an invented event now **exits 2** instead of resolving to `loop=none`. The plan said what to delete but not what should happen instead; a silent `none` means loops stop firing and nobody notices. |
| 12 | 2 | **added** | Phase 2 listed the table shape, the merge, the renames and the tests. | Also **deleted the `state` field** from the rule shape (no rule used it, and review events aren't in the vocabulary, so it implied a matching mode the spec doesn't have), renamed the *output* key `route=` → `loop=` for one vocabulary, added a **caller-repo checkout** to `loop-dispatch.yml` (without it the overlay isn't on disk at the edge), and shipped `ops-routing.schema.json` + an example. |
| 13 | 2 | **added** | Nothing in the plan says anything about label naming. | **Every engine-owned label is namespaced `ops/`** — `ops/ready-for-ai`, `ops/auto-merge`, `ops/auto-rework`, `ops/auto-release`, `ops/generated-by-ai`, `ops/ai-blocked`, `ops/proto-learning`, `ops/triaged`, `ops/loop-improvement`, `ops/release-blocked`. Requested in review (28-07-2026). The prefix says at a glance that a label drives automation and keeps engine labels out of a repo's existing triage vocabulary. Enforced by pattern in `route-map.schema.json` (engine-owned) and a test; a **SHOULD** only in `ops-routing.schema.json`, because an overlay legitimately routes on labels a repo had before the engine arrived. Every §8/Phase 6 prerequisite about creating labels now means the prefixed names. Shortening `ops/auto-merge` → `ops/merge` and friends was raised in the same review and **declined** — the `auto-` is redundant under the prefix, but the churn buys nothing. |
| 14 | 3 | **added** | Phase 3 named `ops-integrate`, `ops-ci` and `ops-branching`. | Also built **`ops-repo-meta`** and **`ops-notify`**, because Phase 3's own work needs them: `ops-branching` reads `lines` from repo-meta, `ops-merge-loop` reads `topology` and the landing label, and the release loop pushed notifications inline in four places. Building the loops without them would have meant hard-coding the very facts this phase exists to centralise. `ops-workspace` is still deferred — nothing in Phase 3 calls it. |
| 15 | 3 | **added** | The §1 roster gives `ops-release-loop` these callees: `ops-release` and `ops-ci`. | It also commands **`ops-change · implement` / `verify`**, to fix a red release branch — behaviour `auto-release-loop` already had ("fix failures on the release branch, the 8-attempt cap applies"). Dropping it would have quietly removed a working capability. Legal under the visibility rules: `ops-change` is a service, and a loop may command a service. |
| 16 | 3 | **added** | §6.9 fixed the outcome vocabulary at five values. | **Seven.** Writing the gates surfaced two states the five could not express: `blocked:wrong-base` (a base that is neither an integration branch nor a release base — §7 says this *will* happen on a multi-line repo) and `blocked:no-label` (the label was pulled between the loop's sweep and the service's gate). Folding either into an existing value would have made the loop comment the wrong blocker. Still a convention, not a contract (§9a.6). |
| 17 | 3 | **added** | `ai-ops.yml` is read by every loop until Phase 8 deletes it. | **Exactly one skill reads it now** — `ops-repo-meta`, as an explicitly transitional step. The loops already speak only the capability interface, so Phase 8 becomes a deletion inside one skill instead of a rewrite of all of them. Recorded in that skill as transitional, with "do not add a key" attached. |
| 18 | 3 | **changed** | Nothing in the plan says where framework-default capability skills live. | One new plugin, **`ops-capabilities`**, holding all five. The README already groups them as "you inherit these", so one install gets a consumer the whole inherited set; scattering them across the loop plugins would have made "what do I inherit?" unanswerable. |
| 19 | 3 | **added** | The hazard register only said the two phantom marketplace entries should be "scaffolded or marked unreleased". | **Removed them**, and added **`scripts/validate-manifests.sh`** + 12 tests. An entry whose `source` resolves to nothing makes `/plugin marketplace add` fail for the *whole* marketplace, so this was live breakage, not untidiness. The validator also catches an undeclared plugin and any name/version/description drift between the two manifests — drift that already existed on `ops-setup`. |
| 20 | 3 | **added** | Not mentioned: `operation-catalog.json`'s `detect-base-branch`. | **Deleted.** §7 named it as the fourth place base-branch knowledge lived, and its own title said "defer to release-and-branching" — a forge operation that existed only to point at a skill that no longer exists. Leaving it would have left the fourth leak open while claiming §7 was closed. |
| 21 | 4 | **added** | Phase 4 named `ops-issue-loop`, `ops-rework-loop` and the learnings mechanism. | Also built **`ops-workspace`**, the last framework default. `ops-change` wraps it and `ops-change` is repo-provided, so without a default every consumer would have had to write worktree handling before its first build. |
| 22 | 4 | **changed** | Nothing said who fires `ops-change · close-issue`. §6.8a only established that `ops-change` *ends* there. | **`ops-merge-loop` fires it, after a `merged` outcome**, and it passes the **landed PR, not an issue**. That is the only moment a landing becomes known, and nothing else was watching for it. Passing the PR keeps two repo facts inside the repo's own capability: how a PR references its issue, and which lines are targets. The catalog's `close-issue` input and example changed to match, and it now returns `waiting_on` so a partially-landed change reads as normal rather than as a failure. |
| 23 | 4 | **dropped** | `issue-loop-core` had a long-lived **review phase**: it watched each PR, dispatched response subagents, and **merged on approval**. | **Gone.** `ops-issue-loop` stops at a green PR. The review phase existed only to serve its own merge, and that merge was a second merge path behind a second gate — exactly what §6.8/§6.9 collapsed. Review feedback is `ops-rework-loop` (event-driven), landing is `ops-merge-loop`. The loop got materially simpler as a result: no long waits, no wake-up re-arming, no `ScheduleWakeup`. |
| 24 | 4 | **corrected** | §2a said the three residual Phase 4 questions were the threshold numbers, dedupe-as-eval-target, and whether `shared-skills` is reachable. | All three are recorded in `ops-triage-loop` itself rather than left in the plan: the numbers are marked **inherited defaults, not measurements**, dedupe is called out as the one judgement step, and the skill says plainly that **where `shared-skills` is unreachable the threshold gates nothing** — and to say so in the run summary rather than pretending to apply it. |
| 25 | 4 | **added** | The plan does not say how the capture hook — bash, no session — resolves the `learnings` repo. | It **cannot invoke a skill**, so it resolves `$OPS_LEARNINGS_REPO`, else the current git remote. Unset therefore lands on the current repo, which is exactly what the framework default for the `learnings` role resolves to, so the two agree without the hook knowing about roles. The label, the loop signature and the log/state paths are env-overridable for the same reason. |
| 26 | 4 | **added** | Nothing asked for tests on the capture hook. | **28 cases**, hermetic — the analyzer is injected and filing is forced to dry-run, so nothing reaches GitHub. The property under test is that capture **never fails the session**: every case asserts exit 0, including the broken ones. Capture runs off the critical path, so a bug there must cost a log line, never a build. |
| 27 | 4 | **changed** | Phase 8 removes the README's config-contract section. | The README's **opening** was left describing the retired model as current — "each consumer supplies a build skill and a config block, found via the `playbook` key" — which stopped being true the moment the loops started commanding capabilities. Corrected now; the config-contract *section* still stands, but marked as read by exactly one skill and deleted in Phase 8. Leaving a factually wrong first paragraph for four more phases was not worth the tidiness of a clean phase boundary. |
| 28 | 5 | **changed** | Phase 5 describes the installer as a skill that reports coverage, scaffolds and validates. | **Four of its six steps are scripts** — `coverage.sh`, `scaffold-capability.sh`, `validate-overlay.sh` and the kept `detect.sh` — with 92 tests between them. *(It has since grown to seven scripts across ten steps, adding `check-installed-versions.sh`, `plan-labels.sh` and `validate-repo-meta.sh`; the skill and the README carry the current count, not this row.)* Conformance §8's three clauses are the three claims nobody re-checks; a model reading directories to produce "you are covered" can be quietly wrong, and the skill's job is to *show the output*, not to be trusted. |
| 29 | 5 | **added** | Nothing asked for a manifest check. | `scripts/validate-manifests.sh` came out of Phase 3 and is listed there (§10.19); Phase 5 is where it earned its keep, catching the `ops-setup` → `ops-install` rename in both manifests and the marketplace at once. |
| 30 | 5 | **corrected** | `coverage.sh` could have read the catalog's `framework_default` flag to decide `inherited`. | It reads the **defaults off disk** instead. The flag is a claim about what exists; a coverage report exists to check claims, and one that trusts its own catalog would report `inherited` for a default someone deleted. |
| 31 | 7 | **added** | Phase 7: "per-capability suites seeded from the catalog examples; opt-in." | Suites are **generated with a `--check` gate**, not seeded once. Seeding is a one-time act and drifts immediately; the README table taught that lesson in Phase 1. Also fixed the case set: rather than one case per example, each action gets **four** — example, empty-context, unknown-action, idempotency — because those are the four MUSTs of §2b that a capability can satisfy on paper and violate in practice. |
| 32 | 7 | **changed** | Not stated: what the eval runner is called. | `scripts/run-evals.sh`, deliberately **not** `*.test.sh`. CI now finds every `*.test.sh` in the repo (§10.7), so a runner named that way would join the hermetic gate and fail on every machine without `claude`. Its hermetic paths (`--list`, `--plan`) have their own tests. |
| 33 | 8 | **added** | Phase 8 lists the config files to delete. | Also deleted the **transitional read** inside `ops-repo-meta` that Phase 3 added (§10.17), which is the thing that would otherwise have kept the file alive in spirit. Safe now only because no consumer is onboarded — §8 records that neither repo has a trigger label yet. |
| 34 | 5 | **added** | The hazard register called `scripts/cloud-skill-sync.sh` a Phase 6 blocker. | **Ported and fixed.** Both `README.md` and `CLAUDE.md` named it as the mechanism that delivers the engine to a cloud routine — the main runtime — and the file did not exist. It now delivers **every** skill and agent rather than a hand-maintained list (one less thing to forget), and it **wires the capture hooks into `settings.json`**, without which proto-learning capture works locally and silently does nothing in cloud. 29 tests, hermetic via `$OPS_SRC` and `$OPS_HOME`. |
| 35 | — | **corrected** | *(process, not plan)* | Two of my own bugs, worth recording because both were silent: jq's `index` with an **array** argument searches for a subsequence, not an element, so the overlay validator's disable-check never matched; and under `set -o pipefail`, `cmd \| grep -q` reports the *writer's* status because `grep -q` closes the pipe early, so a passing assertion read as a failure. Both are commented at the site. |
| 36 | 8b | **added** | §6.7 decided to remove `ai-ops.yml` with **no thin remnant**, on the grounds that a second source of the same facts is the drift this migration exists to kill. | **A narrow file comes back, and the decision is narrowed with it.** §6.7's reasoning is right for every fact that had another owner — the skill pointers, `ci.provider`, `branching.*` — and each of those is still dead. It does **not** hold for facts with no other owner: there is no second source for "v17 is the primary line", and after Phase 8 there was no *first* source either, only prose inside a repo-authored skill. `CLAUDE.md`'s own rule settles it: what a consumer *implements* is a capability, what it *declares* is a data seam. Topology and lines are declared. Raised in review 28-07-2026. |
| 37 | 8b | **corrected** | My own schema forbade `topology.code`, on the grounds that detection reads it from the git remote. | **Wrong, and implementation caught it.** In a split topology the file on the **issues** repo is the only place the code repo can be named — detection there reads the issues repo's own remote. Without it the edge router cannot resolve a target at all, which is the main thing this file exists for. The rule is now "declare the roles that are **not** the repo this file is in", which is symmetric and needs no special case. |
| 38 | 8b | **added** | Nothing said the router should read declared facts. | `route-event.sh` gained `--repo-meta` / `$REPO_META` and derives the cross-repo target from `topology.code`. **`with.target_repo` is deprecated** — it was a second hand-written copy of one fact, in a different file in a different repo. A missing or unreadable file must never break routing, so both cases fall through to no target; tested. |
| 39 | 5 | **added** | `ops-install` listed "create the labels" as a **manual** step for a human. | **The installer creates them.** `plan-labels.sh` (32 tests) resolves every label's name, colour and **target repo** — issue labels to `issues`, PR labels to `code`, learnings labels to `learnings`, per conformance §7.3 — with the repo's overrides applied, and `github-ops` → **`create-label`** does the writes. That operation did not exist and is added to the catalog and both provider references, with `gh label create --force` for idempotency and a read-then-skip on the MCP path, which has no upsert. Manual was the right call when label names were prose in twenty files; once names, overrides and target repos are all readable, making a person copy them out of a document is just work we had not done. Asked for in review 28-07-2026. |
| 40 | — | **corrected** | *(the plan describing itself)* | **§7's hazard register was six rows out of date**, still written in the present tense about hazards execution had closed — the placeholder central loop, the four-way base-branch drift, the `ci.provider` spelling split, the duplicated route map, label names as prose, and a missing `cloud-skill-sync.sh`. A register that reads as open when it is closed is worse than no register: the next reader re-opens settled questions and stops trusting the rows that *are* live. Swept, each closure pointing at the §10 row or phase that did it, and the **one genuinely open item flagged `⚠ OPEN`** — the repo-family consumer shape, which needs a ruling, not more building. `README.md` was stale in the same direction: it still called evals outstanding, still said `cloud-skill-sync.sh` was "not here yet", and its Status section still read "work in progress". `CLAUDE.md` had one structural bug — the "grep for product-specifics" rule and the CI paragraph had drifted out of **Before you commit** into the middle of the evals section, so "the first two are enforced in CI" pointed at nothing. |
| 41 | — | **corrected** | *(§6.10, one commit after writing it)* | **A code review caught four overclaims in the deferral ruling, and re-reading the prototype corrected a fifth.** (a) Both docs claimed triage's `shared-skills` destination "degrades" to a safe landing spot — the README said a plain issue, the plan said `loop-self`, and the skill says **neither**: it names two live destinations on a single repo and tells the triager to *hold* rather than mis-file. Nothing is lost, but there is no designed fallback, and saying there was is exactly the kind of claim §7 exists to stop. (b) The §7 row still opened `⚠ OPEN` while its own tail, the section intro and the summary all said "deferred by ruling" — the failure row 40 had just been written to prevent. (c) The README said "both single-repo consumers use it"; neither has written its two skills. (d) `marketplace.json` still described consumers as supplying "a build playbook + a config block", a model deleted in Phase 8. (e) Worst of the five: §6.10 called the family shape "not designed and not tested". **Checking `hifi-phil/umbraco-mcp-ops` disproved it** — `mcp-issue-loop` serves the whole family today and `cloud-skill-sync/` delivers it, so *delivery is solved* and the open part is much narrower (name collision, and `topology` when `code` varies per run). That is §10.2 and §10.3 for the third time: **this repo keeps declaring prototype-solved problems unsolved.** The rule is now written into the ruling itself — check the prototype before calling anything undesigned. |
| 42 | 5 | **corrected** | *(the first real install, reported by the operator)* | **Running `ops-install` against a real repo for the first time found five faults no test could have caught, because every test supplied by hand what a real run has to discover.** (a) `coverage.sh`, `scaffold-capability.sh` and `validate-overlay.sh` resolved the engine by a **fixed depth** (`../../../../..`), which is right for a git checkout and off by one for an installed plugin — the operator had to set `ENGINE_ROOT` and `CATALOG_FILE` by hand. Now a shared `engine-root.sh` **walks up for `catalog.json`**, which is layout-independent; 9 tests assert both layouts, including that the two really do differ in depth. (b) `scaffold-capability.sh` rejected `ops-change`, the name the coverage report had just printed, because the catalog keys capabilities bare; it now strips the prefix. (c) Detection reported `nbgv: false` for a repo that plainly uses Nerdbank.GitVersioning — the pathspec `version.json` matches the **root only**, and a multi-product repo versions each product in its own folder. (d) It reported `has_release_tags: false` for a repo with 28 tags, because the pattern `release-*` was a naming guess matching neither `2026.07.1` nor `Product@1.2.3`; any tag now answers the question honestly. (e) **Step 8 listed the two routine secrets first and "stand up the routine" last** — an order that cannot be followed, since the routine is what mints the Fire URL and token. Re-ordered causally, with the reason stated so it does not drift back. Also added: `AskUserQuestion` is now **required** for the declared-facts interview and every question is **seeded from detection** (`lines_seen` is emitted for exactly this), and a **wrong-base smoke test** is the last step — a throwaway PR based off a non-live branch, where `blocked:wrong-base` *is* the pass, so the whole chain is proved before anything can merge. |
| 43 | — | **added** | Nothing in the plan opens a port. §8.1 settled that *landing* is per-PR and §8.2 that the port *direction* is the repo's business, and then nothing was left holding "and who cuts the N PRs?". `close-issue` waited on lines that nobody was creating. | **`ops-port-loop`, a sixth framework loop**, plus a fifth base route row on `ops/port` and the `port` label. It reads the direction off `ops-repo-meta · lines`, drives each target through the repo's own `ops-change` as a real change (§7: a port is not a cherry-pick), and lands none of them. The `-loop` suffix keeps it out of the capability namespace exactly as §2 intended, so it cost no rule change — only this row, which is why the plan's "the five" went stale unnoticed until a review swept it. |
| 44 | — | **added** | Coverage reports `inherited` for every framework default, and §7 already flagged that "coverage ≠ correctness". The plan left it there. | **`override_when` per capability in the catalog** — a fifth extra field (§9b.4) — carried into the coverage report, so an `inherited` row arrives with the reason a repo might *not* want the default. `ops-install` turns those into one batched question seeded from `detect.sh`'s `override_signals`. Without it, the honest answer "this is a name match, not a fitness check" had no way to become an action. |
| 45 | — | **added** | The plan treats `verify` as pass/fail and `prepare` as done/not-done. | **`workspace · prepare` returns `fidelity`** (`ci-parity` or `reduced`) and **`change · verify` returns `authoritative`**. A repo whose fast local target is not what CI runs produces false passes as well as false failures, and a loop that cannot tell the two apart reports "verified" for something CI will reject. Cheap to carry, and it makes the weaker check say so instead of borrowing the stronger one's words. |
| 46 | — | **added** | The plan has one finished-state label. | **`ops/in-progress` is a separate label from `ops/generated-by-ai`**: state versus provenance. They were one slot until a live routine read the slot name `labels.in_progress`, found it pointed at the *finished* label, and invented `ops/in-progress` for itself (29-07-2026). Without a state label an interrupted run leaves an issue that looks untouched and cannot be found. Recorded in `CLAUDE.md` at the time; this row is the plan catching up. |
| 47 | — | **corrected** | *(a full review against `CLAUDE.md`, the README and this plan, 29-07-2026)* | **Four silent faults, each of the shape this repo keeps hitting: documented, tested, and not doing the thing.** (a) `route-event.sh` would only derive a cross-repo `target` when the declared facts named `topology.issues` *and* it matched the event repo — but the schema, the installer and the caller workflow all tell the issues repo to declare `code` and nothing else, so the conformant file produced **no target** and the routine ran in the issues repo. Nothing failed; the test fixture happened to declare both keys. Now it reads `code` alone, with the conformant shape as its own case. (b) `check-installed-versions.sh` treated *not installed* as *out of date* and exited 1, while Step 0's instruction is "stop if you are behind" and the README's install step fetches three of eight plugins — so the documented onboarding path could not clear its own first check. Behind and missing are now different answers. (c) The capture hook's loop signature listed three loops out of six, so port-loop and merge-loop runs captured nothing, and the log line read like an ordinary non-loop session. (d) `labels.port` existed in the planner and the schema but not in `ops-repo-meta · identity`, the table every loop looks up — two loops resolved a purpose off a list that did not have it. A test now asserts the three copies of the purpose list agree, because that drift is invisible from any one of them. |
| 48 | — | **corrected** | *(same review)* | **Three places where the design was stated but not reachable.** (a) `ops-integrate` listed "the base is a live integration branch" as a gate to check *before* merging, and the only way to ask is to tell `ops-branching · merge` to merge — it is command-only by §9b.3. So the skill described a fourth gate that was really the merge, then listed the merge again as the next step; idempotency hid it. The base check is now explicitly the merge attempt, called **once**, last. (b) Telling `skipped:release-base` from `blocked:wrong-base` meant string-matching a prose `detail`. `merge` now returns a classified **`refused`** (`release-base` / `not-a-merge-target`); a classification is not a branch name, so the privacy rule holds. (c) Nothing could name the line a PR is on: the mapping is `ops-branching`'s private business, yet `close-issue` and the port loop both need it. `merge` now returns **`line`** and `land` passes it through — a *line* is declared public data even though its branch is not, and this is the only place the mapping exists. Also: **`live` is now ordered oldest-first** and documented as load-bearing, so the port loop takes direction from position instead of comparing the numbers in `v17` and `v18`, and `verify`'s catalog entry now carries the code and security review the issue loop has always required of it — a requirement stated only in the loop is one the first scaffolded `ops-change` drops. |
| 49 | 5 | **corrected** | Row 48 made **`live` ordered oldest-first** and load-bearing, and left detection alone. | **`detect.sh` had been emitting `lines_seen` newest-first all along, and Step 2 seeds `lines.live` straight from it with every option pre-selected** — so a human clicking through onboarding wrote a backwards array. `ops-port-loop` then computed **zero** targets for every change on the primary line, and zero targets is a legitimate outcome it comments and stops on, so nothing failed: the first symptom was two version lines quietly drifting apart. Found on the second real install (`umbraco/Umbraco.Automate`, 29-07-2026) and fixed downstream in its PRs #194/#195. The `-r` is gone from the sort, `detect.test.sh` asserted the **wrong** order as correct so the contradiction was locked in by a passing test and is now flipped with the reason written next to it, and `validate-repo-meta.sh` **warns** when an all-`vN` `live` is descending — a warning and not an error, because a line name is an arbitrary string (`default` is documented) with no general notion of older. The port loop's no-targets comment now also distinguishes "one live line" from "the source is at the end of the direction", so the case a wrong order lands in says which line it read and in what order. Same shape as rows 42 and 47: the design was written down correctly and the code did the opposite, silently, past a green test suite. |
