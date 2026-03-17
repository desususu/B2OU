// CLI.swift — Command-line interface for b2ou.
//
// Subcommands: export, status, clean

import ArgumentParser
import B2OUCore
import Foundation

import Darwin.C

let appVersion = "7.0.0"

/// Global flag for signal handlers (C function pointers cannot capture context).
private nonisolated(unsafe) var shutdownFlag = false

@main
struct B2OUCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "b2ou",
        abstract: "Bear to Obsidian / Ulysses export tool",
        version: appVersion,
        subcommands: [Export.self, Status.self, Clean.self]
    )
}

// MARK: - Export Subcommand

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export Bear notes to disk"
    )

    @Option(name: .long, help: "Destination folder for exported notes")
    var out: String?

    @Option(name: .long, help: "Use settings from a b2ou.toml profile")
    var profile: String?

    @Flag(name: .long, help: "Run all profiles from b2ou.toml")
    var all = false

    @Option(name: .long, help: "Path to b2ou.toml")
    var config: String?

    @Option(name: .long, help: "Override path for the BearImages asset folder")
    var images: String?

    @Option(name: .long, help: "Export format: md, tb, or both")
    var format: String = "md"

    @Option(name: .long, help: "TextBundle output folder (required with --format both)")
    var outTb: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Skip notes with this Bear tag (repeatable)")
    var excludeTag: [String] = []

    @Flag(name: .long, help: "Strip #tags from exported Markdown")
    var hideTags = false

    @Flag(name: .long, help: "Organise notes into subdirectories by tag")
    var tagFolders = false

    @Flag(name: .long, help: "Add YAML front matter")
    var yamlFrontMatter = false

    @Option(name: .long, help: "Filename strategy: title, slug, date-title, id")
    var naming: String = "title"

    @Option(name: .long, help: "How to handle stale files: trash, remove, keep")
    var onDelete: String = "trash"

    @Flag(name: .long, help: "Re-export all notes, ignoring incremental cache")
    var force = false

    @Flag(name: .long, help: "Re-export on Bear database changes")
    var watch = false

    @Option(name: .long, help: "With --watch: seconds to wait after DB change")
    var debounce: Double = 3.0

    @Option(name: .long, help: "Write JSON status to this file (for GUI integration)")
    var statusFile: String?

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    func run() throws {
        setupLogging(verbose: verbose)

        if all {
            let profiles = loadProfiles(configPath: config)
            guard !profiles.isEmpty else {
                throw ExitCode(rawValue: 1)
            }
            for (name, cfg) in profiles {
                log("Running profile: \(name)")
                if !force && !checkDBModified(config: cfg) {
                    log("  Skipped (unchanged).")
                    continue
                }
                runExport(cfg)
            }
            return
        }

        let cfg = try buildConfig()
        let statusURL = statusFile.map { URL(fileURLWithPath: $0) }

        if watch {
            runWatchLoop(cfg: cfg, debounce: debounce, statusFile: statusURL)
            return
        }

        if !force && !checkDBModified(config: cfg) {
            log("No notes needed export (Bear database unchanged).")
            return
        }

        runExport(cfg)
    }

    private func buildConfig() throws -> ExportConfig {
        if let profileName = profile {
            var cfg = try loadProfile(name: profileName, configPath: config)
            if let out { cfg.exportPath = URL(fileURLWithPath: out) }
            if let outTb { cfg.exportPathTB = URL(fileURLWithPath: outTb) }
            if let images { cfg.assetsPath = URL(fileURLWithPath: images) }
            return cfg
        }

        guard let out else {
            printErr("Error: --out is required (or use --profile)")
            throw ExitCode(rawValue: 1)
        }

        return ExportConfig(
            exportPath: URL(fileURLWithPath: out),
            exportPathTB: outTb.map { URL(fileURLWithPath: $0) },
            assetsPath: images.map { URL(fileURLWithPath: $0) },
            exportFormat: format,
            makeTagFolders: tagFolders,
            hideTags: hideTags,
            excludeTags: excludeTag,
            yamlFrontMatter: yamlFrontMatter,
            naming: naming,
            onDelete: onDelete
        )
    }
}

// MARK: - Status Subcommand

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show export state without modifying anything"
    )

    @Option(name: .long, help: "Export folder to inspect")
    var out: String

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    func run() {
        setupLogging(verbose: verbose)

        let cfg = ExportConfig(exportPath: URL(fileURLWithPath: out))
        let (maxMod, noteCount) = bearDBSignature(dbPath: cfg.bearDB)

        if noteCount < 0 {
            print("Bear database:     not found at \(cfg.bearDB.path)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let modStr = formatter.string(from: Date(timeIntervalSince1970: maxMod))
        print("Bear database:     \(noteCount) active notes (last modified: \(modStr))")

        let fm = FileManager.default
        let exportPath = cfg.exportPath
        guard fm.fileExists(atPath: exportPath.path) else {
            print("Export folder:     not found at \(exportPath.path)")
            return
        }

        var fileCount = 0
        var bundleCount = 0
        if let enumerator = fm.enumerator(at: exportPath, includingPropertiesForKeys: [.isDirectoryKey]) {
            while let url = enumerator.nextObject() as? URL {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if url.pathExtension == "textbundle" {
                        bundleCount += 1
                        enumerator.skipDescendants()
                    }
                } else {
                    let ext = url.pathExtension.lowercased()
                    if ext == "md" || ext == "txt" || ext == "markdown" { fileCount += 1 }
                }
            }
        }

        print("Export folder:     \(fileCount + bundleCount) files in \(exportPath.path)")

        if fm.fileExists(atPath: cfg.exportTsFile.path) {
            if let dbMod = (try? fm.attributesOfItem(atPath: cfg.bearDB.path))?[.modificationDate] as? Date,
               let tsMod = (try? fm.attributesOfItem(atPath: cfg.exportTsFile.path))?[.modificationDate] as? Date {
                if dbMod > tsMod {
                    print("Pending changes:   database modified since last export")
                } else {
                    print("Pending changes:   none (up to date)")
                }
            }
        } else {
            print("Pending changes:   never exported")
        }
    }
}

// MARK: - Clean Subcommand

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove exported files and reset state"
    )

    @Option(name: .long, help: "Export folder to clean")
    var out: String

    @Flag(name: .long, help: "Keep the BearImages folder, only remove note files")
    var keepImages = false

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompt")
    var yes = false

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    func run() {
        setupLogging(verbose: verbose)
        let fm = FileManager.default
        let exportPath = URL(fileURLWithPath: out)

        guard fm.fileExists(atPath: exportPath.path) else {
            printErr("Export folder does not exist: \(out)")
            return
        }

        if !yes {
            print("This will remove all exported notes from: \(exportPath.path)")
            if keepImages { print("(BearImages folder will be kept)") }
            print("Continue? [y/N] ", terminator: "")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                print("Aborted.")
                return
            }
        }

        var removed = 0
        if let enumerator = fm.enumerator(at: exportPath, includingPropertiesForKeys: [.isDirectoryKey]) {
            let skipSet: Set<String> = [".b2ou-trash", ".obsidian", "BearImages"]
            while let url = enumerator.nextObject() as? URL {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let name = url.lastPathComponent
                if isDir {
                    if skipSet.contains(name) || name.hasPrefix(".Ulysses") {
                        enumerator.skipDescendants()
                        continue
                    }
                    if name.hasSuffix(".textbundle") {
                        try? fm.removeItem(at: url)
                        removed += 1
                        enumerator.skipDescendants()
                    }
                } else {
                    let ext = url.pathExtension.lowercased()
                    if ext == "md" || ext == "txt" || ext == "markdown" {
                        try? fm.removeItem(at: url)
                        removed += 1
                    }
                }
            }
        }

        if !keepImages {
            let imagesPath = exportPath.appendingPathComponent("BearImages")
            if fm.fileExists(atPath: imagesPath.path) {
                try? fm.removeItem(at: imagesPath)
                log("Removed BearImages folder.")
            }
        }

        for name in [".export-time.log", ".b2ou-manifest"] {
            let p = exportPath.appendingPathComponent(name)
            try? fm.removeItem(at: p)
        }

        let trashPath = exportPath.appendingPathComponent(".b2ou-trash")
        if fm.fileExists(atPath: trashPath.path) {
            try? fm.removeItem(at: trashPath)
            log("Removed .b2ou-trash folder.")
        }

        // Clean empty subdirectories
        if let enumerator = fm.enumerator(at: exportPath, includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.producesRelativePathURLs]) {
            var dirs: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { dirs.append(url) }
            }
            for d in dirs.sorted(by: { $0.path > $1.path }) {
                if let contents = try? fm.contentsOfDirectory(atPath: d.path), contents.isEmpty {
                    try? fm.removeItem(at: d)
                }
            }
        }

        log("Cleaned \(removed) exported files from \(exportPath.path)")
    }
}

// MARK: - Export Runner

@discardableResult
private func runExport(_ cfg: ExportConfig) -> Int {
    var totalCount = 0
    var totalChanged = 0
    var paths: [String] = []

    let configs: [ExportConfig]
    do { configs = try cfg.splitExportConfigs() }
    catch { printErr("Error: \(error.localizedDescription)"); return 0 }

    for sub in configs {
        try? FileManager.default.createDirectory(at: sub.exportPath, withIntermediateDirectories: true)
        let result = exportNotes(config: sub)
        if result.changedCount < 0 {
            log("Export already running for \(sub.exportPath.path) — skipping.")
            continue
        }
        writeTimestamps(config: sub)

        if result.changedCount > 0 {
            let removed = cleanupStaleNotes(exportPath: sub.exportPath, expectedPaths: result.expectedPaths, onDelete: sub.onDelete)
            if removed > 0 { log("Cleaned \(removed) stale files from export folder.") }

            if maintenanceDue(exportPath: sub.exportPath) {
                if sub.exportImageRepository {
                    let orphans = cleanupOrphanRootImages(config: sub)
                    if orphans > 0 { log("Cleaned \(orphans) orphan root images.") }
                }
                let purged = purgeOldTrash(exportPath: sub.exportPath)
                if purged > 0 { log("Purged \(purged) old trash folders.") }
                touchMaintenance(exportPath: sub.exportPath)
            }
        }

        if !result.expectedPaths.isEmpty {
            writeManifest(exportPath: sub.exportPath, paths: result.expectedPaths)
        }

        totalCount = max(totalCount, result.noteCount)
        totalChanged += result.changedCount
        paths.append(sub.exportPath.path)
    }

    let dest = paths.joined(separator: ", ")
    log("\(totalCount) notes exported (\(totalChanged) changed) to: \(dest)")
    return totalCount
}

// MARK: - Watch Loop

private func runWatchLoop(cfg: ExportConfig, debounce: Double, statusFile: URL?) {
    let minInterval = 10.0
    log("Watching Bear database for changes (debounce=\(String(format: "%.1f", debounce))s)...")
    log("Press Ctrl+C to stop.")

    writeStatus(statusFile, state: "watching", exportPath: cfg.exportPath.path)

    shutdownFlag = false
    signal(SIGINT) { _ in shutdownFlag = true }
    signal(SIGTERM) { _ in shutdownFlag = true }

    var lastSignature: (Double, Int) = (0.0, -1)
    var lastExportTime: Double = 0
    var consecutiveFailures = 0
    var noteCount = 0
    var idleSleep = 2.0
    let idleMax = 30.0

    while !shutdownFlag {
        let shouldSleep: Bool = autoreleasepool {
            let sig = bearDBSignature(dbPath: cfg.bearDB)
            if sig == lastSignature || sig.noteCount < 0 {
                Thread.sleep(forTimeInterval: idleSleep)
                idleSleep = min(idleMax, idleSleep * 1.5)
                return false
            }
            idleSleep = 2.0

            let interval = minInterval * pow(2.0, Double(min(consecutiveFailures, 4)))
            let elapsed = Date().timeIntervalSince1970 - lastExportTime
            if lastExportTime > 0 && elapsed < interval {
                Thread.sleep(forTimeInterval: min(2.0, interval - elapsed))
                return false
            }

            if lastSignature.1 >= 0 {
                log("Bear database changed, waiting for writes to settle...")
                var waited = 0.0
                while !shutdownFlag && waited < debounce * 3 {
                    if dbIsQuiet(dbPath: cfg.bearDB, quietSeconds: debounce) { break }
                    Thread.sleep(forTimeInterval: 1.0)
                    waited += 1.0
                }
            }

            writeStatus(statusFile, state: "exporting", noteCount: noteCount, exportPath: cfg.exportPath.path)

            noteCount = runExport(cfg)
            lastExportTime = Date().timeIntervalSince1970
            consecutiveFailures = 0
            writeStatus(statusFile, state: "idle", noteCount: noteCount, exportPath: cfg.exportPath.path)

            lastSignature = bearDBSignature(dbPath: cfg.bearDB)
            return true
        }
        if shouldSleep {
            Thread.sleep(forTimeInterval: 2.0)
        }
    }

    writeStatus(statusFile, state: "stopped", noteCount: noteCount, exportPath: cfg.exportPath.path)
    log("Watch mode stopped.")
}

// MARK: - Helpers

private func setupLogging(verbose: Bool) {
    // For now, just a simple logging setup
}

private func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(formatter.string(from: Date())) [INFO] \(message)")
}

private func printErr(_ message: String) {
    let stderr = FileHandle.standardError
    stderr.write(Data("\(message)\n".utf8))
}

private func writeStatus(_ statusFile: URL?, state: String,
                          noteCount: Int = 0, error: String? = nil,
                          exportPath: String = "") {
    guard let statusFile else { return }
    let formatter = ISO8601DateFormatter()
    let data: [String: Any] = [
        "state": state,
        "note_count": noteCount,
        "last_update": formatter.string(from: Date()),
        "error": error as Any,
        "export_path": exportPath,
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
          let json = String(data: jsonData, encoding: .utf8) else { return }
    let tmp = statusFile.deletingLastPathComponent().appendingPathComponent(statusFile.lastPathComponent + ".tmp")
    try? json.write(to: tmp, atomically: false, encoding: .utf8)
    try? FileManager.default.moveItem(at: tmp, to: statusFile)
}

