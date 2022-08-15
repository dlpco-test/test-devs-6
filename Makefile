NAME=go-project-template
NAME_API=$(NAME)-api
NAME_WORKER=$(NAME)-worker
VERSION=dev
OS ?= linux
PROJECT_PATH ?= github.com/dlpco/$(NAME)
PKG ?= github.com/dlpco/$(NAME)/cmd
REGISTRY ?= dlpco
TERM=xterm-256color
CLICOLOR_FORCE=true
GIT_COMMIT=$(shell git rev-parse HEAD)
GIT_BUILD_TIME=$(shell date '+%Y-%m-%d__%I:%M:%S%p')

define goBuild
	@echo "==> Go Building $2"
	@env GOOS=${OS} GOARCH=amd64 go build -v -o  build/$1 \
	-ldflags "-X main.BuildGitCommit=$(GIT_COMMIT) -X main.BuildTime=$(GIT_BUILD_TIME) -X main.BuildGitTAG=$(TAG)" \
	${PKG}/$2
endef

.PHONY: download
download:
	@echo "==> Downloading go.mod dependencies"
	@go mod download

.PHONY: install-tools
install-tools: download
	@echo "==> Installing tools from tools/tools.go"
	@cat tools/tools.go | grep _ | awk -F'"' '{print $$2}' | xargs -tI % go install %

.PHONY: install-golangci-lint
install-golangci-lint:
ifeq (, $(shell which $$(go env GOPATH)/bin/golangci-lint))
	@echo "Installing golangci-lint"
	@curl -sfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $$(go env GOPATH)/bin
endif

.PHONY: setup
setup: install-tools install-golangci-lint
	@go mod tidy

.PHONY: lint
lint:
	@echo "==> Running golangci-lint"
	@golangci-lint run --fix

.PHONY: test
test:
	@echo "==> Running tests"
	@gotest -race -failfast ./...

.PHONY: test-coverage
test-coverage:
	@echo "==> Running tests with coverage"
	@gotest -race -failfast -coverprofile=coverage.out ./...
	@go tool cover -html=coverage.out -o coverage.html

.PHONY: generate
generate:
	@echo "Running go generate"
	@go generate ./...

.PHONY: compile
compile: clean
	@echo "==> Compiling project"
	$(call goBuild,${NAME_API},api)
	$(call goBuild,${NAME_WORKER},worker)

.PHONY: build
build: compile
	@echo "==> Building Docker API image"
	@docker build -t ${REGISTRY}/${NAME_API}:${VERSION} build -f build/api.dockerfile
	@echo "==> Building Docker worker image"
	@docker build -t ${REGISTRY}/${NAME_WORKER}:${VERSION} build -f build/worker.dockerfile

.PHONY:
push:
	@echo "==> Pushing API image to registry"
	@docker push ${REGISTRY}/${NAME_API}:${VERSION}
	@echo "==> Pushing worker image to registry"
	@docker push ${REGISTRY}/${NAME_WORKER}:${VERSION}

.PHONY: clean
clean:
	@echo "==> Cleaning releases"
	@GOOS=${OS} go clean -i -x ./...
	@rm -f build/${NAME_API}
	@rm -f build/${NAME_WORKER}

############################
# BUILD AND DEPLOY TARGETS #
############################

VCS_REF = $(if $(GITHUB_SHA),$(GITHUB_SHA),$(shell git rev-parse HEAD))
TAG ?= $(subst  /,-,$(if $(RELEASE_VERSION),$(RELEASE_VERSION),$(if $(GITHUB_HEAD_REF),$(GITHUB_HEAD_REF),$(shell git rev-parse --abbrev-ref HEAD))))
TRIGGER_KIND ?= $(if $(RELEASE_VERSION),PRODUCTION,HOMOLOG)
REGISTRY_PREFIX ?= stonebankingregistry347.azurecr.io/
PROJECT = go-project-template
IMAGE = $(REGISTRY_PREFIX)dlpco/$(PROJECT)
TAGS = SANDBOX PRODUCTION
STATUS_CODE := $(shell curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Basic $(VSTS_AUTH)" -H "Content-Type: application/json" "https://stone-banking.vsrm.visualstudio.com/$(PROJECT)/_apis/release/releases?api-version=4.1-preview.6")

.PHONY: create-deploy-artifact
create-deploy-artifact:
	rm -rf deploy/rendered dist; \
	if [ $(TAG) != "main" ]; then \
		for tag in $(TAGS); do \
			TRIGGER_KIND="$${tag}"; \
			env TAG=$(TAG) PROJECT=$(PROJECT) REGISTRY_PREFIX=${REGISTRY_PREFIX} TRIGGER_KIND=$$TRIGGER_KIND ./deploy/render.sh; \
			mkdir -p dist || true; \
			tar -C deploy -czf dist/$$TRIGGER_KIND:$(TAG).tar.gz rendered; \
		done; \
	else \
		TRIGGER_KIND="HOMOLOG"; \
		env TAG=$(TAG) PROJECT=$(PROJECT) REGISTRY_PREFIX=${REGISTRY_PREFIX} TRIGGER_KIND=$$TRIGGER_KIND ./deploy/render.sh; \
		mkdir -p dist || true; \
		tar -C deploy -czf dist/$$TRIGGER_KIND:$(TAG).tar.gz rendered; \
	fi;

.PHONY: upload-deploy-artifact
upload-deploy-artifact:
	for artifacts in dist/*; do \
		az storage blob upload \
		--container-name artifacts \
		--name stone-payments/$(PROJECT)/$${artifacts##*/} \
		--file $${artifacts}; \
	done;

.PHONY: create-and-upload-deploy-artifact
create-and-upload-deploy-artifact: create-deploy-artifact upload-deploy-artifact

.PHONY: trigger-deploy
trigger-deploy:
ifndef VSTS_AUTH
	$(error "Missing VSTS_AUTH environment variable")
endif

ifneq ($(STATUS_CODE), $(filter $(STATUS_CODE),200 302))
    $(error "Can't trigger deploy. HTTP Error: $(STATUS_CODE)")
endif

	curl -f -X POST \
	-H "Authorization: Basic $(VSTS_AUTH)" \
	-H "Content-Type: application/json" \
	-d '{ "description": "$(TRIGGER_KIND):$(TAG)", "definitionId": 1, "reason": "continuousIntegration" }' \
	"https://stone-banking.vsrm.visualstudio.com/$(PROJECT)/_apis/release/releases?api-version=4.1-preview.6"
