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
# Inputs for `make bundle`: the Burrito-built Symphony binary to embed, and the
# versions to write into Info.plist (left as in Info.plist when unset).
SYMPHONY_BIN ?=
SHORT_VERSION ?=
BUILD_NUMBER ?=
# The minisign public key (the key line of minisign.pub) updates are verified
# against, written into Info.plist. Without it the app's Update item is off.
MINISIGN_PUBLIC_KEY ?=

.PHONY: all app bundle install run test clean

all: app

app:
	swift build $(SWIFT_FLAGS) -c $(CONFIG) --product $(EXECUTABLE)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path)/$(EXECUTABLE)" "$(APP)/Contents/MacOS/$(EXECUTABLE)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/update-helper.sh "$(APP)/Contents/Resources/update-helper.sh"
	@if [ -n "$(MINISIGN_PUBLIC_KEY)" ]; then plutil -replace SymphonyUpdatePublicKey -string "$(MINISIGN_PUBLIC_KEY)" "$(APP)/Contents/Info.plist"; fi
	codesign --force --sign "$(SIGNING_IDENTITY)" "$(APP)"
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
	codesign --force --sign "$(SIGNING_IDENTITY)" "$(APP)/Contents/Resources/symphony"
	codesign --force --sign "$(SIGNING_IDENTITY)" "$(APP)"
	codesign --verify --strict "$(APP)/Contents/Resources/symphony"
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

clean:
	rm -rf $(BUILD_DIR) .build
