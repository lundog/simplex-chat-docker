# Convenience targets for building, running, and publishing the image.
# Override any variable on the command line, e.g.:
#   make build TAG=v6.5.4
#   make buildx IMAGE=lundog/simplex-chat TAG=v6.5.4

IMAGE            ?= lundog/simplex-chat
TAG              ?= latest
PLATFORMS        ?= linux/amd64,linux/arm64
DATA_DIR         ?= $(HOME)/simplex-volume
WS_PORT          ?= 5225

# Pinned upstream versions (must match the SHA-256 args in the Dockerfile).
SIMPLEX_VERSION  ?= v6.5.4
WEBSOCAT_VERSION ?= v1.14.1
BUILD_ARGS        = --build-arg SIMPLEX_VERSION=$(SIMPLEX_VERSION) \
                    --build-arg WEBSOCAT_VERSION=$(WEBSOCAT_VERSION)

.DEFAULT_GOAL := help
.PHONY: help build run stop logs clean login push buildx

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Build the image for the local architecture
	docker build $(BUILD_ARGS) -t $(IMAGE):$(TAG) .

run: ## Run the container detached (bind-mounts DATA_DIR)
	docker run -d --name simplex-chat \
	  -p $(WS_PORT):5225/tcp \
	  -v $(DATA_DIR):/data \
	  -v $(DATA_DIR)/simplex:/simplex \
	  --restart unless-stopped \
	  $(IMAGE):$(TAG)

stop: ## Stop and remove the running container
	-docker stop simplex-chat
	-docker rm simplex-chat

logs: ## Follow container logs
	docker logs -f simplex-chat

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
