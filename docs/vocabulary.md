# Vocabulary

Status: **Reviewed, no outstanding notes** (PR #4, 27-07-2026) — formally ratified by Phase 0 of the
[capabilities migration plan](capabilities-migration-plan.md), which is also when `CLAUDE.md` starts
pointing here. Use this language now; Phase 0 is the paperwork, not the argument.

Shared words, so a review argument is about the design and not about which thing someone meant.
The **collisions** table is the load-bearing part — those are words already used for two or three
different things *in this repo today*.

---

## 1. Exposure: service · supporting primitive · cross-cutting

Three classes describing **who is allowed to call a capability**. Recorded per capability as its
`visibility` (§1 roster + catalog entry).

| Term | Means | Rule |
|---|---|---|
| **service** | An intention the system pursues. The only thing a framework loop may command. | `ops-change`, `ops-release`, `ops-integrate` |
| **supporting primitive** | Domain mechanics owned and wrapped by a service. Never called by a loop. | `ops-branching`, `ops-workspace` |
| **cross-cutting** | A question (read) or a side-effect (infra). Callable from any layer. | `ops-repo-meta`, `ops-ci`, `ops-notify` |

Rule of thumb: **loops command services only · primitives are wrapped by a service · reads and
notifications are cross-cutting.**

> **"Service" is a metaphor, not machinery.** It does not mean a process, a daemon, a container,
> an HTTP endpoint, or anything that runs independently. Every capability is a skill invoked by
> name with `(action, context-json)` — identical mechanism regardless of visibility. The three
> classes are a *review convention* about exposure, enforced by reading the catalog, not by code.
> There is no new layer and no new runtime.

---

## 2. Capabilities

| Term | Means |
|---|---|
| **capability** | A unit of variation the engine defers to, implemented as a skill named `ops-<capability>` and invoked by that name. Replaces the older "seam". |
| **action** | A verb a capability answers to — `ops-change · implement`. The second half of `(action, context-json)`. |
| **capability skill** | The skill implementing a capability. Either shipped by the engine (a *framework default*) or owned by the repo. |
| **capability catalog** | `catalog.json` (+ `catalog.schema.json`) — the normative declaration of every capability, its actions, its `visibility`, and a worked `example`. The single source of truth for the interface. JSON per the plan's §6.6. |
| **visibility** | The exposure class from §1, carried as a catalog field. |
| **framework default** | An engine-shipped implementation a repo inherits when it provides none. |
| **coverage** | Whether a repo satisfies the catalog. Per capability: **present** (repo ships it) · **inherited** (using the framework default) · **missing** (no implementation — `ops-install` reports it). |
| **example** | The normative sample in a catalog entry. Seeds both the installer's scaffold and the eval — one artifact, two consumers. |

---

## 3. Framework

| Term | Means |
|---|---|
| **engine** | This repo. Product-agnostic; ships framework loops, framework defaults, the catalog, the router. |
| **framework loop** | An engine-owned orchestrator triggered by an event, named from the reserved list: `ops-issue-loop`, `ops-merge-flow`, `ops-auto-release`, `ops-rework`, `ops-triage`. Commands services; never touches a primitive. |
| **framework mechanics** | Engine internals that are *not* a capability and cannot be overridden — e.g. forge mechanism (gh CLI vs GitHub MCP). |
| **edge router** | `loop-dispatch` — maps an inbound event to a framework loop. |
| **routing table** | The `{event, label, loop}` rows the router reads: a **base** table shipped by the engine ⊕ a per-repo **overlay**. Overlay wins; `loop: null` disables a row. |
| **event vocabulary** | The permitted event strings — `issues.labeled`, `issues.opened`, `pull_request.labeled`, `pull_request.opened`. |
| **caller workflow** | The workflow in a consumer repo that calls the engine's reusable dispatch workflow. |
| **routine** | A scheduled/triggered cloud run of a loop. The delivery vehicle, not the logic. |

---

## 4. Repos and roles

| Term | Means |
|---|---|
| **consumer** | A repo that uses the engine and supplies its own capability skills. |
| **applied repo** | A consumer once installed and covered. Interchangeable with consumer in practice; prefer **consumer**. |
| **role** | What a repo *is to* a loop, from `ops-repo-meta · topology`: `code`, `issues`, `learnings`. Replaces the old `repos.source` / `repos.inbox` keys. |
| **topology** | The set of roles and which repo fills each. Single-repo setups collapse every role onto `code`. |
| **identity** | Ambient facts about the repo itself (name, labels, defaults), from `ops-repo-meta`. |

---

## 5. Branches

Post-migration these values are **private to `ops-branching`** — the vocabulary exists so we can
discuss them, not so callers can read them.

| Term | Means |
|---|---|
| **integration branch** | The branch feature work targets. Was `branching.base`. Prefer this phrase over "base" when talking about the concept. |
| **release base** | The branch releases land on; a PR into it is the release path, owned by `ops-release`. Was `branching.release_base`. |
| **line** | A version's pair of branches — `vN/dev` + `vN/main`. A repo can have several **live** at once, so "the integration branch" is a *set*, and the wrong-base gate tests membership. |
| **primary line** | The line work starts on before being ported. **Not** necessarily the newest line or the default branch — a declared `ops-repo-meta` fact. |
| **port** | Moving a landed change to another live line. **Forward-port** = to a newer line, **back-port** = to an older one. One logical change → one PR per line, each landing on its own. Not a mechanical cherry-pick: a port may need adapting, so it gets its own verify and CI. |
| **merge strategy** | `squash` or `merge-commit`. Chosen *inside* `ops-branching · merge`; no caller passes it. |
| **branch model** | `gitflow` · `main-only` · `versioned-gitflow` · `custom`. Knowledge internal to `ops-branching`, no longer a config enum. |

---

## 6. Collisions — words that already mean two things here

Qualify these every time, or use the ruling.

| Word | Meaning A | Meaning B | Ruling |
|---|---|---|---|
| **action** | GitHub webhook action — `route-map.json`'s `"action": "labeled"` | Capability action — `ops-change · implement` | Phase 2 removes A by folding it into the **event vocabulary** (`issues.labeled`). After that, "action" means B only. |
| **catalog** | **Capability catalog** — `catalog.json`, the capability/action interface | **Operation catalog** — `operation-catalog.json`, the github-ops provider interface | Always qualify. Never bare "the catalog" in a doc that touches both — and note both are now JSON, so the extension doesn't disambiguate them. |
| **operation** | A github-ops primitive invoked by name — `get-ci-status`, `merge-pr` | — | An **operation** is a forge/CI primitive; an **action** is a capability verb. Never interchange them. |
| **provider** | **CI provider** — `github-checks` / `azure-pipelines` | **Forge** — gh CLI vs GitHub MCP | Say "CI provider" or "forge". Bare "provider" is what produced the `ci.provider`/`ci_provider` split. |
| **skill** | An engine skill | A repo-owned capability skill | Qualify: *framework loop*, *framework default*, or *repo-owned*. |
| **loop** | A framework loop (the artifact) | "the loop" meaning the whole automation | Use **framework loop** for the artifact. |
| **base** | The integration branch | A PR's `base` field as GitHub reports it | Use **integration branch** for the concept; reserve `base` for quoting the API field. |
| **service** | Exposure class (§1) | A running process / microservice | Only ever A here. See the callout in §1. |

---

## 7. Retired terms

Replaced by this model. If you see them, they predate the migration.

| Retired | Replaced by |
|---|---|
| **seam** (as "a config pointer or a data+schema file") | **capability** |
| **override / defer** (same-name shadowing, config pointers) | **convention** — a capability is found by its `ops-<capability>` name |
| **`playbook`** (the build-skill pointer) | `ops-change` |
| **`branching.release_skill`** (the release-skill pointer) | `ops-release` |
| **`ci.provider` / `ci_provider`** | internal to `ops-ci` |
| **`branching.base` / `merge_strategy`** as config | private to `ops-branching` |

Note: **seam** survives in one narrow sense — a *data + schema* extension point such as the
routing table or the operation catalog. Those remain data seams and are not capabilities.
