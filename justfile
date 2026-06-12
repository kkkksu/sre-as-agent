set dotenv-load

default:
    @just --list

help:
    @just --list

print-image:
    @echo "${REGISTRY:-localhost:5001}/${IMAGE_NAME:-sre-slack-bridge}:${TAG:-latest}"

build:
    docker build ${PLATFORM:+--platform "$PLATFORM"} -t "${REGISTRY:-localhost:5001}/${IMAGE_NAME:-sre-slack-bridge}:${TAG:-latest}" .

push:
    docker push "${REGISTRY:-localhost:5001}/${IMAGE_NAME:-sre-slack-bridge}:${TAG:-latest}"

build-push: build push

kind-platform:
    @arch="$(kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null)"; if [ -z "$arch" ]; then echo "Could not detect Kind node platform. Is the cluster running?"; exit 1; fi; echo "linux/$arch"

build-kind:
    PLATFORM="$(just kind-platform)" just build

build-kind-push:
    PLATFORM="$(just kind-platform)" just build-push

inspect: inspect-tags

inspect-tags:
    curl -s "http://${REGISTRY:-localhost:5001}/v2/${IMAGE_NAME:-sre-slack-bridge}/tags/list" | jq .

inspect-catalog:
    curl -s "http://${REGISTRY:-localhost:5001}/v2/_catalog" | jq .

local-kagent-install:
    kagent install --profile "${KAGENT_INSTALL_PROFILE:-demo}"

local-status:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} get pods -n "${KAGENT_NAMESPACE:-kagent}"

local-services:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} get svc -n "${KAGENT_NAMESPACE:-kagent}" "${KAGENT_CONTROLLER_SERVICE:-kagent-controller}" "${KAGENT_UI_SERVICE:-kagent-ui}"

local-url:
    @echo "Set KAGENT_BASE_URL for the in-cluster Slack bridge to:"
    @echo "http://${KAGENT_CONTROLLER_SERVICE:-kagent-controller}.${KAGENT_NAMESPACE:-kagent}:${KAGENT_CONTROLLER_PORT:-8083}"

apply-sre-agent:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} apply -f k8s/datadog-agent.yaml

apply-bridge:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} apply -f k8s/slack-bridge.yaml

apply-all: apply-sre-agent apply-bridge

restart-bridge:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} -n "${KAGENT_NAMESPACE:-kagent}" rollout restart "deployment/${BRIDGE_DEPLOYMENT:-sre-slack-bridge}"

local-port-forward-controller:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} port-forward -n "${KAGENT_NAMESPACE:-kagent}" "svc/${KAGENT_CONTROLLER_SERVICE:-kagent-controller}" "${KAGENT_CONTROLLER_PORT:-8083}:${KAGENT_CONTROLLER_PORT:-8083}"

local-port-forward-ui:
    kubectl ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} port-forward -n "${KAGENT_NAMESPACE:-kagent}" "svc/${KAGENT_UI_SERVICE:-kagent-ui}" "${KAGENT_UI_PORT:-8082}:8080"

test:
    PYTHONPATH=src python3 -m unittest discover -s tests -v

compile:
    PYTHONPYCACHEPREFIX=/tmp/sre-as-agent-pycache python3 -m py_compile src/sre_as_agent/slack_bridge.py tests/test_slack_bridge.py
