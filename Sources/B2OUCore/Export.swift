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
    let lines = paths
        .compactMap { url -> String? in
            guard url != manifest else { return nil }
            let rel = url.path.hasPrefix(exportPath.path)
                ? String(url.path.dropFirst(exportPath.path.count + 1))
                : url.lastPathComponent
            return rel
        }
        .sorted()
    let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    let tmp = manifest.deletingLastPathComponent().appendingPathComponent(".\(manifestName).tmp")
    do {
        try content.write(to: tmp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: tmp, to: manifest)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        // Fallback: write directly
        try? content.write(to: manifest, atomically: true, encoding: .utf8)
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

public func generateFrontMatter(note: BearNote, text: String) -> String {
    let created = Date(timeIntervalSince1970: coreDataToUnix(note.creationDate))
    let modified = Date(timeIntervalSince1970: coreDataToUnix(note.modifiedDate))

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdStr = formatter.string(from: created)
    let modifiedStr = formatter.string(from: modified)

    let tags = extractTags(text)

    var lines = [
        "---",
        "title: \(yamlEscape(note.title))",
        "created: \(createdStr)",
        "modified: \(modifiedStr)",
        "bear_id: \(note.uuid)",
    ]
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
        _ = try? fm.moveItem(at: tmp, to: filepath)
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
                if !expectedPaths.contains(fileURL) {
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
        if expectedPaths.contains(fileURL) { continue }

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
        try? fm.removeItem(at: tmpBundle)
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
        guard let dbAttrs = try? fm.attributesOfItem(atPath: cfg.bearDB.path),
              let tsAttrs = try? fm.attributesOfItem(atPath: cfg.exportTsFile.path),
              let dbMod = dbAttrs[.modificationDate] as? Date,
              let tsMod = tsAttrs[.modificationDate] as? Date else { return true }
        if dbMod > tsMod { return true }
    }
    return false
}

// MARK: - Export Lock

private func acquireLock(exportPath: URL) -> Int32? {
    let fm = FileManager.default
    try? fm.createDirectory(at: exportPath, withIntermediateDirectories: true)
    let lockPath = exportPath.appendingPathComponent(".b2ou.lock")
    let fd = open(lockPath.path, O_WRONLY | O_CREAT, 0o644)
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
}

public func exportNotes(config: ExportConfig) -> ExportResult {
    guard let lockFd = acquireLock(exportPath: config.exportPath) else {
        return ExportResult(noteCount: 0, expectedPaths: [], changedCount: -1)
    }
    defer { releaseLock(lockFd) }

    let (conn, tmpPath) = copyAndOpen(dbPath: config.bearDB)
    defer {
        if let tmpPath {
            try? FileManager.default.removeItem(at: tmpPath)
        }
    }

    let allFileMaps = buildNoteFileMap(conn: conn)
    var noteCount = 0
    var changedCount = 0
    var expectedPaths = Set<URL>()
    var reservedTargets = Set<URL>()

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

    for note in iterNotes(conn: conn) {
        if isUntitledPlaceholder(note) { continue }

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
                if isExcluded { continue }
            }
            fileList = [config.exportPath.appendingPathComponent(filename).path]
        }

        if fileList.isEmpty { continue }
        noteCount += 1

        var seenPaths = Set<String>()
        for filepathStr in fileList {
            guard !seenPaths.contains(filepathStr) else { continue }
            seenPaths.insert(filepathStr)

            var filepath = URL(fileURLWithPath: filepathStr)
            let asTextbundle = config.exportAsTextbundles && shouldUseTextbundle(text: rawText, filepath: filepath, config: config)
            filepath = uniqueBasePath(basePath: filepath, asTextbundle: asTextbundle, noteUUID: note.uuid)
            let target = targetFor(basePath: filepath, asTextbundle: asTextbundle)

            // Incremental skip
            if fm.fileExists(atPath: target.path),
               let attrs = try? fm.attributesOfItem(atPath: target.path),
               let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
               mtime >= modUnix {
                expectedPaths.insert(target)
                continue
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
            } else {
                writeNoteFile(filepath: target, content: frontMatter + processedText,
                              modifiedUnix: modUnix, createdCoreData: note.creationDate)
                expectedPaths.insert(target)
            }
        }
    }

    return ExportResult(noteCount: noteCount, expectedPaths: expectedPaths, changedCount: changedCount)
}

private func shouldUseTextbundle(text: String, filepath: URL, config: ExportConfig) -> Bool {
    if !config.exportAsHybrids { return true }
    let tb = URL(fileURLWithPath: filepath.path + ".textbundle")
    if FileManager.default.fileExists(atPath: tb.path) { return true }
    return reBearImage.firstMatch(in: text) != nil || reMarkdownImage.firstMatch(in: text) != nil
}

// MARK: - Helpers

private func relativePathString(from base: URL, to target: URL) -> String {
    guard target.path.hasPrefix(base.path) else { return "" }
    var rel = String(target.path.dropFirst(base.path.count))
    if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
    return rel
}
