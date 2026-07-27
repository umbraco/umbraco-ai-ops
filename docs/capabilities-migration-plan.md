# Capabilities-model migration plan

Status: Draft for review · Author: audit of `umbraco-ai-ops@main` against the two design docs
(Layer 1 — *Ops Capability Skills* explainer; Layer 2 — *Conformance Specification*).

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
| `ops-integrate` | B | **service** *(conditional — §6.8)* | framework loops |
| `ops-branching` | B | **supporting** | services only — **never a loop** |
| `ops-workspace` | B | **supporting** | `ops-change` only |
| `ops-repo-meta` | D | **cross-cutting** (read) | any layer |
| `ops-ci` | B | **cross-cutting** (read) | loops (to gate) + services |
| `ops-notify` | B | **cross-cutting** (infra) | any layer |
| `ops-learnings` | F + D | **framework mechanism + data** | capture is framework-wide (§4 P4) |

Two consequences bite this plan directly: `ops-branching`'s strategy/base values become
**private** — no loop and no service reads `merge_strategy` or `base`, they ask for an *outcome*
(§1a, §2) — and `ops-workspace` is prepared/torn down by `ops-change`, not by the issue loop.

Terms used throughout — *service*, *supporting primitive*, *cross-cutting*, *action* vs
*operation*, *capability catalog* vs *operation catalog* — are defined in
[`vocabulary.md`](vocabulary.md).

### Action inventory — the draft catalog

> **Superseded by Phase 1.** This table is the *input* to the capability catalog (§3.1), not a
> second copy of it: author the catalog from these rows, then **delete this table**. Visibility and
> callers are deliberately absent — they live in the roster above, one fact in one place.
>
> **Status is load-bearing.** Most of these action names are proposals from the audit, not
> implemented behaviour. Read `proposed` as "argue with me".

Status legend: **exists** = implemented today (source named) · **proposed** = invented by this
audit, nothing implements it · **conditional** = depends on an open decision in §6.

| Capability | Action | Status | Notes / where the behaviour lives today |
|---|---|---|---|
| `ops-change` | `implement` | proposed | prose in the repo's `CLAUDE.md` + the `playbook` build skill |
| | `verify` | proposed | build/test/sanity pass, same source |
| | `close-issue` | proposed | forge op `close-issue` exists; cross-repo close MUST be explicit (§7.4) |
| | `land` | conditional §6.8 | only if `auto-merge` stays PR-generic; delegates to `ops-integrate` |
| `ops-release` | `plan` | proposed | `release-reviewer` agent + `auto-release-loop` prose |
| | `cut` | proposed | version-file list + changelog bump (`auto-release-loop:51`) |
| | `publish` | proposed | `release-tag.yml`, version-source per stack |
| | `sync` | **exists** | the `sync-dev` skill, folded in per §2 |
| `ops-integrate` | `land` | conditional §6.8 | thin service wrapping `ops-branching · merge`; owns the four gates |
| `ops-branching` | `merge` | proposed | strategy chosen internally; replaces `merge_strategy` config + forge `merge-pr` |
| | `open-pr` | proposed | forge `create-pr` exists as an operation |
| | `start-branch` | proposed | forge `create-branch` exists as an operation |
| | `classify-pr` | conditional §6.9(a) | `integration \| release \| wrong-base`; exists only if the skip stays in the loop |
| | *(base / release-base / model)* | **not actions** | internal knowledge — private per §0 |
| `ops-workspace` | `prepare` | proposed | "repo's own `/cleanup`" (`gitflow.md:37`) |
| | `teardown` | proposed | worktree + DB teardown, same source |
| `ops-repo-meta` | `identity` | proposed | `detect.sh` can pre-fill; replaces `repos.source` |
| | `topology` | proposed | roles `code` / `issues` / `learnings`; backs the map `README.md:110` already claims exists (§7) |
| `ops-ci` | `status` | **exists** | operation `get-ci-status` |
| | `log` | **exists** | operation `read-failing-ci-log` |
| `ops-notify` | `send` | proposed | loops emit "Reworked PR #N…" inline today |
| ~~`ops-learnings`~~ | — | **not a capability** | framework capture hook + `ops-triage`; destinations are `ops-repo-meta` data (§6.2) |

Counts: **4 exist**, 13 proposed, 3 conditional. The two `land` rows are the same action reached
two ways — see §6.8.

### 1a. Config-pointer seams (`ai-ops.yml` / `ai-ops.schema.json`)

| Current key | Kind | Target capability · action | Migration note |
|---|---|---|---|
| `repos.source` | D | `ops-repo-meta` · `topology` (role `code`) + `identity` | source = the `code` role |
| `repos.inbox` | D | `ops-repo-meta` · `topology` (role `issues`) | issues = the `issues` role; single-repo collapses to `code` |
| `repos.issue_link` | — | *removed* → `ops-change` · `close-issue` | enum disappears; cross-repo close is behaviour (§7.4), not config |
| `ci.provider` | B | `ops-ci` (provider internal to the consumer's skill) | **kills the `ci.provider`/`ci_provider` split** |
| `ci.ado_org` / `ci.ado_project` / `ci.gh_repo` | B | internal to consumer `ops-ci` | out of central config |
| `branching.model` | B | `ops-branching` (internal knowledge / framework default) | model becomes skill logic, not an enum |
| `branching.base` | B | `ops-branching` — **private**; callers get outcomes, never the value | **single source of truth** (ends the four-way drift in §7) |
| `branching.release_base` | B | `ops-branching` (private); reaches a caller as a PR *classification*, not a branch name — §6.9 | |
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
| cross-repo issue close (can't use `Closes #N`) | `ops-change` · `close-issue` (§7.4 — MUST be explicit) |
| CI status reads (`github-ops` → `ci_provider`) | `ops-ci` · `status` |
| failing check / build log reads (`operation-catalog` → `read-failing-ci-log`) | `ops-ci` · `log` (the `ci` axis is **read-only** — both its operations are reads) |
| forge mechanism (gh CLI vs GitHub MCP), PR/label/merge by role | **F** — stays framework; target resolved by `ops-repo-meta` · `topology` role |
| release-tag automation version-source per stack (`release-tag.yml`) | `ops-release` · `cut` / `publish` (internal) |

### 1c. Routing seams (`route-map.json` / `route-event.sh`)

| Current | Target (spec §6) |
|---|---|
| Whole-file replacement (`$ROUTE_MAP` swaps the entire map) | **base ⊕ per-repo overlay** merged live at the edge; identity key `(event,label)`; overlay wins; `loop:null` disables |
| Rule shape `{event:"issues", action:"labeled", route}` | `{event:"issues.labeled", label, loop}` — collapse event+action into the event vocab (`issues.labeled`, `pull_request.labeled`, `issues.opened`, `pull_request.opened`), rename `route`→`loop` |
| Route targets `issue-loop-core` / `auto-release-loop` / `merge-flow` / `rework-loop` | reserved loop names `ops-issue-loop` / `ops-auto-release` / `ops-merge-flow` / `ops-rework` |
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
| `rework-loop` *(placeholder)* | `ops-rework` | `ops-change` · `ops-ci` (status/log), `ops-repo-meta` (reads) |
| `merge-flow` | `ops-merge-flow` | `ops-change` · `land` **or** `ops-integrate` (§6.8) · `ops-ci` (status), `ops-repo-meta` (topology). **Never `ops-branching` directly** |
| `auto-release-loop` | `ops-auto-release` | `ops-release` (plan/cut/publish/sync) · `ops-ci`. Reaches `ops-branching` **only through `ops-release`** |
| `release-and-branching` | *demoted* → `ops-branching` (framework default) | — (becomes a capability, repo may override) |
| `sync-dev` | folded into `ops-release` · `sync` | — |
| `github-ops` | split: `ops-ci` (capability) + forge mechanics stay **F** | forge target resolved via `ops-repo-meta` topology |
| `loop-dispatch` | `loop-dispatch` (unchanged name) | gains base⊕overlay merge + event vocab |
| `new-loop-routine` | loop-scaffolder (writes overlay rows) | — |
| `ops-setup` / `umbraco-ops-setup` | `ops-install` | reads catalog; coverage + scaffold + overlay-validate |
| `learning` *(placeholder)* | framework capture hook + `ops-triage` (loop); destinations are `ops-repo-meta` data | uniform across repos so lessons compound (§6.2) |
| `release-reviewer` (agent) | stays (orchestration internal to `ops-auto-release`) | non-normative |

---

## 3. New artifacts to create in the engine

1. **The catalog** (spec §5) — `catalog.(yml|json)` + schema, normative, one entry per capability
   (`release, change, ci, branching, workspace, notify, repo-meta, learnings`, plus `integrate` if
   §6.8 says so), each with actions, a **`visibility`** field (`service` / `supporting` /
   `cross-cutting`, per the §1 roster) + a normative `example` (it seeds *both* the installer's
   scaffold and the eval). This is the pivot artifact — build it first; it defines the interface
   everything else conforms to.
2. **Base routing table** in the spec's `{event,label,loop}` shape, shipped beside `route-event.sh`,
   versioned by the caller's `@ref`.
3. **Overlay-merge logic** in `route-event.sh` (base ⊕ overlay, `(event,label)` identity,
   `loop:null` disable) + updated tests.
4. **Framework-default ("inherited") capability skills** for the capabilities that *can* have a
   sensible generic default — candidates: `ops-branching`, `ops-ci`, `ops-workspace`, `ops-notify`,
   `ops-repo-meta` (backed by `detect.sh`). `ops-change` and `ops-release` are **always
   repo-specific** (no framework default).
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
including the retirement of "seam" for everything except data+schema extension points. Settle the
open decisions in §6. *No behaviour change.*

**Phase 1 — Author the catalog.** Create `catalog.(yml|json)` + schema for all 8 capabilities from
the §1 action inventory, each carrying its `visibility` (§1 roster). **Delete the action-inventory
table** once the catalog exists — it is draft input, and leaving it behind creates the second source
of truth this migration exists to kill. Reserve the framework loop names. This is the interface
pivot; everything downstream conforms to it.

Also in this phase: extend the README's capability section with the **action** level — **derived
from the catalog, not hand-maintained**, or it drifts the way everything else in §7 has. The
capability level (the eight, their visibility, and which two a repo must always provide) is already
in the README, marked as the target model, since that much is settled; only the actions were
waiting on the catalog. The README's "config contract" section is what Phase 8 deletes, so leave it
alone here.

**Phase 2 — Routing to spec (edge).** Convert `route-map` to the `{event,label,loop}` shape +
event vocab; add base⊕overlay merge to `route-event.sh`; rename route targets to reserved loop
names; remove the duplicated `case` fallback; move the overlay to the caller workflow /
`.github/ops-routing.yml`. Update `route-event.test.sh`.

**Phase 3 — Framework loops invoke *services* by name.** Rewrite `merge-flow`→`ops-merge-flow` to
command a service (`ops-change · land` or `ops-integrate`, per §6.8) plus the cross-cutting reads
`ops-ci · status` / `ops-repo-meta · topology` — and to **stop resolving `base` / `release_base` /
`merge_strategy` itself** (today `merge-flow/SKILL.md:40-59` tabulates all three, `:87-94` compares
against two of them, `:99` passes the strategy into the merge). Rewrite
`auto-release-loop`→`ops-auto-release` to call `ops-release` only, never `ops-branching`. Extract
`ops-ci` (`status` + `log`) from `github-ops`, keeping forge mechanics as framework. Demote
`release-and-branching`→`ops-branching` framework default **with its values private**; fold
`sync-dev` into `ops-release.sync`. Settle §6.9 before this phase — it decides where the
release-base skip lives.

**Phase 4 — Build the placeholder loops directly in capability form.** `ops-issue-loop` (commands
`ops-change`, which itself wraps `ops-workspace`; reads `ops-ci` / `ops-repo-meta`), `ops-rework`,
and the learnings mechanism as a **uniform framework capture hook + `ops-triage`** with destinations
read from `ops-repo-meta` (§6.2). Avoids a build-then-migrate double.

**Phase 5 — Rebuild the installer as `ops-install`.** Coverage report
(present/inherited/missing by `ops-<cap>` name); scaffold a stub per missing catalog capability;
validate the routing overlay per §6. Keep `detect.sh` for pre-fill.

**Phase 6 — Forms consumer capability skills.** Provide Forms' seam implementations:
`ops-change` (dotnet build/verify + cross-repo close to `Umbraco.Forms.Issues`), `ops-release`
(nbgv/version bump/tag/back-merge across `vN/dev`↔`vN/main`), `ops-repo-meta` (topology: public
issues repo + internal code repo), `ops-branching` (versioned-gitflow, values private), `ops-ci` (azure-pipelines),
`ops-workspace` (worktree + SQLite DB, wrapped by `ops-change`), `ops-notify`. Learnings needs no
Forms-specific capability — only a `topology` destination. Run `/ops-install` and prove full
coverage.

**Phase 7 — Evals.** Per-capability suites seeded from the catalog examples; opt-in.

**Phase 8 — Retire the config-pointer model.** Remove/shrink `ai-ops.yml` + schema, the
`playbook` / `release_skill` pointers, and the `ci.*` / `branching.*` config. Update README +
CLAUDE.md. (Or keep a minimal remnant per the §6 coexistence decision.)

---

## 5. What survives of `ai-ops.yml`?

If `ops-repo-meta` (`identity` + `topology`) owns repo identity and the capabilities own everything
else, `ai-ops.yml`'s normative content is fully absorbed and the file can be **removed**. The open
question (§6) is whether a thin remnant is worth keeping for humans to eyeball, or whether
`ops-repo-meta` (detect-backed) is the single source. Recommendation: remove it — a second source
of the same facts is exactly the drift this migration exists to kill.

---

## 6. Decisions to settle before starting

1. **Coexistence vs clean break.** Big-bang the config-pointer → capabilities move, or run both
   during transition? (Recommend: clean break per phase, since the placeholders let us build the
   central loops fresh rather than migrate them.)
2. **Which capabilities ship a framework default (`inherited`).** Proposed defaults:
   `ops-branching`, `ops-ci`, `ops-workspace`, `ops-notify`, `ops-repo-meta`. Always-repo-provided:
   `ops-change` and `ops-release` — **those two only**. Learnings is *not* a per-repo capability:
   capture should be uniform framework machinery (+ `ops-triage`) so lessons compound, with
   destinations as `ops-repo-meta` data. Evidence it was never a real seam: `ai-ops.schema.json`
   types `learning.routing` as a free-form prose string ("Free-form note on where triage routes
   learnings"), so there is nothing behavioural to override.
3. **Build the placeholders directly in capability form?** (Recommend: yes — `issue-loop-core`,
   `rework-loop`, `learning` don't exist, so build once as `ops-issue-loop`/`ops-rework`/
   `ops-learnings`.)
4. **Overlay home.** Caller-workflow input block vs committed `.github/ops-routing.yml`. (Both are
   spec-legal; committed file is more auditable.)
5. **Delivery mechanics.** Same stacked-PR-into-`main` workflow we used for the engine baseline?
   One PR per phase keeps CI green and reviewable.
6. **Catalog format.** YAML (matches the spec's examples) or JSON (matches the repo's existing
   `*.schema.json` data-seam convention)?
7. **Remove `ai-ops.yml` entirely** (§5) or keep a thin remnant?
8. **`auto-merge` scope — does `ops-integrate` exist?** *(blocks Phase 3)*

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

   **These aren't exclusive.** `ops-integrate` owns landing; `ops-change · land` is the delivery
   sequence that *calls* it for its final step. One merge path, two entry points — which is what B
   is really reaching for (a coherent delivery tail) without dropping dependabot.

   **Recommendation: A, with `ops-change · land` delegating to `ops-integrate`.** Narrowing is the
   change that needs justifying, since it removes working behaviour.

   **Follow-on this settles:** `ops-integrate` owns merge *policy* (the four gates);
   `ops-merge-flow` keeps *orchestration* — sweeping labelled PRs, the CI poll cadence and 15-minute
   cap, the per-run cap of 10, and reporting. Policy in the service, scheduling in the loop.

9. **If `base` is private, who skips a release-base PR?** *(blocks Phase 3)*

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

   **Recommendation: (b), with `ops-integrate` returning a structured outcome** —
   `merged | skipped:release-base | blocked:ci | blocked:conflict | blocked:changes-requested` — so
   the loop can still comment the specific blocker (Step 4's behaviour) and stays observable
   without holding branch names. That gets (a)'s legibility without the leak.

**8 and 9 are coupled**, through one question neither names: **do the merge gates belong to the
loop or the service?** All four live in the loop today (`merge-flow` Step 2). Move them to the
service and 8 gets `ops-integrate` and 9 answers itself as (b); leave them in the loop and it keeps
needing base knowledge, which forces 9(a). Settle gate ownership and both fall out.

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
- **`README.md:110` references a "topology map" that doesn't exist.** Either build `ops-repo-meta`
  topology to back it or fix the doc.
- **No static typing (deliberate).** A capability that returns the wrong shape is caught at runtime
  or by an eval, never statically (spec's explicit trade). Coverage ≠ correctness — Phase 7 evals
  are the only behavioural guard.
