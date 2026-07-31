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

**Narrower than it looks, because of which trigger we use.** The `/fire` endpoint ships behind a
dated beta header (`experimental-cc-routine-2026-04-01`), and *"Breaking changes ship behind new
dated beta header versions, and the two most recent previous header versions continue to work so
that callers have time to migrate."* We fire only through that endpoint (see the note below R2), so
the trigger half of our exposure comes with two versions of warning. **No equivalent promise covers
the routine configuration itself or the setup-script/environment contract** — `cloud-setup-stub.sh`
and `cloud-skill-sync.sh` sit on an unversioned surface. That is where the real exposure is.

---

> ### Which trigger we use, and why the caps differ
>
> A routine can be started three ways, and the limits are **not** the same for each.
>
> We do **not** use Anthropic's native **GitHub event trigger**. `.github/workflows/loop-dispatch.yml`
> is our own GitHub Actions workflow: it receives the repo event, runs `route-event.sh` at the edge,
> and **POSTs to the routine's API trigger `/fire` endpoint only when the event maps to a loop**.
>
> That is a deliberate design choice and it buys two things. Non-matching events (a Dependabot
> `dependencies` label) cost nothing — not even a routine session. And the **per-routine and
> per-account hourly webhook caps that apply to the native GitHub trigger do not apply to us**, because
> no webhook is delivered to Anthropic at all. GitHub delivers to GitHub Actions; we decide; we call.
>
> What applies to us instead is R2: the `/fire` endpoint's own limit.

## R2 — The `/fire` endpoint 429s on the account's daily run allowance

| | |
|---|---|
| **Impact** | Direct hit on `loop-dispatch`. Once the allowance is gone, every fire is rejected and every loop stops: no issue picked up, no merge, no release. |
| **Signal** | **Good — the workflow step fails loudly.** `curl --fail-with-body` turns the 429 into a non-zero exit, so the run goes red in the caller repo's Actions tab. Remaining runs are visible at [claude.ai/code/routines](https://claude.ai/code/routines). |
| **Status** | **open** — visible, but the lost event is never replayed. |
| **Review** | 31-10-2026, or the first time a consumer repo runs a busy day. |

The API reference: *"Routine runs count against a per-account daily allowance that varies by plan,
and the resulting sessions draw down the same Claude Code subscription usage as interactive
sessions. When either limit is reached, the endpoint returns `429 rate_limit_error` with a
`Retry-After` header. Organizations with extra usage enabled continue past the included allowance on
metered overage."*
([Trigger a routine through the API](https://platform.claude.com/docs/en/api/claude-code/routines-fire))

**No number is published** — the allowance varies by plan and remaining runs are read off
`claude.ai/code/routines`. Until someone reads the live figure we do not know our headroom, so treat
any number for this as a guess.

**The real cost is the lost event, not the red build.** Nothing re-fires a route once the window
resets. The issue keeps its `ops/ready-for-ai` label and simply sits there until something else
touches it. A failed dispatch is visible to whoever looks at Actions, and invisible to everyone else.

**Two things to check in the workflow.** The fire step runs
`curl --retry 3 --retry-delay 5 --retry-all-errors`, added for transient 5xx. Against a 429 those
retries cannot succeed, and curl's handling of the `Retry-After` header interacts with
`--retry-delay` in ways worth confirming rather than assuming — a long `Retry-After` should not be
allowed to park a runner. Distinguishing 429 from 5xx and failing fast on it would be the tidier
shape.

**What would close this:** read the live allowance, count the loop-mapped events a real consumer repo
emits on its busiest day, and either confirm the headroom or turn on extra usage (below).

---

## R3 — Extra usage is what turns the R2 wall into a slope

| | |
|---|---|
| **Impact** | Without it, hitting the allowance is a hard stop until the window resets. With it, runs continue on metered overage and the engine keeps going. |
| **Signal** | Same 429 as R2 — the difference is whether it happens at all. |
| **Status** | **available, not confirmed on** — a setting, not a hazard, until someone checks it. |
| **Review** | Before any consumer goes live. |

Not a separate limit from R2; it is the lever that changes what R2 does. The docs: *"When a routine
hits the daily cap or your subscription usage limit, organizations with usage credits turned on can
keep running routines on metered overage. Without usage credits, additional runs are rejected until
the window resets."*
([Automate work with routines](https://code.claude.com/docs/en/routines))

On a Team plan an admin turns this on for the organisation at
[claude.ai/admin-settings/usage](https://claude.ai/admin-settings/usage). Worth confirming before a
consumer goes live, or the first busy day stops the engine dead. It has a cost, so it is a decision
for whoever owns the budget, not a default to flip.

---

## R4 — A routine belongs to one person's account, and acts as them

| | |
|---|---|
| **Impact** | Bus factor of one on the runtime. Everything the engine does on GitHub carries that person's identity, and R2's daily allowance is **that individual's**, not the organisation's. If they leave, change plan, or spend their allowance on other work, the engine stops. |
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
