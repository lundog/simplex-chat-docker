# Convenience targets for building, running, and publishing the image.
# Override any variable on the command line, e.g.:
#   make build TAG=v6.5.6
#   make buildx IMAGE=lundog/simplex-websocket-bridge TAG=v6.5.6

IMAGE            ?= lundog/simplex-websocket-bridge
TAG              ?= latest
PLATFORMS        ?= linux/amd64,linux/arm64
DATA_DIR             ?= $(HOME)/simplex-volume
WS_PORT              ?= 5225
PROFILE_DISPLAY_NAME ?= SimpleX Bot
PROFILE_PEER_TYPE    ?= bot

# simplex-chat / websocat versions and their SHA-256 pins are a matched set,
# bumped together in the Dockerfile — not overridable here.
#
# IMAGE_REVISION is an optional container-only hotfix suffix for the image
# version label (e.g. make build IMAGE_REVISION=-1). Empty by default.
IMAGE_REVISION   ?=
BUILD_ARGS        = $(if $(IMAGE_REVISION),--build-arg IMAGE_REVISION=$(IMAGE_REVISION),)

.DEFAULT_GOAL := help
.PHONY: help build run stop logs clean login push buildx

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build the image for the local architecture
	docker build $(BUILD_ARGS) -t $(IMAGE):$(TAG) .

run: ## Run the container detached (bind-mounts DATA_DIR)
	docker run -d --name simplex-websocket-bridge \
	  -p $(WS_PORT):5225/tcp \
	  -e PROFILE_DISPLAY_NAME="$(PROFILE_DISPLAY_NAME)" \
	  -e PROFILE_PEER_TYPE="$(PROFILE_PEER_TYPE)" \
	  -v $(DATA_DIR):/data \
	  --restart unless-stopped \
	  $(IMAGE):$(TAG)

stop: ## Stop and remove the running container
	-docker stop simplex-websocket-bridge
	-docker rm simplex-websocket-bridge

logs: ## Follow container logs
	docker logs -f simplex-websocket-bridge

clean: ## Remove the locally built image
	-docker rmi $(IMAGE):$(TAG)

login: ## Log in to Docker Hub
	docker login

push: ## Push a single-arch image (after `make build`)
	docker push $(IMAGE):$(TAG)

buildx: ## Build multi-arch (amd64+arm64) and push to Docker Hub (needs `make login`)
	docker buildx build $(BUILD_ARGS) \
	  --platform $(PLATFORMS) \
	  -t $(IMAGE):$(TAG) \
	  --push .
