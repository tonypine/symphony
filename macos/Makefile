APP_NAME := Symphony
EXECUTABLE := SymphonyBar
CONFIG := release
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
# The QA driver helper app holds the Screen Recording and Accessibility grants, so
# Symphony.app and the agents it spawns never get them (see docs/configuration.md).
QA_DRIVER_SOURCE := ../priv/qa_driver
QA_DRIVER_APP := $(APP)/Contents/Helpers/SymphonyQADriver.app
INSTALL_DIR ?= $(HOME)/Applications
SWIFT_FLAGS ?=
# `-` signs ad hoc, so local builds need no certificate. CI passes the
# release signing identity.
SIGNING_IDENTITY ?= -
# Extra codesign options, such as `--keychain <file>` for an identity in a
# keychain that isn't in the search list.
CODESIGN_FLAGS ?=
# A SymphonyBar executable built already (`swift build -c release`), copied
# instead of building one, so several bundles can share one build.
PREBUILT_EXECUTABLE ?=
# Inputs for `make bundle`: the `mix release` directory to embed (`make release`
# at the repo root builds _build/prod/rel/symphony), and the versions to write
# into Info.plist (left as in Info.plist when unset).
SYMPHONY_RELEASE ?=
# For `make qa-app` only: a single-file Symphony (the escript) embedded at
# Contents/Resources/symphony in place of a release.
SYMPHONY_ESCRIPT ?=
SHORT_VERSION ?=
BUILD_NUMBER ?=
# The minisign public key (the key line of minisign.pub) updates are verified
# against, written into Info.plist. Without it the app's Update item is off.
MINISIGN_PUBLIC_KEY ?=
# Inputs for `make qa-app`: the Mix and Erlang it builds Symphony with.
MIX ?= mix
ERL ?= erl
QA_SYMPHONY := $(BUILD_DIR)/qa-symphony

.PHONY: all app bundle qa-app install run test e2e release-pair snapshots clean

all: app

# The QA helper is signed with the hardened runtime, so dyld ignores
# DYLD_INSERT_LIBRARIES and no other code runs with its Accessibility and Screen
# Recording grants. It needs no entitlements: both are TCC grants.
app:
	@if [ -z "$(PREBUILT_EXECUTABLE)" ]; then swift build $(SWIFT_FLAGS) -c $(CONFIG) --product $(EXECUTABLE); fi
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	@if [ -n "$(PREBUILT_EXECUTABLE)" ]; then cp "$(PREBUILT_EXECUTABLE)" "$(APP)/Contents/MacOS/$(EXECUTABLE)"; \
	else cp "$$(swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path)/$(EXECUTABLE)" "$(APP)/Contents/MacOS/$(EXECUTABLE)"; fi
	cp Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/update-helper.sh "$(APP)/Contents/Resources/update-helper.sh"
	@if [ -n "$(MINISIGN_PUBLIC_KEY)" ]; then plutil -replace SymphonyUpdatePublicKey -string "$(MINISIGN_PUBLIC_KEY)" "$(APP)/Contents/Info.plist"; fi
	mkdir -p "$(QA_DRIVER_APP)/Contents/MacOS"
	swiftc -O -o "$(QA_DRIVER_APP)/Contents/MacOS/symphony-qa-driver" "$(QA_DRIVER_SOURCE)/symphony-qa-driver.swift"
	cp "$(QA_DRIVER_SOURCE)/Info.plist" "$(QA_DRIVER_APP)/Contents/Info.plist"
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(QA_DRIVER_APP)"
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)"
	codesign --verify --strict "$(QA_DRIVER_APP)"
	codesign --verify --strict "$(APP)"

# Builds the app with the Symphony release embedded at
# Contents/Resources/symphony-release and its launcher (the release's
# bin/symphony-app) at Contents/Resources/symphony, the path the app runs. Every
# Mach-O in the release (ERTS's executables, NIFs, port programs) is signed first,
# innermost first, then the bundle, without --deep. Hardened runtime stays off.
bundle: app
	@if [ -n "$(SYMPHONY_ESCRIPT)" ]; then \
		if [ ! -f "$(SYMPHONY_ESCRIPT)" ]; then echo "ERROR: SYMPHONY_ESCRIPT $(SYMPHONY_ESCRIPT) does not exist"; exit 1; fi; \
	elif [ -z "$(SYMPHONY_RELEASE)" ]; then \
		echo "ERROR: set SYMPHONY_RELEASE to the release directory to embed, e.g. make bundle SYMPHONY_RELEASE=../_build/prod/rel/symphony (make release at the repo root builds it)"; exit 1; \
	elif [ ! -f "$(SYMPHONY_RELEASE)/releases/start_erl.data" ] || [ ! -f "$(SYMPHONY_RELEASE)/bin/symphony-app" ]; then \
		echo "ERROR: SYMPHONY_RELEASE $(SYMPHONY_RELEASE) is not a Symphony release (no releases/start_erl.data or bin/symphony-app)"; exit 1; \
	fi
	mkdir -p "$(APP)/Contents/Resources"
	rm -rf "$(APP)/Contents/Resources/symphony" "$(APP)/Contents/Resources/symphony-release"
	@if [ -n "$(SYMPHONY_ESCRIPT)" ]; then \
		cp "$(SYMPHONY_ESCRIPT)" "$(APP)/Contents/Resources/symphony"; \
	else \
		ditto "$(SYMPHONY_RELEASE)" "$(APP)/Contents/Resources/symphony-release" && \
		cp "$(APP)/Contents/Resources/symphony-release/bin/symphony-app" "$(APP)/Contents/Resources/symphony"; \
	fi
	chmod 755 "$(APP)/Contents/Resources/symphony"
	@if [ -n "$(SHORT_VERSION)" ]; then plutil -replace CFBundleShortVersionString -string "$(SHORT_VERSION)" "$(APP)/Contents/Info.plist"; fi
	@if [ -n "$(BUILD_NUMBER)" ]; then plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"; fi
	@release="$(APP)/Contents/Resources/symphony-release"; \
	if [ -d "$$release" ]; then \
		find "$$release" -type f -exec file {} + | grep 'Mach-O' | cut -d: -f1 | \
			awk -F/ '{ print NF "\t" $$0 }' | sort -rn | cut -f2- > "$(BUILD_DIR)/macho.txt"; \
		test -s "$(BUILD_DIR)/macho.txt" || { echo "ERROR: no Mach-O files found in $$release"; exit 1; }; \
		echo "Signing $$(wc -l < "$(BUILD_DIR)/macho.txt" | tr -d ' ') Mach-O files in symphony-release"; \
		while IFS= read -r file; do \
			codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$$file" || exit 1; \
		done < "$(BUILD_DIR)/macho.txt"; \
	else \
		codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)/Contents/Resources/symphony"; \
	fi
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)"
	@if [ -f "$(BUILD_DIR)/macho.txt" ] && [ -d "$(APP)/Contents/Resources/symphony-release" ]; then \
		while IFS= read -r file; do codesign --verify --strict "$$file" || exit 1; done < "$(BUILD_DIR)/macho.txt"; \
	fi
	codesign --verify --strict "$(QA_DRIVER_APP)"
	codesign --verify --strict --deep "$(APP)"

# Builds the app with this checkout's Symphony embedded, for the QA state's macos_app playbook
# (see docs/configuration.md), so the app's `symphony check` runs this code. Symphony is
# the checkout's escript with its shebang pointed at this Mac's Erlang, so it runs without
# mise or PATH. It reports the commit in source-commit, which `git archive` fills in (a QA
# host gets such a copy), else the checkout's HEAD.
qa-app:
	cd .. && $(MIX) local.hex --if-missing --force && $(MIX) local.rebar --if-missing --force && $(MIX) deps.get
	cd .. && SYMPHONY_BUILD_SHA="$$(grep -E '^[0-9a-f]{40}$$' macos/source-commit || git rev-parse HEAD 2>/dev/null)" $(MIX) escript.build
	mkdir -p "$(BUILD_DIR)"
	root="$$($(ERL) -noshell -eval 'io:put_chars(code:root_dir()), halt().')" && \
		{ printf '#!%s/bin/escript\n' "$$root"; tail -n +2 ../bin/symphony; } > "$(QA_SYMPHONY)"
	chmod 755 "$(QA_SYMPHONY)"
	$(MAKE) bundle SYMPHONY_ESCRIPT="$(QA_SYMPHONY)"

install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	codesign --verify --strict "$(INSTALL_DIR)/$(APP_NAME).app"

run: app
	open "$(APP)"

test:
	swift test $(SWIFT_FLAGS)
	sh Tests/update-helper-test.sh

# Builds releases N and N+1 from this checkout and tests Update, Restart and
# rollback end to end in an isolated instance. See Tests/e2e/README.md.
e2e:
	python3 Tests/e2e/update_restart_e2e.py

# Builds a signed release N and its update N+1 from this checkout at fixed paths under
# build/release-pair (N/Symphony.app, feed/, manifest.json), signed with a throwaway or given
# test identity and a throwaway minisign key. See ../test/support/README.md.
RELEASE_PAIR_BUILD_N ?= 90001
RELEASE_PAIR_BUILD_N1 ?= 90002
release-pair:
	python3 ../test/support/macos_release/release_pair.py --out build/release-pair \
		--build-n $(RELEASE_PAIR_BUILD_N) --build-n1 $(RELEASE_PAIR_BUILD_N1)

# Renders the snapshots in Tests/Snapshots offscreen with ImageRenderer (no NSApplication, no window) and
# writes their PNGs there: the app's views, minus main.swift, compiled with the snapshot program.
# `-disable-sandbox` lets the SwiftUI macros' plugin server run inside an agent sandbox.
snapshots:
	swift build $(SWIFT_FLAGS) --product SymphonyBarUI
	mkdir -p $(BUILD_DIR)
	swiftc -disable-sandbox -swift-version 5 -module-cache-path .build/snapshot-module-cache \
		-I "$$(swift build $(SWIFT_FLAGS) --show-bin-path)/Modules" -o $(BUILD_DIR)/render-snapshots \
		Tests/Snapshots/main.swift $$(ls Sources/SymphonyBar/*.swift | grep -v '/main.swift$$') \
		"$$(swift build $(SWIFT_FLAGS) --show-bin-path)"/SymphonyBarCore.build/*.o \
		"$$(swift build $(SWIFT_FLAGS) --show-bin-path)"/SymphonyBarUI.build/*.o
	$(BUILD_DIR)/render-snapshots

clean:
	rm -rf $(BUILD_DIR) .build
