APP_NAME := Symphony
EXECUTABLE := SymphonyBar
CONFIG := release
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR ?= $(HOME)/Applications
SWIFT_FLAGS ?=

.PHONY: all app install run test clean

all: app

app:
	swift build $(SWIFT_FLAGS) -c $(CONFIG) --product $(EXECUTABLE)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path)/$(EXECUTABLE)" "$(APP)/Contents/MacOS/$(EXECUTABLE)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
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

clean:
	rm -rf $(BUILD_DIR) .build
