#!/bin/bash
# ──────────────────────────────────────────────────────────────────────
# build_app.sh — Build B2OU.app as a standalone macOS application
#
# Architecture: Swift menu-bar UI (~5MB RAM) + Python CLI backend.
# The Swift app manages the menu bar and launches the Python CLI
# as a subprocess for actual export work.
#
# Usage:
#   ./build_app.sh          # Build the app
#   ./build_app.sh clean    # Remove build artifacts
#
# Output: dist/B2OU.app
# ──────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VENV_DIR=".build-venv"
APP_NAME="B2OU"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[build]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

# ── Clean mode ────────────────────────────────────────────────────────
if [[ "${1:-}" == "clean" ]]; then
    log "Cleaning build artifacts..."
    rm -rf build/ dist/ "$VENV_DIR" *.egg-info
    rm -rf resources/icon.iconset
    log "Done."
    exit 0
fi

# ── Check we're on macOS ─────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
    err "This script must be run on macOS."
    exit 1
fi

# ── Check Python version ─────────────────────────────────────────────
PYTHON=""
for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        major=${ver%%.*}
        minor=${ver##*.}
        if (( major >= 3 && minor >= 10 )); then
            PYTHON="$candidate"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    err "Python 3.10+ is required.  Install it from https://www.python.org/downloads/"
    exit 1
fi

log "Using Python: $PYTHON ($($PYTHON --version))"

# ── Create isolated build virtualenv ─────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating build virtualenv..."
    "$PYTHON" -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

log "Installing build dependencies..."
pip install --upgrade pip setuptools wheel -q
pip install pyinstaller -q
pip install -e . -q

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
        touch resources/B2OU.icns
    fi
    rm -rf resources/icon.iconset
fi

# ── Compile Swift menu-bar app ──────────────────────────────────────
log "Compiling Swift menu-bar app..."
mkdir -p build/

swiftc -O -whole-module-optimization \
    -o "build/$APP_NAME" \
    swift/B2OUMenuBar.swift \
    -framework Cocoa

# Strip debug symbols to reduce binary size (~1-2 MB savings)
strip -x "build/$APP_NAME"

log "Swift binary: build/$APP_NAME ($(du -sh "build/$APP_NAME" | cut -f1))"

# ── Build Python CLI with PyInstaller ────────────────────────────────
log "Building Python CLI with PyInstaller..."
python -m PyInstaller \
    --noconfirm \
    --clean \
    B2OU-CLI.spec

# ── Assemble .app bundle ────────────────────────────────────────────
log "Assembling $APP_NAME.app bundle..."
APP_PATH="dist/$APP_NAME.app"
rm -rf "$APP_PATH"

CONTENTS="$APP_PATH/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

# Copy Swift binary as main executable
cp "build/$APP_NAME" "$MACOS/$APP_NAME"

# Copy PyInstaller-built CLI into the bundle
if [[ -d "dist/b2ou-cli" ]]; then
    cp -R "dist/b2ou-cli" "$MACOS/b2ou-cli-dist"
    # Create a wrapper script that the Swift app calls
    cat > "$MACOS/b2ou-cli" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/b2ou-cli-dist/b2ou-cli" "$@"
WRAPPER
    chmod +x "$MACOS/b2ou-cli"
fi

# Copy icons
if [[ -d resources/icons ]]; then
    mkdir -p "$RESOURCES/resources/icons"
    cp resources/icons/*.png "$RESOURCES/resources/icons/"
fi
if [[ -f resources/B2OU.icns ]]; then
    cp resources/B2OU.icns "$RESOURCES/B2OU.icns"
fi

# Write Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
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
    <string>6.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>6.0</string>
    <key>CFBundleExecutable</key>
    <string>B2OU</string>
    <key>CFBundleIconFile</key>
    <string>B2OU</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# ── Verify ───────────────────────────────────────────────────────────
if [[ -d "$APP_PATH" ]]; then
    SIZE=$(du -sh "$APP_PATH" | cut -f1)
    log "Built successfully: $APP_PATH ($SIZE)"
    log ""
    log "To install:"
    log "  cp -r dist/$APP_NAME.app /Applications/"
    log ""
    log "To run now:"
    log "  open dist/$APP_NAME.app"
else
    err "Build failed — $APP_PATH not found"
    exit 1
fi

deactivate
