# SRE as Agent

Slack bridge for Datadog alert investigations with kagent.

## Flow

```text
Datadog monitor -> Slack alert channel -> structured Datadog marker
-> sre-slack-bridge -> local kagent datadog-agent
-> thread reply in Slack
```

The bridge owns Slack credentials and thread routing. The `kagent/datadog-agent`
owns investigation only and should remain read-only for auto-triggered alerts.

## Local kagent Cluster

For local development, run kagent and the Slack bridge in the same Kubernetes
cluster and namespace. The bridge should call kagent through Kubernetes DNS:

```text
http://kagent-controller.kagent:8083
```

This is the same pattern for Kind, OrbStack, or a cloud Kubernetes cluster when
the bridge and kagent run together in the cluster. You only need a public kagent
URL if the bridge runs outside the cluster.

Install kagent locally with the kagent CLI:

```bash
export KAGENT_DEFAULT_MODEL_PROVIDER=openAI
export OPENAI_API_KEY="<your-openai-or-compatible-api-key>"
kagent install --profile demo
```

Verify the local cluster:

```bash
kubectl get pods -n kagent
kubectl get svc -n kagent kagent-controller
```

For this same-cluster local setup, configure the bridge with:

```yaml
KAGENT_BASE_URL: "http://kagent-controller.kagent:8083"
KAGENT_NAMESPACE: "kagent"
KAGENT_AGENT_NAME: "datadog-agent"
KAGENT_API_TOKEN: "unused-in-local-unsecure-mode"
```

Local kagent installs usually use `controller.auth.mode=unsecure`, so
`KAGENT_API_TOKEN` is only a non-empty placeholder. In an authenticated kagent
deployment, replace it with the token accepted by the auth proxy in front of
kagent.

## Slack App

Create a Slack app for the bridge from `slack-app-manifest.yaml`, then install it to the workspace.
The manifest enables Socket Mode, creates the `kagent` bot user, grants the bot scopes needed by
the bridge, and subscribes to public/private channel message events.

After creating the app:

- Create an app-level token with `connections:write`.
- Copy the bot token (`xoxb-...`) after installing the app.
- Copy the app-level token (`xapp-...`) from Basic Information > App-Level Tokens.
- Set `KAGENT_BOT_USER_ID` to the Slack bot user ID, for example `<slack-bot-user-id>`.
  Do not use the display name `kagent`; Slack mentions are sent as `<@...>`, using the Slack user ID.
- Install the app and invite the bot to the Datadog alert channel.

Configure Datadog's Slack monitor message to include a structured marker.
Do not use `@kagent` as the automation trigger in Datadog; Datadog interprets
`@...` as a Datadog notification handle, not as a Slack user mention.

````text
```json
{"source":"datadog","alert_id":"<MONITOR_ID>:{{host.name}}:{{last_triggered_at_epoch}}","monitor_id":"<MONITOR_ID>","dedupe_key":"datadog:<MONITOR_ID>:{{host.name}}:{{last_triggered_at_epoch}}"}
```
````

Keep the rest of the monitor message human-readable. The bridge treats this
marker as the machine contract and uses the alert ID to ask kagent to fetch
details through Datadog MCP.

If the marker is missing, the bridge can still derive `monitor_id` and
`alert_id` from Datadog's Slack attachment `title_link` when that link includes
`link_monitor_id` and `link_event_id`.

Datadog test notifications are useful for validating the Slack-to-kagent
pipeline, but they may contain placeholder values such as `host.name` instead
of a real alert group. Use a real triggered monitor when validating that kagent
can investigate a specific host, service, or Kubernetes workload.

## Runtime Config

Required environment variables:

| Name | Description |
| --- | --- |
| `SLACK_BOT_TOKEN` | Slack bot token, starts with `xoxb-`. |
| `SLACK_APP_TOKEN` | Slack app-level Socket Mode token, starts with `xapp-`. |
| `KAGENT_BOT_USER_ID` | Slack user ID for the kagent bot, for example `<slack-bot-user-id>`. The display name `kagent` will not work. |
| `ALLOWED_CHANNEL_IDS` | Comma or space-separated Slack channel IDs to watch. |
| `TRUSTED_DATADOG_SENDER_IDS` | Optional comma or space-separated Slack `bot_id`/`user` IDs allowed to trigger marker-based Datadog investigations. Leave empty for local testing. |
| `KAGENT_BASE_URL` | kagent controller base URL. Use `http://kagent-controller.kagent:8083` for same-cluster local setup. |
| `KAGENT_API_TOKEN` | Token sent as `Authorization: Bearer ...`. Use a dummy non-empty value for local unsecure kagent. |
| `KAGENT_NAMESPACE` | Defaults to `kagent`. |
| `KAGENT_AGENT_NAME` | Defaults to `datadog-agent`. |
| `KAGENT_USER_ID` | Defaults to `admin@kagent.dev`. Used when polling kagent session events for the final answer. |
| `KAGENT_SESSION_POLL_TIMEOUT_SECONDS` | Defaults to `90`. Maximum time to wait for kagent to write a final session event. |
| `KAGENT_SESSION_POLL_INTERVAL_SECONDS` | Defaults to `2`. Delay between session event polls. |

The bridge first calls the kagent A2A endpoint. If that immediate response only
contains task metadata, it polls the matching kagent session until it finds a
model text response or an `ask_user` question to relay back into the Slack
thread.

## Local Run

```bash
cp .env.example .env
# Fill in local values in .env; never commit real tokens.
python -m venv .venv
. .venv/bin/activate
pip install -e .
sre-slack-bridge
```

## Kubernetes

1. Replace placeholders in `k8s/datadog-agent.yaml` and `k8s/slack-bridge.yaml` locally.
2. Build and publish the image from `Dockerfile`.
3. Update the deployment image.
4. Apply:

```bash
kubectl apply -f k8s/datadog-agent.yaml
kubectl apply -f k8s/slack-bridge.yaml
```

The Makefile wraps the common local commands:

```bash
make kind-platform
make build-kind-push
make restart-bridge
make local-status
make local-url
make apply-sre-agent
make apply-bridge
make local-port-forward-ui
```

Use `make build-kind-push` for local Kind/OrbStack clusters. It detects the
Kind node architecture and builds the image with the matching Docker platform.
If the pod shows `ImagePullBackOff` with `no match for platform in manifest`,
the image was built for the wrong architecture; rebuild with `make
build-kind-push`, then run `make restart-bridge`.

This repo also includes a `justfile`. It uses `set dotenv-load`, so values from
a local `.env` file are loaded automatically when you run recipes:

```dotenv
REGISTRY=localhost:5001
IMAGE_NAME=sre-slack-bridge
TAG=latest
KUBE_CONTEXT=kind-kagent
KAGENT_NAMESPACE=kagent
```

Common `just` recipes:

```bash
just
just local-url
just kind-platform
just build-kind-push
just restart-bridge
just apply-all
just local-port-forward-ui
just test
```

## Security

This repository is structured to be safe for a public GitHub repo: checked-in
manifests use placeholders, local `.env` files are ignored, and `.env.example`
contains only templates. Review `SECURITY.md` and `PUBLICATION_CHECKLIST.md`
before publishing.

Rotate any Datadog keys that were previously committed or pasted into manifests.
Keep Slack tokens and any authenticated kagent token only in Kubernetes Secrets.
