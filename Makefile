# Muninn development tasks. See PRD §8 (quality strategy) and §9 (plan).
#
# Point the Crystal compile cache at a project-local, gitignored dir so every
# target works regardless of whether the global ~/.cache/crystal is writable.
# Override by exporting CRYSTAL_CACHE_DIR yourself before invoking make.
CRYSTAL_CACHE_DIR ?= $(CURDIR)/.cache/crystal
export CRYSTAL_CACHE_DIR

CRYTIC_VERSION := ~> 9.0
MUTATION_TARGETS := matcher frontmatter index session_state review

# Where `make install` drops the binary. Default to the per-user bin dir that is
# already on PATH in the devcontainer; override with `make install PREFIX=/usr/local`.
PREFIX ?= $(HOME)/.local

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## Install shard dependencies
	shards install

.PHONY: build
build: ## Build the muninn binary (debug)
	shards build muninn

.PHONY: release
release: ## Build the muninn binary (release)
	crystal build --release src/muninn.cr -o bin/muninn

.PHONY: install
install: release ## Build the release binary and install it to PREFIX/bin (on PATH)
	@mkdir -p "$(PREFIX)/bin"
	install -m 0755 bin/muninn "$(PREFIX)/bin/muninn"
	@echo ">> installed muninn to $(PREFIX)/bin/muninn"

.PHONY: spec
spec: ## Run the spec suite
	crystal spec

.PHONY: lint
lint: ## Run ameba (zero findings required)
	./bin/ameba

.PHONY: coverage
coverage: ## Run specs under kcov and enforce the coverage gate
	./scripts/coverage.sh

# Mutation testing is advisory-only and never gates CI (PRD §8.1). Crytic is
# installed on demand into the gitignored .crytic/ so it stays out of the main
# dependency graph. If it fails to build against the target Crystal, this target
# prints the manual-mutation checklist instead of failing.
#
# Usage:
#   make mutate SUBJECT=src/muninn/matcher.cr
#   make mutate                      # lists the recommended mutation targets
.PHONY: mutate
mutate: .crytic/bin/crytic ## Run crytic on SUBJECT=<file> (advisory; see docs/mutation-testing.md)
ifndef SUBJECT
	@echo "Usage: make mutate SUBJECT=src/muninn/<module>.cr"
	@echo "Recommended mutation targets (pure logic — PRD §8.1):"
	@for m in $(MUTATION_TARGETS); do echo "  src/muninn/$$m.cr"; done
else
	./.crytic/bin/crytic test -s $(SUBJECT)
endif

# Build crytic on demand. On failure, fall back to the documented manual
# mutation workflow (PRD §8.1) rather than breaking the developer's build.
.crytic/bin/crytic:
	@echo ">> installing crytic ($(CRYTIC_VERSION)) into .crytic/ ..."
	@mkdir -p .crytic
	@printf 'name: muninn-mutation\nversion: 0.1.0\ncrystal: ">= 1.20"\ndependencies:\n  crytic:\n    github: hanneskaeufler/crytic\n    version: %s\n' '$(CRYTIC_VERSION)' > .crytic/shard.yml
	@cd .crytic && shards install || { \
		echo ""; \
		echo "!! crytic failed to build against this Crystal toolchain."; \
		echo "!! Fall back to a manual mutation session — see docs/mutation-testing.md."; \
		exit 1; \
	}

.PHONY: check
check: lint spec ## Lint + spec (the fast local gate)

.PHONY: clean
clean: ## Remove build artifacts and local caches
	rm -rf bin lib .shards .crytic .cache coverage
