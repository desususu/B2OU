import Foundation

public struct ProfileConfigUpdate: Sendable {
    public var exportPath: String
    public var exportFormat: String
    public var exportPathTB: String?
    public var yamlFrontMatter: Bool
    public var hideTags: Bool
    public var tagFolders: Bool
    public var onDelete: String
    public var naming: String
    public var excludeTags: [String]?
    public var backupInterval: Int
    public var backupPath: String?
    /// Max completed backups to retain when scheduled backup is enabled (default 24).
    public var backupMaxKeep: Int
    public var source: String
    public var bearCLIPath: String?

    public init(
        exportPath: String,
        exportFormat: String = "md",
        exportPathTB: String? = nil,
        yamlFrontMatter: Bool = false,
        hideTags: Bool = false,
        tagFolders: Bool = false,
        onDelete: String = "trash",
        naming: String = "title",
        excludeTags: [String]? = nil,
        backupInterval: Int = 0,
        backupPath: String? = nil,
        backupMaxKeep: Int = 24,
        source: String = "auto",
        bearCLIPath: String? = nil
    ) {
        self.exportPath = exportPath
        self.exportFormat = exportFormat
        self.exportPathTB = exportPathTB
        self.yamlFrontMatter = yamlFrontMatter
        self.hideTags = hideTags
        self.tagFolders = tagFolders
        self.onDelete = onDelete
        self.naming = naming
        self.excludeTags = excludeTags
        self.backupInterval = backupInterval
        self.backupPath = backupPath
        self.backupMaxKeep = max(1, backupMaxKeep)
        self.source = source
        self.bearCLIPath = bearCLIPath
    }

    public init(config: ExportConfig) {
        self.init(
            exportPath: config.exportPath.path,
            exportFormat: config.exportFormat,
            exportPathTB: config.exportPathTB?.path,
            yamlFrontMatter: config.yamlFrontMatter,
            hideTags: config.hideTags,
            tagFolders: config.makeTagFolders,
            onDelete: config.onDelete,
            naming: config.naming,
            excludeTags: config.excludeTags,
            backupInterval: config.backupInterval,
            backupPath: config.backupPath?.path,
            backupMaxKeep: config.backupMaxKeep,
            source: config.bearSource,
            bearCLIPath: config.bearCLIPath.path
        )
    }
}

public func defaultConfigFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    home.appendingPathComponent(".config/b2ou/b2ou.toml")
}

@discardableResult
public func writeProfileConfig(
    profileName: String,
    update: ProfileConfigUpdate,
    configFile: URL? = nil
) throws -> URL {
    let targetURL = configFile ?? findConfig() ?? defaultConfigFileURL()
    try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let current = (try? String(contentsOf: targetURL, encoding: .utf8)) ?? ""
    let section = renderProfileSection(profileName: profileName, update: update)
    let updated = replaceProfileSection(in: current, profileName: profileName, with: section)
    try updated.write(to: targetURL, atomically: true, encoding: .utf8)
    return targetURL
}

private func renderProfileSection(profileName: String, update: ProfileConfigUpdate) -> String {
    var lines = [
        "[profile.\(profileName)]",
        "out = \"\(tomlEscape(update.exportPath))\"",
        "format = \"\(tomlEscape(update.exportFormat))\"",
        "on-delete = \"\(tomlEscape(update.onDelete))\"",
        "naming = \"\(tomlEscape(update.naming))\"",
    ]
    if let tb = update.exportPathTB, !tb.isEmpty {
        lines.append("out-tb = \"\(tomlEscape(tb))\"")
    }
    if update.yamlFrontMatter { lines.append("yaml-front-matter = true") }
    if update.hideTags { lines.append("hide-tags = true") }
    if update.tagFolders { lines.append("tag-folders = true") }
    if update.source != "auto" {
        lines.append("source = \"\(tomlEscape(update.source))\"")
    }
    if let bearCLIPath = update.bearCLIPath,
       !bearCLIPath.isEmpty,
       bearCLIPath != defaultBearCLIPath.path {
        lines.append("bearcli-path = \"\(tomlEscape(bearCLIPath))\"")
    }
    if let tags = update.excludeTags, !tags.isEmpty {
        let tagsString = tags.map { "\"\(tomlEscape($0))\"" }.joined(separator: ", ")
        lines.append("exclude-tags = [\(tagsString)]")
    }
    if update.backupInterval > 0 {
        lines.append("backup-interval = \(update.backupInterval)")
        if update.backupMaxKeep != 24 {
            lines.append("backup-max-keep = \(update.backupMaxKeep)")
        }
    }
    if let backupPath = update.backupPath, !backupPath.isEmpty {
        lines.append("backup-path = \"\(tomlEscape(backupPath))\"")
    }
    return lines.joined(separator: "\n")
}

private let writableProfileKeys: Set<String> = [
    "out",
    "format",
    "on-delete",
    "naming",
    "out-tb",
    "yaml-front-matter",
    "hide-tags",
    "tag-folders",
    "source",
    "bearcli-path",
    "exclude-tags",
    "backup-interval",
    "backup-max-keep",
    "backup-path",
]

private func replaceProfileSection(in content: String, profileName: String, with section: String) -> String {
    let header = "[profile.\(profileName)]"
    let sectionLines = section.components(separatedBy: .newlines)
    var lines = content.components(separatedBy: .newlines)
    if lines.last == "" { lines.removeLast() }

    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
        let base = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return "# B2OU - Bear note export configuration\n\n\(section)\n"
        }
        return "\(base)\n\n\(section)\n"
    }

    var end = start + 1
    while end < lines.count {
        if isTOMLTableHeader(lines[end]) { break }
        end += 1
    }

    let preserved = lines[(start + 1)..<end].filter { line in
        guard let key = tomlAssignmentKey(in: line) else { return true }
        return !writableProfileKeys.contains(key)
    }
    var replacement = sectionLines
    if !preserved.isEmpty {
        replacement.append("")
        replacement.append(contentsOf: preserved)
    }

    lines.replaceSubrange(start..<end, with: replacement)
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
}

private func isTOMLTableHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("[[")
}

private func tomlAssignmentKey(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eqIdx = trimmed.firstIndex(of: "=") else {
        return nil
    }
    return String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
}

private func tomlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\0", with: "")
}
