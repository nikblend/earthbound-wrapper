# EarthboundWrapper — developer entry points.
#
# Every target here is a thin wrapper over a script in scripts/, so CI and a local
# shell run the same commands and a fix to one is a fix to both.
#
#   make            list targets
#   make ipa        device build, packaged as an unsigned .ipa
#   make simulator  build and launch in the iOS Simulator

APP          := EarthboundWrapper
SCHEME       := EarthboundWrapper
PROJECT      := $(APP).xcodeproj
DERIVED      := build/DerivedData
DEVICE_APP   := $(DERIVED)/Build/Products/Release-iphoneos/$(APP).app
SIM_APP      := $(DERIVED)/Build/Products/Debug-iphonesimulator/$(APP).app
IPA          := dist/$(APP).ipa

# Set to your development team to run on a physical device from Xcode. Left empty
# so nothing here requires an Apple account.
DEVELOPMENT_TEAM ?=

.DEFAULT_GOAL := help
.PHONY: help assets core core-all project device simulator ipa open verify test check clean distclean

# The glue tests need only a C compiler, so they run anywhere -- including a Linux
# CI runner, which is where they are most useful as a fast gate.
# clang is preferred, to match Xcode's compiler: the signature check in
# EBCoreGlue.c is expressed as a clang diagnostic, and testing with the same
# compiler that will build the app is the point. It falls back to cc so that a
# runner without clang reports a weaker check rather than a missing tool.
TEST_CC      ?= $(shell command -v clang >/dev/null 2>&1 && echo clang || echo cc)
TEST_BIN     := .build/test/glue_test
TEST_SOURCES := tests/glue_test.c tests/glue_stubs.c Sources/Support/EBCoreGlue.c
TEST_FLAGS   := -std=gnu11 -O1 -g -Wall -Wextra -Werror \
                -Itests/shims -ISources/Support -IThirdParty/libretro/include

help: ## Show this list
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

assets: ## Generate the app icon and asset catalog
	@python3 scripts/make-assets.py

core: ## Build the emulator core for the device SDK
	@./scripts/build-core.sh iphoneos

core-all: ## Build the emulator core for both the device and simulator SDKs
	@./scripts/build-core.sh iphoneos iphonesimulator

project: assets ## Regenerate the Xcode project from project.yml
	@command -v xcodegen >/dev/null || { echo "install XcodeGen: brew install xcodegen"; exit 1; }
	@xcodegen generate --spec project.yml

device: core project ## Build the app for a device (unsigned)
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-sdk iphoneos -destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
		build

simulator: core-all project ## Build for and launch the iOS Simulator
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
		build
	@xcrun simctl boot "iPhone 16" 2>/dev/null || true
	@open -a Simulator
	@xcrun simctl install booted $(SIM_APP)
	@xcrun simctl launch booted dev.nikan.earthbound

ipa: device ## Build the app and package it as an unsigned .ipa
	@./scripts/package-ipa.sh "$(DEVICE_APP)" "$(IPA)"

open: project ## Open the generated project in Xcode
	@open $(PROJECT)

verify: ## Check the vendored libretro.h against the pinned core revision
	@./scripts/verify-core-pin.sh

test: ## Build and run the C glue tests (needs no Xcode)
	@mkdir -p $(dir $(TEST_BIN))
	@$(TEST_CC) $(TEST_FLAGS) $(TEST_SOURCES) -lpthread -o $(TEST_BIN)
	@$(TEST_BIN)

check: test verify ## Everything that can be checked without Xcode

clean: ## Remove build output but keep the built core
	@rm -rf build dist "$(PROJECT)" Support/Info.plist

distclean: ## Remove build output, the built core, and generated assets
	@rm -rf build dist Core/lib .build "$(PROJECT)" Support/Info.plist Resources
