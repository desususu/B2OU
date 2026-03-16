// Config.swift — Export configuration for the Bear → disk export engine.

import Foundation

// MARK: - Default Bear Paths

private let home = FileManager.default.homeDirectoryForCurrentUser

public let defaultBearDB = home
    .appendingPathComponent("Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear")
    .appendingPathComponent("Application Data/database.sqlite")

public let defaultBearImagePath = home
    .appendingPathComponent("Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear")
    .appendingPathComponent("Application Data/Local Files/Note Images")

public let defaultBearFilePath = home
    .appendingPathComponent("Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear")
    .appendingPathComponent("Application Data/Local Files/Note Files")

// MARK: - ExportConfig

public struct ExportConfig: Sendable {
    // Required paths
    public var exportPath: URL
    public var exportPathTB: URL?

    // Optional / defaulted paths
    public var bearDB: URL
    public var bearImagePath: URL
    public var bearFilePath: URL
    public var assetsPath: URL?

    // Export format: "md", "tb", "both"
    public var exportFormat: String

    // Tag / folder options
    public var makeTagFolders: Bool
    public var multiTagFolders: Bool
    public var hideTags: Bool
    public var onlyExportTags: [String]
    public var excludeTags: [String]

    // Metadata
    public var yamlFrontMatter: Bool

    // Filename strategy: "title", "slug", "date-title", "id"
    public var naming: String

    // Stale-file policy: "trash", "remove", "keep"
    public var onDelete: String

    // Scheduled backup: interval in minutes (0 = disabled), max kept backups
    public var backupInterval: Int
    public var backupPath: URL?
    public var backupMaxKeep: Int

    public init(
        exportPath: URL,
        exportPathTB: URL? = nil,
        bearDB: URL = defaultBearDB,
        bearImagePath: URL = defaultBearImagePath,
        bearFilePath: URL = defaultBearFilePath,
        assetsPath: URL? = nil,
        exportFormat: String = "md",
        makeTagFolders: Bool = false,
        multiTagFolders: Bool = true,
        hideTags: Bool = false,
        onlyExportTags: [String] = [],
        excludeTags: [String] = [],
        yamlFrontMatter: Bool = false,
        naming: String = "title",
        onDelete: String = "trash",
        backupInterval: Int = 0,
        backupPath: URL? = nil,
        backupMaxKeep: Int = 24
    ) {
        self.exportPath = exportPath
        self.exportPathTB = exportPathTB
        self.bearDB = bearDB
        self.bearImagePath = bearImagePath
        self.bearFilePath = bearFilePath
        self.assetsPath = assetsPath ?? exportPath.appendingPathComponent("BearImages")
        self.exportFormat = exportFormat
        self.makeTagFolders = makeTagFolders
        self.multiTagFolders = multiTagFolders
        self.hideTags = hideTags
        self.onlyExportTags = onlyExportTags
        self.excludeTags = excludeTags
        self.yamlFrontMatter = yamlFrontMatter
        self.naming = naming
        self.onDelete = onDelete
        self.backupInterval = backupInterval
        self.backupPath = backupPath
        self.backupMaxKeep = backupMaxKeep
    }

    // MARK: - Derived Flags

    public var exportAsTextbundles: Bool { exportFormat == "tb" }
    public var exportAsHybrids: Bool { exportFormat == "tb" }
    public var exportImageRepository: Bool { exportFormat == "md" }

    public var exportTsFile: URL {
        exportPath.appendingPathComponent(".export-time.log")
    }

    // MARK: - Multi-Format Helpers

    public func splitExportConfigs() throws -> [ExportConfig] {
        guard exportFormat == "both" else { return [self] }
        guard let tbPath = exportPathTB else {
            throw B2OUError.missingTextBundleFolder
        }
        guard tbPath.standardizedFileURL != exportPath.standardizedFileURL else {
            throw B2OUError.sameFolderForBothFormats
        }

        var mdCfg = self
        mdCfg.exportFormat = "md"
        mdCfg.exportPathTB = nil
        mdCfg.assetsPath = mdCfg.exportPath.appendingPathComponent("BearImages")

        var tbCfg = self
        tbCfg.exportFormat = "tb"
        tbCfg.exportPath = tbPath
        tbCfg.exportPathTB = nil
        tbCfg.assetsPath = nil

        return [mdCfg, tbCfg]
    }
}

// MARK: - Errors

public enum B2OUError: Error, LocalizedError {
    case missingTextBundleFolder
    case sameFolderForBothFormats
    case profileNotFound(String, available: [String])
    case missingOutputPath(String)
    case tomlNotAvailable
    case databaseOpenFailed(String)
    case exportLocked(URL)

    public var errorDescription: String? {
        switch self {
        case .missingTextBundleFolder:
            return "TextBundle output folder is required when format is 'both'."
        case .sameFolderForBothFormats:
            return "Markdown and TextBundle output folders must be different."
        case .profileNotFound(let name, let available):
            return "Profile '\(name)' not found. Available: \(available.joined(separator: ", "))"
        case .missingOutputPath(let profile):
            return "Profile '\(profile)' is missing required 'out' key."
        case .tomlNotAvailable:
            return "Could not parse TOML configuration."
        case .databaseOpenFailed(let reason):
            return "Could not open Bear database: \(reason)"
        case .exportLocked(let path):
            return "Another b2ou instance is already exporting to \(path.path)."
        }
    }
}
