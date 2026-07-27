# Capabilities-model migration plan

Status: **Reviewed — §6 settled** (PR #4, 27-07-2026) · Author: audit of `umbraco-ai-ops@main`
against the two design docs (Layer 1 — *Ops Capability Skills* explainer; Layer 2 — *Conformance
Specification*).

All nine §6 decisions are resolved, so **Phase 3 is unblocked**. One sub-question remains open
(§6.8a — whether `ops-change` keeps a delegating `land`); it changes one catalog row, not the
model.

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

### Action inventory — the draft catalog

> **Superseded by Phase 1.** This table is the *input* to the capability catalog (§3.1), not a
> second copy of it: author the catalog from these rows, then **delete this table**. Visibility and
> callers are deliberately absent — they live in the roster above, one fact in one place.
>
> **Status is load-bearing.** Most of these action names are proposals from the audit, not
> implemented behaviour — and the argument about them happens at **Phase 1**, against concrete
> catalog entries rather than against this draft table (agreed on PR #4). It stands as-is until
> then.

Status legend: **exists** = implemented today (source named) · **proposed** = invented by this
audit, nothing implements it · **open** = one unresolved sub-question (§6.8a) · **dropped** =
ruled out by a settled §6 decision.

| Capability | Action | Status | Notes / where the behaviour lives today |
|---|---|---|---|
| `ops-change` | `implement` | proposed | prose in the repo's `CLAUDE.md` + the `playbook` build skill; takes **port context** where a line-port is a real change (§8) |
| | `verify` | proposed | build/test/sanity pass, same source |
| | `close-issue` | proposed | forge op `close-issue` exists; cross-repo close MUST be explicit (spec §7.4); fires when **all** target lines have landed (§8) |
| | `land` | **open §6.8a** | a *delegating* tail calling `ops-integrate` — or no such action at all; see §6.8a |
| `ops-release` | `plan` | proposed | `release-reviewer` agent + `auto-release-loop` prose |
| | `cut` | proposed | version-file list + changelog bump (`auto-release-loop:51`) |
| | `publish` | proposed | `release-tag.yml`, version-source per stack |
| | `sync` | **exists** | the `sync-dev` skill, folded in per §2 |
| `ops-integrate` | `land` | proposed | thin service wrapping `ops-branching · merge`; owns the four gates + the release-base skip; returns a structured outcome (§6.8, §6.9) |
| `ops-branching` | `merge` | proposed | strategy chosen internally; replaces `merge_strategy` config + forge `merge-pr` |
| | `open-pr` | proposed | forge `create-pr` exists as an operation |
| | `start-branch` | proposed | forge `create-branch` exists as an operation |
| | ~~`classify-pr`~~ | **dropped** | §6.9 settled as (b) — the skip lives in `ops-integrate`, so the primitive stays command-only |
| | *(base / release-base / model)* | **not actions** | internal knowledge — private per §0. `base` is a **set** of live integration branches, not one branch (§7, §8) |
| `ops-workspace` | `prepare` | proposed | "repo's own `/cleanup`" (`gitflow.md:37`) |
| | `teardown` | proposed | worktree + DB teardown, same source |
| `ops-repo-meta` | `identity` | proposed | `detect.sh` can pre-fill; replaces `repos.source` |
| | `topology` | proposed | roles `code` / `issues` / `learnings`; also holds the **live lines** and which is **primary** — neither is derivable from version numbers (§8) |
| `ops-ci` | `status` | **exists** | operation `get-ci-status` |
| | `log` | **exists** | operation `read-failing-ci-log` |
| `ops-notify` | `send` | proposed | loops emit "Reworked PR #N…" inline today |
| ~~`ops-learnings`~~ | — | **not a capability** | framework capture hook + `ops-triage`; destinations are `ops-repo-meta` data (§6.2) |

Counts: **3 exist** (`ops-release · sync`, `ops-ci · status`, `ops-ci · log`), **15 proposed**,
**1 open** (`ops-change · land`, §6.8a), 1 dropped. If §6.8a resolves against the delegating tail,
the open row disappears and `land` exists only on `ops-integrate`.

### 1a. Config-pointer seams (`ai-ops.yml` / `ai-ops.schema.json`)

| Current key | Kind | Target capability · action | Migration note |
|---|---|---|---|
| `repos.source` | D | `ops-repo-meta` · `topology` (role `code`) + `identity` | source = the `code` role |
| `repos.inbox` | D | `ops-repo-meta` · `topology` (role `issues`) | issues = the `issues` role; single-repo collapses to `code` |
| `repos.issue_link` | — | *removed* → `ops-change` · `close-issue` | enum disappears; cross-repo close is behaviour (spec §7.4), not config |
| `ci.provider` | B | `ops-ci` (provider internal to the consumer's skill) | **kills the `ci.provider`/`ci_provider` split** |
| `ci.ado_org` / `ci.ado_project` / `ci.gh_repo` | B | internal to consumer `ops-ci` | out of central config |
| `branching.model` | B | `ops-branching` (internal knowledge / framework default) | model becomes skill logic, not an enum |
| `branching.base` | B | `ops-branching` — **private**; callers get outcomes, never the value | **single source of truth** (ends the four-way drift in §7). Internally a **set** of live integration branches (§8) |
| `branching.release_base` | B | `ops-branching` (private) — **never reaches a caller at all** | §6.9 = (b): `ops-integrate` asks and declines release-base PRs itself; no classification is exposed |
| `branching.merge_strategy` | B | `ops-branching` · `merge` picks it internally | **single source of truth**; no caller passes a strategy |
| `branching.branch_naming` | B | internal to `ops-branching` / `ops-change` | |
| `branching.release_skill` | B | `ops-release` (whole capability) | the *pointer* becomes the *convention* (`ops-release`) |
| `learning.inbox` | D | `ops-repo-meta` · `topology` (role `learnings`) | the destination is a *fact*, not behaviour |
| `learning.routing` | — | *removed* → framework capture + `ops-triage` | today a free-form prose string in the schema — never a machine-readable seam (§6.2) |
| `playbook` (build-skill pointer) | B | `ops-change` · `implement` / `verify` / `close-issue` | the central pointer becomes the convention (`ops-change`) |
| `version` (schema pin) | F | catalog/spec version | replaced by catalog + spec versioning |

Net: `ai-ops.yml`'s normative content is absorbed by `ops-repo-meta` (identity/topology) + the
per-capability skills. See §5 for what, if anything, remains.

### 1b. Behavioral / skill-reference seams (prose deferrals)

| Current deferral (where) | Target capability · action |
|---|---|
| build/test commands, sanity pass (repo `CLAUDE.md`; `playbook` skill) | `ops-change` · `implement` / `verify` (internal) |
| version-file list + changelog bump (repo `CLAUDE.md`; `auto-release-loop:51`) | `ops-release` · `cut` (internal) |
| worktree / DB cleanup ("repo's own `/cleanup`"; `gitflow.md:37`) | `ops-workspace` · `prepare` / `teardown` — wrapped by `ops-change`, not called by a loop |
| human push notifications (loops emit "Reworked PR #N…") | `ops-notify` · `send` |
| base-branch + merge-strategy detection via `release-and-branching` | `ops-branching` **internals** — not a caller-visible action (§6.9) |
| cross-repo issue close (can't use `Closes #N`) | `ops-change` · `close-issue` (spec §7.4 — MUST be explicit) |
| CI status reads (`github-ops` → `ci_provider`) | `ops-ci` · `status` |
| failing check / build log reads (`operation-catalog` → `read-failing-ci-log`) | `ops-ci` · `log` (the `ci` axis is **read-only** — both its operations are reads) |
| forge mechanism (gh CLI vs GitHub MCP), PR/label/merge by role | **F** — stays framework; target resolved by `ops-repo-meta` · `topology` role |
| release-tag automation version-source per stack (`release-tag.yml`) | `ops-release` · `cut` / `publish` (internal) |

### 1c. Routing seams (`route-map.json` / `route-event.sh`)

| Current | Target (spec §6) |
|---|---|
| Whole-file replacement (`$ROUTE_MAP` swaps the entire map) | **base ⊕ per-repo overlay** merged live at the edge; identity key `(event,label)`; overlay wins; `loop:null` disables |
| Rule shape `{event:"issues", action:"labeled", route}` | `{event:"issues.labeled", label, loop}` — collapse event+action into the event vocab (`issues.labeled`, `pull_request.labeled`, `issues.opened`, `pull_request.opened`), rename `route`→`loop` |
| Route targets `issue-loop-core` / `auto-release-loop` / `merge-flow` / `rework-loop` | reserved loop names `ops-issue-loop` / `ops-auto-release` / `ops-merge-flow` / `ops-rework`, **plus a fifth row for `ops-triage`** (§2a) |
| Built-in `case` fallback duplicating the 4 rules ("keep in sync") | base table is the single source; drop the dup (or generate the fallback from base) |
| Overlay = ad-hoc `$ROUTE_MAP` file | overlay in the caller workflow input block **or** a committed `.github/ops-routing.yml` |
| `new-loop-routine` scaffolds caller workflow | evolves into the loop-scaffolder that *writes overlay rows* (§6) |

`route-event.sh`'s cross-repo `--target`/`$TARGET_REPO` dispatch and `pull_request_target`
normalisation already match the spec — keep them.

### 1d. Installer seam (`ops-setup` / `umbraco-ops-setup`)

| Current | Target (`ops-install`, spec §8) |
|---|---|
| `detect.sh` pre-fills a config guess | keep — feeds the pre-fill + topology defaults |
| `AskUserQuestion` confirm/fill of config keys | shrinks to what `ops-repo-meta` can't auto-detect |
| Writes `ai-ops.yml` (schema-validated) | writes/updates `ops-repo-meta` facts + overlay; validates overlay per §6 |
| Scaffolds `<playbook>` build skill + release override | scaffolds a standard **capability-skill stub per catalog entry** for each MISSING capability |
| **No coverage check** (only schema-conformance) | **coverage report**: each catalogued capability `present / inherited / missing` by matching `ops-<capability>` skill names |

---

## 2. Framework-skill → framework-loop map

Reserved framework names (spec §2.3): `loop-dispatch`, `ops-install`, `ops-issue-loop`,
`ops-merge-flow`, `ops-auto-release`, `ops-rework`, `ops-triage`.

| Today | Becomes | Calls (by name) |
|---|---|---|
| `issue-loop-core` *(placeholder)* | `ops-issue-loop` | `ops-change` (implement/verify/close-issue) · `ops-ci`, `ops-repo-meta` (reads). **Not** `ops-workspace` — `ops-change` wraps it |
| `rework-loop` *(placeholder)* | `ops-rework` | `ops-change` · `ops-ci` (status/log), `ops-repo-meta` (reads). **Does not land its own fix** — hands the PR back to `ops-merge-flow` so there is one merge path behind one human gate (§8) |
| `merge-flow` | `ops-merge-flow` | `ops-integrate` · `land` (§6.8 = A) · `ops-ci` (status), `ops-repo-meta` (topology). **Never `ops-branching` directly** |
| `auto-release-loop` | `ops-auto-release` | `ops-release` (plan/cut/publish/sync) · `ops-ci`. Reaches `ops-branching` **only through `ops-release`** |
| `release-and-branching` | *demoted* → `ops-branching` (framework default) | — (becomes a capability, repo may override) |
| `sync-dev` | folded into `ops-release` · `sync` | — |
| `github-ops` | split: `ops-ci` (capability) + forge mechanics stay **F** | forge target resolved via `ops-repo-meta` topology |
| `loop-dispatch` | `loop-dispatch` (unchanged name) | gains base⊕overlay merge + event vocab |
| `new-loop-routine` | loop-scaffolder (writes overlay rows) | — |
| `ops-setup` / `umbraco-ops-setup` | `ops-install` | reads catalog; coverage + scaffold + overlay-validate |
| `learning` *(placeholder)* | framework capture hook + `ops-triage` (loop); destinations are `ops-repo-meta` data | uniform across repos so lessons compound (§6.2, detailed in §2a) |
| `release-reviewer` (agent) | stays (orchestration internal to `ops-auto-release`) | non-normative |

### 2a. `ops-triage` — what it inherits

`ops-triage` is a reserved framework loop name (§2) that nothing in this repo implements:
`plugins/learning/` does not exist on disk, despite `marketplace.json` declaring it (§7). But it is
**not undefined** — the `triage-learnings` design it renames is stated across four files, all from
`633a2a7` ("scaffold engine foundation and generic plugins"). Recording it here so Phase 4 builds
what was designed rather than reinventing it.

**Canonical statement** — the `learning` plugin's description, `.claude-plugin/marketplace.json:96`:

> read-only capture hooks (SubagentStop/SessionEnd) that file proto-learning issues off the critical
> path, the proto-learning schema, and **triage-learnings (dedupe + threshold + route to owning repo
> / shared-skills PR / loop-improvement issue)**.

**The contract, as the shipped skills already describe it:**

| | | Source |
|---|---|---|
| **Input** | `proto-learning` issues in the inbox repo, filed by read-only `SubagentStop` / `SessionEnd` hooks that analyse transcripts **off the critical path**. No loop and no subagent ever files one by hand. | `issue-loop-core/SKILL.md:269-277`, `rework-loop/SKILL.md:104-106` |
| **Operations** | **dedupe** → **threshold** → **route**. Threshold implies a lesson must recur before it is acted on; dedupe implies a stable identity for "the same lesson". | `marketplace.json:96` |
| **Output** | a **PR**, not a comment — "a separate triage routine later turns those into PRs" | `issue-loop-core/SKILL.md:274` |
| **Cadence** | "later" / "separate" — batch, not per-event. See the trigger gap below. | `issue-loop-core/SKILL.md:274` |

**The three destinations**, named twice under different labels and reconciling cleanly:

| `marketplace.json:96` | `ai-ops.schema.json:58` | Means | Post-migration home |
|---|---|---|---|
| owning repo | `product-repo` | PR against the product repo's own skills / `CLAUDE.md` | `ops-repo-meta` role `code` |
| shared-skills PR | `shared-skills` | PR against the shared **consumer** repo of a repo family | `ops-repo-meta` — **no role exists for this yet** (§7) |
| loop-improvement issue | `loop-self` | issue against the engine itself | a fixed engine fact, not repo data |

This is consistent with §6.2 rather than in tension with it: `learning.routing` dies because it was
prose in the schema, while the **destinations** were always real and become `ops-repo-meta` data.
`learning.inbox` becomes the `learnings` role (§1a).

**What Phase 4 still has to decide** — genuinely open, not recoverable from history:

1. **The threshold value and the dedupe key.** "Recurs enough" and "the same lesson" are both
   undefined. Given the capture side is LLM-authored prose issues, dedupe is a judgement call, which
   makes this the one part of the mechanism an eval (Phase 7) should cover.
2. **Who applies the triage label.** Triage needs no new trigger machinery: it is a **fifth route
   row** in exactly the shape of the other four — `issues.labeled` + a triage label on a
   `proto-learning` issue → `ops-triage`. `route-event.sh` is already a pure function of
   `(event, action, label)`, and the cross-repo case it documents at `:20-25` is precisely this one:
   the caller workflow is committed in the **inbox** repo, where the label fires, and `--target`
   names the repo the routine works in. Firing per-issue doesn't make triage per-issue —
   dedupe/threshold query the inbox for kin and legitimately no-op ("one occurrence, below
   threshold") or close a duplicate.

   What's actually undecided is **who labels**:

   - **A human sweeping the inbox** — identical in shape to `ready-for-ai`, which
     `issue-loop-core`'s Rules call "the only gate". Consistent with the engine's design, but it puts
     a human in the compounding path.
   - **The capture hook, at file time** — every `proto-learning` issue fires triage immediately and
     the threshold does all the suppressing. Fully automatic, at the cost of many no-op routine
     fires.

   One wrinkle either way: every existing route has a **single known target**, but triage's
   destination is one of three (§2a table) and is chosen *by* triage, not known at dispatch. So
   `--target` can't carry it — the destination is an output of the loop, not an input.

   Note also that "a separate triage routine **later**" (`issue-loop-core:274`) reads as a batch
   sweep, which per-issue firing isn't. Either the wording is loose or a sweep was intended; history
   doesn't say.
3. **Whether the `shared-skills` destination is reachable at all**, since the repo-family consumer
   shape is never migrated by this plan (§7).

---

## 3. New artifacts to create in the engine

1. **The catalog** (spec §5) — **`catalog.json` + `catalog.schema.json`** (§6.6: JSON, matching the
   repo's existing data-seam convention rather than the spec's YAML examples), normative, one entry
   per capability (`release, change, ci, branching, workspace, notify, repo-meta, integrate`), each
   with actions, a **`visibility`** field (`service` / `supporting` / `cross-cutting`, per the §1
   roster) + a normative `example` (it seeds *both* the installer's scaffold and the eval). This is
   the pivot artifact — build it first; it defines the interface everything else conforms to.
   `learnings` is deliberately absent: it is framework mechanics, not a capability (§6.2).
2. **Base routing table** in the spec's `{event,label,loop}` shape, shipped beside `route-event.sh`,
   versioned by the caller's `@ref`.
3. **Overlay-merge logic** in `route-event.sh` (base ⊕ overlay, `(event,label)` identity,
   `loop:null` disable) + updated tests.
4. **Framework-default ("inherited") capability skills** for the capabilities that *can* have a
   sensible generic default — `ops-branching`, `ops-ci`, `ops-workspace`, `ops-notify`,
   `ops-repo-meta` (backed by `detect.sh`), and **`ops-integrate`**, which is new code rather than a
   demotion: nothing implements the gates-plus-merge service today (Phase 3 builds it). `ops-change`
   and `ops-release` are **always repo-specific** (no framework default).
5. **Eval harness** (spec §9) — per-capability suites seeded from catalog examples, LLM-judged,
   opt-in. Later phase.
6. **The spec itself, in-repo** — commit the two design docs as `docs/` companions so the catalog
   and installer have a normative reference to cite.

---

## 4. Phased migration plan

Ordering follows the spec's §10 "first build" guidance (reference impls → installer → routing →
the rest), adapted for migrating a live engine whose central loop (`issue-loop-core`) is still a
placeholder. **Key sequencing insight:** the placeholder loops (`issue-loop-core`, `rework-loop`,
`learning`) do **not** exist yet — build them *directly* in capability-model form so we never build
them twice.

**Phase 0 — Ratify (docs + charter).** Commit both design docs to `docs/`. Rewrite the
`CLAUDE.md` "seam doctrine" from config-pointer/override-defer to convention/`ops-<capability>`,
and point it at [`vocabulary.md`](vocabulary.md) — ratifying that glossary is part of this phase,
including the retirement of "seam" for everything except data+schema extension points. §6 is
settled in review (PR #4) — nothing left to decide here beyond §6.8a. *No behaviour change.*

**Phase 1 — Author the catalog.** Create `catalog.json` + `catalog.schema.json` for all 8
capabilities from the §1 action inventory, each carrying its `visibility` (§1 roster). This is also
where the inventory's `proposed` rows get argued — concrete entries, not draft table rows.
**Delete the action-inventory table** once the catalog exists — it is draft input, and leaving it
behind creates the second source of truth this migration exists to kill. Reserve the framework loop
names. This is the interface pivot; everything downstream conforms to it.

Also in this phase: extend the README's capability section with the **action** level — **derived
from the catalog, not hand-maintained**, or it drifts the way everything else in §7 has. The
capability level (the eight, their visibility, and which two a repo must always provide) is already
in the README, marked as the target model, since that much is settled; only the actions were
waiting on the catalog. The README's "config contract" section is what Phase 8 deletes, so leave it
alone here.

**Phase 2 — Routing to spec (edge).** Convert `route-map` to the `{event,label,loop}` shape +
event vocab; add base⊕overlay merge to `route-event.sh`; rename route targets to reserved loop
names; remove the duplicated `case` fallback; move the overlay to a committed
`.github/ops-routing.yml` (§6.4). Update `route-event.test.sh`. **Add the fifth base route row for
`ops-triage`** (§2a) — `issues.labeled` + a triage label, fired from the inbox repo — while the base
table is being authored anyway; who applies that label is a Phase 4 question, not a routing one.

**Phase 3 — Framework loops invoke *services* by name.** *(Unblocked — §6.8 and §6.9 are settled.)*
Rewrite `merge-flow`→`ops-merge-flow` to command **`ops-integrate · land`** plus the cross-cutting
reads `ops-ci · status` / `ops-repo-meta · topology` — and to **stop resolving `base` /
`release_base` / `merge_strategy` itself** (today `merge-flow/SKILL.md:40-59` tabulates all three,
`:87-94` compares against two of them, `:99` passes the strategy into the merge). Build
`ops-integrate` as the new home for the four gates **plus the release-base skip** (§6.9 = b),
returning the structured outcome the loop comments on; the loop keeps orchestration only — sweep,
CI-poll cadence, the 15-minute cap and the per-run cap of 10. Rewrite
`auto-release-loop`→`ops-auto-release` to call `ops-release` only, never `ops-branching`. Extract
`ops-ci` (`status` + `log`) from `github-ops`, keeping forge mechanics as framework. Demote
`release-and-branching`→`ops-branching` framework default **with its values private** and
**command-only** (no `classify-pr`); its base knowledge must be a **set** of live integration
branches, not one branch (§8). Fold `sync-dev` into `ops-release.sync`.

**Phase 4 — Build the placeholder loops directly in capability form.** `ops-issue-loop` (commands
`ops-change`, which itself wraps `ops-workspace`; reads `ops-ci` / `ops-repo-meta`), `ops-rework`,
and the learnings mechanism as a **uniform framework capture hook + `ops-triage`** with destinations
read from `ops-repo-meta` (§6.2). Avoids a build-then-migrate double. **Build `ops-triage` to the
inherited contract in §2a** — dedupe → threshold → route, output a PR — and settle the three things
history doesn't answer: the threshold value, the dedupe key, and whether a human or the capture hook
applies the triage label.

**Phase 5 — Rebuild the installer as `ops-install`.** Coverage report
(present/inherited/missing by `ops-<cap>` name); scaffold a stub per missing catalog capability;
validate the routing overlay per §6. Keep `detect.sh` for pre-fill.

**Phase 6 — Consumer capability skills (Forms, then Automate).** Provide Forms' implementations:
`ops-change` (dotnet build/verify + cross-repo close to `Umbraco.Forms.Issues`), `ops-release`
(nbgv/version bump/tag/back-merge across `vN/dev`↔`vN/main`), `ops-repo-meta` (topology: public
issues repo + internal code repo; **live lines + primary line** per §8), `ops-branching`
(versioned-gitflow, values private), `ops-ci` (azure-pipelines), `ops-workspace` (worktree + SQLite
DB, wrapped by `ops-change`), `ops-notify`. Learnings needs no Forms-specific capability — only a
`topology` destination. Then Automate, which differs only in `ops-change` (port direction) and
topology (in-repo issues). Run `/ops-install` and prove full coverage on both.

**Onboarding prerequisites** — repo-side changes both consumers need before a loop can run; see §8
for the evidence:

| Prerequisite | Forms | Automate | Why |
|---|---|---|---|
| Create the trigger labels (`ready-for-ai`, `auto-merge`, …) | needed | needed | none exist in either repo today; nothing can be routed without them |
| Declare **live lines** + the **primary line** as `ops-repo-meta` facts | needed | needed | multiple majors are live simultaneously; neither is inferable from version numbers |
| Move the default branch off `v15/dev` | needed | — | routines clone the **default branch** (`README.md` caveat), and Forms' default is a line no longer worked on |
| `allow_update_branch` → true | needed | needed | both `false`; the loop can't refresh a stale branch before the merge gate |
| Leave native auto-merge **disabled** | keep off | keep off | landing is the service's decision; native auto-merge would race it |
| Document per-PR labelling for ports | needed | needed | landing is per-PR (§8), so each line's PR carries its own label |
| Branch protection on live lines | recommended | recommended | not required, but with none (the case today) `ops-integrate`'s own CI re-check is the **only** real gate |

**Phase 7 — Evals.** Per-capability suites seeded from the catalog examples; opt-in.

**Phase 8 — Retire the config-pointer model.** Delete `ai-ops.yml` + `ai-ops.schema.json` +
`ai-ops.example.yml` outright (§6.7 — no remnant), along with the `playbook` / `release_skill`
pointers and the `ci.*` / `branching.*` config. Remove the README's "config contract" section and
update `CLAUDE.md`.

---

## 5. What survives of `ai-ops.yml`?

If `ops-repo-meta` (`identity` + `topology`) owns repo identity and the capabilities own everything
else, `ai-ops.yml`'s normative content is fully absorbed and the file can be **removed**.
**Decided (§6.7): remove it** — no thin remnant. A second source of the same facts is exactly the
drift this migration exists to kill. Phase 8 does the deletion.

---

## 6. Decisions — settled

All nine were resolved in review on PR #4 (27-07-2026). The arguments are kept as the decision log;
the **Decided** line is what binds. One sub-question was opened by the resolution and is tracked as
§6.8a.

1. **Coexistence vs clean break.** → **Decided: clean break per phase.** The placeholders let us
   build the central loops fresh rather than migrate them, so there is nothing to run in parallel.
2. **Which capabilities ship a framework default (`inherited`).** → **Decided:** defaults for
   `ops-branching`, `ops-ci`, `ops-workspace`, `ops-notify`, `ops-repo-meta` and — once §6.8 settled
   as A — `ops-integrate`, whose merge gates are engine policy and should be identical everywhere.
   Always-repo-provided:
   `ops-change` and `ops-release` — **those two only**. Learnings is *not* a per-repo capability:
   capture is uniform framework machinery (+ `ops-triage`) so lessons compound, with destinations as
   `ops-repo-meta` data. Evidence it was never a real seam: `ai-ops.schema.json` types
   `learning.routing` as a free-form prose string ("Free-form note on where triage routes
   learnings"), so there is nothing behavioural to override.
3. **Build the placeholders directly in capability form?** → **Decided: yes.** `issue-loop-core`,
   `rework-loop` and `learning` don't exist, so build once as `ops-issue-loop` / `ops-rework` /
   framework capture + `ops-triage`.
4. **Overlay home.** → **Decided: a committed `.github/ops-routing.yml`.** Both are spec-legal; the
   committed file is auditable and reviewable in the consumer repo.
5. **Delivery mechanics.** → **Decided: stacked PRs into `main`, one per phase**, as with the engine
   baseline. Keeps CI green and each phase reviewable on its own.
6. **Catalog format.** → **Decided: JSON** — `catalog.json` + `catalog.schema.json`, matching the
   repo's existing data-seam convention (`route-map.json`, `operation-catalog.json`) rather than the
   spec's YAML examples.
7. **Remove `ai-ops.yml` entirely** (§5) or keep a thin remnant? → **Decided: remove it entirely**,
   in Phase 8.
8. **`auto-merge` scope — does `ops-integrate` exist?** → **Decided: A — it exists.**

   **The status quo is PR-generic, not undecided.** `merge-flow` Step 1 (`SKILL.md:63`) lists open
   PRs filtered by the label alone — no author check, no `generated-by-ai` filter, no issue link —
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
   release-base skip); `ops-merge-flow` keeps *orchestration* — sweeping labelled PRs, the CI poll
   cadence and 15-minute cap, the per-run cap of 10, and reporting. Policy in the service,
   scheduling in the loop.

   **8a. Does `ops-change` also keep a *delegating* `land`?** *(open — one catalog row)*

   The original recommendation was "A, with `ops-change · land` delegating to `ops-integrate`" —
   one merge path, two entry points — and that is what review agreed to. Two facts found afterwards
   argue against the delegating tail:

   - **A change lands N times at N moments.** Forms ships one logical fix across v13/main, v17 and
     v18 (§8); v17 can be green while v18 is still being adapted. "The tail of `ops-change`" implies
     one tail, and there isn't one.
   - **A human gate splits delivery in two.** `implement → verify → land` isn't a single run, so the
     tail isn't reachable from the same invocation anyway.

   Under that reading `ops-change` ends at `close-issue`, which fires when **all** target lines have
   landed, and every merge enters through `ops-merge-flow → ops-integrate`. **Not settled** —
   it removes one row from the catalog and changes nothing else, so Phase 1 can carry it either way.

9. **If `base` is private, who skips a release-base PR?** → **Decided: (b) — the service.**

   `merge-flow` currently decides this itself, comparing the PR's base against the resolved
   `release_base` (`SKILL.md:87-94`, guardrail `:118`) and skipping release PRs as
   `ops-auto-release`'s job. A private `ops-branching` forbids that comparison.

   - **Option (a) — a classification read.** `ops-branching · classify-pr` returns
     `integration | release | wrong-base`; the loop routes on the classification and never sees a
     branch name. Satisfies the privacy rule (a classification is not a branch name) but adds a
     read to a primitive we just defined as command-only, and leaves merge policy split across loop
     and service.
   - **Option (b) — the skip lives in the service.** `ops-merge-flow` hands every labelled PR to
     `ops-integrate`, which asks `ops-branching` and declines release-base PRs. All merge policy in
     one place, and the wrong-base flag is authored by the thing that knows what right looks like.

   **Resolution: (b), with `ops-integrate` returning a structured outcome** —
   `merged | skipped:release-base | blocked:ci | blocked:conflict | blocked:changes-requested` — so
   the loop can still comment the specific blocker (Step 4's behaviour) and stays observable without
   holding branch names. That gets (a)'s legibility without the leak, keeps `ops-branching`
   command-only, and puts all merge policy in one place. **`classify-pr` is dropped.**

   The service re-checks CI even though the loop already polled it. That duplication is deliberate:
   native auto-merge is disabled and there is **no branch protection on either consumer repo** (§8),
   so the service's own check is the only gate that actually holds. A service that trusts its caller
   has no gate at all.

**8 and 9 were coupled**, through one question neither named: **do the merge gates belong to the
loop or the service?** All four lived in the loop (`merge-flow` Step 2). **Review settled it: the
gates belong to the service** — which gives 8 its `ops-integrate` and answers 9 as (b) in one move.
That was the last thing blocking Phase 3.

---

## 7. Risk / hazard register

- **Central loop is a placeholder.** `issue-loop-core` (and `rework-loop`) are routed-to but
  unbuilt; the whole issue→PR path is not exercisable today. Migration and first-build are the same
  work here — plan accordingly.
- **Base-branch knowledge lives in *four* places**, not two: `ai-ops.schema.json`
  (`branching.base` / `release_base`), runtime detection in `release-and-branching`, `merge-flow`'s
  own resolve-and-compare (`SKILL.md:40-59`, `:87-94`), and `operation-catalog.json`'s
  `detect-base-branch` (a `forge`-axis operation whose title is "defer to release-and-branching").
  Making the values private to `ops-branching` is the only move that collapses all four; migrating
  them into a caller-visible `resolve-base` action would just relocate the leak.
- **`ci.provider` vs `ci_provider` spelling split** (schema/detector vs the github-ops references).
  Don't carry it forward; the capability is the source.
- **Route-map lives in two places** (`route-map.json` + the `case` fallback in `route-event.sh`).
  Collapse to one during Phase 2.
- **Two marketplace entries point at directories that don't exist.** `marketplace.json` declares
  eight plugins; `plugins/` holds six. `learning` and `dotnet-web-runtime` have a `source` path but
  no directory and no `plugin.json`, which `CLAUDE.md` requires of every declared plugin — so
  `/plugin marketplace add` would fail on them. They read as shipped rather than as placeholders.
  Either scaffold them or mark them unreleased; `learning`'s description is currently the **only**
  written spec for `ops-triage` (§2a), so deleting the entry would lose it.
- **The repo-family consumer shape is never migrated.** `README.md` names three consumer shapes —
  Forms, Automate, and the MCP server family with its shared consumer repo (`umbraco-mcp-ops`) —
  and this plan covers only the first two (Phase 6). The one-`ops-change`-serving-many-repos case is
  neither migrated nor tested against the convention model, even though the design docs this plan
  ports were written *for* that repo. It also strands `ops-triage`'s `shared-skills` destination
  (§2a), which only means anything for a repo family. Needs either a Phase 6b or an explicit
  out-of-scope ruling.
- **`ops-triage` has no route row, and its destination can't be a dispatch input.** The trigger
  mechanism is fine — a triage label on a `proto-learning` issue in the inbox repo is the same
  `issues.labeled` shape as the other four routes, cross-repo included (`route-event.sh:20-25`). But
  no such label or row exists yet, nobody has decided whether a human or the capture hook applies it,
  and unlike every other loop the *destination* is chosen by triage rather than passed as `--target`
  (§2a). Add the row in Phase 2; settle the labeller and the destination handling in Phase 4.
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
