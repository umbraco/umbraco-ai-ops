# Risk register

Standing risks to the engine that are **conditions we watch**, not work we do. A risk lives here
when it is something outside our control that could break the engine, and the only sane response is
to know the signal and re-check on a date.

**Rows are never deleted.** A closed risk keeps its row with its status changed and a date, because
a hazard that leaves no trace gets re-discovered from scratch.

**This is not the migration plan's hazard register.** [§7 of the
plan](capabilities-migration-plan.md#7-risk--hazard-register) is scoped to that migration, and every
row in it is closed or deferred by ruling. What belongs here instead is anything that outlives the
plan — chiefly the platform the engine runs on.

## What a row holds

| Field | Means |
|-------|-------|
| **Risk** | The condition, in one line. |
| **Impact** | What breaks if it fires. Be concrete about which part of the engine. |
| **Signal** | How we would know it fired. If there is no signal, say so — that is itself the finding. |
| **Status** | `open` · `mitigated` · `closed (DD-MM-YYYY)`. |
| **Review** | The date we re-check. Vendor-docs risks get a date, not a hope. |

Cite a source for every claim about someone else's platform. An unverified number goes in as
**unverified**, not as a fact.

---

## R1 — Routines are a research preview

| | |
|---|---|
| **Impact** | Web routines are the **main runtime** (`README.md`, *How a consumer links to the engine*). If the shape changes, `cloud-setup-stub.sh`, `cloud-skill-sync.sh` and every consumer's routine configuration change with it. There is no second runtime to fall back to. |
| **Signal** | None automatic. A run fails, or the docs page changes. |
| **Status** | **open** — accepted. We built on it deliberately; the prototype proved the model here. |
| **Review** | 31-10-2026, and on any routine failure we cannot explain. |

The docs are explicit: *"Routines are in research preview. Behavior, limits, and the API surface may
change."*
([Automate work with routines](https://code.claude.com/docs/en/routines))

**Partly mitigated for the API trigger only.** The `/fire` endpoint ships behind a dated beta header
(`experimental-cc-routine-2026-04-01`), and *"Breaking changes ship behind new dated beta header
versions, and the two most recent previous header versions continue to work so that callers have
time to migrate."* So an API-triggered break gives us two versions of warning. **Nothing equivalent
is promised for the routine configuration itself, the setup-script/environment contract, or GitHub
triggers.** That is where our exposure actually sits.

---

## R2 — GitHub webhook events are capped, and overflow is dropped silently

| | |
|---|---|
| **Impact** | Direct hit on `loop-dispatch`. A dropped event is a loop that never fires: an `ops/ready-for-ai` issue never picked up, a merged PR that never triggers the release loop. The engine has no idea it missed anything. |
| **Signal** | **There is none on our side.** Nothing errors. The only evidence is work that quietly did not happen. |
| **Status** | **open** — no mitigation. |
| **Review** | 31-10-2026, or the first time a consumer repo runs a busy day. |

The docs: *"During the research preview, GitHub webhook events are subject to per-routine and
per-account hourly caps. Events beyond the limit are dropped until the window resets. See your
current limits at [claude.ai/code/routines](https://claude.ai/code/routines)."*
([Automate work with routines](https://code.claude.com/docs/en/routines))

**The cap is hourly, and no number is published.** The limit is shown per-account in the UI, so it
has to be read there rather than quoted from docs. Until someone reads the live figure, we do not
know our headroom — so treat any number for this as a guess.

**Why this is worse for us than for most callers.** Our routing is event-driven end to end, and
`ops-issue-loop` / `ops-merge-loop` fire per event. A repo with a normal day of PR activity generates
`pull_request` events on `opened`, `synchronize`, `labeled` and `closed` — and the docs are clear
that *"Each matching GitHub event starts a new session"*, with no reuse. Filters on the trigger are
the only lever that reduces the count, since they decide what starts a session at all.

**What would close this:** read the live per-account figure, count the events a real consumer repo
emits in its busiest hour, and either confirm the headroom or narrow the GitHub trigger filters so
only events a loop actually routes on reach the routine.

---

## R3 — A separate daily cap on routine runs, per account

| | |
|---|---|
| **Impact** | Once hit, further runs are rejected outright until the window resets. Every loop stops. |
| **Signal** | Runs rejected. Consumption is visible at [claude.ai/settings/usage](https://claude.ai/settings/usage). |
| **Status** | **mitigated, conditionally** — usage credits turn the wall into metered overage. |
| **Review** | 31-10-2026. |

Distinct from R2 and easy to confuse with it: R2 caps **inbound events per hour**, R3 caps **runs
started per day**. The docs: *"routines have a daily cap on how many runs can start per account"*,
and *"When a routine hits the daily cap or your subscription usage limit, organizations with usage
credits turned on can keep running routines on metered overage. Without usage credits, additional
runs are rejected until the window resets."*
([Automate work with routines](https://code.claude.com/docs/en/routines))

**No number is published here either.** On a Team plan an admin turns usage credits on for the
organisation at [claude.ai/admin-settings/usage](https://claude.ai/admin-settings/usage) — worth
confirming that is on before a consumer goes live, or the first busy day stops the engine dead.

---

## R4 — A routine belongs to one person's account, and acts as them

| | |
|---|---|
| **Impact** | Bus factor of one on the runtime. Everything the engine does on GitHub carries that person's identity, and the caps in R2/R3 are **that individual's**, not the organisation's. If they leave, change plan, or spend their allowance on other work, the engine stops. |
| **Signal** | None automatic. |
| **Status** | **open** — inherent to the platform today. |
| **Review** | 31-10-2026. |

The docs: *"Routines belong to your individual claude.ai account. They are not shared with
teammates, and they count against your account's daily run allowance. Anything a routine does
through your connected GitHub identity or connectors appears as you: commits and pull requests carry
your GitHub user."*
([Automate work with routines](https://code.claude.com/docs/en/routines))

This is why `ops/generated-by-ai` matters as provenance: the GitHub author will be a person, so the
label is the only honest marker that a loop wrote the change.

**Worth knowing:** a Team or Enterprise Owner can switch routines off for every member with one
toggle at [claude.ai/admin-settings/claude-code](https://claude.ai/admin-settings/claude-code). That
is a single setting between the engine and a full stop.

---

## Closed

Nothing yet.
