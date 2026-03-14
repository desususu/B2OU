# B2OU

[中文文档](README.zh-CN.md)

![B2OU hero](docs/hero.png)

Bear → Obsidian / Ulysses export tool for macOS.

Latest release: [v6.1.0](https://github.com/desususu/B2OU/releases/tag/v6.1.0) · Download: [B2OU.app.zip](https://github.com/desususu/B2OU/releases/download/v6.1.0/B2OU.app.zip)

---

## Backup Required Before First Use (Important)

Before running this tool for the first time, **please back up your Bear database**.
B2OU opens the database in **read‑only** mode and prefers the SQLite **backup API**
for safe snapshots, but any tool that reads production data should be used only after
a backup exists.

Recommended backup options (choose one):
- Quit Bear and manually copy the database file.
- Use Time Machine or another system backup.
- Export everything via Bear’s built‑in export feature.

Default database path (may vary by system/version):
- `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite`

---

## Overview

B2OU converts Bear notes to **Markdown** or **TextBundle** (ideal for Ulysses). It
supports incremental exports, tag‑based folders, YAML front matter, and optional
watch mode.

---

## How It Works

- Opens Bear’s SQLite database in **read‑only** mode.
- Uses the SQLite **backup API** to snapshot the DB (minimizes interference with live writes).
- Parses notes and normalizes Bear‑specific Markdown.
- Generates filenames based on a chosen naming strategy.
- Writes Markdown or TextBundle files to disk.
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
python -m b2ou export --out ~/Notes
```

Export as TextBundle:
```bash
python -m b2ou export --out ~/Notes --format tb
```

Organize by tag folders:
```bash
python -m b2ou export --out ~/Notes --tag-folders
```

Watch for DB changes and re‑export automatically:
```bash
python -m b2ou export --out ~/Notes --watch
```

Inspect export state (read‑only):
```bash
python -m b2ou status --out ~/Notes
```

Clean exported files and reset state:
```bash
python -m b2ou clean --out ~/Notes
```

---

## Build The macOS App

The project ships a menu‑bar app for quick use. Build it on macOS with:
```bash
./build_app.sh
```

Output:
- `dist/B2OU.app`

Clean build artifacts:
```bash
./build_app.sh clean
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
python -m b2ou export --profile obsidian
```

---

## Options At a Glance

- `--format md|tb|both`: export format
- `--yaml-front-matter`: add YAML metadata
- `--hide-tags`: strip Bear tags from body
- `--exclude-tag TAG`: skip notes with a tag (repeatable)
- `--naming title|slug|date-title|id`: filename strategy
- `--on-delete trash|remove|keep`: stale file policy
