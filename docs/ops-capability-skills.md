<!--
  Converted copy of a design artifact shared with the team, committed per Phase 0 of
  docs/capabilities-migration-plan.md so the plan's citations resolve in-repo.

  Source (authoritative): https://claude.ai/code/artifact/4a1ecf91-6009-452d-8484-dd72438dce74
  Layer 1 of 3 — informative explainer. Owners: AI team (Phil, Matt).
  Converted 27-07-2026 from the artifact's HTML.

  CONVERSION CAVEAT: the source is a designed page, so text that sat in side-by-side
  diagram panels is flattened into run-together lines here (notably the §02 skill lists,
  the §05 catalog summary, and the §08 sample coverage report). The wording is verbatim;
  only the visual grouping is lost. Consult the artifact when layout matters.
-->

Ops Capability Skills AgreedSolutionUmbraco MCP · Ops

# Ops Capability Skills

Every seam is a standard skill. Generic framework loops delegate each repo-specific step to a per-repo *capability* skill; a data-driven router wires labels to loops from a base template plus a project overlay; a catalog and an installer keep coverage honest, and evals test behavior when we want it.

Target**umbraco-mcp-ops** Unita standard skill Bindingconvention — **ops-<capability>** OwnersAI team · Phil, Matt §01

## The decision

Skills all the way — no bespoke handler format, no contract frontmatter, no compiler. The design earns its keep through encapsulation and uniformity, and leans on two things the team's instincts already reached for.

- **Everything is a standard skill.** Normal `name` + `description`, standard `SKILL.md`, bundled `references/` and `scripts/` — nothing the marketplace doesn't already understand.

- **Convention is the binding.** A skill's name is the namespaced capability, `ops-<capability>`. A loop reaches a seam by invoking that skill by name — no frontmatter to key on, no collision with a repo's own skills.

- **Coverage, not correctness, is checked statically.** An installer skill proves the capability skills exist; evals probe whether they behave. Cost is not a factor.

The trade, said once

There's no compiler here. The installer proves a skill *exists*; an eval probes whether it *behaves*; a skill that quietly returns the wrong shape is caught at runtime or by an eval, never statically. That's the deliberate cost of the all-skills encapsulation — and it's internally consistent.

§02

## Two kinds of skill

The whole architecture rests on one split. Both are standard skills; they differ only in who owns them and how generic they are.

Framework · ships in the ops repo

Generic and project-agnostic. The **loops**, the **router**, the **installer**.

ops-issue-loop · ops-merge-flow ops-auto-release · ops-rework · ops-triage loop-dispatch · ops-install Capability · implemented per repo

The **seams** — everything that varies by repo. A project's real work lives here.

ops-release · ops-change · ops-ci ops-branching · ops-workspace · ops-notify ops-learnings · ops-repo-meta The load-bearing idea

The framework loops are reusable *because* they delegate every repo-specific step to a capability skill. `ops-issue-loop` doesn't know how your repo builds — it calls `ops-change`. So a project gets the loops unmodified and supplies only its capability skills. The rest of this spec is just the shape of that delegation.

One thing is deliberately *not* a skill: the **routing config**, which runs at the CI edge before any session exists. It lives in the GitHub Actions YAML — the single justified exception (§06).

§03

## The capability skill — one per capability, delegating actions

A loop talks to a *capability*. The capability skill is the single door; it fans out to its own actions internally.

ops-issue-loop → ops-release (skill) → plancutpublishsync

Standard skill layout, standard frontmatter, action passed as an argument:

skills/ops-release/ # namespaced: ops-<capability> ├── SKILL.md # reads $action ($1), delegates to a procedure below ├── references/ # plan.md, cut.md, publish.md, sync.md — one per action ├── scripts/ # helpers actions call (build, tag-verify, action guard) └── schema/ # example I/O — installer + eval seeds, not enforced skills/ops-release/SKILL.md — standard fields only

```
---
name: ops-release
description: Cut and ship a release for this repo. Actions: plan, cut, publish, sync.
argument-hint: [action] [context-json]
arguments: [action, context]
disable-model-invocation: true      # the loop invokes it by name; never auto-fire
---
Read $action and delegate:  plan → references/plan.md · cut → references/cut.md · …
Reject an unknown $action. Emit one JSON object for the action (shape in schema/).
```

**Standard fields only, no bespoke contract.** `description` (+ optional `when_to_use`) is the native prompt hint — it drives the installer's discovery and the catalog and lists the actions; it isn't used for triggering here. The action and context ride in on `arguments` (`$action` / `$context`). `argument-hint` is only a `/`-menu display string with no parsing — it does nothing for programmatic invocation. And `disable-model-invocation: true` makes the loop the only caller.

Where validation lives

No frontmatter enforces anything, so validation is logic. **The action name** is guarded in the skill body (or a bundled `scripts/` guard for hard determinism) — an unknown `$action` returns an error. **The payload shape** is *not* runtime-checked; that's the schema we moved to guidance + evals. Guard the verb; leave shape to evals.

§04

## How the loops call it

Convention over configuration: the capability name is the address. The loop invokes `ops-<capability>` with an action + context; the skill delegates. Model in the loop every time, by design.

before · repo-aware prose

"Bump the repo's version-file list (from its `CLAUDE.md`) and the changelog — use the repo's own release skill if it has one (e.g. `umbraco-mcp-skills:release`)."

after · a capability skill

Invoke `ops-release cut` with the plan as context. It delegates to this repo's cut procedure and returns `{ prNumber }`.

The loop stays agnostic — it knows the `release` capability has a `cut` action, nothing about how this repo cuts. Discovery is "is a skill named `ops-release` installed?" — a list-and-match.

§05

## The catalog — guidance, not a contract

What used to be "interfaces" is now a plain doc in the ops repo: the capabilities, the actions each delegates, a prose description, rough in/out, and an example input. Two consumers — the installer (what to cover) and eval seeds. Nothing here validates a running skill.

releasecut & ship a release plan→ branch, units[] cut→ prNumber publish→ tags[] sync→ syncedTo changebuild one change to green implement→ prNumber verify→ passed, logs close-issue→ ok (cross-repo, §07) ciis CI green for a ref status→ green|pending|failed branchingthe repo's branch model resolve-base→ branch merge-strategy→ merge|squash workspaceisolated build env prepare→ path, branch teardown→ ok notifytell a human sendin {text, level} repo-metaambient repo facts identity→ {…} labels→ {…} topology→ role→repo map (§07) learningsroute a proto-learning route→ home file→ ref

Blue = behavioral capabilities (a loop calls their actions); green = data capabilities (ambient facts). All are still just `ops-<name>` skills. (Routing isn't here — it's edge config, not a skill; §06.)

§06

## Routing & the core-loop template

Routing is the one deliberate exception to "everything is a skill." It runs at the GitHub Actions edge, in bash, before any session exists — so its config lives in the Actions YAML where the edge reads it, not in a skill that would have to be materialized back down.

- **`loop-dispatch` / `route-event.sh` (framework):** a generic, table-driven router — given an event it finds the matching rule and invokes that loop. Knows no specific labels or loops.

- **Base** ships with the framework: bundled beside `route-event.sh`, versioned by the `@ref` the caller pins, so improvements propagate on a ref bump with no re-install.

- **Overlay** lives in the per-repo caller workflow — an input block, or a committed `.github/ops-routing.yml` it passes.

- `route-event.sh` **merges base ⊕ overlay live at the edge** — both halves are already there. No skill, no materialization, no drift.

resolved live at the edge — framework base ⊕ caller-workflow overlay

```
[ { event: "issues.labeled",       label: "ready-for-ai", loop: "ops-issue-loop" },   # base
  { event: "pull_request.labeled", label: "auto-merge",   loop: "ops-merge-flow" },   # base
  { event: "issues.labeled",       label: "needs-triage", loop: "acme-triage-loop" } ] # overlay ← custom
```

### The base template

The framework ships the core loop skills *and* a base routing table wiring the standard labels to them. A fresh repo gets working automation out of the box; the core loops are shareable precisely because they delegate repo-specifics to capability skills (§02). A project customizes by overlay: **add** a row (new custom loop), **override** a row (reroute a label to a custom loop), **disable** a row, or — rarely — **shadow** a core loop with a same-named skill.

**Skills author it; they don't store it.** A loop-scaffolding skill (the repo's `new-loop-routine`, evolved) writes the overlay row into the caller YAML when you add a custom loop — ergonomic authoring, edge-natural storage. `/ops-install` then validates the overlay: well-formed, and every `loop:` it names resolves to an installed skill.

Why the exception is cheap

Everything the loops invoke *at runtime* is a skill; the one thing that runs *before* a session — the edge router config — lives at the edge. That's the philosophy correctly scoped, and it's less code than a routing skill plus a materialization step. "CI wiring lives in the CI config" is about the least surprising exception you could pick.

§07

## Topology — one project, many repos

"The repo" isn't always one place. Some projects keep code + PRs in a private repo and issues on a public one. That variation is contained entirely in `repo-meta`: `topology` returns a **role → repo map**, and every GitHub op resolves its target by role.

ops-repo-meta topology — roles, not one identity

```
{ "repos": {
    "issues":   "umbraco/Foo",          # public — ready-for-ai lives here
    "code":     "umbraco-private/Foo",  # private — branches, PRs, CI, tags
    "releases": "umbraco-private/Foo" } }
```

- **issues repo:** gather `ready-for-ai`, swap labels, close on done, the `auto-release` trigger issue.

- **code repo:** branch, push, PR, `ci/status`, `auto-merge`/`auto-rework` PR labels, merge, tag, publish.

Gotcha · cross-repo auto-close

GitHub's closing keywords only auto-close an issue in the *same* repo as the PR — so `Closes #N` won't fire across a public/private split. The `change` capability must **explicitly close + label the issue on the issues repo after merge** (its `close-issue` action), not lean on the keyword. And the `loop-dispatch` caller workflow installs on *both* repos — the installer materializes issue-label rules to the public repo, PR-label rules to the private one.

§08

## The installer skill

`/ops-install` is the coverage check and the wiring step — not a compiler.

1. Read the catalog — the capabilities each repo should provide.

2. List installed skills; match by convention name → **present** / **inherited** (framework default) / **MISSING**.

3. **Validate the routing overlay** in each repo's caller workflow — well-formed, and every `loop:` it names resolves to an installed skill. (Routing lives in the Actions YAML, not a skill — §06; the installer checks it, doesn't own it.)

4. **Scaffold** missing capabilities — generate a standard capability-skill stub from the catalog entry, for a human to finish.

/ops-install — coverage report Capability skills ops-ci ✓ ops-notify ✓ ops-repo-meta ✓ ops-workspace ✓ ops-branching ✓ ops-change ✓ present · mentions: implement, verify, close-issue ops-release ✗ no skill named `ops-release` installed routing overlay ✓ valid · 1 custom rule → acme-triage-loop (skill present) 1 capability missing · run /ops-install --scaffold to generate an `ops-release` skill stub §09

## Evals — the only behavioral test

When we want confidence a capability skill does its job, we run an eval — not a schema replay. Per capability, a small suite seeded from the catalog's example inputs, LLM-judged against the described output. Opt-in, run on demand; cost is explicitly not a concern.

The catalog's example inputs earn a second use here: the guidance that tells the installer what to scaffold is the same fixture that seeds the eval. One doc, two jobs.

§10

## Why it holds together

- **Uniform** — everything is a standard skill, the native marketplace unit. No mix of scripts, prompts, and JSON.

- **Encapsulated** — a capability and all it needs ship as one versioned skill; actions delegate inside it.

- **Agnostic** — loops bind to a capability name and an action, never to how a repo implements it, which repos it spans, or which loops it runs.

- **Extensible** — custom loops are an overlay row plus a skill; no framework fork, and the base template stays updatable.

- **Self-checking at the level that's possible** — installer guarantees coverage; evals guarantee behavior on demand.

It resolves to the two things the team's instincts kept pointing at: **convention over configuration** (the namespaced skill name is the binding) and **an installer that ensures every seam is implemented** (the original ask).

First build

Stand up `ops-release` + `ops-repo-meta` first — behavioral and ambient-data — then write `/ops-install` against the catalog. Routing rides in the caller workflow (base from the framework, overlay per repo, live-merged); a loop-scaffolder skill writes overlay rows. The other capabilities and core loops follow from there.

Ops Capability Skills · Agreed solutionumbraco-mcp-ops
