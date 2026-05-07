import Foundation
import B2OUCore

public enum SettingsValidationIssue: String, Equatable, Sendable {
    case markdownFolderMissing
    case textBundleFolderMissing
    case bothFormatsShareFolder
    case backupFolderConflictsWithExport
}

public struct SettingsValidationInput: Equatable, Sendable {
    public var exportPath: String
    public var exportPathTB: String
    public var exportFormat: String
    public var backupInterval: Int
    public var backupPath: String

    public init(
        exportPath: String,
        exportPathTB: String,
        exportFormat: String,
        backupInterval: Int,
        backupPath: String
    ) {
        self.exportPath = exportPath
        self.exportPathTB = exportPathTB
        self.exportFormat = exportFormat
        self.backupInterval = backupInterval
        self.backupPath = backupPath
    }
}

public func validateSettingsInput(_ input: SettingsValidationInput) -> SettingsValidationIssue? {
    let format = normalizedExportFormat(input.exportFormat)
    let markdownPath = normalizedSettingsPath(input.exportPath)
    let textBundlePath = normalizedSettingsPath(input.exportPathTB)

    if (format == "md" || format == "both") && markdownPath.isEmpty {
        return .markdownFolderMissing
    }

    if (format == "tb" || format == "both") && textBundlePath.isEmpty {
        return .textBundleFolderMissing
    }

    if format == "both" && markdownPath == textBundlePath {
        return .bothFormatsShareFolder
    }

    if input.backupInterval > 0 {
        let backupPath = normalizedSettingsPath(input.backupPath)
        if !backupPath.isEmpty {
            let exportRoots: [String]
            switch format {
            case "tb":
                exportRoots = [textBundlePath]
            case "both":
                exportRoots = [markdownPath, textBundlePath]
            default:
                exportRoots = [markdownPath]
            }
            if exportRoots.contains(backupPath) {
                return .backupFolderConflictsWithExport
            }
        }
    }

    return nil
}

public func settingsValidationMessage(for issue: SettingsValidationIssue) -> String {
    switch issue {
    case .markdownFolderMissing:
        return t("settings.folder_md_missing")
    case .textBundleFolderMissing:
        return t("settings.folder_tb_missing")
    case .bothFormatsShareFolder:
        return t("settings.folder_tb_conflict")
    case .backupFolderConflictsWithExport:
        return t("menu.backup_folder_conflict")
    }
}

private func normalizedExportFormat(_ value: String) -> String {
    switch value {
    case "tb", "both":
        return value
    default:
        return "md"
    }
}

private func normalizedSettingsPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "..." else { return "" }
    return (trimmed as NSString).standardizingPath
}
