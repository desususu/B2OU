# B2OU — Apple Native Refactoring Plan

## Goal

Rewrite the B2OU project (currently ~5K lines Python + ~2K lines Swift) entirely in Swift,
eliminating the Python runtime dependency and achieving native macOS performance (~5 MB RAM,
instant launch, no bundled interpreter).

---

## Current Architecture

| Layer | Current Tech | LOC |
|---|---|---|
| CLI | Python (argparse) | 563 |
| Export engine | Python | 784 |
| SQLite DB access | Python (sqlite3) | 296 |
| Markdown transforms | Python (regex) | 295 |
| Image handling | Python | 461 |
| Config / profiles | Python (dataclass, TOML) | 269 |
| i18n | Python + NSUserDefaults | 456 |
| Menu-bar app | Swift (shells out to Python CLI) | ~2000 |
| Settings panel | Python (PyObjC / AppKit) | 732 |
| Autostart | Python (LaunchAgent plist) | 88 |
| **Total** | | **~5,944** |

## Target Architecture

Everything in Swift, single binary, no Python dependency.

---

## Phase 1 — Foundation & Data Layer

### 1.1 Swift Package setup
- Create a Swift Package (`Package.swift`) with two targets:
  - **B2OUCore** (library) — all logic
  - **b2ou** (executable) — CLI entry point
- Add dependency on **swift-argument-parser** (CLI) and **GRDB** or raw SQLite3 C API (database).
- Keep the existing `swift/B2OUMenuBar.swift` as reference; it will be integrated later.

### 1.2 Configuration model (`Sources/B2OUCore/Config.swift`)
- Port `config.py` — translate the `ExportConfig` dataclass to a Swift `struct` with `Codable`.
- Port `profile.py` — TOML parsing (use a lightweight Swift TOML library, or parse manually since the format is simple).
- Port `constants.py` — regex patterns as `NSRegularExpression` / Swift `Regex` (Swift 5.7+).

### 1.3 Database layer (`Sources/B2OUCore/Database.swift`)
- Port `db.py` — open Bear's SQLite DB in read-only mode.
- Implement the SQLite backup API via the C `sqlite3_backup_*` functions.
- Model `BearNote` struct (id, title, text, modifiedDate, tags, hasFiles, etc.).
- Handle Core Data epoch (2001-01-01) timestamps.

### 1.4 Unit tests for Phase 1
- Port `test_config.py` and `test_profile.py` to Swift XCTest.
- Add DB layer tests with a fixture `.sqlite` file.

---

## Phase 2 — Export Engine

### 2.1 Markdown transforms (`Sources/B2OUCore/Markdown.swift`)
- Port `markdown.py` — Bear-specific syntax → standard Markdown.
- Use Swift `Regex` (or `NSRegularExpression`) for all transformations.
- Port `test_markdown.py` to XCTest.

### 2.2 Image handling (`Sources/B2OUCore/Images.swift`)
- Port `images.py` — image extraction, path normalization, copy/embed logic.
- Use `FileManager` for all file operations.
- Port `test_images.py` to XCTest.

### 2.3 Core export engine (`Sources/B2OUCore/Export.swift`)
- Port `export.py` — incremental export with manifest tracking.
- Implement `.b2ou-manifest` read/write (JSON or plist).
- Support Markdown, TextBundle, and hybrid export modes.
- YAML front matter generation.
- Tag-based folder creation.
- Stale file cleanup (trash via `NSWorkspace.shared.recycle`, remove, keep).
- Port `test_export.py` to XCTest.

---

## Phase 3 — CLI

### 3.1 CLI entry point (`Sources/b2ou/CLI.swift`)
- Port `cli.py` using **swift-argument-parser**.
- Subcommands: `export`, `status`, `clean`, `version`.
- Same flags/options as current CLI for backward compatibility.
- Watch mode (`--watch`) using `DispatchSource.makeFileSystemObjectSource` or a timer.

### 3.2 CLI integration tests
- Port `test_cli.py` — test argument parsing and end-to-end export.

---

## Phase 4 — Menu-Bar App (Native)

### 4.1 Merge existing Swift menu-bar code
- Refactor `swift/B2OUMenuBar.swift` to call **B2OUCore** directly instead of shelling out to the Python CLI.
- Remove all `Process`/subprocess management code.
- Remove JSON status-file polling; call export engine in-process.

### 4.2 Settings panel (`SettingsPanel.swift`)
- Port `settings_panel.py` to native AppKit (NSWindow, NSStackView, etc.).
- The existing Swift file already has a partial settings dialog — expand it to full parity.

### 4.3 Internationalization (`Sources/B2OUCore/I18n.swift`)
- Port `i18n.py` — use `Bundle.localizedString` or a lightweight string table.
- Support English and Chinese.
- Use `Localizable.strings` files for proper macOS localization.

### 4.4 Autostart (`Sources/B2OUCore/Autostart.swift`)
- Port `autostart.py` — LaunchAgent plist management via `FileManager`.
- Alternatively use `SMAppService` (macOS 13+) or `SMLoginItemSetEnabled`.

---

## Phase 5 — Build & Distribution

### 5.1 Xcode project / SPM build
- Add an Xcode project (or keep pure SPM) for the `.app` bundle target.
- Configure `Info.plist`: LSUIElement, bundle ID (`net.b2ou.app`), icon.
- Embed resources (icons, localization files).

### 5.2 Replace build scripts
- Remove `build_app.sh`, `B2OU.spec`, `B2OU-CLI.spec`, `setup_app.py`.
- Single `swift build -c release` for CLI.
- `xcodebuild` or `swift build` for `.app`.
- Update `Makefile` targets accordingly.

### 5.3 Final cleanup
- Remove `pyproject.toml`, Python virtualenv references.
- Archive `b2ou/` Python package (or delete after verification).
- Update `README.md` and `README.zh-CN.md` with new build/install instructions.

---

## Phase 6 — Validation

### 6.1 Feature parity checklist
- [ ] All export formats (md, textbundle, hybrid)
- [ ] Incremental export with manifest
- [ ] All naming strategies (title, slug, date-title, id)
- [ ] YAML front matter
- [ ] Tag-based folders
- [ ] Image handling (copy, embed, shared folder)
- [ ] Watch mode (CLI + menu-bar)
- [ ] Settings persistence
- [ ] i18n (en, zh)
- [ ] Autostart / login item
- [ ] Stale file cleanup (trash, remove, keep)

### 6.2 Performance benchmarks
- Measure: launch time, memory usage, export throughput (notes/sec).
- Target: <5 MB idle RAM, <100 ms cold start, ≥2× Python throughput.

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Min macOS version | 13.0 (Ventura) | Swift `Regex`, `SMAppService`, modern APIs |
| SQLite access | Raw C API via Swift | Zero overhead, backup API support, no heavy ORM |
| CLI framework | swift-argument-parser | Standard Apple-endorsed CLI library |
| TOML parsing | Lightweight Swift library or manual | Simple config format, minimal dependency |
| UI framework | AppKit (not SwiftUI) | Menu-bar apps need AppKit; matches existing code |
| Localization | `Localizable.strings` | Native macOS pattern, tooling support |

## Estimated Scope

| Phase | Estimated Swift LOC |
|---|---|
| Phase 1 — Foundation | ~500 |
| Phase 2 — Export engine | ~1,200 |
| Phase 3 — CLI | ~400 |
| Phase 4 — Menu-bar app | ~1,500 |
| Phase 5 — Build/dist | ~100 (configs) |
| **Total** | **~3,700** |

Swift is more concise than Python for this workload due to built-in macOS APIs, so total LOC decreases despite full feature parity.
