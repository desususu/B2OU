// SyncState.swift — sidecar mapping for safe Bear ↔ Obsidian synchronization.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public let syncStateDirectoryName = ".b2ou"
public let syncStateFileName = "state.json"

public struct B2OUSyncState: Codable, Sendable {
    public var version: Int
    public var created: String
    public var updated: String
    public var exportRoot: String
    public var bindings: [B2OUSyncBinding]

    private enum CodingKeys: String, CodingKey {
        case version
        case created
        case updated
        case exportRoot = "export_root"
        case bindings
    }

    public init(
        version: Int = 1,
        created: String? = nil,
        updated: String? = nil,
        exportRoot: String,
        bindings: [B2OUSyncBinding]
    ) {
        self.version = version
        self.created = created ?? isoNow()
        self.updated = updated ?? isoNow()
        self.exportRoot = exportRoot
        self.bindings = bindings
    }
}

public struct B2OUSyncBinding: Codable, Sendable {
    public var obsidianPath: String
    public var bearID: String
    public var bearHash: String
    public var bearModified: String
    public var bearTitleKey: String
    public var lastExportedObsidianHash: String
    public var lastSeenMTime: Double
    public var lastSeenSize: Int64
    public var matchMethod: String
    public var riskLevel: String
    public var managedByManifest: Bool

    private enum CodingKeys: String, CodingKey {
        case obsidianPath = "obsidian_path"
        case bearID = "bear_id"
        case bearHash = "bear_hash"
        case bearModified = "bear_modified"
        case bearTitleKey = "bear_title_key"
        case lastExportedObsidianHash = "last_exported_obsidian_hash"
        case lastSeenMTime = "last_seen_mtime"
        case lastSeenSize = "last_seen_size"
        case matchMethod = "match_method"
        case riskLevel = "risk_level"
        case managedByManifest = "managed_by_manifest"
    }

    public init(
        obsidianPath: String,
        bearID: String,
        bearHash: String = "",
        bearModified: String = "",
        bearTitleKey: String = "",
        lastExportedObsidianHash: String = "",
        lastSeenMTime: Double = 0,
        lastSeenSize: Int64 = 0,
        matchMethod: String,
        riskLevel: String,
        managedByManifest: Bool
    ) {
        self.obsidianPath = obsidianPath
        self.bearID = bearID
        self.bearHash = bearHash
        self.bearModified = bearModified
        self.bearTitleKey = bearTitleKey
        self.lastExportedObsidianHash = lastExportedObsidianHash
        self.lastSeenMTime = lastSeenMTime
        self.lastSeenSize = lastSeenSize
        self.matchMethod = matchMethod
        self.riskLevel = riskLevel
        self.managedByManifest = managedByManifest
    }
}

public struct B2OUStateRebuildReport: Sendable {
    public let previewOnly: Bool
    public let exportRoot: URL
    public let bearActiveNotes: Int
    public let managedExportFiles: Int
    public let unmanagedExportFiles: Int
    public let plannedBindings: Int
    public let unboundManagedFiles: Int
    public let unboundBearNotes: Int
    public let bindingMethods: [String: Int]
    public let bindingRiskLevels: [String: Int]
    public let statePath: URL

    public var isSafeToWrite: Bool {
        unboundManagedFiles == 0 && unboundBearNotes == 0
            && (bindingRiskLevels["high"] ?? 0) == 0
    }
}

public struct BearCLINoteMetadata: Sendable {
    public let id: String
    public let title: String
    public let hash: String
    public let modified: String

    public init(id: String, title: String, hash: String = "", modified: String = "") {
        self.id = id
        self.title = title
        self.hash = hash
        self.modified = modified
    }
}

public func syncStateURL(exportPath: URL) -> URL {
    exportPath.appendingPathComponent(syncStateDirectoryName).appendingPathComponent(syncStateFileName)
}

public func readSyncState(exportPath: URL) -> B2OUSyncState? {
    let url = syncStateURL(exportPath: exportPath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    return try? decoder.decode(B2OUSyncState.self, from: data)
}

public func writeSyncState(_ state: B2OUSyncState, exportPath: URL) throws {
    let fm = FileManager.default
    let url = syncStateURL(exportPath: exportPath)
    let dir = url.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)

    let tmp = dir.appendingPathComponent(".\(syncStateFileName).tmp-\(UUID().uuidString)")
    try data.write(to: tmp, options: [])
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
    if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
    } else {
        try fm.moveItem(at: tmp, to: url)
    }
}

public func syncBindingsByPath(exportPath: URL) -> [String: B2OUSyncBinding] {
    guard let state = readSyncState(exportPath: exportPath) else { return [:] }
    return Dictionary(uniqueKeysWithValues: state.bindings.map { ($0.obsidianPath, $0) })
}

public func syncRelativePath(from base: URL, to target: URL) -> String {
    let basePath = base.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    guard targetPath.hasPrefix(basePath) else { return target.lastPathComponent }
    var rel = String(targetPath.dropFirst(basePath.count))
    if rel.hasPrefix("/") { rel.removeFirst() }
    return rel
}

public func makeExportSyncBinding(
    exportPath: URL,
    target: URL,
    bearID: String,
    bearHash: String,
    bearModified: String,
    bearTitle: String,
    matchMethod: String = "export",
    riskLevel: String = "low",
    managedByManifest: Bool = true
) -> B2OUSyncBinding {
    let rel = syncRelativePath(from: exportPath, to: target)
    let fp = fileFingerprint(target)
    return B2OUSyncBinding(
        obsidianPath: rel,
        bearID: bearID,
        bearHash: bearHash,
        bearModified: bearModified,
        bearTitleKey: syncTitleKey(cleanTitle(bearTitle)),
        lastExportedObsidianHash: fp.hash,
        lastSeenMTime: fp.mtime,
        lastSeenSize: fp.size,
        matchMethod: matchMethod,
        riskLevel: riskLevel,
        managedByManifest: managedByManifest
    )
}

public func writeExportSyncState(
    exportPath: URL,
    bindings: [B2OUSyncBinding],
    merge: Bool = false
) {
    let existing = readSyncState(exportPath: exportPath)
    let now = isoNow()
    let nextBindings: [B2OUSyncBinding]
    if merge, let existing {
        let updatedBearIDs = Set(bindings.map(\.bearID))
        let updatedPaths = Set(bindings.map(\.obsidianPath))
        nextBindings = existing.bindings.filter {
            !updatedBearIDs.contains($0.bearID) && !updatedPaths.contains($0.obsidianPath)
        } + bindings
    } else {
        nextBindings = bindings
    }
    let state = B2OUSyncState(
        created: existing?.created ?? now,
        updated: now,
        exportRoot: exportPath.path,
        bindings: nextBindings.sorted { $0.obsidianPath < $1.obsidianPath }
    )
    try? writeSyncState(state, exportPath: exportPath)
}

public func rebuildSyncStatePlan(
    exportPath: URL,
    bearNotes: [BearCLINoteMetadata],
    write: Bool
) -> B2OUStateRebuildReport {
    let manifest = readManifest(exportPath: exportPath)
    let files = scanExportedMarkdownFiles(exportPath: exportPath, manifest: manifest)
    let managedFiles = files.filter(\.managedByManifest)
    let unmanagedFiles = files.filter { !$0.managedByManifest }

    let notes = bearNotes.map { IndexedBearNote(metadata: $0) }
    let notesByBase = Dictionary(grouping: notes, by: \.baseKey)
    let filesByBase = Dictionary(grouping: managedFiles, by: \.baseKey)
    var notesByPrefix: [String: IndexedBearNote] = [:]
    for note in notes where !note.prefix.isEmpty && notesByPrefix[note.prefix] == nil {
        notesByPrefix[note.prefix] = note
    }

    var bindings: [B2OUSyncBinding] = []
    var usedBearIDs = Set<String>()
    var usedPaths = Set<String>()

    func addBinding(file: IndexedExportFile, note: IndexedBearNote, method: String, risk: String) {
        guard !usedPaths.contains(file.relativePath), !usedBearIDs.contains(note.metadata.id) else { return }
        bindings.append(makeMigrationBinding(exportPath: exportPath, file: file, note: note, method: method, risk: risk))
        usedPaths.insert(file.relativePath)
        usedBearIDs.insert(note.metadata.id)
    }

    for (base, groupedNotes) in notesByBase {
        let groupedFiles = filesByBase[base] ?? []
        if groupedNotes.count == 1, groupedFiles.count == 1 {
            addBinding(file: groupedFiles[0], note: groupedNotes[0], method: "unique_clean_title", risk: "low")
        }
    }

    for file in managedFiles where !usedPaths.contains(file.relativePath) {
        guard let suffix = uuidSuffixMatch(file.stem) else { continue }
        guard let note = notesByPrefix[suffix.prefix], note.baseKey == suffix.baseKey else { continue }
        addBinding(file: file, note: note, method: "uuid_suffix", risk: "low")
    }

    for (base, groupedNotes) in notesByBase {
        let remainingNotes = groupedNotes.filter { !usedBearIDs.contains($0.metadata.id) }
        let remainingFiles = (filesByBase[base] ?? []).filter { !usedPaths.contains($0.relativePath) }
        if remainingNotes.count == 1, remainingFiles.count == 1 {
            addBinding(file: remainingFiles[0], note: remainingNotes[0], method: "duplicate_remainder", risk: "medium")
        }
    }

    if write {
        let now = isoNow()
        let state = B2OUSyncState(
            created: now,
            updated: now,
            exportRoot: exportPath.path,
            bindings: bindings.sorted { $0.obsidianPath < $1.obsidianPath }
        )
        try? writeSyncState(state, exportPath: exportPath)
    }

    let methods = Dictionary(grouping: bindings, by: \.matchMethod).mapValues(\.count)
    let risks = Dictionary(grouping: bindings, by: \.riskLevel).mapValues(\.count)
    return B2OUStateRebuildReport(
        previewOnly: !write,
        exportRoot: exportPath,
        bearActiveNotes: bearNotes.count,
        managedExportFiles: managedFiles.count,
        unmanagedExportFiles: unmanagedFiles.count,
        plannedBindings: bindings.count,
        unboundManagedFiles: managedFiles.count - usedPaths.count,
        unboundBearNotes: bearNotes.count - usedBearIDs.count,
        bindingMethods: methods,
        bindingRiskLevels: risks,
        statePath: syncStateURL(exportPath: exportPath)
    )
}

public func syncTitleKey(_ title: String) -> String {
    title
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

public func fileFingerprint(_ url: URL) -> (hash: String, size: Int64, mtime: Double) {
    let fm = FileManager.default
    let sourceURL: URL
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        sourceURL = url.appendingPathComponent("text.md")
    } else {
        sourceURL = url
    }

    let attrs = (try? fm.attributesOfItem(atPath: sourceURL.path)) ?? [:]
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    guard let data = try? Data(contentsOf: sourceURL) else {
        return ("", size, mtime)
    }

#if canImport(CryptoKit)
    let digest = SHA256.hash(data: data)
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return (hash, size, mtime)
#else
    return (String(data.hashValue), size, mtime)
#endif
}

private struct IndexedBearNote {
    let metadata: BearCLINoteMetadata
    let baseKey: String
    let prefix: String

    init(metadata: BearCLINoteMetadata) {
        self.metadata = metadata
        self.baseKey = syncTitleKey(cleanTitle(metadata.title))
        self.prefix = String(metadata.id.prefix(8)).lowercased()
    }
}

private struct IndexedExportFile {
    let url: URL
    let relativePath: String
    let stem: String
    let baseKey: String
    let managedByManifest: Bool
}

private func scanExportedMarkdownFiles(exportPath: URL, manifest: Set<String>) -> [IndexedExportFile] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: exportPath,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }

    var files: [IndexedExportFile] = []
    while let url = enumerator.nextObject() as? URL {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            let name = url.lastPathComponent
            if name.hasPrefix(".")
                || exportSkipDirs.contains(name)
                || exportSkipDirPrefixes.contains(where: { name.hasPrefix($0) })
                || name.hasSuffix(".textbundle") {
                enumerator.skipDescendants()
            }
            continue
        }

        guard noteExtensions.contains(".\(url.pathExtension.lowercased())") else { continue }
        let rel = syncRelativePath(from: exportPath, to: url)
        let stem = url.deletingPathExtension().lastPathComponent
        files.append(IndexedExportFile(
            url: url,
            relativePath: rel,
            stem: stem,
            baseKey: syncTitleKey(stem),
            managedByManifest: manifest.contains(rel)
        ))
    }
    return files
}

private func makeMigrationBinding(
    exportPath: URL,
    file: IndexedExportFile,
    note: IndexedBearNote,
    method: String,
    risk: String
) -> B2OUSyncBinding {
    let fp = fileFingerprint(file.url)
    return B2OUSyncBinding(
        obsidianPath: file.relativePath,
        bearID: note.metadata.id,
        bearHash: note.metadata.hash,
        bearModified: note.metadata.modified,
        bearTitleKey: note.baseKey,
        lastExportedObsidianHash: fp.hash,
        lastSeenMTime: fp.mtime,
        lastSeenSize: fp.size,
        matchMethod: method,
        riskLevel: risk,
        managedByManifest: file.managedByManifest
    )
}

private func uuidSuffixMatch(_ stem: String) -> (baseKey: String, prefix: String)? {
    let pattern = #"^(.*) - ([0-9a-fA-F]{8})(?: - \d{2})?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = stem as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: stem, range: range), match.numberOfRanges >= 3 else {
        return nil
    }
    let base = ns.substring(with: match.range(at: 1))
    let prefix = ns.substring(with: match.range(at: 2)).lowercased()
    return (syncTitleKey(base), prefix)
}

private func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}
