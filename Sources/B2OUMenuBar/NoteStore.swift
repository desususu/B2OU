// NoteStore.swift — Data layer for scanning exported notes and computing statistics.
//
// Scans the export directory, parses YAML front matter from exported .md files,
// computes word counts, tag frequencies, and activity data for the dashboard
// and note preview features.

import Foundation
import B2OUCore

// MARK: - Note Metadata

struct NoteMetadata {
    let title: String
    let created: Date?
    let modified: Date?
    let tags: [String]
    let wordCount: Int
    let charCount: Int
    let filePath: URL
    let bearId: String
    let hasImages: Bool
}

// MARK: - Aggregate Statistics

struct NoteStatistics {
    let totalNotes: Int
    let totalWords: Int
    let totalChars: Int
    let averageWords: Int
    let tagFrequency: [(tag: String, count: Int)]
    let longestNotes: [(title: String, words: Int)]
    let oldestNote: NoteMetadata?
    let newestNote: NoteMetadata?
    let notesWithImages: Int
    let activityDays: [Date: Int]
}

// MARK: - NoteStore

class NoteStore {
    private(set) var notes: [NoteMetadata] = []
    private(set) var stats: NoteStatistics?

    /// Scan exported notes at the given path (safe to call from any thread).
    func scan(exportPath: URL) {
        var scanned: [NoteMetadata] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: exportPath,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return }

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
            if let meta = parseNote(at: url) {
                scanned.append(meta)
            }
        }

        notes = scanned
        stats = computeStats(from: scanned)
    }

    /// Pick a deterministic "note of the day" (consistent within the same calendar day).
    func noteOfTheDay() -> NoteMetadata? {
        guard !notes.isEmpty else { return nil }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let old = notes.filter { ($0.created ?? Date()) < cutoff }
        let pool = old.isEmpty ? notes : old
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        let year = Calendar.current.component(.year, from: Date())
        return pool[(dayOfYear &+ year) % pool.count]
    }

    // MARK: - Parsing

    private func parseNote(at url: URL) -> NoteMetadata? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var title = url.deletingPathExtension().lastPathComponent
        var created: Date?
        var modified: Date?
        var tags: [String] = []
        var bearId = ""
        var bodyContent = content

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

        // Fallback: file system dates
        if created == nil || modified == nil {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                if created == nil { created = attrs[.creationDate] as? Date }
                if modified == nil { modified = attrs[.modificationDate] as? Date }
            }
        }

        let body = bodyContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = body.isEmpty ? 0 : body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let chars = body.filter { !$0.isWhitespace && !$0.isNewline }.count
        let hasImages = body.contains("![") || body.contains("[image:")

        return NoteMetadata(
            title: title, created: created, modified: modified,
            tags: tags, wordCount: words, charCount: chars,
            filePath: url, bearId: bearId, hasImages: hasImages
        )
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
        return f.date(from: s)
    }

    // MARK: - Statistics

    private func computeStats(from notes: [NoteMetadata]) -> NoteStatistics {
        let totalWords = notes.reduce(0) { $0 + $1.wordCount }
        let totalChars = notes.reduce(0) { $0 + $1.charCount }

        var tagCounts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags { tagCounts[tag, default: 0] += 1 }
        }
        let tagFreq = tagCounts.sorted { $0.value > $1.value }.map { (tag: $0.key, count: $0.value) }

        let sorted = notes.sorted { $0.wordCount > $1.wordCount }
        let longest = Array(sorted.prefix(5).map { (title: $0.title, words: $0.wordCount) })

        let byCreated = notes.filter { $0.created != nil }.sorted { $0.created! < $1.created! }

        let cal = Calendar.current
        var activityDays: [Date: Int] = [:]
        for note in notes {
            if let mod = note.modified {
                let day = cal.startOfDay(for: mod)
                activityDays[day, default: 0] += 1
            }
        }

        return NoteStatistics(
            totalNotes: notes.count,
            totalWords: totalWords,
            totalChars: totalChars,
            averageWords: notes.isEmpty ? 0 : totalWords / notes.count,
            tagFrequency: tagFreq,
            longestNotes: longest,
            oldestNote: byCreated.first,
            newestNote: byCreated.last,
            notesWithImages: notes.filter { $0.hasImages }.count,
            activityDays: activityDays
        )
    }
}
