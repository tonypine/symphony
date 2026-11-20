APP_NAME := Symphony
EXECUTABLE := SymphonyBar
CONFIG := release
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
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

.PHONY: all build app bundle qa-app install run test e2e release-pair gallery build-gallery gallery-resources clean

all: app

build:
	swift build $(SWIFT_FLAGS)

# `make guarded-<target>` once built with a slow type-check guard; the guard is gone. The name is kept, as plain
# <target>, for a symphony.yml whose Build step still names `make guarded-build`.
guarded-%:
	@$(MAKE) --no-print-directory $*

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
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)"
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
	$(MAKE) build-gallery
	mkdir -p "$(APP)/Contents/Helpers"
	cp "$(GALLERY)" "$(APP)/Contents/Helpers/SymphonyGallery"
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)/Contents/Helpers/SymphonyGallery"
	$(MAKE) gallery-resources GALLERY_RESOURCES="$(APP)/Contents/Resources/GalleryResources"
	codesign --force --sign "$(SIGNING_IDENTITY)" $(CODESIGN_FLAGS) "$(APP)"
	codesign --verify --strict "$(APP)"

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
# build/release-pair (N/Symphony.app, feed/, manifest.json), or RELEASE_PAIR_OUT, signed with a
# throwaway or given test identity and a throwaway minisign key. See ../test/support/README.md.
RELEASE_PAIR_BUILD_N ?= 90001
RELEASE_PAIR_BUILD_N1 ?= 90002
RELEASE_PAIR_OUT ?= build/release-pair
release-pair:
	python3 ../test/support/macos_release/release_pair.py --out "$(RELEASE_PAIR_OUT)" \
		--build-n $(RELEASE_PAIR_BUILD_N) --build-n1 $(RELEASE_PAIR_BUILD_N1)

# The Component Gallery (Gallery/): every shared component in its kinds, sizes and states, and the sections and
# pages built from them, drawn by the app's own views in a window, one story at a time. It is compiled apart from the
# app (the app's views, minus main.swift, with the gallery's stories), so the app pays nothing for it.
#   make gallery                        builds $(GALLERY) and opens it
#   $(GALLERY) --entries                the entries, as JSON
#   $(GALLERY) --shot button --out /tmp/shots   draws that entry's board to files, in light and dark
# `make qa-app` puts it inside the QA build's bundle, where a launch on Tests/Fixtures/gallery starts it in the
# app's place (Sources/SymphonyBar/GalleryLaunch.swift), so QA drives it with the tools it drives the app with, and
# puts the fixtures it reads beside it (`gallery-resources`), since a QA host has no checkout.
# `-disable-sandbox` lets the SwiftUI macros' plugin server run inside an agent sandbox.
GALLERY := $(BUILD_DIR)/SymphonyGallery
build-gallery:
	swift build $(SWIFT_FLAGS) --product SymphonyBarUI
	mkdir -p $(BUILD_DIR)
	@# The libraries' modules and objects: SwiftPM's native build system (Xcode 26) puts them in
	@# Modules/ and <target>.build/*.o; Swift Build (Xcode 27) beside the products, as <target>.o.
	bin="$$(swift build $(SWIFT_FLAGS) --show-bin-path)"; \
	if [ -d "$$bin/Modules" ]; then modules="$$bin/Modules"; objects="$$bin/SymphonyBarCore.build/*.o $$bin/SymphonyBarUI.build/*.o"; \
	else modules="$$bin"; objects="$$bin/SymphonyBarCore.o $$bin/SymphonyBarUI.o"; fi; \
	swiftc -disable-sandbox -swift-version 5 -module-cache-path .build/gallery-module-cache \
		-I "$$modules" -o $(GALLERY) \
		Gallery/*.swift $$(ls Sources/SymphonyBar/*.swift | grep -v '/main.swift$$') \
		$$objects
	@# The built gallery, copied out of the checkout with its fixtures, still reads every story (TP-1520).
	sh Tests/gallery-portable-test.sh "$(GALLERY)"

# What a built gallery reads, copied in the checkout's layout to $(GALLERY_RESOURCES) (Gallery/Files.swift): the
# committed fixtures, Symphony's API fixtures, the shared views' files and the list of component variations `--check`
# reads. `make qa-app` puts it in the QA build at Contents/Resources/GalleryResources, so the gallery runs on a QA host
# that has no checkout.
# It takes no default: a copy at build/GalleryResources would sit beside build/SymphonyGallery and stand in for the
# checkout there.
gallery-resources:
	@test -n "$(GALLERY_RESOURCES)" || { echo "gallery-resources needs GALLERY_RESOURCES=<folder>" >&2; exit 2; }
	rm -rf "$(GALLERY_RESOURCES)"
	mkdir -p "$(GALLERY_RESOURCES)/macos/Gallery" "$(GALLERY_RESOURCES)/macos/Tests" "$(GALLERY_RESOURCES)/macos/Sources/SymphonyBarUI" \
		"$(GALLERY_RESOURCES)/test/fixtures"
	cp -R Tests/Fixtures "$(GALLERY_RESOURCES)/macos/Tests/Fixtures"
	cp Sources/SymphonyBarUI/*.swift "$(GALLERY_RESOURCES)/macos/Sources/SymphonyBarUI/"
	cp Gallery/component-variations.txt "$(GALLERY_RESOURCES)/macos/Gallery/"
	cp -R ../test/fixtures/api "$(GALLERY_RESOURCES)/test/fixtures/api"

gallery: build-gallery
	$(GALLERY) --window

clean:
	rm -rf $(BUILD_DIR) .build
