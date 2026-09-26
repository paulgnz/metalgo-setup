SHELL := /usr/bin/env bash
SCRIPTS := setup.sh lib/*.sh test/run.sh test/in-container.sh test/fakes/* scripts/verify-pins.sh

.PHONY: hooks secretscan lint test verify-pins

# Git hooks that refuse commits and pushes containing secrets.
hooks:
	git config core.hooksPath .githooks
	@echo "git hooks installed: commits and pushes are scanned for secrets"

# Scan every commit on every branch.
secretscan:
	go run ./scripts/secretscan history

# shellcheck every script, and the scanner's own tests. (bash -n runs in
# the test container, with Ubuntu 24.04's bash.)
lint:
	shellcheck $(SCRIPTS)
	go vet ./... && go test ./...

# Every scenario in throwaway ubuntu:24.04 containers (docker, linux/amd64).
test: lint
	test/run.sh

# Check lib/pins.sh against upstream: tags, branches, tarball hash, VM IDs.
verify-pins:
	scripts/verify-pins.sh
