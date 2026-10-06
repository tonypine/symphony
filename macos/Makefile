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
# Inputs for `make bundle`: the Burrito-built Symphony binary to embed, and the
# versions to write into Info.plist (left as in Info.plist when unset).
SYMPHONY_BIN ?=
SHORT_VERSION ?=
BUILD_NUMBER ?=
# The minisign public key (the key line of minisign.pub) updates are verified
# against, written into Info.plist. Without it the app's Update item is off.
MINISIGN_PUBLIC_KEY ?=
# Inputs for `make qa-app`: the Mix and Erlang it builds Symphony with.
MIX ?= mix
ERL ?= erl
QA_SYMPHONY := $(BUILD_DIR)/qa-symphony

.PHONY: all app bundle qa-app install run test e2e clean

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

# Builds the app with Symphony embedded at Contents/Resources/symphony. The
# embedded binary is signed first, then the bundle, without --deep. Hardened
# runtime stays off: the Burrito binary unpacks and runs its own Erlang runtime.
bundle: app
	@if [ -z "$(SYMPHONY_BIN)" ]; then echo "ERROR: set SYMPHONY_BIN to the Symphony binary to embed, e.g. make bundle SYMPHONY_BIN=../burrito_out/symphony-macos-arm64"; exit 1; fi
	@if [ ! -f "$(SYMPHONY_BIN)" ]; then echo "ERROR: SYMPHONY_BIN $(SYMPHONY_BIN) does not exist"; exit 1; fi
	mkdir -p "$(APP)/Contents/Resources"
	cp "$(SYMPHONY_BIN)" "$(APP)/Contents/Resources/symphony"
	chmod 755 "$(APP)/Contents/Resources/symphony"
	@if [ -n "$(SHORT_VERSION)" ]; then plutil -replace CFBundleShortVersionString -string "$(SHORT_VERSION)" "$(APP)/Contents/Info.plist"; fi
	@if [ -n "$(BUILD_NUMBER)" ]; then plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$(APP)/Contents/Info.plist"; fi
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)/Contents/Resources/symphony"
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)"
	codesign --verify --strict "$(APP)/Contents/Resources/symphony"
	codesign --verify --strict "$(QA_DRIVER_APP)"
	codesign --verify --strict "$(APP)"

# Builds the app with this checkout's Symphony embedded, for Auto Review's macos_app QA
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
	$(MAKE) bundle SYMPHONY_BIN="$(QA_SYMPHONY)"

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

clean:
	rm -rf $(BUILD_DIR) .build
