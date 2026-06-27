# SRE as Agent

Turn Datadog alerts in Slack into automatic kagent investigations.

When Datadog posts an alert, this bridge picks it up from an allowlisted Slack
channel, asks a kagent Datadog agent to investigate, and posts the findings back
in the same Slack thread.

```text
Datadog monitor -> Slack alert channel -> sre-slack-bridge
-> kagent datadog-agent -> Slack thread reply
```
<img width="832" height="547" alt="image" src="https://github.com/user-attachments/assets/aa3d771c-c2cc-4cfa-9899-15c2ae6a03a4" />

## Why this exists

On-call engineers often lose time doing the same first checks for every alert:
open the monitor, inspect logs and metrics, correlate symptoms, and summarize
what changed. This project automates that first investigation pass while keeping
humans in control.

The design keeps Datadog, Slack, and kagent loosely coupled:

- Datadog only posts to Slack.
- The bridge owns Slack credentials and thread routing.
- kagent owns the investigation.
- The agent should stay read-only for automatically triggered alerts.

## What you get

- **Slack-native workflow**: investigations happen in the alert thread where the
  team is already looking.
- **No public Datadog webhook endpoint**: Datadog does not need direct access to
  kagent or your cluster.
- **Structured alert contract**: Datadog messages can include a small JSON marker
  so the bridge can identify the alert reliably.
- **Channel and sender controls**: process only configured Slack channels and,
  when enabled, trusted Datadog sender IDs.
- **Local-cluster friendly**: works with Kind, OrbStack, or any Kubernetes
  cluster where the bridge and kagent run together.

## How it works

1. Datadog sends an alert to Slack.
2. The bridge receives the Slack message through Socket Mode.
3. The bridge checks the channel, sender, and Datadog alert marker.
4. The bridge calls the kagent A2A endpoint.
5. kagent investigates with Datadog MCP tools.
6. The bridge posts the final summary back to the Slack thread.

If the structured marker is missing, the bridge can still derive `monitor_id`
and `alert_id` from Datadog Slack attachment links when they include
`link_monitor_id` and `link_event_id`.

## Local kagent cluster

For local development, run kagent and the Slack bridge in the same Kubernetes
cluster and namespace. The bridge should call kagent through Kubernetes DNS:

```text
http://kagent-controller.kagent:8083
```

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

For this same-cluster setup, configure the bridge with:

```yaml
KAGENT_BASE_URL: "http://kagent-controller.kagent:8083"
KAGENT_NAMESPACE: "kagent"
KAGENT_AGENT_NAME: "sre-as-agent"
KAGENT_API_TOKEN: "unused-in-local-unsecure-mode"
```

Local kagent installs usually use `controller.auth.mode=unsecure`, so
`KAGENT_API_TOKEN` can be any non-empty placeholder. In an authenticated kagent
deployment, replace it with the token accepted by your auth proxy.

## Create the Slack app

Create a Slack app from `slack-app-manifest.yaml`, then install it to your
workspace. The manifest enables Socket Mode, creates the `kagent` bot user,
grants the required bot scopes, and subscribes to public/private channel message
events.

After creating the app:

1. Create an app-level token with `connections:write`.
2. Copy the bot token after installing the app.
3. Copy the app-level token from **Basic Information > App-Level Tokens**.
4. Set `KAGENT_BOT_USER_ID` to the Slack bot user ID, for example
   `<slack-bot-user-id>`. Do not use the display name `kagent`; Slack mentions
   use the Slack user ID, as in `<@...>`.
5. Install the app and invite the bot to the Datadog alert channel.

## Configure the Datadog alert message

Add a structured marker to the Datadog Slack monitor message:

````text
```json
{"source":"datadog","alert_id":"<MONITOR_ID>:{{host.name}}:{{last_triggered_at_epoch}}","monitor_id":"<MONITOR_ID>","dedupe_key":"datadog:<MONITOR_ID>:{{host.name}}:{{last_triggered_at_epoch}}"}
```
````

Keep the rest of the monitor message human-readable. The bridge treats the JSON
marker as the machine contract and uses the alert ID to ask kagent to fetch
Datadog details.

Do not use `@kagent` as the automation trigger in Datadog. Datadog interprets
`@...` as a Datadog notification handle, not as a Slack user mention.

Datadog test notifications are useful for validating the Slack-to-kagent
pipeline, but they may contain placeholder values such as `host.name`. Use a
real triggered monitor when validating investigation quality for a specific
host, service, or Kubernetes workload.

## Runtime config

Copy `.env.example` to `.env` for local runs, or set these values in Kubernetes:

| Name | Description |
| --- | --- |
| `SLACK_BOT_TOKEN` | Slack bot token. |
| `SLACK_APP_TOKEN` | Slack app-level Socket Mode token. |
| `KAGENT_BOT_USER_ID` | Slack user ID for the kagent bot. The display name `kagent` will not work. |
| `ALLOWED_CHANNEL_IDS` | Comma- or space-separated Slack channel IDs to watch. |
| `TRUSTED_DATADOG_SENDER_IDS` | Optional comma- or space-separated Slack `bot_id`/`user` IDs allowed to trigger marker-based Datadog investigations. Leave empty for local testing. |
| `KAGENT_BASE_URL` | kagent controller base URL. Use `http://kagent-controller.kagent:8083` for same-cluster local setup. |
| `KAGENT_API_TOKEN` | Token sent as `Authorization: Bearer ...`. Use a dummy non-empty value for local unsecure kagent. |
| `KAGENT_NAMESPACE` | Defaults to `kagent`. |
| `KAGENT_AGENT_NAME` | Defaults to `sre-as-agent`. |
| `KAGENT_USER_ID` | Defaults to `admin@kagent.dev`. Used when polling kagent session events for the final answer. |
| `KAGENT_SESSION_POLL_TIMEOUT_SECONDS` | Defaults to `90`. Maximum time to wait for kagent to write a final session event. |
| `KAGENT_SESSION_POLL_INTERVAL_SECONDS` | Defaults to `2`. Delay between session event polls. |

The bridge first calls the kagent A2A endpoint. If the immediate response only
contains task metadata, it polls the matching kagent session until it finds a
model text response or an `ask_user` question to relay back into Slack.

## Run locally

```bash
cp .env.example .env
# Fill in local values in .env; never commit real tokens.
python -m venv .venv
. .venv/bin/activate
pip install -e .
sre-slack-bridge
```

Run tests:

```bash
just test
# or
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

## Deploy to Kubernetes

1. Replace placeholders in `k8s/datadog-agent.yaml` and
   `k8s/slack-bridge.yaml` locally.
2. Build and publish the image from `Dockerfile`.
3. Update the deployment image.
4. Apply the manifests:

```bash
kubectl apply -f k8s/datadog-agent.yaml
kubectl apply -f k8s/slack-bridge.yaml
```

The Makefile wraps common local commands:

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
rebuild with `make build-kind-push`, then run `make restart-bridge`.

The `justfile` uses `set dotenv-load`, so recipes automatically load values
from a local `.env` file:

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

## ArgoCD

If the cluster runs ArgoCD, **always install and upgrade it with server-side
apply**:

```bash
make argocd-install
# or directly:
kubectl -n argocd apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/install.yaml
```

Do **not** use a plain client-side `kubectl apply -f install.yaml`. ArgoCD's
CRDs are large — the `ApplicationSet` CRD is ~1.3 MB — and client-side apply
tries to store the whole object in the `kubectl.kubernetes.io/last-applied-configuration`
annotation, which Kubernetes caps at 262144 bytes (256 KiB). The apply then
fails for that one CRD with `metadata.annotations: Too long`, so the CRD is
never created while the rest of the install succeeds. The
`argocd-applicationset-controller` then crash-loops (`CrashLoopBackOff`) with
`no matches for kind "ApplicationSet" in version "argoproj.io/v1alpha1"`.
Server-side apply does not write that annotation, so it has no size limit. To
recover an install that already hit this, apply just the missing CRD:

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.3/manifests/crds/applicationset-crd.yaml
```

Keep `ARGOCD_VERSION` in the `Makefile` matched to the running ArgoCD version.

### Example Go service via ArgoCD

`k8s/argocd/go-example-app.yaml` defines an ArgoCD `Application` that deploys a
small Go HTTP service from its own public repo
(`github.com/kkkksu/go-example`, manifests under `k8s/`) into the `go-example`
namespace. ArgoCD deploys the manifests from git; it does **not** build the
image — that is pushed to the local kind registry separately:

```bash
make go-example-image          # build + push localhost:5001/go-example:0.1.0
make argocd-app-go-example     # register the Application (server-side apply)
make argocd-app-status         # Application + go-example namespace pods
```

Because auto-sync watches git (not the registry), rebuilds must use a **new**
`GO_EXAMPLE_TAG` and a matching bump in the service repo's
`k8s/deployment.yaml` to trigger a rollout.

## Safety notes

- Keep real Slack, Datadog, kagent, and LLM tokens out of git.
- Keep autonomous alert investigations read-only.
- Enable `TRUSTED_DATADOG_SENDER_IDS` outside local testing.
- Review `SECURITY.md` before using this outside a local/dev environment.
