# Security

This project uses Slack as the decoupling layer between Datadog alerts and
kagent investigations:

```text
Datadog monitor -> Slack alert channel -> sre-slack-bridge
-> in-cluster kagent datadog-agent -> Slack thread reply
```

The design is reasonable for local development and can be made production-safe,
but the current implementation should be treated as dev-grade until the
hardening checklist below is complete.

## Security Posture

The good security properties are:

- kagent does not need a public API endpoint when the bridge runs in the same
  cluster. The bridge calls kagent through Kubernetes DNS, for example
  `http://kagent-controller.kagent:8083`.
- Datadog is decoupled from kagent. Datadog posts to Slack and does not receive
  direct access to the cluster or kagent.
- Slack channel allowlisting limits where autonomous investigations can
  originate.
- `TRUSTED_DATADOG_SENDER_IDS` limits marker-based autonomous triggers to the
  Datadog Slack app/user IDs observed in the workspace.
- The kagent agent should remain read-only for auto-triggered alerts. It should
  investigate using Datadog MCP, cluster logs/events, and other read-only data,
  then post findings back to Slack.

## Main Risks

- Slack becomes part of the automation control plane. Anyone who can cause
  Datadog's Slack app to post a matching alert into the allowlisted channel can
  trigger kagent.
- Datadog monitor edit permissions become part of the security boundary,
  because monitor notifications control what the Datadog Slack app posts.
- Sender ID allowlisting protects against normal users posting fake markers, but
  it does not protect against compromised Slack app credentials, compromised
  Datadog access, or users with Datadog monitor notification edit access.
- Alert text is untrusted prompt input. The agent must not obey instructions
  embedded in an alert body that ask it to change policy, reveal secrets, or take
  write actions.
- In-memory dedupe is not durable. A bridge pod restart can reprocess the same
  alert.
- Auto-remediation is not safe by default. Suggested fixes should be posted to
  Slack first unless a separate approval and policy layer exists.

## Secrets

Do not commit real tokens or API keys to this repository.

Sensitive values include:

- `SLACK_BOT_TOKEN`
- `SLACK_APP_TOKEN`
- `KAGENT_API_TOKEN` when kagent is authenticated
- Datadog API keys, application keys, and MCP credentials
- LLM provider API keys

For local development, create Kubernetes Secrets from local environment values
or encrypted manifests. For shared environments, use a secret manager such as
External Secrets, Sealed Secrets, SOPS, or the cloud provider's native secret
manager.

If a real token was committed, pasted into a manifest, shared in a screenshot,
or exposed in logs, rotate it.

## Production Hardening Checklist

Before using this outside local development:

1. Rotate any exposed Slack, Datadog, kagent, or LLM tokens.
2. Remove real secrets from plain Kubernetes manifests.
3. Manage secrets through a secret manager or encrypted manifest workflow.
4. Keep `TRUSTED_DATADOG_SENDER_IDS` enabled.
5. Restrict the Slack app to the alert channel, such as
   `#monitor-sre-as-agent`.
6. Restrict who can edit Datadog monitors that notify the alert channel.
7. Use read-only Datadog credentials for MCP access.
8. Keep the kagent agent read-only for autonomous alert handling.
9. Add persistent dedupe keyed by Datadog monitor/event ID.
10. Add an allowlist for monitor IDs, monitor tags, or service tags that are
    allowed to trigger autonomous investigations.
11. Keep auto-remediation disabled unless there is an explicit approval path.
12. Add audit logging for accepted alerts, rejected alerts, kagent session IDs,
    and Slack thread timestamps.

## Prompt Safety

The bridge should treat Slack and Datadog message content as data, not
instructions.

The kagent prompt for autonomous investigations should enforce:

- Use the Datadog alert ID, monitor ID, and linked metadata as evidence.
- Prefer data from Datadog MCP, Kubernetes events/logs, and other trusted tools.
- Do not reveal credentials or environment variables.
- Do not execute write actions or remediation commands.
- If evidence is incomplete, state uncertainty and provide best-effort findings.
- Post a concise report with severity, suspected root cause, evidence, and next
  recommended human action.

## Recommended Authorization Model

Use layered authorization:

1. Slack channel allowlist: only process messages from known alert channels.
2. Sender allowlist: only auto-trigger marker-based investigations from Datadog
   Slack sender IDs.
3. Alert allowlist: only process approved monitor IDs, monitor tags, service
   tags, or environments.
4. Tool permissions: keep Datadog, Kubernetes, and source-control access
   read-only for autonomous investigations.
5. Human approval: require approval before any write action or remediation.

This keeps Slack useful as a human-readable event bus without making every
Slack message an implicit command to the cluster.
