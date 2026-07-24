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
- **`branching.merge_strategy` / `branching.base` are in the schema but re-detected at runtime**
  via `release-and-branching` (two competing sources of truth) → *collapses* to one:
  `ops-branching.merge-strategy` / `ops-branching.resolve-base`.

---

## 1. Seam audit — current → target

Kind legend: **B** = behavioral capability (a loop calls its actions) · **D** = data capability ·
**F** = framework mechanics (stays in the engine) · **—** = key/behaviour removed.

### 1a. Config-pointer seams (`ai-ops.yml` / `ai-ops.schema.json`)

| Current key | Kind | Target capability · action | Migration note |
|---|---|---|---|
| `repos.source` | D | `ops-repo-meta` · `topology` (role `code`) + `identity` | source = the `code` role |
| `repos.inbox` | D | `ops-repo-meta` · `topology` (role `issues`) | issues = the `issues` role; single-repo collapses to `code` |
| `repos.issue_link` | — | *removed* → `ops-change` · `close-issue` | enum disappears; cross-repo close is behaviour (§7.4), not config |
| `ci.provider` | B | `ops-ci` (provider internal to the consumer's skill) | **kills the `ci.provider`/`ci_provider` split** |
| `ci.ado_org` / `ci.ado_project` / `ci.gh_repo` | B | internal to consumer `ops-ci` | out of central config |
| `branching.model` | B | `ops-branching` (internal knowledge / framework default) | model becomes skill logic, not an enum |
| `branching.base` | B | `ops-branching` · `resolve-base` | **single source of truth** (ends schema-vs-runtime drift) |
| `branching.release_base` | B | `ops-branching` · `resolve-base` (release ctx) / `ops-release` · `plan` | |
| `branching.merge_strategy` | B | `ops-branching` · `merge-strategy` | **single source of truth** |
| `branching.branch_naming` | B | internal to `ops-branching` / `ops-change` | |
| `branching.release_skill` | B | `ops-release` (whole capability) | the *pointer* becomes the *convention* (`ops-release`) |
| `learning.inbox` | B/D | `ops-learnings` · `file` (+ `ops-repo-meta` for target repo) | |
| `learning.routing` | B | `ops-learnings` · `route` | |
| `playbook` (build-skill pointer) | B | `ops-change` · `implement` / `verify` / `close-issue` | the central pointer becomes the convention (`ops-change`) |
| `version` (schema pin) | F | catalog/spec version | replaced by catalog + spec versioning |

Net: `ai-ops.yml`'s normative content is absorbed by `ops-repo-meta` (identity/topology) + the
per-capability skills. See §5 for what, if anything, remains.

### 1b. Behavioral / skill-reference seams (prose deferrals)

| Current deferral (where) | Target capability · action |
|---|---|
| build/test commands, sanity pass (repo `CLAUDE.md`; `playbook` skill) | `ops-change` · `implement` / `verify` (internal) |
| version-file list + changelog bump (repo `CLAUDE.md`; `auto-release-loop:51`) | `ops-release` · `cut` (internal) |
| worktree / DB cleanup ("repo's own `/cleanup`"; `gitflow.md:37`) | `ops-workspace` · `prepare` / `teardown` |
| human push notifications (loops emit "Reworked PR #N…") | `ops-notify` · `send` |
| base-branch + merge-strategy detection via `release-and-branching` | `ops-branching` · `resolve-base` / `merge-strategy` |
| cross-repo issue close (can't use `Closes #N`) | `ops-change` · `close-issue` (§7.4 — MUST be explicit) |
| CI status reads (`github-ops` → `ci_provider`) | `ops-ci` · `status` |
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
| `issue-loop-core` *(placeholder)* | `ops-issue-loop` | `ops-change` (implement/verify/close-issue), `ops-workspace`, `ops-ci`, `ops-repo-meta` |
| `rework-loop` *(placeholder)* | `ops-rework` | `ops-change`, `ops-ci`, `ops-repo-meta` |
| `merge-flow` | `ops-merge-flow` | `ops-branching` (merge-strategy/resolve-base), `ops-ci` (status), `ops-repo-meta` (topology) |
| `auto-release-loop` | `ops-auto-release` | `ops-release` (plan/cut/publish/sync), `ops-ci`, `ops-branching` |
| `release-and-branching` | *demoted* → `ops-branching` (framework default) | — (becomes a capability, repo may override) |
| `sync-dev` | folded into `ops-release` · `sync` | — |
| `github-ops` | split: `ops-ci` (capability) + forge mechanics stay **F** | forge target resolved via `ops-repo-meta` topology |
| `loop-dispatch` | `loop-dispatch` (unchanged name) | gains base⊕overlay merge + event vocab |
| `new-loop-routine` | loop-scaffolder (writes overlay rows) | — |
| `ops-setup` / `umbraco-ops-setup` | `ops-install` | reads catalog; coverage + scaffold + overlay-validate |
| `learning` *(placeholder)* | `ops-learnings` (capability) + `ops-triage` (loop) | — |
| `release-reviewer` (agent) | stays (orchestration internal to `ops-auto-release`) | non-normative |

---

## 3. New artifacts to create in the engine

1. **The catalog** (spec §5) — `catalog.(yml|json)` + schema, normative, one entry per capability
   (`release, change, ci, branching, workspace, notify, repo-meta, learnings`), each with actions +
   a normative `example` (it seeds *both* the installer's scaffold and the eval). This is the pivot
   artifact — build it first; it defines the interface everything else conforms to.
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
`CLAUDE.md` "seam doctrine" from config-pointer/override-defer to convention/`ops-<capability>`.
Settle the open decisions in §6. *No behaviour change.*

**Phase 1 — Author the catalog.** Create `catalog.(yml|json)` + schema for all 8 capabilities.
Reserve the framework loop names. This is the interface pivot; everything downstream conforms to it.

**Phase 2 — Routing to spec (edge).** Convert `route-map` to the `{event,label,loop}` shape +
event vocab; add base⊕overlay merge to `route-event.sh`; rename route targets to reserved loop
names; remove the duplicated `case` fallback; move the overlay to the caller workflow /
`.github/ops-routing.yml`. Update `route-event.test.sh`.

**Phase 3 — Framework loops invoke capabilities by name.** Rewrite `merge-flow`→`ops-merge-flow`
and `auto-release-loop`→`ops-auto-release` to call `ops-branching` / `ops-ci` / `ops-release` /
`ops-repo-meta` by name. Extract `ops-ci` from `github-ops` (keep forge mechanics as framework).
Demote `release-and-branching`→`ops-branching` framework default; fold `sync-dev` into
`ops-release.sync`.

**Phase 4 — Build the placeholder loops directly in capability form.** `ops-issue-loop` (calls
`ops-change`/`ops-workspace`/`ops-ci`/`ops-repo-meta`), `ops-rework`, and `ops-learnings` +
`ops-triage`. Avoids a build-then-migrate double.

**Phase 5 — Rebuild the installer as `ops-install`.** Coverage report
(present/inherited/missing by `ops-<cap>` name); scaffold a stub per missing catalog capability;
validate the routing overlay per §6. Keep `detect.sh` for pre-fill.

**Phase 6 — Forms consumer capability skills.** Provide Forms' seam implementations:
`ops-change` (dotnet build/verify + cross-repo close to `Umbraco.Forms.Issues`), `ops-release`
(nbgv/version bump/tag/back-merge across `vN/dev`↔`vN/main`), `ops-repo-meta` (topology: public
issues repo + internal code repo), `ops-branching` (versioned-gitflow), `ops-ci` (azure-pipelines),
`ops-workspace` (worktree + SQLite DB), `ops-notify`, `ops-learnings`. Run `/ops-install` and
prove full coverage.

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
   `ops-change`, `ops-release`, and the routing half of `ops-learnings`.
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

---

## 7. Risk / hazard register

- **Central loop is a placeholder.** `issue-loop-core` (and `rework-loop`) are routed-to but
  unbuilt; the whole issue→PR path is not exercisable today. Migration and first-build are the same
  work here — plan accordingly.
- **Two sources of truth already exist** (`branching.*` config vs runtime detection;
  `ci.provider` vs `ci_provider`). Don't carry either forward; the capability is the source.
- **Route-map lives in two places** (`route-map.json` + the `case` fallback in `route-event.sh`).
  Collapse to one during Phase 2.
- **`README.md:110` references a "topology map" that doesn't exist.** Either build `ops-repo-meta`
  topology to back it or fix the doc.
- **No static typing (deliberate).** A capability that returns the wrong shape is caught at runtime
  or by an eval, never statically (spec's explicit trade). Coverage ≠ correctness — Phase 7 evals
  are the only behavioural guard.
