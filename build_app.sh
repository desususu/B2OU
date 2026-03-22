#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# build_app.sh — Build B2OU.app as a native macOS application
#
# Pure Swift build — no Python runtime needed. Produces a single
# lightweight .app bundle (~5 MB RAM at idle).
#
# Usage:
#   ./build_app.sh          # Build the app
#   ./build_app.sh clean    # Remove build artifacts
#   ./build_app.sh cli      # Build CLI binary only
#
# Output: dist/B2OU.app (and dist/b2ou for CLI)
# ──────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="B2OU"
VERSION="7.0.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[build]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Clean mode ────────────────────────────────────────────────────────
if [[ "${1:-}" == "clean" ]]; then
    log "Cleaning build artifacts..."
    rm -rf .build/ dist/
    rm -rf resources/icon.iconset
    log "Done."
    exit 0
fi

# ── Check we're on macOS ─────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    err "This script must be run on macOS."
    exit 1
fi

# ── Check Swift ─────────────────────────────────────────────────────
if ! command -v swift &>/dev/null; then
    err "Swift is required. Install Xcode or Xcode Command Line Tools:"
    err "  xcode-select --install"
    exit 1
fi

SWIFT_VER=$(swift --version 2>&1 | head -1)
log "Using: $SWIFT_VER"

# ── CLI-only mode ────────────────────────────────────────────────────
if [[ "${1:-}" == "cli" ]]; then
    log "Building CLI binary..."
    swift build -c release --product b2ou
    mkdir -p dist/
    cp .build/release/b2ou dist/b2ou
    strip -x dist/b2ou
    log "Built: dist/b2ou ($(du -sh dist/b2ou | cut -f1))"
    exit 0
fi

# ── Build all targets ────────────────────────────────────────────────
log "Resolving Swift package dependencies..."
swift package resolve

log "Building release binaries..."
swift build -c release

# ── Build icon ───────────────────────────────────────────────────────
if [[ -d resources/icons ]] && ! [[ -f resources/B2OU.icns ]]; then
    log "Building .icns from pre-generated PNGs..."
    mkdir -p resources/icon.iconset

    for size in 16 32 64 128 256 512; do
        src="resources/icons/icon_${size}x${size}.png"
        if [[ -f "$src" ]]; then
            cp "$src" "resources/icon.iconset/icon_${size}x${size}.png"
        fi
    done
    for pair in "32:16" "64:32" "256:128" "512:256" "1024:512"; do
        hi="${pair%%:*}"
        lo="${pair##*:}"
        src="resources/icons/icon_${hi}x${hi}.png"
        if [[ -f "$src" ]]; then
            cp "$src" "resources/icon.iconset/icon_${lo}x${lo}@2x.png"
        fi
    done

    if command -v iconutil &>/dev/null; then
        iconutil -c icns resources/icon.iconset -o resources/B2OU.icns
        log "Created resources/B2OU.icns"
    else
        warn "iconutil not found — skipping .icns generation"
    fi
    rm -rf resources/icon.iconset
fi

# ── Assemble .app bundle ────────────────────────────────────────────
log "Assembling $APP_NAME.app bundle..."
APP_PATH="dist/$APP_NAME.app"
rm -rf "$APP_PATH"

CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

# Copy the menu-bar binary as main executable
cp ".build/release/B2OUMenuBar" "$MACOS/$APP_NAME"
strip -x "$MACOS/$APP_NAME"

# Copy CLI binary alongside (for `b2ou export` from terminal)
mkdir -p dist/
cp ".build/release/b2ou" dist/b2ou
strip -x dist/b2ou

# Copy icons
if [[ -d resources/icons ]]; then
    mkdir -p "$RESOURCES/icons"
    cp resources/icons/*.png "$RESOURCES/icons/"
fi
if [[ -f resources/B2OU.icns ]]; then
    cp resources/B2OU.icns "$RESOURCES/B2OU.icns"
fi

# Write Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>B2OU</string>
    <key>CFBundleDisplayName</key>
    <string>B2OU — Bear Export</string>
    <key>CFBundleIdentifier</key>
    <string>net.b2ou.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>B2OU</string>
    <key>CFBundleIconFile</key>
    <string>B2OU</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# ── Verify ───────────────────────────────────────────────────────────
if [[ -d "$APP_PATH" ]]; then
    SIZE=$(du -sh "$APP_PATH" | cut -f1)
    CLI_SIZE=$(du -sh dist/b2ou | cut -f1)
    log ""
    log "Build successful!"
    log "  App:  $APP_PATH ($SIZE)"
    log "  CLI:  dist/b2ou ($CLI_SIZE)"
    log ""
    log "To install the app:"
    log "  cp -r dist/$APP_NAME.app /Applications/"
    log ""
    log "To install the CLI:"
    log "  cp dist/b2ou /usr/local/bin/"
    log ""
    log "To run now:"
    log "  open dist/$APP_NAME.app"
else
    err "Build failed — $APP_PATH not found"
    exit 1
fi
