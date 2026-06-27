REGISTRY ?= localhost:5001
IMAGE_NAME ?= sre-slack-bridge
TAG ?= latest
PLATFORM ?= linux/arm64
KUBE_CONTEXT ?= kind-kagent
KAGENT_NAMESPACE ?= kagent
KAGENT_CONTROLLER_SERVICE ?= kagent-controller
KAGENT_UI_SERVICE ?= kagent-ui
KAGENT_CONTROLLER_PORT ?= 8083
KAGENT_UI_PORT ?= 8082
KAGENT_INSTALL_PROFILE ?= demo
BRIDGE_DEPLOYMENT ?= sre-slack-bridge
ARGOCD_NAMESPACE ?= argocd
ARGOCD_VERSION ?= v3.4.3
ARGOCD_MANIFEST ?= https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
GO_EXAMPLE_DIR ?= $(HOME)/code/go-example
GO_EXAMPLE_IMAGE ?= go-example
GO_EXAMPLE_TAG ?= 0.1.0
KUBECTL_CONTEXT_FLAG := $(if $(KUBE_CONTEXT),--context $(KUBE_CONTEXT),)

IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(TAG)
PLATFORM_FLAG := $(if $(PLATFORM),--platform $(PLATFORM),)
KIND_NODE_NAME := $(shell kubectl $(KUBECTL_CONTEXT_FLAG) get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
KIND_NODE_ARCH := $(shell kubectl $(KUBECTL_CONTEXT_FLAG) get node $(KIND_NODE_NAME) -o jsonpath='{.status.nodeInfo.architecture}' 2>/dev/null)
KIND_PLATFORM := $(if $(KIND_NODE_ARCH),linux/$(KIND_NODE_ARCH),)

.PHONY: help build push build-push build-kind build-kind-push inspect inspect-tags inspect-catalog print-image kind-platform
.PHONY: local-kagent-install local-status local-services local-url apply-sre-agent apply-bridge apply-all restart-bridge local-port-forward-controller local-port-forward-ui
.PHONY: argocd-install argocd-status go-example-image argocd-app-go-example argocd-app-status

help:
	@echo "Targets:"
	@echo "  make build       Build $(IMAGE)"
	@echo "  make push        Push $(IMAGE)"
	@echo "  make build-push  Build and push $(IMAGE)"
	@echo "  make kind-platform     Print detected Kind node platform"
	@echo "  make build-kind        Build $(IMAGE) for the detected Kind node platform"
	@echo "  make build-kind-push   Build and push $(IMAGE) for the detected Kind node platform"
	@echo "  make inspect     Show tags for $(IMAGE_NAME) in $(REGISTRY)"
	@echo "  make local-kagent-install     Install kagent with the kagent CLI"
	@echo "  make local-status              Show kagent namespace pods"
	@echo "  make local-services            Show kagent controller/UI services"
	@echo "  make local-url                 Print same-cluster bridge URL for kagent"
	@echo "  make apply-sre-agent             Apply datadog-mcp, github-mcp, and the sre-as-agent"
	@echo "  make apply-bridge              Apply Slack bridge manifests"
	@echo "  make apply-all                 Apply datadog-agent and Slack bridge manifests"
	@echo "  make restart-bridge            Restart the Slack bridge deployment"
	@echo "  make local-port-forward-ui     Forward local UI to http://localhost:$(KAGENT_UI_PORT)"
	@echo "  make local-port-forward-controller Forward controller to http://localhost:$(KAGENT_CONTROLLER_PORT)"
	@echo "  make argocd-install            Install/upgrade ArgoCD $(ARGOCD_VERSION) with server-side apply"
	@echo "  make argocd-status             Show ArgoCD namespace pods"
	@echo "  make go-example-image          Build+push $(REGISTRY)/$(GO_EXAMPLE_IMAGE):$(GO_EXAMPLE_TAG) from $(GO_EXAMPLE_DIR)"
	@echo "  make argocd-app-go-example     Register the go-example ArgoCD Application"
	@echo "  make argocd-app-status         Show the go-example Application and namespace pods"
	@echo ""
	@echo "Overrides:"
	@echo "  REGISTRY=localhost:5001 IMAGE_NAME=sre-slack-bridge TAG=dev PLATFORM=linux/arm64"
	@echo "  KUBE_CONTEXT=kind-kagent KAGENT_NAMESPACE=kagent KAGENT_INSTALL_PROFILE=demo"

build:
	docker build $(PLATFORM_FLAG) -t $(IMAGE) .

push:
	docker push $(IMAGE)

build-push: build push

kind-platform:
	@if [ -z "$(KIND_PLATFORM)" ]; then echo "Could not detect Kind node platform. Is the cluster running?"; exit 1; fi
	@echo "$(KIND_PLATFORM)"

build-kind:
	@if [ -z "$(KIND_PLATFORM)" ]; then echo "Could not detect Kind node platform. Is the cluster running?"; exit 1; fi
	$(MAKE) build PLATFORM=$(KIND_PLATFORM)

build-kind-push:
	@if [ -z "$(KIND_PLATFORM)" ]; then echo "Could not detect Kind node platform. Is the cluster running?"; exit 1; fi
	$(MAKE) build-push PLATFORM=$(KIND_PLATFORM)

inspect: inspect-tags

inspect-tags:
	curl -s http://$(REGISTRY)/v2/$(IMAGE_NAME)/tags/list | jq .

inspect-catalog:
	curl -s http://$(REGISTRY)/v2/_catalog | jq .

print-image:
	@echo $(IMAGE)

local-kagent-install:
	kagent install --profile $(KAGENT_INSTALL_PROFILE)

local-status:
	kubectl $(KUBECTL_CONTEXT_FLAG) get pods -n $(KAGENT_NAMESPACE)

local-services:
	kubectl $(KUBECTL_CONTEXT_FLAG) get svc -n $(KAGENT_NAMESPACE) $(KAGENT_CONTROLLER_SERVICE) $(KAGENT_UI_SERVICE)

local-url:
	@echo "Set KAGENT_BASE_URL for the in-cluster Slack bridge to:"
	@echo "http://$(KAGENT_CONTROLLER_SERVICE).$(KAGENT_NAMESPACE):$(KAGENT_CONTROLLER_PORT)"

apply-sre-agent:
	kubectl $(KUBECTL_CONTEXT_FLAG) apply -f k8s/datadog-agent.yaml
	kubectl $(KUBECTL_CONTEXT_FLAG) apply -f k8s/github-mcp.yaml

apply-bridge:
	kubectl $(KUBECTL_CONTEXT_FLAG) apply -f k8s/slack-bridge.yaml

apply-all: apply-sre-agent apply-bridge

restart-bridge:
	kubectl $(KUBECTL_CONTEXT_FLAG) -n $(KAGENT_NAMESPACE) rollout restart deployment/$(BRIDGE_DEPLOYMENT)

local-port-forward-controller:
	kubectl $(KUBECTL_CONTEXT_FLAG) port-forward -n $(KAGENT_NAMESPACE) svc/$(KAGENT_CONTROLLER_SERVICE) $(KAGENT_CONTROLLER_PORT):$(KAGENT_CONTROLLER_PORT)

local-port-forward-ui:
	kubectl $(KUBECTL_CONTEXT_FLAG) port-forward -n $(KAGENT_NAMESPACE) svc/$(KAGENT_UI_SERVICE) $(KAGENT_UI_PORT):8080

# ArgoCD CRDs (notably ApplicationSet) exceed the 256KiB annotation limit that
# client-side `kubectl apply` writes, so a plain apply silently drops them and the
# applicationset-controller crash-loops. Always install/upgrade with --server-side.
argocd-install:
	kubectl $(KUBECTL_CONTEXT_FLAG) create namespace $(ARGOCD_NAMESPACE) --dry-run=client -o yaml | kubectl $(KUBECTL_CONTEXT_FLAG) apply -f -
	kubectl $(KUBECTL_CONTEXT_FLAG) -n $(ARGOCD_NAMESPACE) apply --server-side --force-conflicts -f $(ARGOCD_MANIFEST)

argocd-status:
	kubectl $(KUBECTL_CONTEXT_FLAG) get pods -n $(ARGOCD_NAMESPACE)

# Example Go service deployed via ArgoCD GitOps. ArgoCD only deploys the manifests
# from git; the image is built/pushed here to the local kind registry. Bump
# GO_EXAMPLE_TAG when the code changes so the Deployment actually rolls.
go-example-image:
	docker build $(if $(KIND_PLATFORM),--platform $(KIND_PLATFORM),) -t $(REGISTRY)/$(GO_EXAMPLE_IMAGE):$(GO_EXAMPLE_TAG) $(GO_EXAMPLE_DIR)
	docker push $(REGISTRY)/$(GO_EXAMPLE_IMAGE):$(GO_EXAMPLE_TAG)

argocd-app-go-example:
	kubectl $(KUBECTL_CONTEXT_FLAG) apply --server-side -f k8s/argocd/go-example-app.yaml

argocd-app-status:
	kubectl $(KUBECTL_CONTEXT_FLAG) -n $(ARGOCD_NAMESPACE) get application go-example
	kubectl $(KUBECTL_CONTEXT_FLAG) -n go-example get deploy,po,svc
