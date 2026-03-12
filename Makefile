# B2OU — Build targets for the macOS menu-bar app

.PHONY: app clean test

# Build the standalone .app bundle (macOS only)
# Creates dist/B2OU.app with all dependencies bundled — no pip needed.
app:
	./build_app.sh

# Run tests
test:
	python -m pytest tests/ -v

# Clean build artifacts
clean:
	./build_app.sh clean
	rm -f resources/B2OU.icns
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
