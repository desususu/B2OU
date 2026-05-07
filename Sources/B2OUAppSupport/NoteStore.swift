// NoteStore.swift — Data layer for scanning Bear/exported notes and computing statistics.
//
// Prefer the current Bear source for the export workspace, then fall back to
// exported Markdown files when Bear cannot be read. Dashboard and preview
// surfaces still use the same aggregate metadata model.

import Foundation
import Combine
import B2OUCore

// MARK: - Note Metadata

public enum NoteSourceKind: Equatable, Sendable {
    case bearSource
    case exportedMarkdown
}

public struct NoteMetadata {
    public let title: String
    public let created: Date?
    public let modified: Date?
    public let tags: [String]
    public let wordCount: Int
    public let charCount: Int
    public let filePath: URL
    public let bearId: String
    public let hasImages: Bool
    public let missingImageRefs: Int
    public let bodyText: String
    public let sourceMarkdown: String
    public let sourceKind: NoteSourceKind

    public init(
        title: String,
        created: Date?,
        modified: Date?,
        tags: [String],
        wordCount: Int,
        charCount: Int,
        filePath: URL,
        bearId: String,
        hasImages: Bool,
        missingImageRefs: Int,
        bodyText: String,
        sourceMarkdown: String,
        sourceKind: NoteSourceKind
    ) {
        self.title = title
        self.created = created
        self.modified = modified
        self.tags = tags
        self.wordCount = wordCount
        self.charCount = charCount
        self.filePath = filePath
        self.bearId = bearId
        self.hasImages = hasImages
        self.missingImageRefs = missingImageRefs
        self.bodyText = bodyText
        self.sourceMarkdown = sourceMarkdown
        self.sourceKind = sourceKind
    }
}

extension NoteMetadata {
    public var normalizedTitleKey: String {
        Self.normalizedTitleKey(title)
    }

    public static func normalizedTitleKey(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    public var isBearSourceBacked: Bool {
        sourceKind == .bearSource
    }
}

// MARK: - Aggregate Statistics

public struct NoteStatistics {
    public let totalNotes: Int
    public let totalWords: Int
    public let totalChars: Int
    public let averageWords: Int
    public let tagFrequency: [(tag: String, count: Int)]
    public let longestNotes: [(title: String, words: Int)]
    public let oldestNote: NoteMetadata?
    public let newestNote: NoteMetadata?
    public let notesWithImages: Int
    public let activityDays: [Date: Int]
    public let untaggedNotes: Int
    public let missingBearIds: Int
    public let missingImageRefs: Int
    public let duplicateTitleNotes: Int

    // New richer stats
    public let writingStreak: Int
    public let uniqueTags: Int
    public let thisWeekNotes: Int
    public let thisWeekWords: Int
    public let todayWords: Int
    public let medianWords: Int
    public let notesWithLinks: Int

    public var healthIssueCount: Int {
        untaggedNotes + missingBearIds + missingImageRefs + duplicateTitleNotes
    }
}

// MARK: - NoteStore

public class NoteStore: ObservableObject {
    private let lock = NSLock()
    private var storedNotes: [NoteMetadata] = []
    private var storedStats: NoteStatistics? = nil

    /// Thread-safe read access (synchronous).
    public var notes: [NoteMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return storedNotes
    }

    /// Thread-safe read access (synchronous).
    public var stats: NoteStatistics? {
        lock.lock()
        defer { lock.unlock() }
        return storedStats
    }

    private static let markdownImageReferenceRegex = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(([^)]+)\)"#,
        options: [.caseInsensitive]
    )
    private static let htmlImageReferenceRegex = try! NSRegularExpression(
        pattern: #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#,
        options: [.caseInsensitive]
    )

    public init() {}

    public func clear() {
        lock.lock()
        storedNotes = []
        storedStats = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Scan exported notes at the given path (safe to call from any thread).
    public func scan(exportPath: URL) {
        var scanned: [NoteMetadata] = []
        let fm = FileManager.default
        let stateBindings = syncBindingsByPath(exportPath: exportPath)

        guard let enumerator = fm.enumerator(
            at: exportPath,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            publish([])
            return
        }

        while let url = enumerator.nextObject() as? URL {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = url.lastPathComponent

            if isDir {
                if name.hasPrefix(".") || exportSkipDirs.contains(name)
                    || exportSkipDirPrefixes.contains(where: { name.hasPrefix($0) })
                    || name.hasSuffix(".textbundle") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard url.pathExtension.lowercased() == "md" else { continue }
            if let meta = parseNote(at: url, exportPath: exportPath, stateBindings: stateBindings) {
                scanned.append(meta)
            }
        }

        publish(scanned)
    }

    /// Scan the configured Bear source first, falling back to exported notes if
    /// the source is temporarily unavailable.
    public func scan(config: ExportConfig, allowExportFallback: Bool = true) {
        if let sourceNotes = scanBearSource(config: config) {
            publish(sourceNotes)
            return
        }
        guard allowExportFallback else {
            clear()
            return
        }
        scan(exportPath: config.exportPath)
    }

    /// Pick a deterministic "note of the day" (consistent within the same calendar day).
    public func noteOfTheDay() -> NoteMetadata? {
        let notes = notes
        guard !notes.isEmpty else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let old = notes.filter { ($0.created ?? Date()) < cutoff }
        let pool = old.isEmpty ? notes : old
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let year = Calendar.current.component(.year, from: Date())
        return pool[(dayOfYear &+ year) % pool.count]
    }

    // MARK: - Parsing

    private func scanBearSource(config: ExportConfig) -> [NoteMetadata]? {
        if shouldReadWithBearCLI(config: config) {
            do {
                let client = BearCLIClient(executable: config.bearCLIPath)
                let notes = try client.listNotes(location: "notes")
                var reservedTargets = Set<String>()
                return notes.compactMap { cliNote in
                    metadata(
                        from: cliNote.bearNote,
                        config: config,
                        explicitTags: cliNote.tags,
                        attachmentCount: cliNote.attachmentCountHint ?? cliNote.attachments.count,
                        reservedTargets: &reservedTargets
                    )
                }
            } catch {
                if config.bearSource.lowercased() == "bearcli" {
                    return nil
                }
            }
        }

        do {
            let (conn, tmpPath) = try copyAndOpen(dbPath: config.bearDB)
            defer {
                if let tmpPath {
                    try? FileManager.default.removeItem(at: tmpPath)
                }
            }
            let fileMap = buildNoteFileMap(conn: conn)
            var reservedTargets = Set<String>()
            var sourceNotes: [NoteMetadata] = []
            forEachNote(conn: conn) { note in
                guard let meta = metadata(
                    from: note,
                    config: config,
                    explicitTags: nil,
                    attachmentCount: fileMap[note.pk]?.count ?? 0,
                    reservedTargets: &reservedTargets
                ) else { return }
                sourceNotes.append(meta)
            }
            return sourceNotes
        } catch {
            return nil
        }
    }

    private func publish(_ scanned: [NoteMetadata]) {
        let computedStats = computeStats(from: scanned)
        lock.lock()
        storedNotes = scanned
        storedStats = computedStats
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func metadata(
        from note: BearNote,
        config: ExportConfig,
        explicitTags: [String]?,
        attachmentCount: Int,
        reservedTargets: inout Set<String>
    ) -> NoteMetadata? {
        if isPlaceholder(note) { return nil }

        let normalizedText = normaliseBearMarkdown(note.text)
        let tags = (explicitTags ?? extractTags(normalizedText))
            .map(normalizeBearTag)
            .filter { !$0.isEmpty }

        if isExcluded(tags: tags, excludeTags: config.excludeTags) {
            return nil
        }

        let filename = generateFilename(note: note, naming: config.naming)
        let ext = config.exportFormat == "tb" ? "textbundle" : "md"
        let target = uniqueTarget(
            base: config.exportPath.appendingPathComponent(filename),
            extensionName: ext,
            noteUUID: note.uuid,
            reservedTargets: &reservedTargets
        )
        let body = config.hideTags ? hideTags(normalizedText) : normalizedText
        let sourceMarkdown = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = Date(timeIntervalSince1970: coreDataToUnix(note.creationDate))
        let modified = Date(timeIntervalSince1970: coreDataToUnix(note.modifiedDate))
        let hasImages = attachmentCount > 0
            || body.contains("![")
            || body.contains("[image:")
            || body.range(of: "<img", options: .caseInsensitive) != nil
        let missingImageRefs = Self.missingImageReferenceCount(in: body, relativeTo: target)

        let bodyText = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let metrics = Self.countTextMetrics(body)

        return NoteMetadata(
            title: note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : note.title,
            created: created,
            modified: modified,
            tags: tags,
            wordCount: metrics.words,
            charCount: metrics.characters,
            filePath: target,
            bearId: note.uuid,
            hasImages: hasImages,
            missingImageRefs: missingImageRefs,
            bodyText: bodyText,
            sourceMarkdown: sourceMarkdown,
            sourceKind: .bearSource
        )
    }

    private func uniqueTarget(
        base: URL,
        extensionName: String,
        noteUUID: String,
        reservedTargets: inout Set<String>
    ) -> URL {
        func target(for candidate: URL) -> URL {
            URL(fileURLWithPath: candidate.path + ".\(extensionName)")
        }

        let initial = target(for: base)
        let initialKey = initial.standardizedFileURL.path
        if !reservedTargets.contains(initialKey) {
            reservedTargets.insert(initialKey)
            return initial
        }

        let prefix = String(noteUUID.prefix(8))
        let taggedBase = base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent) - \(prefix)")
        let tagged = target(for: taggedBase)
        let taggedKey = tagged.standardizedFileURL.path
        if !reservedTargets.contains(taggedKey) {
            reservedTargets.insert(taggedKey)
            return tagged
        }

        var count = 2
        while true {
            let candidateBase = taggedBase.deletingLastPathComponent()
                .appendingPathComponent("\(taggedBase.lastPathComponent) - \(String(format: "%02d", count))")
            let candidate = target(for: candidateBase)
            let key = candidate.standardizedFileURL.path
            if !reservedTargets.contains(key) {
                reservedTargets.insert(key)
                return candidate
            }
            count += 1
        }
    }

    private func isExcluded(tags: [String], excludeTags: [String]) -> Bool {
        guard !excludeTags.isEmpty else { return false }
        return tags.contains { noteTag in
            excludeTags.contains { excluded in
                noteTag.lowercased().hasPrefix(excluded.lowercased())
            }
        }
    }

    private func isPlaceholder(_ note: BearNote) -> Bool {
        if !note.title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        let text = note.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }
        return text.allSatisfy { "# \t\r\n".contains($0) }
    }

    private func parseNote(
        at url: URL,
        exportPath: URL,
        stateBindings: [String: B2OUSyncBinding]
    ) -> NoteMetadata? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var title = url.deletingPathExtension().lastPathComponent
        var created: Date?
        var modified: Date?
        var tags: [String] = []
        var bearId = ""
        var bodyContent = content
        let relativePath = syncRelativePath(from: exportPath, to: url)
        let stateBearId = stateBindings[relativePath]?.bearID ?? ""

        // Parse YAML front matter
        if content.hasPrefix("---\n") || content.hasPrefix("---\r\n") {
            let lines = content.components(separatedBy: .newlines)
            var endIdx = -1
            for i in 1..<lines.count {
                if lines[i] == "---" { endIdx = i; break }
            }
            if endIdx > 0 {
                var inTags = false
                for line in lines[1..<endIdx] {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("title:") {
                        title = unquoteYaml(String(trimmed.dropFirst(6)))
                        inTags = false
                    } else if trimmed.hasPrefix("created:") {
                        created = parseISO8601(String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces))
                        inTags = false
                    } else if trimmed.hasPrefix("modified:") {
                        modified = parseISO8601(String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces))
                        inTags = false
                    } else if trimmed.hasPrefix("bear_id:") {
                        bearId = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                        inTags = false
                    } else if trimmed == "tags:" {
                        inTags = true
                    } else if inTags && trimmed.hasPrefix("- ") {
                        tags.append(unquoteYaml(String(trimmed.dropFirst(2))))
                    } else {
                        inTags = false
                    }
                }
                bodyContent = lines[(endIdx + 1)...].joined(separator: "\n")
            }
        }

        // Fallback: extract tags from content
        if tags.isEmpty {
            tags = extractTags(content)
        }

        if !stateBearId.isEmpty {
            bearId = stateBearId
        }

        // Fallback: file system dates
        if created == nil || modified == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if created == nil { created = attrs[.creationDate] as? Date }
                if modified == nil { modified = attrs[.modificationDate] as? Date }
            }
        }

        let body = bodyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = body.contains("![")
            || body.contains("[image:")
            || body.range(of: "<img", options: .caseInsensitive) != nil
        let missingImageRefs = Self.missingImageReferenceCount(in: body, relativeTo: url)
        let metrics = Self.countTextMetrics(body)

        return NoteMetadata(
            title: title, created: created, modified: modified,
            tags: tags, wordCount: metrics.words, charCount: metrics.characters,
            filePath: url, bearId: bearId, hasImages: hasImages,
            missingImageRefs: missingImageRefs, bodyText: body,
            sourceMarkdown: body,
            sourceKind: .exportedMarkdown
        )
    }

    private static func missingImageReferenceCount(in body: String, relativeTo noteURL: URL) -> Int {
        let baseURL = noteURL.deletingLastPathComponent()
        var missing = 0
        let nsBody = body as NSString
        let range = NSRange(location: 0, length: nsBody.length)

        for regex in [markdownImageReferenceRegex, htmlImageReferenceRegex] {
            for match in regex.matches(in: body, options: [], range: range) where match.numberOfRanges > 1 {
                var raw = nsBody.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let space = raw.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    raw = String(raw[..<space])
                }
                raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

                guard !raw.isEmpty, !Self.isExternalImageReference(raw) else { continue }

                let candidate: URL
                if let absolute = URL(string: raw), absolute.scheme != nil {
                    guard absolute.isFileURL else { continue }
                    candidate = absolute
                } else {
                    let path = raw.removingPercentEncoding ?? raw
                    candidate = baseURL.appendingPathComponent(path).standardizedFileURL
                }

                if !FileManager.default.fileExists(atPath: candidate.path) {
                    missing += 1
                }
            }
        }

        return missing
    }

    private static func isExternalImageReference(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("data:")
            || lower.hasPrefix("bear://")
            || lower.hasPrefix("[image:")
            || lower.hasPrefix("#")
    }

    /// Strip all Markdown syntax, leaving only prose for counting.
    /// Links (including display text), images, code, and URLs are removed entirely.
    private static func stripMarkdown(_ text: String) -> String {
        var r = text

        // Remove code blocks (``` ... ```)
        r = r.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        // Remove inline code
        r = r.replacingOccurrences(of: #"`[^`]+`"#, with: " ", options: .regularExpression)
        // Remove images entirely: ![alt](url)
        r = r.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: " ", options: .regularExpression)
        // Remove links entirely (including display text): [text](url)
        r = r.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]+\)"#, with: " ", options: .regularExpression)
        // Remove reference-style links: [text][ref]
        r = r.replacingOccurrences(of: #"\[([^\]]*)\]\[[^\]]*\]"#, with: " ", options: .regularExpression)
        // Remove reference definitions: [ref]: url
        r = r.replacingOccurrences(of: #"(?m)^\s*\[[^\]]+\]:\s+\S+.*$"#, with: " ", options: .regularExpression)
        // Remove autolinks: <http://...>
        r = r.replacingOccurrences(of: #"<https?://[^>]+>"#, with: " ", options: .regularExpression)
        // Remove bare URLs
        r = r.replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
        // Remove heading markers
        r = r.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Remove bold/italic markers
        r = r.replacingOccurrences(of: #"\*{1,3}(.+?)\*{1,3}"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"_{1,3}(.+?)_{1,3}"#, with: "$1", options: .regularExpression)
        // Remove strikethrough
        r = r.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)
        // Remove highlight
        r = r.replacingOccurrences(of: #"==(.+?)=="#, with: "$1", options: .regularExpression)
        // Remove horizontal rules
        r = r.replacingOccurrences(of: #"(?m)^[\s]*[-*_]{3,}[\s]*$"#, with: " ", options: .regularExpression)
        // Remove blockquote markers
        r = r.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)
        // Remove list markers (-, *, +, 1.)
        r = r.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)
        // Remove HTML tags
        r = r.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)

        return r
    }

    /// Count text using the standard Chinese metric (字数):
    /// each CJK character = 1, each English/Latin word = 1,
    /// punctuation and whitespace excluded.
    private static func countTextMetrics(_ text: String) -> (words: Int, characters: Int) {
        let clean = stripMarkdown(text)
        var words = 0
        var characters = 0
        var inLatinWord = false

        for scalar in clean.unicodeScalars {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                characters += 1
            }
            if Self.isCJK(scalar) {
                // Each CJK character counts as 1
                if inLatinWord { words += 1; inLatinWord = false }
                words += 1
            } else if Self.isLatinLetter(scalar) || scalar == "-" || scalar == "'" {
                // Latin letters, hyphens in compound words, apostrophes
                if !inLatinWord { inLatinWord = true }
            } else if scalar.properties.isAlphabetic && !Self.isPunctuation(scalar) {
                // Other alphabetic scripts (Cyrillic, etc.) — treat like Latin
                if !inLatinWord { inLatinWord = true }
            } else {
                // Whitespace, punctuation, numbers, symbols — word boundary
                if inLatinWord { words += 1; inLatinWord = false }
                // Standalone digits don't count
            }
        }
        if inLatinWord { words += 1 }
        return (words, characters)
    }

    private static func countText(_ text: String) -> Int {
        countTextMetrics(text).words
    }

    private static func countCharacters(_ text: String) -> Int {
        countTextMetrics(text).characters
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        // CJK Unified Ideographs, Extension A/B, Compatibility, Rare
        return (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x2F800...0x2FA1F).contains(v)
            // Hiragana, Katakana
            || (0x3040...0x309F).contains(v)
            || (0x30A0...0x30FF).contains(v)
            // Hangul Syllables
            || (0xAC00...0xD7AF).contains(v)
    }

    private static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x41...0x5A).contains(v)   // A-Z
            || (0x61...0x7A).contains(v)   // a-z
            || (0xC0...0x24F).contains(v)  // Latin Extended (accented)
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        // Chinese punctuation, general punctuation, ASCII punctuation
        let v = s.value
        return (0x3000...0x303F).contains(v)       // CJK Symbols and Punctuation
            || (0xFF01...0xFF0F).contains(v)       // Fullwidth punctuation
            || (0xFF1A...0xFF20).contains(v)
            || (0xFF3B...0xFF40).contains(v)
            || (0xFF5B...0xFF65).contains(v)
            || (0xFE30...0xFE4F).contains(v)       // CJK Compatibility Forms
            || (0x2000...0x206F).contains(v)       // General Punctuation
            || CharacterSet.punctuationCharacters.contains(s)
    }

    private func unquoteYaml(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
            v = v.replacingOccurrences(of: "\\\"", with: "\"")
                 .replacingOccurrences(of: "\\n", with: "\n")
                 .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return v
    }

    private func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: - Statistics

    private func computeStats(from notes: [NoteMetadata]) -> NoteStatistics {
        var totalWords = 0
        var totalChars = 0
        var tagCounts: [String: Int] = [:]
        var longest: [(title: String, words: Int)] = []
        var oldestNote: NoteMetadata?
        var newestNote: NoteMetadata?
        var notesWithImages = 0
        var untaggedNotes = 0
        var missingBearIds = 0
        var missingImageRefs = 0
        var titleCounts: [String: Int] = [:]
        let cal = Calendar.current
        var activityDays: [Date: Int] = [:]

        for note in notes {
            totalWords += note.wordCount
            totalChars += note.charCount
            for tag in note.tags { tagCounts[tag, default: 0] += 1 }
            if note.hasImages { notesWithImages += 1 }
            if note.tags.isEmpty { untaggedNotes += 1 }
            if note.bearId.isEmpty { missingBearIds += 1 }
            missingImageRefs += note.missingImageRefs

            longest.append((title: note.title, words: note.wordCount))
            longest.sort { $0.words > $1.words }
            if longest.count > 5 { longest.removeLast() }

            if let created = note.created {
                if oldestNote?.created == nil || created < (oldestNote?.created ?? created) {
                    oldestNote = note
                }
                if newestNote?.created == nil || created > (newestNote?.created ?? created) {
                    newestNote = note
                }
            }

            if let mod = note.modified {
                let day = cal.startOfDay(for: mod)
                activityDays[day, default: 0] += 1
            }

            let key = note.normalizedTitleKey
            if !key.isEmpty {
                titleCounts[key, default: 0] += 1
            }
        }
        let tagFreq = tagCounts.sorted { $0.value > $1.value }.map { (tag: $0.key, count: $0.value) }
        var duplicateTitleNotes = 0
        for note in notes where titleCounts[note.normalizedTitleKey, default: 0] > 1 {
            duplicateTitleNotes += 1
        }

        // Writing streak
        var streak = 0
        let today = cal.startOfDay(for: Date())
        var cursor = today
        while true {
            if activityDays[cursor, default: 0] > 0 {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            } else {
                if cursor == today { cursor = cal.date(byAdding: .day, value: -1, to: today) ?? today }
                else { break }
            }
        }

        // This week activity (Monday as first weekday)
        var mondayCal = cal
        mondayCal.firstWeekday = 2
        let weekStart = mondayCal.date(from: mondayCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
        var thisWeekNotes = 0
        var thisWeekWords = 0
        var todayWords = 0
        var notesWithLinks = 0
        let todayStart = cal.startOfDay(for: Date())

        // Median words
        let sortedWordCounts = notes.map(\.wordCount).sorted()
        let medianWords: Int
        if sortedWordCounts.isEmpty {
            medianWords = 0
        } else {
            let mid = sortedWordCounts.count / 2
            if sortedWordCounts.count % 2 == 0 {
                medianWords = (sortedWordCounts[mid - 1] + sortedWordCounts[mid]) / 2
            } else {
                medianWords = sortedWordCounts[mid]
            }
        }

        for note in notes {
            if let mod = note.modified, mod >= weekStart {
                thisWeekNotes += 1
                thisWeekWords += note.wordCount
            }
            if let mod = note.modified, cal.isDate(mod, inSameDayAs: todayStart) {
                todayWords += note.wordCount
            }
            if note.sourceMarkdown.contains("](") {
                notesWithLinks += 1
            }
        }

        return NoteStatistics(
            totalNotes: notes.count,
            totalWords: totalWords,
            totalChars: totalChars,
            averageWords: notes.isEmpty ? 0 : totalWords / notes.count,
            tagFrequency: tagFreq,
            longestNotes: longest,
            oldestNote: oldestNote,
            newestNote: newestNote,
            notesWithImages: notesWithImages,
            activityDays: activityDays,
            untaggedNotes: untaggedNotes,
            missingBearIds: missingBearIds,
            missingImageRefs: missingImageRefs,
            duplicateTitleNotes: duplicateTitleNotes,
            writingStreak: streak,
            uniqueTags: tagCounts.count,
            thisWeekNotes: thisWeekNotes,
            thisWeekWords: thisWeekWords,
            todayWords: todayWords,
            medianWords: medianWords,
            notesWithLinks: notesWithLinks
        )
    }
}
