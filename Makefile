PRODUCT   = Fen
DIST      = dist

.PHONY: build build-debug test lint format clean install open run resolve

## Build release binary
build:
	swift build -c release --product $(PRODUCT)

## Build debug binary (faster)
build-debug:
	swift build --product $(PRODUCT)

## Run test suite
test:
	swift test

## Build signed .app bundle into dist/
app:
	./scripts/build-app.sh

## Install .app to /Applications (builds first)
install: app
	cp -R "$(DIST)/Fen.app" /Applications/Fen.app
	@echo "Installed to /Applications/Fen.app"

## Open the built .app
open: app
	open "$(DIST)/Fen.app"

## Lint with SwiftLint
lint:
	swiftlint lint --quiet

## Auto-fix lint issues
lint-fix:
	swiftlint lint --fix --quiet

## Format with SwiftFormat
format:
	swiftformat .

## Format check only (no writes)
format-check:
	swiftformat . --lint

## Re-resolve SPM dependencies
resolve:
	swift package resolve

## Update SPM dependencies to latest allowed versions
update:
	swift package update

## Show build targets
describe:
	swift package describe

## Clean build artifacts
clean:
	rm -rf .build $(DIST)

## Run app via SPM (debug, console output visible)
run:
	swift run $(PRODUCT)

## Generate Xcode project (for IDE use; not needed for building)
xcode:
	swift package generate-xcodeproj
