.PHONY: help all setup deps audit build package fmt fmt-check lint test test-profile coverage coverage-profile check ci dialyzer dialyzer-profile e2e

MIX ?= mix
TEST_MAX_CASES ?= 4
BEAM_SCHEDULERS ?= 4
TEST_ENV := ELIXIR_ERL_OPTIONS="+S $(BEAM_SCHEDULERS):$(BEAM_SCHEDULERS)"
TEST_ARGS := --max-cases $(TEST_MAX_CASES)

help:
	@echo "Targets: setup, deps, audit, fmt, fmt-check, lint, test, test-profile, coverage, coverage-profile, check, dialyzer, dialyzer-profile, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

# `mix deps.get` only rejects advisories for packages it downloads, so a warm deps/ dir hides them.
audit:
	$(MIX) hex.audit

build:
	$(MIX) build

# Zig 0.15.2 (pinned by Burrito 1.5.0) can't link against the macOS 26 and later
# SDKs' libSystem.tbd. The shim dir holds an xcrun wrapper that redirects Zig to
# the macOS 15 SDK when present, else to a copy of the active SDK it can link
# against; on older macOS it's a no-op pass-through.
PACKAGE_PATH := $(CURDIR)/scripts/zig-sdk-shim:$(PATH)

package:
	PATH="$(PACKAGE_PATH)" MIX_ENV=prod $(MIX) deps.get --only prod
	PATH="$(PACKAGE_PATH)" MIX_ENV=prod $(MIX) release symphony --overwrite
	@if [ -f burrito_out/symphony_macos_arm64 ]; then mv burrito_out/symphony_macos_arm64 burrito_out/symphony-macos-arm64; fi
	@if [ -f burrito_out/symphony_macos_x86_64 ]; then mv burrito_out/symphony_macos_x86_64 burrito_out/symphony-macos-x86_64; fi

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

check:
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) build
	$(MAKE) test

ci:
	$(MAKE) setup
	$(MAKE) audit
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
