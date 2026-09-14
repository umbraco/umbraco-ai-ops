---
name: ops-notify
description: >-
  Tell a human something happened, through whichever channel this repo uses — a Claude push
  notification by default, or whatever a repo overrides this with. Infrastructure, not a
  gate: a notification that fails must never fail the work it was reporting on. Idempotent
  per caller-supplied key, so a sweeping loop cannot send the same message twice. Called by
  name with (action, context-json) . NOT for direct use — never select it from a description match.
---

# ops-notify

One way to reach a human, so no loop has to know which way that is.

**Visibility: cross-cutting (infrastructure).** Any layer may call it — a loop, a service, a
primitive.

**It is never a gate.** Nothing waits on a notification, nothing branches on one, and a
failure to send **MUST NOT** fail the work being reported. A loop that lands a PR and then
cannot push-notify has still landed the PR; it says so in the outcome and moves on. Getting
this backwards means an outage in a notification channel stops releases.

## Invocation

```
ops-notify <action> '<context-json>'
```

| Action | Context | Returns |
|---|---|---|
| `send` | `{ subject, body, urgency?, key? }` | `{ ok, sent }` |

An absent context is `{}`. **Reject any other action.**

- **`subject`** — one line. Assume it is all a human reads on a phone.
- **`body`** — the detail, in plain language. Include the repo and the PR/issue number; a
  notification with no address is a notification nobody can act on.
- **`urgency`** — `normal` (default) or `high`. `high` means a human is *blocking* something,
  not merely that the loop found it interesting.
- **`key`** — a stable id for this notification. See idempotency.

## Idempotency

**The same `key` twice MUST NOT produce a second message.** This is not a nicety: the merge
loop sweeps on a cadence and the landing label stays on a PR after it lands, so the same
"landed PR #8890" moment is reachable on the next run. Without a key, a routine that fires
six times a day notifies six times about one merge, and a human learns to ignore it.

Form a key from the *event*, not the *moment*: `landed-owner/repo-8890`,
`release-blocked-owner/repo-512`. Never include a timestamp — that defeats it.

With **no** `key`, send unconditionally. A caller that cannot form a stable id is better off
sending twice than not sending.

## The framework default

The `PushNotification` tool, when it is available in the environment.

**When it is not available** — a local run, or a routine whose `allowed_tools` omits it —
do not fail. Fall back to the most visible thing the caller already has: a comment on the
issue or PR the notification is about, and say in the returned `detail` that push was
unavailable. Return `{ ok: true, sent: false }` when nothing could be delivered; the caller
needs to know a human was *not* reached, without that being an error.

A repo that notifies through Slack, Teams or email ships its own `ops-notify`. That is the
whole reason this is a capability rather than a `PushNotification` call inlined in four
loops — which is exactly where it was before.

## Rules

- **Never gate on it, never retry it in a loop, never let it fail the caller.**
- **One notification per real event.** Use a key.
- **`high` is for a human being blocked.** Everything else is `normal`. An urgency that is
  always high is an urgency nobody reads.
- **Never put a secret, a token or a full CI log in a notification.** A subject line and a
  link; the detail lives where the work is.
- **Never notify instead of commenting.** A push is ephemeral and only reaches one person —
  the durable record belongs on the issue or PR. Notify *as well*, not *instead*.
