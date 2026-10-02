APP_NAME := Symphony
EXECUTABLE := SymphonyBar
CONFIG := release
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
SWIFT_FLAGS ?=

.PHONY: all app run test clean

all: app

app:
	swift build $(SWIFT_FLAGS) -c $(CONFIG) --product $(EXECUTABLE)
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$$(swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path)/$(EXECUTABLE)" "$(APP)/Contents/MacOS/$(EXECUTABLE)"
	cp Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	codesign --verify --strict "$(APP)"

run: app
	open "$(APP)"

test:
	swift test $(SWIFT_FLAGS)

clean:
	rm -rf $(BUILD_DIR) .build
