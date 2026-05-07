// Export.swift — Bear SQLite database → Markdown / TextBundle files on disk.
//
// Entry point: exportNotes(config:)
//
// The export is incremental: notes whose on-disk file is already at or newer
// than the Bear modification timestamp are skipped. At the end, stale files
// are removed.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Manifest

public let manifestName = ".b2ou-manifest"

public func readManifest(exportPath: URL) -> Set<String> {
    let manifest = exportPath.appendingPathComponent(manifestName)
    guard let content = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
    return Set(content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
}

public func writeManifest(exportPath: URL, paths: Set<URL>) {
    let manifest = exportPath.appendingPathComponent(manifestName)
    let manifestPath = manifest.standardizedFileURL.path
    let exportRoot = exportPath.standardizedFileURL.path
    let lines = paths
        .compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            guard path != manifestPath else { return nil }
            let rel = path.hasPrefix(exportRoot + "/")
                ? String(path.dropFirst(exportRoot.count + 1))
                : url.lastPathComponent
            return rel
        }
        .sorted()
    let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    let tmp = manifest.deletingLastPathComponent().appendingPathComponent(".\(manifestName).tmp")
    do {
        try content.write(to: tmp, atomically: false, encoding: .utf8)
        try replaceFile(at: manifest, with: tmp)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        // Fallback: write directly
        try? content.write(to: manifest, atomically: true, encoding: .utf8)
    }
}

private func replaceFile(at destination: URL, with tmp: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: destination.path) {
        _ = try fm.replaceItemAt(destination, withItemAt: tmp)
    } else {
        try fm.moveItem(at: tmp, to: destination)
    }
}

// MARK: - Placeholder Detection

func isUntitledPlaceholder(_ note: BearNote) -> Bool {
    if !note.title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
    let text = note.text.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return true }
    return text.allSatisfy { "# \t\r\n".contains($0) }
}

// MARK: - YAML Front Matter

public func generateFrontMatter(
    note: BearNote,
    text: String,
    tags explicitTags: [String]? = nil,
    extraFields: [(String, String)] = []
) -> String {
    let created = Date(timeIntervalSince1970: coreDataToUnix(note.creationDate))
    let modified = Date(timeIntervalSince1970: coreDataToUnix(note.modifiedDate))

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdStr = formatter.string(from: created)
    let modifiedStr = formatter.string(from: modified)

    let tags = explicitTags ?? extractTags(text)

    var lines = [
        "---",
        "title: \(yamlEscape(note.title))",
        "created: \(createdStr)",
        "modified: \(modifiedStr)",
    ]
    for (key, value) in extraFields where !value.isEmpty {
        guard !["bear_id", "bear_hash", "b2ou_source"].contains(key) else { continue }
        lines.append("\(key): \(yamlEscape(value))")
    }
    if !tags.isEmpty {
        lines.append("tags:")
        for tag in tags {
            lines.append("  - \(yamlEscape(tag))")
        }
    }
    lines.append("---")
    return lines.joined(separator: "\n") + "\n\n"
}

public func yamlEscape(_ value: String) -> String {
    if value.isEmpty { return "\"\"" }
    let needsQuoting = value.contains("\n") || value.contains("\r")
        || value.contains(where: { ":{}[]&*?|>!%@`,\"'#".contains($0) })
        || value != value.trimmingCharacters(in: .whitespaces)
        || "-?:!".contains(value.first!)
    if needsQuoting {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
    return value
}

// MARK: - Filename Strategies

public func generateFilename(note: BearNote, naming: String) -> String {
    switch naming {
    case "slug":
        let slug = reNonAlnum.replaceAll(in: note.title.lowercased().trimmingCharacters(in: .whitespaces), with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "untitled" : cleanTitle(slug)

    case "date-title":
        let date = Date(timeIntervalSince1970: coreDataToUnix(note.creationDate))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let datePrefix = formatter.string(from: date)
        let slug = reNonAlnum.replaceAll(in: note.title.lowercased().trimmingCharacters(in: .whitespaces), with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let titlePart = slug.isEmpty ? "untitled" : cleanTitle(slug)
        return "\(datePrefix)-\(titlePart)"

    case "id":
        return String(note.uuid.prefix(8))

    default: // "title"
        return cleanTitle(note.title)
    }
}

// MARK: - File I/O Helpers

public func writeNoteFile(filepath: URL, content: String, modifiedUnix: Double, createdCoreData: Double) {
    let fm = FileManager.default
    let isNew = !fm.fileExists(atPath: filepath.path)
    try? fm.createDirectory(at: filepath.deletingLastPathComponent(), withIntermediateDirectories: true)

    let tmp = filepath.deletingLastPathComponent().appendingPathComponent(".\(filepath.lastPathComponent).tmp")
    do {
        try content.write(to: tmp, atomically: false, encoding: .utf8)
        // Set restrictive permissions on note content before moving into place
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: filepath.path) {
            _ = try fm.replaceItemAt(filepath, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: filepath)
        }
    } catch {
        try? fm.removeItem(at: tmp)
    }

    if modifiedUnix > 0 {
        let date = Date(timeIntervalSince1970: modifiedUnix)
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: filepath.path)
    }

    if createdCoreData > 0 && isNew {
        setCreationDate(filepath: filepath, unixTimestamp: coreDataToUnix(createdCoreData))
    }
}

#if os(macOS)
private func setCreationDate(filepath: URL, unixTimestamp: Double) {
    let secs = Int(unixTimestamp)
    let nsecs = Int((unixTimestamp - Double(secs)) * 1_000_000_000)

    var ts = timespec(tv_sec: secs, tv_nsec: nsecs)
    var attrList = attrlist()
    attrList.bitmapcount = u_short(5) // ATTR_BIT_MAP_COUNT
    attrList.commonattr = attrgroup_t(0x00000200) // ATTR_CMN_CRTIME

    withUnsafePointer(to: &ts) { tsPtr in
        let rawPtr = UnsafeMutableRawPointer(mutating: tsPtr)
        _ = setattrlist(filepath.path, &attrList, rawPtr, MemoryLayout<timespec>.size, 0)
    }
}
#else
private func setCreationDate(filepath: URL, unixTimestamp: Double) {
    // Not supported on non-macOS
}
#endif

// MARK: - Stale-File Cleanup

public func cleanupStaleNotes(exportPath: URL, expectedPaths: Set<URL>, onDelete: String = "trash") -> Int {
    guard onDelete != "keep" else { return 0 }
    let fm = FileManager.default
    guard fm.fileExists(atPath: exportPath.path) else { return 0 }

    let expectedPathStrings = Set(expectedPaths.map { $0.standardizedFileURL.path })
    let managedFiles = readManifest(exportPath: exportPath)
    var trashDir: URL? = nil
    if onDelete == "trash" {
        let dateStr: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        trashDir = exportPath.appendingPathComponent(".b2ou-trash/\(dateStr)")
    }

    var removed = 0
    var emptyDirs: [URL] = []

    guard let enumerator = fm.enumerator(
        at: exportPath,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else { return 0 }

    while let fileURL = enumerator.nextObject() as? URL {
        let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let name = fileURL.lastPathComponent

        if isDir {
            if exportSkipDirs.contains(name) || name == ".b2ou-trash" {
                enumerator.skipDescendants()
                continue
            }
            if exportSkipDirPrefixes.contains(where: { name.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }
            if name.hasSuffix(".Ulysses_Public_Filter") {
                enumerator.skipDescendants()
                continue
            }
            if name.hasSuffix(".textbundle") {
                if !expectedPathStrings.contains(fileURL.standardizedFileURL.path) {
                    let rel = relativePathString(from: exportPath, to: fileURL)
                    if !rel.isEmpty && managedFiles.contains(rel) {
                        if dispose(path: fileURL, isDir: true, trashDir: trashDir) { removed += 1 }
                    }
                }
                enumerator.skipDescendants()
                continue
            }
            emptyDirs.append(fileURL)
            continue
        }

        // File
        if sentinelFiles.contains(name) || name == manifestName { continue }
        if expectedPathStrings.contains(fileURL.standardizedFileURL.path) { continue }

        let ext = fileURL.pathExtension.lowercased()
        guard ext == "md" || ext == "txt" || ext == "markdown" else { continue }

        let rel = relativePathString(from: exportPath, to: fileURL)
        guard managedFiles.contains(rel) else { continue }
        if dispose(path: fileURL, isDir: false, trashDir: trashDir) { removed += 1 }
    }

    // Remove empty tag subdirectories (deepest first)
    for d in emptyDirs.sorted(by: { $0.path > $1.path }) {
        if let contents = try? fm.contentsOfDirectory(atPath: d.path), contents.isEmpty {
            try? fm.removeItem(at: d)
        }
    }

    return removed
}

public struct CleanExportResult: Sendable, Equatable {
    public let removedFiles: Int
    public let removedSentinels: Int
    public let removedImages: Bool

    public init(removedFiles: Int, removedSentinels: Int, removedImages: Bool) {
        self.removedFiles = removedFiles
        self.removedSentinels = removedSentinels
        self.removedImages = removedImages
    }
}

public func cleanManagedExport(exportPath: URL, keepImages: Bool = false) -> CleanExportResult {
    let fm = FileManager.default
    guard fm.fileExists(atPath: exportPath.path) else {
        return CleanExportResult(removedFiles: 0, removedSentinels: 0, removedImages: false)
    }

    let managedFiles = readManifest(exportPath: exportPath)
    var removedFiles = 0
    for rel in managedFiles.sorted(by: >) {
        guard let url = safeManagedManifestURL(exportPath: exportPath, relativePath: rel) else { continue }
        guard fm.fileExists(atPath: url.path) else { continue }
        do {
            try fm.removeItem(at: url)
            removedFiles += 1
        } catch {
            continue
        }
    }

    if let enumerator = fm.enumerator(at: exportPath, includingPropertiesForKeys: [.isDirectoryKey]) {
        var dirs: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let name = url.lastPathComponent
                if exportSkipDirs.contains(name) || name == ".b2ou-trash" {
                    enumerator.skipDescendants()
                    continue
                }
                if exportSkipDirPrefixes.contains(where: { name.hasPrefix($0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                dirs.append(url)
            }
        }
        for dir in dirs.sorted(by: { $0.path > $1.path }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    var removedImages = false
    if !keepImages {
        let imagesPath = exportPath.appendingPathComponent("BearImages")
        if fm.fileExists(atPath: imagesPath.path) {
            do {
                try fm.removeItem(at: imagesPath)
                removedImages = true
            } catch {
                removedImages = false
            }
        }
    }

    var removedSentinels = 0
    for name in [".export-time.log", ".b2ou-manifest", syncStateDirectoryName, ".b2ou-trash"] {
        let url = exportPath.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { continue }
        do {
            try fm.removeItem(at: url)
            removedSentinels += 1
        } catch {
            continue
        }
    }

    return CleanExportResult(
        removedFiles: removedFiles,
        removedSentinels: removedSentinels,
        removedImages: removedImages
    )
}

private func safeManagedManifestURL(exportPath: URL, relativePath: String) -> URL? {
    let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !(trimmed as NSString).isAbsolutePath else { return nil }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        return nil
    }

    let root = exportPath.standardizedFileURL.path
    let url = exportPath.appendingPathComponent(trimmed).standardizedFileURL
    guard url.path.hasPrefix(root + "/") else { return nil }
    return url
}

private func dispose(path: URL, isDir: Bool, trashDir: URL?) -> Bool {
    let fm = FileManager.default
    do {
        if let trashDir {
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            var dest = trashDir.appendingPathComponent(path.lastPathComponent)
            var count = 2
            while fm.fileExists(atPath: dest.path) {
                let stem = isDir ? path.lastPathComponent : (path.deletingPathExtension().lastPathComponent)
                let ext = isDir ? "" : ("." + path.pathExtension)
                dest = trashDir.appendingPathComponent("\(stem) - \(String(format: "%02d", count))\(ext)")
                count += 1
            }
            try fm.moveItem(at: path, to: dest)
        } else {
            try fm.removeItem(at: path)
        }
        return true
    } catch {
        return false
    }
}

public func purgeOldTrash(exportPath: URL, maxAgeDays: Int = 30) -> Int {
    let fm = FileManager.default
    let trashRoot = exportPath.appendingPathComponent(".b2ou-trash")
    guard fm.fileExists(atPath: trashRoot.path) else { return 0 }

    let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date())!
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    var removed = 0
    guard let contents = try? fm.contentsOfDirectory(atPath: trashRoot.path) else { return 0 }

    for entry in contents {
        guard let folderDate = dateFormatter.date(from: entry), folderDate < cutoff else { continue }
        try? fm.removeItem(at: trashRoot.appendingPathComponent(entry))
        removed += 1
    }

    // Remove trash root if empty
    if let remaining = try? fm.contentsOfDirectory(atPath: trashRoot.path), remaining.isEmpty {
        try? fm.removeItem(at: trashRoot)
    }

    return removed
}

// MARK: - Backup Utilities

public let backupFilePrefix = "bear-backup-"
public let backupLockName = ".backup.lock"
public let interruptedBackupGrace: TimeInterval = 30 * 60

public struct BackupResult: Sendable, Equatable {
    public let success: Bool
    public let backupURL: URL?
    public let errorMessage: String?
    public let rotationRemovedCount: Int
    public let cleanedInterruptedCount: Int

    public init(
        success: Bool,
        backupURL: URL? = nil,
        errorMessage: String? = nil,
        rotationRemovedCount: Int = 0,
        cleanedInterruptedCount: Int = 0
    ) {
        self.success = success
        self.backupURL = backupURL
        self.errorMessage = errorMessage
        self.rotationRemovedCount = rotationRemovedCount
        self.cleanedInterruptedCount = cleanedInterruptedCount
    }
}

public func isBackupFile(_ url: URL) -> Bool {
    url.lastPathComponent.hasPrefix(backupFilePrefix)
        && (url.pathExtension == "sqlite" || url.pathExtension == "bearclibackup")
}

public func completeBackupURLs(in dir: URL) -> [URL] {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return urls.filter { isBackupFile($0) }
}

public func latestBackupTime(in dir: URL) -> Date? {
    completeBackupURLs(in: dir).compactMap { url in
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }.max()
}

public func backupConflictsWithExportRoots(_ backupDir: URL, exportRoots: [URL]) -> Bool {
    let backupPath = backupDir.standardizedFileURL.path
    let backupPathWithSlash = backupPath.hasSuffix("/") ? backupPath : backupPath + "/"
    return exportRoots.contains { root in
        let rootPath = root.standardizedFileURL.path
        let rootPathWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return rootPath == backupPath
            || rootPathWithSlash.hasPrefix(backupPathWithSlash)
            || backupPathWithSlash.hasPrefix(rootPathWithSlash)
    }
}

public func rotateBackups(in dir: URL, maxKeep: Int) -> Int {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
        .filter({ isBackupFile($0) })
        .sorted(by: { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }) else { return 0 }

    let limit = max(1, maxKeep)
    var removed = 0
    if files.count > limit {
        for file in files[limit...] {
            do {
                try fm.removeItem(at: file)
                removed += 1
            } catch {
                continue
            }
        }
    }
    return removed
}

public func cleanupInterruptedBackups(in dir: URL) -> Int {
    let fm = FileManager.default
    let cutoff = Date().addingTimeInterval(-interruptedBackupGrace)
    var removed = 0

    if let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) {
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix(".\(backupFilePrefix)"), name.contains(".tmp-") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
    }

    return removed
}

public func acquireBackupLock(in dir: URL) -> Int32? {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockPath = dir.appendingPathComponent(backupLockName)
    let fd = open(lockPath.path, O_WRONLY | O_CREAT, 0o600)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

public func releaseBackupLock(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
}

// MARK: - Maintenance Throttling

private let maintenanceMarker = ".b2ou-maintenance"

public func maintenanceDue(exportPath: URL, minIntervalHours: Double = 6.0) -> Bool {
    let marker = exportPath.appendingPathComponent(maintenanceMarker)
    guard let content = try? String(contentsOf: marker, encoding: .utf8),
          let last = Double(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return true
    }
    return (Date().timeIntervalSince1970 - last) >= (minIntervalHours * 3600)
}

public func touchMaintenance(exportPath: URL) {
    let marker = exportPath.appendingPathComponent(maintenanceMarker)
    try? String(Date().timeIntervalSince1970.description).write(to: marker, atomically: true, encoding: .utf8)
}

public func cleanupOrphanRootImages(config: ExportConfig) -> Int {
    let fm = FileManager.default
    guard fm.fileExists(atPath: config.exportPath.path) else { return 0 }

    let referenced = collectReferencedLocalImages(rootPath: config.exportPath, skipDirs: exportSkipDirs)
    var assetBasenames = Set<String>()
    if let assetsPath = config.assetsPath, fm.fileExists(atPath: assetsPath.path) {
        if let enumerator = fm.enumerator(at: assetsPath, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                assetBasenames.insert(url.lastPathComponent)
            }
        }
    }

    var removed = 0
    guard let rootFiles = try? fm.contentsOfDirectory(at: config.exportPath, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }

    for fpath in rootFiles {
        let isFile = (try? fpath.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        guard isFile else { continue }
        let ext = ".\(fpath.pathExtension.lowercased())"
        guard imageExtensions.contains(ext) else { continue }
        guard !referenced.contains(fpath) else { continue }
        guard assetBasenames.contains(fpath.lastPathComponent) else { continue }
        try? fm.removeItem(at: fpath)
        removed += 1
    }
    return removed
}

// MARK: - TextBundle Export

public func makeTextBundle(
    text: String,
    filepath: URL,
    modUnix: Double,
    createdCoreData: Double,
    conn: SQLiteConnection,
    notePK: Int64,
    bearImagePath: URL,
    noteUUID: String = "",
    bearFilePath: URL? = nil,
    fileMap: [String: String]? = nil
) {
    let fm = FileManager.default
    let bundlePath = URL(fileURLWithPath: filepath.path + ".textbundle")
    let existingAssets = fm.fileExists(atPath: bundlePath.path) ? bundlePath.appendingPathComponent("assets") : nil

    let tmpBundle = fm.temporaryDirectory.appendingPathComponent(".b2ou-tb-\(UUID().uuidString)")
    let tmpAssets = tmpBundle.appendingPathComponent("assets")
    try? fm.createDirectory(at: tmpAssets, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpBundle) }

    let info: [String: Any] = [
        "transient": true,
        "type": "net.daringfireball.markdown",
        "version": 2,
        "creatorIdentifier": "net.shinyfrog.bear",
        "bear_uuid": noteUUID,
    ]

    do {
        let processedText = processExportImagesTextbundle(
            text: text, bundleAssets: tmpAssets, conn: conn, notePK: notePK,
            bearImagePath: bearImagePath, bearFilePath: bearFilePath,
            existingAssets: existingAssets, fileMap: fileMap
        )

        writeNoteFile(filepath: tmpBundle.appendingPathComponent("text.md"),
                      content: processedText, modifiedUnix: modUnix, createdCoreData: 0)

        let infoData = try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)
        let infoStr = String(data: infoData, encoding: .utf8) ?? "{}"
        writeNoteFile(filepath: tmpBundle.appendingPathComponent("info.json"),
                      content: infoStr, modifiedUnix: modUnix, createdCoreData: 0)

        // Atomic swap
        if fm.fileExists(atPath: bundlePath.path) {
            try fm.removeItem(at: bundlePath)
        }
        try fm.moveItem(at: tmpBundle, to: bundlePath)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: modUnix)],
                             ofItemAtPath: bundlePath.path)
    } catch {
        // defer block handles cleanup of tmpBundle
    }
}

public func makeTextBundleUsingBearCLI(
    text: String,
    filepath: URL,
    modUnix: Double,
    createdCoreData: Double,
    noteID: String,
    attachments: [BearCLIAttachment],
    bearCLI: BearCLIClient
) {
    let fm = FileManager.default
    let bundlePath = URL(fileURLWithPath: filepath.path + ".textbundle")
    let existingAssets = fm.fileExists(atPath: bundlePath.path) ? bundlePath.appendingPathComponent("assets") : nil

    let tmpBundle = fm.temporaryDirectory.appendingPathComponent(".b2ou-tb-\(UUID().uuidString)")
    let tmpAssets = tmpBundle.appendingPathComponent("assets")
    try? fm.createDirectory(at: tmpAssets, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpBundle) }

    let info: [String: Any] = [
        "transient": true,
        "type": "net.daringfireball.markdown",
        "version": 2,
        "creatorIdentifier": "net.shinyfrog.bear",
        "bear_uuid": noteID,
        "bear_source": "bearcli",
    ]

    do {
        let processedText = processExportImagesTextbundleUsingBearCLI(
            text: text,
            bundleAssets: tmpAssets,
            noteID: noteID,
            attachments: attachments,
            bearCLI: bearCLI,
            existingAssets: existingAssets
        )

        writeNoteFile(filepath: tmpBundle.appendingPathComponent("text.md"),
                      content: processedText, modifiedUnix: modUnix, createdCoreData: 0)

        let infoData = try JSONSerialization.data(withJSONObject: info, options: .prettyPrinted)
        let infoStr = String(data: infoData, encoding: .utf8) ?? "{}"
        writeNoteFile(filepath: tmpBundle.appendingPathComponent("info.json"),
                      content: infoStr, modifiedUnix: modUnix, createdCoreData: 0)

        if fm.fileExists(atPath: bundlePath.path) {
            try fm.removeItem(at: bundlePath)
        }
        try fm.moveItem(at: tmpBundle, to: bundlePath)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: modUnix)],
                             ofItemAtPath: bundlePath.path)
        if createdCoreData > 0 {
            setCreationDate(filepath: bundlePath, unixTimestamp: coreDataToUnix(createdCoreData))
        }
    } catch {
        // defer block handles cleanup of tmpBundle
    }
}

// MARK: - Timestamps

public func writeTimestamps(config: ExportConfig) {
    let fm = FileManager.default
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss"
    let msg = "Export from Bear written at: \(formatter.string(from: Date()))"
    let path = config.exportTsFile
    try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? msg.write(to: path, atomically: true, encoding: .utf8)
}

public func checkDBModified(config: ExportConfig) -> Bool {
    let fm = FileManager.default
    guard let configs = try? config.splitExportConfigs() else { return true }

    for cfg in configs {
        guard fm.fileExists(atPath: cfg.exportTsFile.path) else { return true }
        guard let tsAttrs = try? fm.attributesOfItem(atPath: cfg.exportTsFile.path),
              let tsMod = tsAttrs[.modificationDate] as? Date else { return true }
        let sig = sourceSignature(config: cfg)
        if sig.byteCount < 0 { return true }
        if sig.lastModified > tsMod.timeIntervalSince1970 { return true }
    }
    return false
}

// MARK: - Export Lock

private func acquireLock(exportPath: URL) -> Int32? {
    let fm = FileManager.default
    try? fm.createDirectory(at: exportPath, withIntermediateDirectories: true)
    let lockPath = exportPath.appendingPathComponent(".b2ou.lock")
    let fd = open(lockPath.path, O_WRONLY | O_CREAT, 0o600)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

private func releaseLock(_ fd: Int32) {
    flock(fd, LOCK_UN)
    close(fd)
}

// MARK: - Main Export Entry Point

public struct ExportResult {
    public let noteCount: Int
    public let expectedPaths: Set<URL>
    public let changedCount: Int
    public let conflictPaths: Set<URL>
    public let errorMessage: String?

    public init(
        noteCount: Int,
        expectedPaths: Set<URL>,
        changedCount: Int,
        conflictPaths: Set<URL> = [],
        errorMessage: String? = nil
    ) {
        self.noteCount = noteCount
        self.expectedPaths = expectedPaths
        self.changedCount = changedCount
        self.conflictPaths = conflictPaths
        self.errorMessage = errorMessage
    }

    public var hasConflicts: Bool {
        !conflictPaths.isEmpty
    }
}

public func exportNotes(config: ExportConfig) -> ExportResult {
    if shouldReadWithBearCLI(config: config) {
        let client = BearCLIClient(executable: config.bearCLIPath)
        do {
            return try exportNotesUsingBearCLI(config: config, client: client)
        } catch {
            if config.bearSource.lowercased() == "bearcli" {
                return ExportResult(
                    noteCount: 0,
                    expectedPaths: [],
                    changedCount: -1,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }
    return exportNotesFromSQLite(config: config)
}

private enum ExistingTargetDecision {
    case write
    case skip(TargetFingerprint)
    case conflict
}

private struct TargetFingerprint {
    let hash: String
    let size: Int64
    let mtime: Double
}

private func targetFileMetadata(_ url: URL) -> (size: Int64, mtime: Double)? {
    let fm = FileManager.default
    let sourceURL: URL
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        sourceURL = url.appendingPathComponent("text.md")
    } else {
        sourceURL = url
    }
    guard let attrs = try? fm.attributesOfItem(atPath: sourceURL.path) else { return nil }
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return (size, mtime)
}

private func sameFileObservation(_ binding: B2OUSyncBinding, _ metadata: (size: Int64, mtime: Double)) -> Bool {
    binding.lastSeenSize == metadata.size && abs(binding.lastSeenMTime - metadata.mtime) < 0.001
}

private func sourceIsNewerThanTarget(sourceModifiedUnix: Double, targetMTime: Double) -> Bool {
    sourceModifiedUnix > 0 && targetMTime < sourceModifiedUnix
}

private func makeExportSyncBindingWithFingerprint(
    exportPath: URL,
    target: URL,
    bearID: String,
    bearHash: String,
    bearModified: String,
    bearTitle: String,
    fingerprint: TargetFingerprint
) -> B2OUSyncBinding {
    B2OUSyncBinding(
        obsidianPath: syncRelativePath(from: exportPath, to: target),
        bearID: bearID,
        bearHash: bearHash,
        bearModified: bearModified,
        bearTitleKey: syncTitleKey(cleanTitle(bearTitle)),
        lastExportedObsidianHash: fingerprint.hash,
        lastSeenMTime: fingerprint.mtime,
        lastSeenSize: fingerprint.size,
        matchMethod: "export",
        riskLevel: "low",
        managedByManifest: true
    )
}

private func existingTargetDecision(
    target: URL,
    exportPath: URL,
    sourceModifiedUnix: Double,
    stateBindings: [String: B2OUSyncBinding]
) -> ExistingTargetDecision {
    guard FileManager.default.fileExists(atPath: target.path) else {
        return .write
    }

    let relativePath = syncRelativePath(from: exportPath, to: target)
    guard let binding = stateBindings[relativePath],
          !binding.lastExportedObsidianHash.isEmpty else {
        return .conflict
    }

    guard let metadata = targetFileMetadata(target) else { return .conflict }
    let cachedFingerprint = TargetFingerprint(
        hash: binding.lastExportedObsidianHash,
        size: metadata.size,
        mtime: metadata.mtime
    )
    if sameFileObservation(binding, metadata) {
        return sourceIsNewerThanTarget(sourceModifiedUnix: sourceModifiedUnix, targetMTime: metadata.mtime)
            ? .write
            : .skip(cachedFingerprint)
    }

    let fingerprint = fileFingerprint(target)
    guard !fingerprint.hash.isEmpty else { return .conflict }
    guard fingerprint.hash == binding.lastExportedObsidianHash else {
        return .conflict
    }

    let actualFingerprint = TargetFingerprint(
        hash: fingerprint.hash,
        size: fingerprint.size,
        mtime: fingerprint.mtime
    )
    return sourceIsNewerThanTarget(sourceModifiedUnix: sourceModifiedUnix, targetMTime: fingerprint.mtime)
        ? .write
        : .skip(actualFingerprint)
}

private func exportNotesUsingBearCLI(config: ExportConfig, client: BearCLIClient) throws -> ExportResult {
    guard let lockFd = acquireLock(exportPath: config.exportPath) else {
        return ExportResult(
            noteCount: 0,
            expectedPaths: [],
            changedCount: -1,
            errorMessage: B2OUError.exportLocked(config.exportPath).localizedDescription
        )
    }
    defer { releaseLock(lockFd) }

    let cliNotes = try client.listNotes(location: "notes")
    var noteCount = 0
    var changedCount = 0
    var expectedPaths = Set<URL>()
    var reservedTargets = Set<URL>()
    var syncBindings: [B2OUSyncBinding] = []
    var conflictPaths = Set<URL>()
    let stateBindings = syncBindingsByPath(exportPath: config.exportPath)

    func targetFor(basePath: URL, asTextbundle: Bool) -> URL {
        let suffix = asTextbundle ? ".textbundle" : ".md"
        return URL(fileURLWithPath: basePath.path + suffix)
    }

    func uniqueBasePath(basePath: URL, asTextbundle: Bool, noteUUID: String) -> URL {
        let target = targetFor(basePath: basePath, asTextbundle: asTextbundle)
        if !reservedTargets.contains(target) {
            reservedTargets.insert(target)
            return basePath
        }

        let tagged = basePath.deletingLastPathComponent()
            .appendingPathComponent("\(basePath.lastPathComponent) - \(String(noteUUID.prefix(8)))")
        let taggedTarget = targetFor(basePath: tagged, asTextbundle: asTextbundle)
        if !reservedTargets.contains(taggedTarget) {
            reservedTargets.insert(taggedTarget)
            return tagged
        }

        var count = 2
        while true {
            let candidate = basePath.deletingLastPathComponent()
                .appendingPathComponent("\(tagged.lastPathComponent) - \(String(format: "%02d", count))")
            let candidateTarget = targetFor(basePath: candidate, asTextbundle: asTextbundle)
            if !reservedTargets.contains(candidateTarget) {
                reservedTargets.insert(candidateTarget)
                return candidate
            }
            count += 1
        }
    }

    let fm = FileManager.default
    try? fm.createDirectory(at: config.exportPath, withIntermediateDirectories: true)

    for cliNote in cliNotes {
        let note = cliNote.bearNote
        if !config.onlyNoteUUIDs.isEmpty && !config.onlyNoteUUIDs.contains(note.uuid) { continue }
        if isUntitledPlaceholder(note) { continue }

        let filename = generateFilename(note: note, naming: config.naming)
        let modUnix = cliNote.modifiedUnix
        let rawText = note.text

        let fileList: [String]
        if config.makeTagFolders {
            fileList = subPathFromTags(
                basePath: config.exportPath.path,
                filename: filename,
                tags: cliNote.tags.isEmpty ? extractTags(rawText) : cliNote.tags,
                makeTagFolders: true,
                multiTagFolders: config.multiTagFolders,
                onlyExportTags: config.onlyExportTags,
                excludeTags: config.excludeTags
            )
        } else {
            let noteTags = cliNote.tags.isEmpty ? extractTags(rawText) : cliNote.tags
            if !config.excludeTags.isEmpty {
                let isExcluded = noteTags.contains { nt in
                    config.excludeTags.contains { et in
                        nt.lowercased().hasPrefix(et.lowercased())
                    }
                }
                if isExcluded { continue }
            }
            fileList = [config.exportPath.appendingPathComponent(filename).path]
        }

        if fileList.isEmpty { continue }
        noteCount += 1

        let attachments: [BearCLIAttachment]
        if cliNote.needsAttachmentListRefresh {
            attachments = (try? client.listAttachments(noteID: cliNote.id)) ?? cliNote.attachments
        } else {
            attachments = cliNote.attachments
        }

        var seenPaths = Set<String>()
        for filepathStr in fileList {
            guard !seenPaths.contains(filepathStr) else { continue }
            seenPaths.insert(filepathStr)

            var filepath = URL(fileURLWithPath: filepathStr)
            let asTextbundle = config.exportAsTextbundles && shouldUseTextbundle(text: rawText, filepath: filepath, config: config)
            filepath = uniqueBasePath(basePath: filepath, asTextbundle: asTextbundle, noteUUID: note.uuid)
            let target = targetFor(basePath: filepath, asTextbundle: asTextbundle)

            switch existingTargetDecision(
                target: target,
                exportPath: config.exportPath,
                sourceModifiedUnix: modUnix,
                stateBindings: stateBindings
            ) {
            case .skip(let fingerprint):
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBindingWithFingerprint(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: cliNote.id,
                    bearHash: cliNote.hash,
                    bearModified: cliNote.modifiedISO,
                    bearTitle: note.title,
                    fingerprint: fingerprint
                ))
                continue
            case .conflict:
                expectedPaths.insert(target)
                conflictPaths.insert(target)
                continue
            case .write:
                break
            }

            let text = normaliseBearMarkdown(rawText)
            var frontMatter = ""
            if config.yamlFrontMatter {
                frontMatter = generateFrontMatter(
                    note: note,
                    text: text,
                    tags: cliNote.tags.isEmpty ? nil : cliNote.tags
                )
            }
            var processedText = text
            if config.hideTags {
                processedText = hideTags(processedText)
            }

            changedCount += 1

            if asTextbundle {
                makeTextBundleUsingBearCLI(
                    text: frontMatter + processedText,
                    filepath: filepath,
                    modUnix: modUnix,
                    createdCoreData: note.creationDate,
                    noteID: cliNote.id,
                    attachments: attachments,
                    bearCLI: client
                )
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBinding(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: cliNote.id,
                    bearHash: cliNote.hash,
                    bearModified: cliNote.modifiedISO,
                    bearTitle: note.title
                ))
            } else if config.exportImageRepository, let assetsPath = config.assetsPath {
                let processed = processExportImagesUsingBearCLI(
                    text: processedText,
                    filepath: filepath,
                    noteID: cliNote.id,
                    attachments: attachments,
                    bearCLI: client,
                    assetsPath: assetsPath,
                    exportPath: config.exportPath
                )
                writeNoteFile(filepath: target, content: frontMatter + processed,
                              modifiedUnix: modUnix, createdCoreData: note.creationDate)
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBinding(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: cliNote.id,
                    bearHash: cliNote.hash,
                    bearModified: cliNote.modifiedISO,
                    bearTitle: note.title
                ))
            } else {
                writeNoteFile(filepath: target, content: frontMatter + processedText,
                              modifiedUnix: modUnix, createdCoreData: note.creationDate)
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBinding(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: cliNote.id,
                    bearHash: cliNote.hash,
                    bearModified: cliNote.modifiedISO,
                    bearTitle: note.title
                ))
            }
        }
    }

    if conflictPaths.isEmpty {
        writeExportSyncState(
            exportPath: config.exportPath,
            bindings: syncBindings,
            merge: !config.onlyNoteUUIDs.isEmpty
        )
    }
    return ExportResult(
        noteCount: noteCount,
        expectedPaths: expectedPaths,
        changedCount: changedCount,
        conflictPaths: conflictPaths
    )
}

private func exportNotesFromSQLite(config: ExportConfig) -> ExportResult {
    guard let lockFd = acquireLock(exportPath: config.exportPath) else {
        return ExportResult(
            noteCount: 0,
            expectedPaths: [],
            changedCount: -1,
            errorMessage: B2OUError.exportLocked(config.exportPath).localizedDescription
        )
    }
    defer { releaseLock(lockFd) }

    let conn: SQLiteConnection
    let tmpPath: URL?
    do {
        (conn, tmpPath) = try copyAndOpen(dbPath: config.bearDB)
    } catch {
        return ExportResult(
            noteCount: 0,
            expectedPaths: [],
            changedCount: -1,
            errorMessage: error.localizedDescription
        )
    }
    defer {
        if let tmpPath {
            try? FileManager.default.removeItem(at: tmpPath)
        }
    }

    guard validateBearSchema(conn: conn) else {
        return ExportResult(
            noteCount: 0,
            expectedPaths: [],
            changedCount: -1,
            errorMessage: "Bear SQLite schema is missing required note columns."
        )
    }

    let allFileMaps = buildNoteFileMap(conn: conn)
    var noteCount = 0
    var changedCount = 0
    var expectedPaths = Set<URL>()
    var reservedTargets = Set<URL>()
    var syncBindings: [B2OUSyncBinding] = []
    var conflictPaths = Set<URL>()
    let stateBindings = syncBindingsByPath(exportPath: config.exportPath)
    let isoFormatter = ISO8601DateFormatter()

    func targetFor(basePath: URL, asTextbundle: Bool) -> URL {
        let suffix = asTextbundle ? ".textbundle" : ".md"
        return URL(fileURLWithPath: basePath.path + suffix)
    }

    func uniqueBasePath(basePath: URL, asTextbundle: Bool, noteUUID: String) -> URL {
        let target = targetFor(basePath: basePath, asTextbundle: asTextbundle)
        if !reservedTargets.contains(target) {
            reservedTargets.insert(target)
            return basePath
        }

        let tagged = basePath.deletingLastPathComponent()
            .appendingPathComponent("\(basePath.lastPathComponent) - \(String(noteUUID.prefix(8)))")
        let taggedTarget = targetFor(basePath: tagged, asTextbundle: asTextbundle)
        if !reservedTargets.contains(taggedTarget) {
            reservedTargets.insert(taggedTarget)
            return tagged
        }

        var count = 2
        while true {
            let candidate = basePath.deletingLastPathComponent()
                .appendingPathComponent("\(tagged.lastPathComponent) - \(String(format: "%02d", count))")
            let candidateTarget = targetFor(basePath: candidate, asTextbundle: asTextbundle)
            if !reservedTargets.contains(candidateTarget) {
                reservedTargets.insert(candidateTarget)
                return candidate
            }
            count += 1
        }
    }

    let fm = FileManager.default
    try? fm.createDirectory(at: config.exportPath, withIntermediateDirectories: true)

    forEachNote(conn: conn) { note in
        if !config.onlyNoteUUIDs.isEmpty && !config.onlyNoteUUIDs.contains(note.uuid) { return }
        if isUntitledPlaceholder(note) { return }

        let filename = generateFilename(note: note, naming: config.naming)
        let modUnix = coreDataToUnix(note.modifiedDate)
        let rawText = note.text

        // Tag-based path resolution
        let fileList: [String]
        if config.makeTagFolders {
            fileList = subPathFromTag(
                basePath: config.exportPath.path,
                filename: filename,
                text: rawText,
                makeTagFolders: true,
                multiTagFolders: config.multiTagFolders,
                onlyExportTags: config.onlyExportTags,
                excludeTags: config.excludeTags
            )
        } else {
            if !config.excludeTags.isEmpty {
                let noteTags = extractTags(rawText)
                let isExcluded = noteTags.contains { nt in
                    config.excludeTags.contains { et in
                        nt.lowercased().hasPrefix(et.lowercased())
                    }
                }
                if isExcluded { return }
            }
            fileList = [config.exportPath.appendingPathComponent(filename).path]
        }

        if fileList.isEmpty { return }
        noteCount += 1

        var seenPaths = Set<String>()
        for filepathStr in fileList {
            guard !seenPaths.contains(filepathStr) else { continue }
            seenPaths.insert(filepathStr)

            var filepath = URL(fileURLWithPath: filepathStr)
            let asTextbundle = config.exportAsTextbundles && shouldUseTextbundle(text: rawText, filepath: filepath, config: config)
            filepath = uniqueBasePath(basePath: filepath, asTextbundle: asTextbundle, noteUUID: note.uuid)
            let target = targetFor(basePath: filepath, asTextbundle: asTextbundle)

            // Incremental skip, guarded by the last exported file fingerprint.
            switch existingTargetDecision(
                target: target,
                exportPath: config.exportPath,
                sourceModifiedUnix: modUnix,
                stateBindings: stateBindings
            ) {
            case .skip(let fingerprint):
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBindingWithFingerprint(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: note.uuid,
                    bearHash: "",
                    bearModified: isoFormatter.string(from: Date(timeIntervalSince1970: modUnix)),
                    bearTitle: note.title,
                    fingerprint: fingerprint
                ))
                continue
            case .conflict:
                expectedPaths.insert(target)
                conflictPaths.insert(target)
                continue
            case .write:
                break
            }

            // Markdown processing
            let text = normaliseBearMarkdown(rawText)
            var frontMatter = ""
            if config.yamlFrontMatter {
                frontMatter = generateFrontMatter(note: note, text: text)
            }
            var processedText = text
            if config.hideTags {
                processedText = hideTags(processedText)
            }

            changedCount += 1
            let noteFileMap = allFileMaps[note.pk] ?? [:]

            if asTextbundle {
                makeTextBundle(
                    text: frontMatter + processedText, filepath: filepath,
                    modUnix: modUnix, createdCoreData: note.creationDate,
                    conn: conn, notePK: note.pk, bearImagePath: config.bearImagePath,
                    noteUUID: note.uuid, bearFilePath: config.bearFilePath,
                    fileMap: noteFileMap
                )
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBinding(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: note.uuid,
                    bearHash: "",
                    bearModified: isoFormatter.string(from: Date(timeIntervalSince1970: modUnix)),
                    bearTitle: note.title
                ))
            } else if config.exportImageRepository, let assetsPath = config.assetsPath {
                let processed = processExportImages(
                    text: processedText, filepath: filepath, conn: conn, notePK: note.pk,
                    bearImagePath: config.bearImagePath, assetsPath: assetsPath,
                    exportPath: config.exportPath, bearFilePath: config.bearFilePath,
                    fileMap: noteFileMap
                )
                writeNoteFile(filepath: target, content: frontMatter + processed,
                              modifiedUnix: modUnix, createdCoreData: note.creationDate)
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBinding(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: note.uuid,
                    bearHash: "",
                    bearModified: isoFormatter.string(from: Date(timeIntervalSince1970: modUnix)),
                    bearTitle: note.title
                ))
            } else {
                writeNoteFile(filepath: target, content: frontMatter + processedText,
                              modifiedUnix: modUnix, createdCoreData: note.creationDate)
                expectedPaths.insert(target)
                syncBindings.append(makeExportSyncBinding(
                    exportPath: config.exportPath,
                    target: target,
                    bearID: note.uuid,
                    bearHash: "",
                    bearModified: isoFormatter.string(from: Date(timeIntervalSince1970: modUnix)),
                    bearTitle: note.title
                ))
            }
        }
    }

    if conflictPaths.isEmpty {
        writeExportSyncState(
            exportPath: config.exportPath,
            bindings: syncBindings,
            merge: !config.onlyNoteUUIDs.isEmpty
        )
    }
    return ExportResult(
        noteCount: noteCount,
        expectedPaths: expectedPaths,
        changedCount: changedCount,
        conflictPaths: conflictPaths
    )
}

private func shouldUseTextbundle(text: String, filepath: URL, config: ExportConfig) -> Bool {
    if !config.exportAsHybrids { return true }
    let tb = URL(fileURLWithPath: filepath.path + ".textbundle")
    if FileManager.default.fileExists(atPath: tb.path) { return true }
    return reBearImage.firstMatch(in: text) != nil || reMarkdownImage.firstMatch(in: text) != nil
}

// MARK: - Helpers

private func relativePathString(from base: URL, to target: URL) -> String {
    let basePath = base.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    guard targetPath.hasPrefix(basePath + "/") else { return "" }
    var rel = String(targetPath.dropFirst(basePath.count))
    if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
    return rel
}
