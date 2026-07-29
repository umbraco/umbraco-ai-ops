# CLAUDE.md

Guidance for working in **umbraco-ai-ops** — the generic engine for AI-driven issue
automation across Umbraco products. See `README.md` for the what/why; this file is the
**conventions** every plugin follows. Shared terms are defined in
**[`docs/vocabulary.md`](docs/vocabulary.md)** — use that language, and read its
**collisions** table before arguing about a word (`action`, `catalog`, `provider` and `base`
each already mean two things here).

## Golden rule: the engine is product-agnostic

Nothing here may hard-code one product's facts, toolchain, or branching. Product-specific
behaviour is supplied by the **consumer** — its own repo's `.claude/skills/` — as **capability
skills**: one skill per unit of variation, named `ops-<capability>`. (One shared skill serving a
whole repo family is **deferred, not supported**: see the plan's §6.10. Assume one repo.) If you find yourself writing `npm`, an MCP reference, a specific
product name, or a specific branching rule in an engine skill, it belongs in a
**capability**, not the engine.

## Convention, not configuration (how a repo customises the engine)

A capability is found by its **name**. There is no pointer, no registry, no slot to inject
into, and no frontmatter to key on:

- **A capability is a skill named `ops-<capability>`** (`[a-z][a-z0-9-]*` after the prefix) —
  `ops-change`, `ops-release`, `ops-ci`, `ops-branching`, and the rest.
- **A loop reaches one by invoking that name** with two positional arguments, `action` and
  `context`. `context` is a **single JSON object encoded as a string**; an absent context is
  `{}`. An action the capability doesn't implement is **rejected**, never guessed at and
  never silently succeeded.
- **The capability catalog declares the interface** — [`catalog.json`](catalog.json): which
  capabilities exist, which actions each answers to, and a worked `example` per action. The
  **action names are normative** (they are the validation set a skill rejects against); the
  `input` / `output` lists are guidance and must never be enforced at runtime. A capability skill
  for a capability the catalog doesn't declare is illegal.
- **Only `ops-change` and `ops-release` are always the repo's.** The rest ship as **framework
  defaults** the repo *inherits*, and overrides by shipping its own skill of that name.
- **Capability skills MUST NOT set `disable-model-invocation`.** That flag reads like "only a
  loop may call this". It is not: it blocks the **Skill tool outright**, for the model and for
  subagents, so a loop cannot call the capability either. A live routine proved it
  (29-07-2026) — `Skill ops-change cannot be used with Skill tool due to
  disable-model-invocation` — and the loop silently fell back to reading the SKILL.md off disk
  and following it as prose. That looks like it worked and is not invocation at all: no
  arguments in, no result out, and no unknown-action rejection, because none of those exist
  without a call boundary. Enforced by `scripts/validate-capability-skills.sh`.
  - What the flag was there for — a capability auto-firing on a `description` match — is now a
    **sentence in the description**: every capability ends with *"NOT for direct use — never
    select it from a description match."* Weaker than a flag, and the only option that leaves
    the capability callable, which is the whole engine.
  - **Loops and `ops-install` are the opposite case** and keep the flag: a human invokes those
    deliberately, and auto-firing a loop is a real hazard. The validator ignores them.
- **Framework loops are named `ops-<noun>-loop`** — `ops-issue-loop`, `ops-merge-loop`,
  `ops-port-loop`, `ops-release-loop`, `ops-rework-loop`, `ops-triage-loop`. The suffix is what keeps a loop
  out of the capability namespace, so `ops-release-loop` can never collide with the
  `ops-release` capability. **`loop-dispatch`** (the edge router, bash at the CI edge) and
  **`ops-install`** (the installer, invoked by a human) are exempt: neither is a loop.
- **Who may call what is recorded, not enforced.** Each capability carries a `visibility` —
  `service` (a loop may command it), `supporting` (wrapped by a service, **never** called by
  a loop), `cross-cutting` (callable from any layer). Held by review reading the catalog, not
  by code.

Why name-based and not same-name shadowing: skills do **not** cleanly shadow across delivery
mechanisms — plugin skills are namespaced, project skills are not, and cloud delivers both
flat into overlapping locations with undocumented precedence. Convention-by-name sidesteps
that, but it also means an engine skill and a repo skill **must never share a name unless the
repo means to replace it**.

> **There is no central config.** The engine used to bind through `.claude/ai-ops.yml`
> pointers (`playbook` → build skill, `branching.release_skill` → release skill). That file, its
> schema and its example are **deleted**. If you find yourself wanting a config key, the answer
> is a capability — see
> **[`docs/capabilities-migration-plan.md`](docs/capabilities-migration-plan.md)**.
>
> `.claude/ops-repo-meta.json` is **not** that file returning. It is a strict subset: only facts
> nothing can detect and nothing else owns (which repo holds issues, which lines are live, which
> is primary, label overrides). Its schema sets `additionalProperties: false` at every level, so
> putting a branch name, a CI provider or a skill pointer back fails loudly.

## Data seams are data + schema, never prose

**"Seam" now means one narrow thing: a data + schema extension point.** What a consumer
*implements* is a capability (above). What a consumer *declares* is a seam — a JSON data file
plus a `*.schema.json` describing its shape, read by a script or named by a skill. The engine
ships the default data; a consumer overrides by shipping its own file of the same shape —
**never by editing an engine skill**. Current seams:

| Seam | Data | Schema |
|------|------|--------|
| **Capability catalog** (which capabilities exist, their actions, `visibility`) | `catalog.json` | `catalog.schema.json` |
| Event → loop routing, framework **base** | `loop-dispatch/.../scripts/route-map.json` | `route-map.schema.json` |
| Event → loop routing, **per-repo overlay** (merged over the base at the edge) | `<consumer>/.github/ops-routing.json` | `loop-dispatch/.../scripts/ops-routing.schema.json` |
| **Declared repo facts** (topology, live lines, label overrides) | `<consumer>/.claude/ops-repo-meta.json` | `ops-capabilities/.../ops-repo-meta.schema.json` |
| GitHub/CI provider interface | `github-ops/.../operation-catalog.json` | `operation-catalog.schema.json` |

When you add a seam, follow the same pattern (data file + schema alongside the code that
reads it) and document it here.

## Plugin & skill folder layout

```
plugins/<plugin>/
  .claude-plugin/plugin.json         # manifest (see below)
  agents/<agent>.md                  # optional subagent definitions
  skills/<skill>/
    SKILL.md                         # the skill (frontmatter: name, description)
    references/<topic>.md            # supporting reference docs
    scripts/                         # ALL executable scripts + their data + tests
      <name>.sh                      # a script
      <name>.test.sh                 # its test, ALONGSIDE (see below)
      <name>.json / <name>.schema.json   # data + schema a script reads
```

### Scripts and tests

- **Scripts live in the skill's `scripts/` folder** — not loose in the skill root.
- **Tests live alongside the script they test, named `<script>.test.<ext>`** (e.g.
  `route-event.sh` → `route-event.test.sh`). **Do not** use a separate `test/` folder.
- A script that reads a data file resolves it **relative to its own location** (so the
  script + its data move together), with an env override for a consumer's custom file.
- Keep tests **hermetic** — no network, no `gh`, no `claude`; `bash` + `jq` only.

Repo-wide shared scripts (not tied to one skill) live in the top-level `scripts/`.

## Manifests

- Every plugin has `.claude-plugin/plugin.json`; it must be declared in
  `.claude-plugin/marketplace.json` with a matching `name`, `version`, and description.
- `author`: `{ "name": "Umbraco", "url": "https://github.com/umbraco" }`.
- `homepage`: `https://github.com/umbraco/umbraco-ai-ops/tree/main/plugins/<plugin>`.
- `license`: `MIT`. Validate with `jq empty` before committing.

## GitHub / CI work

All GitHub and CI operations go through the **`github-ops`** skill by operation **name** —
never a raw `gh`/`curl` in another skill. The forge (gh vs GitHub MCP) and the CI provider
(`github-checks` vs `azure-pipelines`) are resolved there. Adding a provider = implementing
the `operation-catalog.json` operations for that axis; no loop changes.

An **operation** is a forge/CI primitive (`merge-pr`, `get-ci-status`); an **action** is a
capability verb (`ops-change · implement`). Never interchange them. Phase 3 splits the CI axis
out as the `ops-ci` capability; the forge mechanism stays framework mechanics and is not
overridable.

## A gate that cannot run reports blocked, never pass

If a check cannot execute — the agent will not spawn, the tool is absent, the credential is
missing, the skill came back as text instead of running — the answer is **blocked**, with the
reason. Never a pass, and never a quiet downgrade to a weaker check reported in the same words
as the real one.

The prototype learned this the expensive way: its review skills set
`disable-model-invocation: true`, a headless subagent received them as **inert text** rather
than executing them, and PRs reported a passed review that had never happened
(`hifi-phil/umbraco-mcp-ops` PR #39). Nothing failed, so nothing was investigated.

Two rules follow:

- **Anything that must run inside a subagent or a headless routine is an `agent`, not a
  skill.** Spawning an agent definition is the mechanism that works there. Our one reviewer,
  `release-reviewer`, is an agent for this reason; keep it that way and add new ones the same
  way. `cloud-skill-sync.sh` delivers `plugins/*/agents/*` for exactly this.
- **Never self-review.** A gate performed by the same model that produced the thing being
  gated is not a gate. If the independent reviewer is unavailable, block.

> **Answered, the hard way.** This used to sit here as an open question: does
> `disable-model-invocation` block an *explicit* invocation, or only auto-firing on a
> description match? A live routine settled it on 29-07-2026 — it blocks everything, so no
> loop could command any capability. The flag is now banned on capability skills (see the
> rule under *Convention, not configuration* above) and
> `scripts/validate-capability-skills.sh` keeps it out.
>
> **Keep the shape of that mistake in mind.** It survived the entire build because the failing
> path *looked* like the working one: the loop read the skill off disk and produced a good PR.
> Nothing errored, nothing was missing, and the contract was doing nothing at all.

## Labels are namespaced `ops/`

Every GitHub label the engine owns is prefixed **`ops/`** — `ops/ready-for-ai`,
`ops/in-progress`, `ops/generated-by-ai`, `ops/ai-blocked`, `ops/auto-merge`,
`ops/auto-rework`, `ops/auto-release`, `ops/release-blocked`, `ops/proto-learning`,
`ops/port`, `ops/triaged`, `ops/loop-improvement`. The prefix says at a glance that a label drives
automation, and keeps engine labels out of a repo's existing triage vocabulary.

**State and provenance are separate labels, deliberately.** `ops/in-progress` says a loop is
working an issue **now** and comes off when it stops; `ops/generated-by-ai` says a loop built
it, and stays on forever. They were one slot until a live routine read the slot name
`labels.in_progress`, found it pointed at the *finished* label, and invented `ops/in-progress`
for itself (29-07-2026). Do not merge them again: without the state label, an interrupted run
leaves an issue that looks untouched and cannot be found.

- **Enforced** for the base routing table: `route-map.schema.json` patterns `^ops/…` and
  `route-event.test.sh` asserts it.
- **A SHOULD** for a consumer's `.github/ops-routing.json` overlay — an overlay legitimately
  routes on labels the repo had before the engine arrived, and those names aren't ours.
- Third-party labels (`dependencies`, `javascript`) are never prefixed; they aren't ours.

When you add a label, prefix it, and add it to the list above.

**Keep the `auto-` names as they are.** With `ops/` in front, the `auto-` in `ops/auto-merge`
/ `ops/auto-rework` / `ops/auto-release` is arguably redundant, and shortening them to
`ops/merge` / `ops/rework` / `ops/release` was raised and **declined** (28-07-2026): the
labels are already live in people's heads and the churn buys nothing. Don't re-open it as a
tidy-up.

## Line endings

Scripts run on Linux routine/CI runners. `.gitattributes` forces `*.sh`/`*.yml` to **LF** —
keep it that way; never commit CRLF scripts.

## Before you commit

- `jq empty` every changed `*.json`.
- Run any touched skill's `scripts/*.test.sh`.
- **If you touched `catalog.json`:** run **all three** of `scripts/validate-catalog.sh`,
  `scripts/catalog-to-readme.sh` (regenerates the README's action table) and
  `scripts/build-evals.sh` (regenerates `evals/`). Never hand-edit the generated table or a
  suite — CI fails on drift in either.
- **If you touched the declared-facts schema:** run
  `plugins/ops-capabilities/skills/ops-repo-meta/scripts/validate-repo-meta.sh` against the
  example beside it. The schema is the readable contract; that script is the enforced one, and
  it also holds the rule JSON Schema cannot express (`primary` must be in `live`).
- **If you added, renamed or removed a plugin:** run `scripts/validate-manifests.sh`. A
  marketplace entry pointing at a directory that doesn't exist makes `/plugin marketplace add`
  fail for the **whole** marketplace, not just that entry.
- **If you touched a capability skill's frontmatter:** run
  `scripts/validate-capability-skills.sh`. It is the only thing standing between us and
  re-shipping the `disable-model-invocation` bug, whose symptom is a loop that *appears* to
  work.
- **Grep your change for product-specifics** (`npm`, `mcp`, a product name) — if present, it
  belongs in a **capability**, not in engine code.

The first two are enforced in CI by `.github/workflows/tests.yml`, which runs **every `*.test.sh`
in the repo** (skill tests under `plugins/`, engine-wide ones under `scripts/`) and `jq empty` on
every JSON, on each PR and push to `main` — keep it green. It's hermetic (`bash` + `jq` only): a
new test must not need network, `gh`, or `claude`. The other workflow,
`.github/workflows/loop-dispatch.yml`, is **runtime, not CI** — the reusable edge router consumers
call from their own caller workflow.

Everything generated from the catalog has a `--check` mode with a test asserting it, so the
catalog stays the single source: the README action table, and the eval suites.

## Evals are the only behavioural guard

There are no static types and no payload validation — the conformance spec makes that trade
explicitly. So `ops-install` can report **full coverage** for a repo whose capabilities are
wrong in every action, because coverage matches skill *names*. `evals/` is what checks
behaviour, and it is generated from the catalog's worked examples.

Running them needs `claude` and a real repo, so **they are opt-in and not in the CI gate** —
which is also why the runner is `scripts/run-evals.sh` and deliberately **not** named
`*.test.sh` — CI finds `*.test.sh` anywhere in the repo, so a runner named that way would join
the hermetic gate and fail on every machine without `claude`. Use `--list` and
`--plan <capability>` to inspect a suite without running it.
