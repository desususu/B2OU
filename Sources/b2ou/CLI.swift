// CLI.swift — Command-line interface for b2ou.
//
// Subcommands: export, status, clean, rebuild-state

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
        subcommands: [Export.self, Status.self, Clean.self, RebuildState.self]
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

    @Option(name: .long, help: "Bear read source: auto, bearcli, or sqlite")
    var source: String?

    @Option(name: .long, help: "Path to Bear's bearcli executable")
    var bearcli: String?

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
            if let source { cfg.bearSource = source }
            if let bearcli { cfg.bearCLIPath = URL(fileURLWithPath: bearcli) }
            return cfg
        }

        guard let out else {
            printErr("Error: --out is required (or use --profile)")
            throw ExitCode(rawValue: 1)
        }

        return ExportConfig(
            exportPath: URL(fileURLWithPath: out),
            exportPathTB: outTb.map { URL(fileURLWithPath: $0) },
            bearCLIPath: bearcli.map { URL(fileURLWithPath: $0) } ?? defaultBearCLIPath,
            bearSource: source ?? "auto",
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

    @Option(name: .long, help: "Bear read source: auto, bearcli, or sqlite")
    var source: String = "auto"

    @Option(name: .long, help: "Path to Bear's bearcli executable")
    var bearcli: String?

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    func run() {
        setupLogging(verbose: verbose)

        let cfg = ExportConfig(
            exportPath: URL(fileURLWithPath: out),
            bearCLIPath: bearcli.map { URL(fileURLWithPath: $0) } ?? defaultBearCLIPath,
            bearSource: source
        )

        let maxMod: Double
        let noteCount: Int
        let usedBearCLI: Bool
        if shouldReadWithBearCLI(config: cfg),
           let sig = try? BearCLIClient(executable: cfg.bearCLIPath).signature(location: "notes") {
            maxMod = sig.latestModified
            noteCount = sig.noteCount
            usedBearCLI = true
        } else {
            let dbSig = bearDBSignature(dbPath: cfg.bearDB)
            maxMod = dbSig.maxMod
            noteCount = dbSig.noteCount
            usedBearCLI = false
        }

        if noteCount < 0 {
            print("Bear database:     not found at \(cfg.bearDB.path)")
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let modStr = formatter.string(from: Date(timeIntervalSince1970: maxMod))
        let sourceLabel = usedBearCLI ? "Bear CLI" : "Bear database"
        print("\(sourceLabel):     \(noteCount) active notes (last modified: \(modStr))")

        let fm = FileManager.default
        let exportPath = cfg.exportPath
        guard fm.fileExists(atPath: exportPath.path) else {
            print("Export folder:     not found at \(exportPath.path)")
            return
        }

        var fileCount = 0
        var bundleCount = 0
        if let enumerator = fm.enumerator(at: exportPath, includingPropertiesForKeys: [.isDirectoryKey]) {
            let skipSet = exportSkipDirs.union([".b2ou-trash"])
            while let url = enumerator.nextObject() as? URL {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    let name = url.lastPathComponent
                    if skipSet.contains(name) || exportSkipDirPrefixes.contains(where: { name.hasPrefix($0) }) {
                        enumerator.skipDescendants()
                        continue
                    }
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
            if let tsMod = (try? fm.attributesOfItem(atPath: cfg.exportTsFile.path))?[.modificationDate] as? Date {
                let sig = sourceSignature(config: cfg)
                if sig.byteCount < 0 {
                    print("Pending changes:   source unavailable")
                } else if sig.lastModified > tsMod.timeIntervalSince1970 {
                    print("Pending changes:   source modified since last export")
                } else {
                    print("Pending changes:   none (up to date)")
                }
            }
        } else {
            print("Pending changes:   never exported")
        }
    }
}

// MARK: - Rebuild State Subcommand

struct RebuildState: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild-state",
        abstract: "Preview or rebuild the sidecar Bear-to-file mapping without modifying notes"
    )

    @Option(name: .long, help: "Export folder to inspect")
    var out: String

    @Option(name: .long, help: "Path to Bear's bearcli executable")
    var bearcli: String?

    @Flag(name: .long, help: "Write .b2ou/state.json. Without this flag, only preview.")
    var write = false

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false

    func run() throws {
        setupLogging(verbose: verbose)

        let exportPath = URL(fileURLWithPath: out)
        let client = BearCLIClient(executable: bearcli.map { URL(fileURLWithPath: $0) } ?? defaultBearCLIPath)
        guard client.isAvailable else {
            printErr("Error: Bear CLI is not available at \(client.executable.path)")
            throw ExitCode(rawValue: 1)
        }

        let notes = try client.listNoteMetadata(location: "notes")
        let report = rebuildSyncStatePlan(exportPath: exportPath, bearNotes: notes, write: write)

        print("Mode:              \(report.previewOnly ? "preview" : "write")")
        print("Bear notes:        \(report.bearActiveNotes)")
        print("Managed files:     \(report.managedExportFiles)")
        print("Unmanaged files:   \(report.unmanagedExportFiles)")
        print("Planned bindings:  \(report.plannedBindings)")
        print("Unbound files:     \(report.unboundManagedFiles)")
        print("Unbound Bear notes:\(report.unboundBearNotes)")
        print("Methods:           \(formatCounts(report.bindingMethods))")
        print("Risk levels:       \(formatCounts(report.bindingRiskLevels))")

        if write {
            print("State written:     \(report.statePath.path)")
        } else {
            print("State preview:     \(report.statePath.path)")
            print("Next:              rerun with --write to create the sidecar")
        }

        if !report.isSafeToWrite {
            printErr("Warning: the mapping has unbound or high-risk entries. Review before using it for sync.")
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

        let result = cleanManagedExport(exportPath: exportPath, keepImages: keepImages)
        if result.removedImages {
            log("Removed BearImages folder.")
        }
        log("Cleaned \(result.removedFiles) managed exported files from \(exportPath.path)")
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
            if let message = result.errorMessage, !message.isEmpty {
                printErr("Error: \(message)")
            } else {
                log("Export already running for \(sub.exportPath.path) — skipping.")
            }
            continue
        }
        if result.hasConflicts {
            printErr(B2OUError.dirtyExportFiles(result.conflictPaths.sorted { $0.path < $1.path }).localizedDescription)
            continue
        }
        writeTimestamps(config: sub)

        var removed = 0
        if sub.onlyNoteUUIDs.isEmpty {
            removed = cleanupStaleNotes(exportPath: sub.exportPath, expectedPaths: result.expectedPaths, onDelete: sub.onDelete)
            if removed > 0 { log("Cleaned \(removed) stale files from export folder.") }
            writeManifest(exportPath: sub.exportPath, paths: result.expectedPaths)
        }

        if result.changedCount > 0 || removed > 0 {
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

    var lastSignature = (lastModified: 0.0, byteCount: Int64(-1))
    var lastExportTime: Double = 0
    var consecutiveFailures = 0
    var noteCount = 0
    var idleSleep = 2.0
    let idleMax = 30.0

    while !shutdownFlag {
        let shouldSleep: Bool = autoreleasepool {
            let sig = sourceSignature(config: cfg)
            if sig == lastSignature || sig.byteCount < 0 {
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

            if lastSignature.byteCount >= 0 {
                log("Bear database changed, waiting for writes to settle...")
                var waited = 0.0
                while !shutdownFlag && waited < debounce * 3 {
                    if sourceIsQuiet(config: cfg, quietSeconds: debounce) { break }
                    Thread.sleep(forTimeInterval: 1.0)
                    waited += 1.0
                }
            }

            writeStatus(statusFile, state: "exporting", noteCount: noteCount, exportPath: cfg.exportPath.path)

            noteCount = runExport(cfg)
            lastExportTime = Date().timeIntervalSince1970
            consecutiveFailures = 0
            writeStatus(statusFile, state: "idle", noteCount: noteCount, exportPath: cfg.exportPath.path)

            lastSignature = sourceSignature(config: cfg)
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

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

private func log(_ message: String) {
    print("\(logFormatter.string(from: Date())) [INFO] \(message)")
}

private func printErr(_ message: String) {
    let stderr = FileHandle.standardError
    stderr.write(Data("\(message)\n".utf8))
}

private func formatCounts(_ counts: [String: Int]) -> String {
    if counts.isEmpty { return "-" }
    return counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", ")
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
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: tmp, atomically: false, encoding: .utf8)
        if fm.fileExists(atPath: statusFile.path) {
            _ = try fm.replaceItemAt(statusFile, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: statusFile)
        }
    } catch {
        try? fm.removeItem(at: tmp)
    }
}
