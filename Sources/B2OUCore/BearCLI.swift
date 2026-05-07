// BearCLI.swift — Safe read-only bridge to Bear's official bearcli tool.

import Foundation

public struct BearCLIAttachment: Sendable, Equatable {
    public let filename: String
    public let size: Int64?

    public init(filename: String, size: Int64? = nil) {
        self.filename = filename
        self.size = size
    }
}

public struct BearCLINote: Sendable {
    public let id: String
    public let title: String
    public let content: String
    public let hash: String
    public let modifiedISO: String
    public let createdUnix: Double
    public let modifiedUnix: Double
    public let tags: [String]
    public let attachments: [BearCLIAttachment]
    public let attachmentCountHint: Int?

    public var bearNote: BearNote {
        BearNote(
            title: title,
            text: content.trimmingTrailingWhitespace(),
            creationDate: createdUnix - coreDataEpoch,
            modifiedDate: modifiedUnix - coreDataEpoch,
            uuid: id,
            pk: 0
        )
    }

    public var needsAttachmentListRefresh: Bool {
        guard let attachmentCountHint else { return false }
        return attachmentCountHint > attachments.count
    }
}

public struct BearCLISignature: Sendable, Equatable {
    public let latestModified: Double
    public let noteCount: Int
}

public struct BearCLINoteAttachmentIndex: Sendable {
    public let id: String
    public let attachments: [BearCLIAttachment]
    public let attachmentCountHint: Int?

    public var needsAttachmentListRefresh: Bool {
        guard let attachmentCountHint else { return false }
        return attachmentCountHint > attachments.count
    }
}

public struct BearCLIClient: Sendable {
    public let executable: URL

    public init(executable: URL = defaultBearCLIPath) {
        self.executable = executable
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    public func ensureAvailable() throws {
        guard isAvailable else {
            throw B2OUError.bearCLIUnavailable(executable.path)
        }
    }

    public func listNotes(location: String = "notes") throws -> [BearCLINote] {
        let data = try runJSON([
            "list",
            "--location", location,
            "--format", "json",
            "--fields", "id,title,locked,tags,hash,created,modified,attachments,content",
        ])

        let rawNotes = try JSONDecoder().decode([RawBearCLINote].self, from: data)
        return rawNotes.compactMap { raw in
            guard !raw.locked else { return nil }
            guard let id = raw.id, !id.isEmpty else { return nil }
            guard let content = raw.content else { return nil }
            let fallbackTitle = firstHeading(content)
            let title = raw.title?.isEmpty == false ? raw.title! : (fallbackTitle.isEmpty ? "Untitled" : fallbackTitle)
            return BearCLINote(
                id: id,
                title: title,
                content: content,
                hash: raw.hash ?? "",
                modifiedISO: raw.modified ?? "",
                createdUnix: parseBearCLITimestamp(raw.created) ?? 0,
                modifiedUnix: parseBearCLITimestamp(raw.modified) ?? 0,
                tags: raw.tags.normalizedTags,
                attachments: raw.attachments.items,
                attachmentCountHint: raw.attachments.countHint
            )
        }
    }

    public func listNoteMetadata(location: String = "notes") throws -> [BearCLINoteMetadata] {
        let data = try runJSON([
            "list",
            "--location", location,
            "--format", "json",
            "--fields", "id,title,locked,hash,modified",
        ])

        let rawNotes = try JSONDecoder().decode([RawBearCLINote].self, from: data)
        return rawNotes.compactMap { raw in
            guard !raw.locked else { return nil }
            guard let id = raw.id, !id.isEmpty else { return nil }
            return BearCLINoteMetadata(
                id: id,
                title: raw.title ?? "",
                hash: raw.hash ?? "",
                modified: raw.modified ?? ""
            )
        }
    }

    public func listAttachments(noteID: String) throws -> [BearCLIAttachment] {
        let data = try runJSON([
            "attachments", "list", noteID,
            "--format", "json",
            "--fields", "filename,size",
        ])
        return try JSONDecoder().decode([RawBearCLIAttachment].self, from: data)
            .compactMap { $0.attachment }
    }

    public func noteAttachmentIndex(location: String = "all") throws -> [BearCLINoteAttachmentIndex] {
        let data = try runJSON([
            "list",
            "--location", location,
            "--format", "json",
            "--fields", "id,locked,attachments",
        ])
        let rawNotes = try JSONDecoder().decode([RawBearCLINote].self, from: data)
        return rawNotes.compactMap { raw in
            guard !raw.locked else { return nil }
            guard let id = raw.id, !id.isEmpty else { return nil }
            return BearCLINoteAttachmentIndex(
                id: id,
                attachments: raw.attachments.items,
                attachmentCountHint: raw.attachments.countHint
            )
        }
    }

    public func writeNotesSnapshot(location: String = "all", to destination: URL) throws {
        try ensureAvailable()
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw B2OUError.bearCLICommandFailed("Cannot create temporary notes snapshot")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        do {
            try run(
                args: [
                    "list",
                    "--location", location,
                    "--format", "json",
                    "--fields", "all,content",
                ],
                stdout: handle
            )
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public func saveAttachment(noteID: String, filename: String, to destination: URL) throws {
        try ensureAvailable()

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw B2OUError.bearCLICommandFailed("Cannot create temporary attachment file")
        }

        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        do {
            try run(
                args: ["attachments", "save", noteID, "--filename", filename],
                stdout: handle
            )
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public func signature(location: String = "notes") throws -> BearCLISignature {
        let countData = try runJSON([
            "list",
            "--location", location,
            "--count",
            "--format", "json",
        ])
        let count = (try? JSONDecoder().decode(BearCLICount.self, from: countData).count) ?? 0

        let latestData = try runJSON([
            "list",
            "--location", location,
            "--sort", "modified:desc",
            "--limit", "1",
            "--format", "json",
            "--fields", "id,modified",
        ])
        let latest = (try? JSONDecoder().decode([RawBearCLINote].self, from: latestData).first)
        return BearCLISignature(
            latestModified: parseBearCLITimestamp(latest?.modified) ?? 0,
            noteCount: count
        )
    }

    private func runJSON(_ args: [String]) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2ou-bearcli-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw B2OUError.bearCLICommandFailed("Cannot create temporary output file")
        }
        let handle = try FileHandle(forWritingTo: tmp)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: tmp)
        }

        try run(args: args, stdout: handle)
        return try Data(contentsOf: tmp)
    }

    private func run(args: [String], stdout: Any) throws {
        try ensureAvailable()

        let process = Process()
        process.executableURL = executable
        process.arguments = args

        let err = Pipe()
        process.standardOutput = stdout
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw B2OUError.bearCLICommandFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw B2OUError.bearCLICommandFailed(message?.isEmpty == false ? message! : "exit \(process.terminationStatus)")
        }
    }
}

public func shouldReadWithBearCLI(config: ExportConfig) -> Bool {
    let source = config.bearSource.lowercased()
    if source == "sqlite" { return false }
    let client = BearCLIClient(executable: config.bearCLIPath)
    if source == "bearcli" { return true }
    guard config.bearDB.standardizedFileURL == defaultBearDB.standardizedFileURL else {
        return false
    }
    return client.isAvailable
}

public func sourceSignature(config: ExportConfig) -> (lastModified: Double, byteCount: Int64) {
    let source = config.bearSource.lowercased()
    if shouldReadWithBearCLI(config: config) {
        if let sig = try? BearCLIClient(executable: config.bearCLIPath).signature(location: "notes") {
            return (sig.latestModified, Int64(sig.noteCount))
        }
        if source == "bearcli" {
            return (0, -1)
        }
    }
    return bearDBFileSignature(dbPath: config.bearDB)
}

public func sourceIsQuiet(config: ExportConfig, quietSeconds: TimeInterval) -> Bool {
    if shouldReadWithBearCLI(config: config) { return true }
    return dbIsQuiet(dbPath: config.bearDB, quietSeconds: quietSeconds)
}

public func parseBearCLITimestamp(_ value: String?) -> Double? {
    guard let value, !value.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) {
        return date.timeIntervalSince1970
    }
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: value)?.timeIntervalSince1970
}

public func normalizeBearTag(_ tag: String) -> String {
    var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("#") { value.removeFirst() }
    if value.hasSuffix("#") { value.removeLast() }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func safeBearCLIAssetFolderName(noteID: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    var result = String(noteID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if result.isEmpty { result = "note" }
    return String(result.prefix(48))
}

private struct BearCLICount: Decodable {
    let count: Int
}

private struct RawBearCLINote: Decodable {
    let id: String?
    let title: String?
    let locked: Bool
    let hash: String?
    let tags: FlexibleTags
    let created: String?
    let modified: String?
    let attachments: FlexibleAttachments
    let content: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        locked = ((try? c.decodeIfPresent(FlexibleBool.self, forKey: .locked)) ?? FlexibleBool()).value
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        tags = (try? c.decodeIfPresent(FlexibleTags.self, forKey: .tags)) ?? FlexibleTags()
        created = try c.decodeIfPresent(String.self, forKey: .created)
        modified = try c.decodeIfPresent(String.self, forKey: .modified)
        attachments = (try? c.decodeIfPresent(FlexibleAttachments.self, forKey: .attachments)) ?? FlexibleAttachments()
        content = try c.decodeIfPresent(String.self, forKey: .content)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, locked, hash, tags, created, modified, attachments, content
    }
}

private struct FlexibleBool: Decodable {
    let value: Bool

    init(_ value: Bool = false) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self.value = value
            return
        }
        if let value = try? c.decode(Int.self) {
            self.value = value != 0
            return
        }
        if let value = try? c.decode(String.self) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "locked":
                self.value = true
            default:
                self.value = false
            }
            return
        }
        self.value = false
    }
}

private struct FlexibleTags: Decodable {
    var values: [String] = []

    var normalizedTags: [String] {
        values.map(normalizeBearTag).filter { !$0.isEmpty }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let values = try? c.decode([String].self) {
            self.values = values
        } else if let value = try? c.decode(String.self) {
            self.values = value
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

private struct FlexibleAttachments: Decodable {
    var items: [BearCLIAttachment] = []
    var countHint: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Int.self) {
            countHint = value
        } else if let value = try? c.decode(Bool.self) {
            countHint = value ? 1 : 0
        } else if let values = try? c.decode([String].self) {
            items = values.map { BearCLIAttachment(filename: $0) }
            countHint = items.count
        } else if let values = try? c.decode([RawBearCLIAttachment].self) {
            items = values.compactMap(\.attachment)
            countHint = items.count
        }
    }
}

private struct RawBearCLIAttachment: Decodable {
    let filename: String?
    let name: String?
    let size: Int64?

    var attachment: BearCLIAttachment? {
        guard let value = filename ?? name, !value.isEmpty else { return nil }
        return BearCLIAttachment(filename: value, size: size)
    }
}
