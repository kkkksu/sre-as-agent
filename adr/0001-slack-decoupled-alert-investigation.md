# ADR 0001: Use Slack as the Decoupling Layer for Alert Investigation

## Status

Accepted

## Context

The project goal is to run a 24/7 SRE agent that investigates Datadog alerts
without requiring human input. Datadog should not be tightly coupled to kagent,
kagent agent names, cluster-local URLs, or the Slack bridge implementation.

The team still wants Slack to remain the shared operational surface. Humans
should see an alert message in the on-call channel, and kagent should reply in
the same thread with the investigation result.

## Decision

Use Datadog's native Slack integration as the decoupling layer between Datadog
alerts and kagent investigation.

```text
Datadog alert
-> Datadog Slack integration posts to #monitor-sre-as-agent
-> Slack bridge reads trusted Datadog alert message
-> kagent investigates by Datadog alert ID
-> Slack thread reply with final report
```

There is no custom public HTTP endpoint for Datadog. Datadog only knows about
Slack. The Datadog Slack notification message must be useful to humans and also
contain a small machine-readable marker for automation.

## Slack Message Contract

The Datadog Slack alert message can be human-readable, but it must include a
stable machine-readable alert marker. The bridge must not parse prose as the
source of truth.

Example:

````text
Datadog alert: High error rate on checkout

Service: checkout
Env: prod
Status: Alert
Datadog: https://app.datadoghq.com/...

```json
{"source":"datadog","alert_id":"<MONITOR_ID>:{{host.name}}:{{last_triggered_at_epoch}}","monitor_id":"<MONITOR_ID>","dedupe_key":"datadog:<MONITOR_ID>:{{host.name}}:{{last_triggered_at_epoch}}"}
```
````

Datadog monitor messages must not rely on `@kagent` as the trigger. In Datadog
monitor notifications, `@...` is interpreted as a Datadog notification handle,
not as a Slack user mention. Manual human Slack messages can still use a real
Slack mention, but Datadog-originated alerts trigger from the structured marker.

The Slack bridge processes the message only when all are true:

- Message is in an allowlisted Slack channel.
- Message came from the trusted Datadog Slack app or configured Datadog bot.
- Message contains a valid structured marker with `source=datadog`.
- Marker includes `alert_id`.
- `dedupe_key` has not already been processed.

## Kagent Prompt Contract

The bridge invokes kagent with the Datadog alert ID as the primary input. kagent
fetches alert details through Datadog MCP instead of relying on Slack message
prose.

Prompt shape:

```text
You are an autonomous 24/7 SRE investigation agent.

Investigate Datadog alert_id=<alert_id> monitor_id=<monitor_id>.
Use Datadog MCP to fetch alert and monitor details first.
Then correlate with Kubernetes logs/events and recent GitLab changes if tools
are available.

Do not ask the user questions.
If evidence is missing, report missing evidence and continue.
Do not perform mutating actions.

Return a final Slack-ready incident report with:
- severity
- urgency
- summary
- likely root cause
- evidence
- blast radius
- suggested fix
- confidence
- links
```

## Consequences

Positive:

- Datadog is decoupled from kagent and the Slack bridge.
- No custom public webhook endpoint is required.
- Slack remains the visible handoff point for on-call humans.
- The bridge consumes a stable `alert_id` contract instead of parsing alert
  prose.
- Human-readable alert content can evolve without breaking automation, as long
  as the marker contract remains stable.

Negative:

- Slack Events becomes part of the automation path.
- Slack delivery delays can delay investigations.
- The bridge needs dedupe, trusted-bot filtering, and robust marker parsing.

These tradeoffs are accepted because the project prioritizes decoupling Datadog
from kagent while keeping Slack as the shared operational surface.
