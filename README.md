# B2OU

[中文文档](README.zh-CN.md)

![B2OU hero](docs/hero.png)

Bear → Obsidian / Ulysses export tool for macOS.
The runtime is implemented in Swift, and the menu-bar UI plus utility windows
are built with SwiftUI.

Latest release: [v6.1.0](https://github.com/desususu/B2OU/releases/tag/v6.1.0) · Download: [B2OU.app.zip](https://github.com/desususu/B2OU/releases/download/v6.1.0/B2OU.app.zip)

---

## macOS: “App is damaged and can’t be opened”

If you download the app from GitHub and see “B2OU.app is damaged and can’t be opened”, this is macOS Gatekeeper.
Without an Apple Developer ID, the app is **unsigned/not notarized**, so other Macs will block it by default.

Pick one of these on the target Mac:
- Remove the quarantine flag (most reliable):
  `xattr -dr com.apple.quarantine "/Applications/B2OU.app"`
- System Settings → Privacy & Security → click `Open Anyway` after the first failed launch.
- Finder right‑click `B2OU.app` → `Open` → confirm.

---

## Backup Required Before First Use (Important)

Before running this tool for the first time, **please back up your Bear data**.
B2OU now prefers Bear 2.8+’s official `bearcli` for reading notes. If `bearcli`
is not available, it falls back to the older read-only SQLite snapshot path,
which still uses the SQLite **backup API** to reduce interference with Bear.

Recommended backup options (choose one):
- Quit Bear and manually copy the database file.
- Use Time Machine or another system backup.
- Export everything via Bear’s built‑in export feature.

Default database path (may vary by system/version):
- `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite`

Default Bear CLI path:
- `/Applications/Bear.app/Contents/MacOS/bearcli`

---

## Overview

B2OU converts Bear notes to **Markdown** or **TextBundle** (ideal for Ulysses). It
supports incremental exports, tag‑based folders, YAML front matter, and optional
watch mode.

---

## How It Works

- Prefers Bear’s official `bearcli` to read active notes, timestamps, tags, and attachments.
- Falls back to opening Bear’s SQLite database in **read‑only** mode when `bearcli` is unavailable or `sqlite` is selected.
- Uses the SQLite **backup API** on the fallback path to snapshot the DB.
- Parses notes and normalizes Bear‑specific Markdown.
- Generates filenames based on a chosen naming strategy.
- Writes Markdown or TextBundle files to disk.
- Stores Bear source IDs and hashes in `.b2ou/state.json`, outside note content.
- Incremental export: skips notes whose on‑disk timestamp is already up‑to‑date.
- Cleans up stale exports and tracks generated files via a manifest to avoid deleting
  user‑created files.
- Optional `--watch` mode: content‑signature change detection with debounce and minimum
  interval to reduce thrashing.

---

## Usage

### CLI (recommended)

Quick export to a folder:
```bash
swift run b2ou export --out ~/Notes
```

Export as TextBundle:
```bash
swift run b2ou export --out ~/Notes --format tb
```

Organize by tag folders:
```bash
swift run b2ou export --out ~/Notes --tag-folders
```

Watch for DB changes and re‑export automatically:
```bash
swift run b2ou export --out ~/Notes --watch
```

Force Bear’s official CLI source:
```bash
swift run b2ou export --out ~/Notes --source bearcli
```

Force the legacy SQLite compatibility path:
```bash
swift run b2ou export --out ~/Notes --source sqlite
```

Inspect export state (read‑only):
```bash
swift run b2ou status --out ~/Notes
```

Preview a safe sidecar state rebuild for an existing export:
```bash
swift run b2ou rebuild-state --out ~/Notes
```

Write `.b2ou/state.json` after reviewing the preview:
```bash
swift run b2ou rebuild-state --out ~/Notes --write
```

Clean exported files and reset state:
```bash
swift run b2ou clean --out ~/Notes
```

---

## Build The macOS App

The project ships a menu‑bar app for quick use. Build it on macOS with:
```bash
swift run B2OUBundler
```

Output:
- `dist/B2OU.app`
- `dist/b2ou`

Clean build artifacts:
```bash
swift run B2OUBundler clean
```

Build only the CLI binary:
```bash
swift run B2OUBundler cli
```

---

## Optional: `b2ou.toml` profiles

Define multiple profiles to export to different targets.

Config search paths:
- `./b2ou.toml`
- `~/.config/b2ou/b2ou.toml`
- `~/b2ou.toml`

Example:
```toml
[profile.obsidian]
out = "~/Vaults/Bear"
format = "md"
tag-folders = true
yaml-front-matter = true
naming = "date-title"

[profile.ulysses]
out = "~/Ulysses/Inbox"
format = "tb"
```

Run a profile:
```bash
swift run b2ou export --profile obsidian
```

---

## Options At a Glance

- `--format md|tb|both`: export format
- `--source auto|bearcli|sqlite`: read source, default `auto` (prefer Bear CLI, fall back to SQLite)
- `--bearcli PATH`: path to the `bearcli` executable
- `--yaml-front-matter`: add YAML metadata
- `--hide-tags`: strip Bear tags from body
- `--exclude-tag TAG`: skip notes with a tag (repeatable)
- `--naming title|slug|date-title|id`: filename strategy
- `--on-delete trash|remove|keep`: stale file policy

Design notes for Obsidian CLI, Obsidian Sync, and safe bidirectional sync:
- `docs/obsidian-cli-sync-notes.md`
