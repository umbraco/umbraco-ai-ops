<!--
  Converted copy of a design artifact shared with the team, committed per Phase 0 of
  docs/capabilities-migration-plan.md so the plan's citations resolve in-repo.

  Source (authoritative): https://claude.ai/code/artifact/9003d71b-999c-43a2-aa86-d994889f2a57
  Layer 2 of 3 — the normative conformance specification.
  Converted 27-07-2026 from the artifact's HTML; structure is plain prose and converted cleanly.

  This document is NORMATIVE. Where this repo deliberately diverges from it, that divergence
  is recorded in docs/capabilities-migration-plan.md §9 — not by editing this file.
-->

# Ops Capability Skills — Conformance Specification

**Status:** Draft · **Layer:** 2 of 3 (normative) · **Repo:** `umbraco-mcp-ops`

**Companions:** Layer 1 — *Ops Capability Skills* (informative explainer, the "why"). Layer 3 — reference skills + scaffolder templates (`ops-release`, `ops-repo-meta`, catalog).

## Status of this document

This is the **normative** contract. It pins the **interop frame** only — how a capability is named, invoked, and answers; how the catalog, routing, and topology are shaped; and what the framework loops, router, and installer may rely on.

It deliberately does **not** specify capability *behavior* or enforce *payload shapes*. Those are informative (described in the catalog) and verified by **evals**, per the project's design decision. Where this spec says a field is "guidance," it means non-normative.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, **MAY** are to be interpreted as in RFC 2119.

## 1. Terminology & conformance targets

- **Capability** — a named area of repo-specific behavior (e.g. `release`, `change`, `ci`).

- **Capability skill** — a standard Claude Code skill implementing one capability, named `ops-<capability>`, provided by a consuming repo.

- **Action** — a named operation a capability delegates (e.g. `release` → `plan`, `cut`).

- **Framework skill** — a skill shipped by `umbraco-mcp-ops` (the loops, the installer). Generic.

- **Loop** — a framework skill that orchestrates work and invokes capability skills.

- **Router** — the edge component (`route-event.sh`) that maps a GitHub event to a loop.

- **Catalog** — the framework's declaration of capabilities, actions, and example inputs.

- **Routing config** — the event→loop table; **framework base ⊕ per-repo overlay**.

- **Edge** — the GitHub Actions context where the router runs, with no Claude session.

**Conformance targets** (each has its own clauses in §8): a *capability skill*, the *catalog*, the *routing config*, the *router*, the *installer*.

## 2. Skill naming (normative)

2.1 A capability skill's name **MUST** match `ops-<capability>`, where `<capability>` matches `[a-z][a-z0-9-]*`.

2.2 `<capability>` **MUST** be one of the capabilities declared in the catalog (§5). A repo **MUST NOT** introduce a capability skill for a capability absent from the catalog.

2.3 Framework skill names (`loop-dispatch`, `ops-install`, and the core loops `ops-issue-loop`, `ops-merge-flow`, `ops-auto-release`, `ops-rework`, `ops-triage`) are **reserved**. A consuming repo **MUST NOT** define a skill with a reserved name unless it intends to *shadow* that framework skill (§6.6).

2.4 A capability skill **SHOULD** set `disable-model-invocation: true`. Loops invoke it by name; it is not meant to auto-trigger from a `description` match.

## 3. Invocation contract (normative)

3.1 A loop invokes a capability skill as a standard skill with two positional arguments: `action` (`$1` / `$action`) and `context` (`$2` / `$context`).

3.2 `action` **MUST** be one of the actions the catalog declares for that capability.

3.3 `context` **MUST** be a single JSON object encoded as a string. The skill **MUST** parse it as JSON. An absent context **MUST** be treated as `{}`.

3.4 A capability skill **MUST** reject an `action` it does not implement — it **MUST NOT** silently succeed or guess. It **SHOULD** report the rejection using the result convention (§4).

3.5 A capability skill **MUST** be idempotent per action: invoking the same action twice with the same context **MUST NOT** produce a second side effect (e.g. `cut` re-run **MUST** return the existing PR, not open a second).

## 4. Result convention (recommended)

The consumer of a capability action is a **model** (a loop), not a deterministic parser. So this section is a **convention (SHOULD)** verified by evals (§9) — *not* an enforced contract. Promote it to a MUST only where §4.5 applies.

4.1 An action **SHOULD** return the facts the next action needs, so an action-to-action handoff (e.g. `plan → cut → publish`) stays lossless.

4.2 An action **SHOULD** make success versus failure **unambiguous**. The recommended shape is a single JSON object ending the output: `{"ok": true, ...facts...}` on success, `{"ok": false, "detail": "..."}` on failure. `detail` explains the failure in plain language; there is **no** required error vocabulary.

4.3 A failed action **MUST** leave the system in a safe state — no partial publish, no dangling branch it created and cannot resume. (A behavioral safety invariant, not an output-shape rule, so it stays a MUST even though the shape is a SHOULD.)

4.4 **Data-capability carve-out.** For a *data* capability (e.g. `repo-meta`), structured output is not an imposed envelope — it *is* the deliverable, so such a capability **MUST** return well-formed structured data for each action.

4.5 **When to enforce a strict envelope.** Promote §4.1–4.2 to a MUST for a given capability **only if a non-model consumer** (a shell step, the router, a deterministic pipeline) parses its output. None does today — the loops are model-driven — so nothing is enforced now; revisit per capability if that changes.

```
// recommended shape — a convention, not enforced
{ "ok": true,  "prNumber": 987, "headBranch": "v18/release/2026.07.3" }
{ "ok": false, "detail": "dev branch has un-synced commits" }
```

## 5. The catalog (normative structure; payload contents guidance)

5.1 The catalog **MUST** live in the framework repo, one entry per capability, in a machine-readable form (YAML or JSON) with the keys below.

5.2 Each capability entry **MUST** declare: `capability` (string), `description` (string), and `operations` (a non-empty list).

5.3 Each operation **MUST** declare: `action` (string, matches `[a-z][a-z0-9-]*`), `description` (string), and `example` (a context object used by the installer's scaffolder and as an eval seed). Each operation **SHOULD** declare `input` and `output` field lists.

5.4 The `action` names in the catalog are **normative** — they are the invocation contract (§3.2) and the validation set (§3.4). The `input`/`output` field lists are **guidance**: they inform scaffolding and evals and **MUST NOT** be enforced at runtime.

```
capability: release
description: Cut and ship a release for this repo.
operations:
  - action: plan
    description: Turn the trigger into release facts.
    input:  { trigger: object }                          # guidance
    output: { branch: string, baseBranch: string, units: array }   # guidance
    example: { trigger: { versionText: "release 18.0.0-beta.3" } }  # normative: seeds scaffold + eval
  - action: cut
    description: Branch, bump, changelog, open the release PR.
    output: { prNumber: integer }
    example: { plan: { branch: "v18/release/2026.07.3", units: [] } }
```

## 6. Routing config (normative)

6.1 A routing rule is an object `{ "event": string, "label": string, "loop": string }`.

6.2 `event` **MUST** be from this vocabulary: `issues.labeled`, `pull_request.labeled`, `issues.opened`, `pull_request.opened`. `pull_request_target.labeled` **MUST** be normalized to `pull_request.labeled`. Additional events **MAY** be added to the framework vocabulary; a repo **MUST NOT** invent event strings outside it.

6.3 The effective routing config is **framework base ⊕ per-repo overlay**. The base ships with the framework; the overlay lives in the per-repo caller workflow.

6.4 **Merge/override semantics.** A rule's identity key is the pair `(event, label)`. An overlay rule **MUST** override a base rule with the same key (overlay wins). An overlay rule with `"loop": null` **MUST** disable (remove) the matching base rule. Keys present only in one source are included as-is.

6.5 **The router MUST:** normalize the event (6.2); select the single rule matching `(event, label)` from the effective config; if none matches, produce no route (a no-op — the routine is not fired); otherwise invoke the named `loop`. The router **MUST NOT** invoke more than one loop per event.

6.6 Every `loop` named in the effective config **MUST** resolve to an installed skill (framework core loop or a repo-provided loop skill). A repo-provided loop skill named identically to a core loop **shadows** it. The installer validates this (§8).

6.7 The router runs at the **edge** with no session and **MUST NOT** depend on invoking any skill to resolve a route.

## 7. Topology & roles (normative)

7.1 `ops-repo-meta`'s `topology` action **MUST** return `{ "repos": { <role>: "<owner>/<repo>" } }`.

7.2 Canonical roles: `code` (required), `issues`, `releases`. An unspecified role **MUST** resolve to `code`. Thus a single-repo project returns only `code` and every role collapses to it.

7.3 Operation → role resolution is normative:

| Operation class | Role |
|---|---|
| Read/label/close issues; the `auto-release` trigger issue | `issues` |
| Branch, push, PR, CI status, PR labels, merge, tag | `code` |
| Publish / release realization | `releases` |

7.4 **Cross-repo close.** When `issues` ≠ `code`, GitHub closing keywords do not auto-close across repos. The `change` capability **MUST** explicitly close and label the issue on the `issues` repo after merge; it **MUST NOT** rely on a `Closes #N` keyword to do so.

7.5 The `loop-dispatch` caller workflow **MUST** be installed on every repo that emits events the router consumes — in a split topology, on both the `issues` and `code` repos.

## 8. Conformance clauses

**A capability skill is conformant iff** it satisfies §2.1, §3.2–3.5, and §4.3 (safe-on-failure), and implements exactly the actions the catalog declares for its capability. §2.4 (`disable-model-invocation`) and the §4 result convention (§4.1–4.2) are **SHOULD**s — recommended, not required for conformance.

**The catalog is conformant iff** it satisfies §5.1–5.3 and declares an `action` set and `example` for every operation.

**A routing config is conformant iff** every rule satisfies §6.1–6.2 and every `loop` resolves to an installed skill (§6.6).

**The router is conformant iff** it satisfies §6.5, §6.7, and the merge semantics §6.4.

**The installer is conformant iff** it: (a) reports each catalogued capability as present / inherited / missing by matching `ops-<capability>` skill names; (b) validates the routing overlay against §6; (c) scaffolds a standard capability-skill stub for each missing capability from its catalog entry.

## 9. Explicitly non-normative

The following are **out of scope** and **MUST NOT** be treated as conformance requirements:

- Capability *behavior* and the correctness of an action's work (covered by evals).

- Result/payload shapes — the §4 result convention is a SHOULD verified by evals, and catalog `input`/`output` are guidance; neither is a validated contract.

- Loop orchestration internals (fan-out, model tiering, review loops, backstops).

- The internal structure of a capability skill (references/scripts layout, how it delegates).

- Notification, workspace, and build mechanics (repo-specific, delegated to capabilities).

---

*Follow the naming, the catalog format, the routing rules, and the role vocabulary, and an implementation is interoperable. The result convention and everything else are behavior — recommend them, and test with evals.*
