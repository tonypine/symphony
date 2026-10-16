.PHONY: help all setup deps audit build smoke release fmt fmt-check lint test test-profile coverage coverage-profile check ci dialyzer dialyzer-profile e2e support-test

MIX ?= mix
TEST_MAX_CASES ?= 4
BEAM_SCHEDULERS ?= 4
TEST_ENV := ELIXIR_ERL_OPTIONS="+S $(BEAM_SCHEDULERS):$(BEAM_SCHEDULERS)"
TEST_ARGS := --max-cases $(TEST_MAX_CASES)

help:
	@echo "Targets: setup, deps, audit, build, smoke, release, fmt, fmt-check, lint, test, test-profile, coverage, coverage-profile, check, dialyzer, dialyzer-profile, e2e, support-test, ci"

# Turns on .githooks/pre-push (format, compile and credo on the files a push changes)
# for this clone and all its worktrees.
setup:
	git config core.hooksPath .githooks
	$(MIX) setup

deps:
	$(MIX) deps.get

# `mix deps.get` only rejects advisories for packages it downloads, so a warm deps/ dir hides them.
audit:
	$(MIX) hex.audit

build:
	$(MIX) build

# The release smoke test, run on the escript: `symphony check` must pass on the
# sample symphony.yml, as it must for the release binary.
smoke: build
	scripts/release/smoke_test.sh bin/symphony symphony.yml

# The plain `mix release`, ERTS included, that Symphony.app carries in
# Contents/Resources/symphony-release (`make -C macos bundle SYMPHONY_RELEASE=...`).
RELEASE_DIR := _build/prod/rel/symphony

release:
	MIX_ENV=prod $(MIX) deps.get --only prod
	MIX_ENV=prod $(MIX) release symphony --overwrite
	@echo "Release: $(CURDIR)/$(RELEASE_DIR)"

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(TEST_ENV) $(MIX) test --cover $(TEST_ARGS)

coverage-profile:
	$(TEST_ENV) $(MIX) test --cover --slowest 20 $(TEST_ARGS)

test:
	$(TEST_ENV) $(MIX) test $(TEST_ARGS)

test-profile:
	$(TEST_ENV) $(MIX) test --slowest 20 $(TEST_ARGS)

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

dialyzer-profile:
	$(MIX) deps.get
	time $(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

# The shared test helpers' own tests (test/support/README.md): stdlib Python, no build, no sudo.
support-test:
	python3 -m unittest discover -s test/support/tests -v

check:
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) build
	$(MAKE) test

ci:
	$(MAKE) setup
	$(MAKE) audit
	$(MAKE) smoke
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
