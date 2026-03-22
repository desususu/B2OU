# B2OU — Build targets

.PHONY: build build-release cli menubar test clean

# Build all targets (debug)
build:
	swift build

# Build optimized release
build-release:
	swift build -c release

# Build CLI only
cli:
	swift build --product b2ou

# Build menu-bar app only
menubar:
	swift build --product B2OUMenuBar

# Run tests
test:
	swift test

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build
