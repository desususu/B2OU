import Foundation
import B2OUCore

public enum MenuPanelStatusStyle: String, Equatable, Sendable {
    case success
    case warning
    case neutral
    case error
}

public struct MenuPanelSnapshotInput: Sendable {
    public var languageCode: String
    public var config: ExportConfig?
    public var sourceHealth: BearSourceHealth
    public var isPaused: Bool
    public var isExporting: Bool
    public var noteCount: Int
    public var lastExportTime: Date?
    public var lastBackupTime: Date?
    public var lastExportError: String?
    public var lastBackupError: String?
    public var now: Date

    public init(
        languageCode: String,
        config: ExportConfig?,
        sourceHealth: BearSourceHealth,
        isPaused: Bool,
        isExporting: Bool,
        noteCount: Int,
        lastExportTime: Date?,
        lastBackupTime: Date?,
        lastExportError: String? = nil,
        lastBackupError: String? = nil,
        now: Date = Date()
    ) {
        self.languageCode = languageCode
        self.config = config
        self.sourceHealth = sourceHealth
        self.isPaused = isPaused
        self.isExporting = isExporting
        self.noteCount = noteCount
        self.lastExportTime = lastExportTime
        self.lastBackupTime = lastBackupTime
        self.lastExportError = lastExportError
        self.lastBackupError = lastBackupError
        self.now = now
    }
}

public struct MenuPanelSnapshot: Equatable, Sendable {
    public let appTitle: String
    public let summaryText: String
    public let lastExportText: String
    public let lastBackupText: String
    public let statusText: String
    public let statusStyle: MenuPanelStatusStyle
    public let canExportNow: Bool
    public let exportFolderName: String?
    public let toolTip: String
}

public func buildMenuPanelSnapshot(_ input: MenuPanelSnapshotInput) -> MenuPanelSnapshot {
    let appTitle = localizedMenuText(languageCode: input.languageCode, zh: "Bear 导出助手", en: "Exporter for Bear")
    let sourceProblem = normalizedMessage(input.config == nil ? nil : input.sourceHealth.problemMessage)
    let lastExportError = normalizedMessage(input.lastExportError)
    let lastBackupError = normalizedMessage(input.lastBackupError)
    let primaryRuntimeError = lastExportError ?? lastBackupError

    let summaryText: String
    if let config = input.config {
        if let sourceProblem {
            summaryText = sourceProblem
        } else if let primaryRuntimeError {
            summaryText = firstLine(of: primaryRuntimeError)
        } else if input.noteCount > 0 {
            summaryText = t("menu.notes_exported")
                .replacingOccurrences(of: "{count}", with: "\(input.noteCount)")
        } else {
            summaryText = t("menu.exporting_to")
                .replacingOccurrences(of: "{folder}", with: config.exportPath.lastPathComponent)
        }
    } else {
        summaryText = t("menu.no_profile")
    }

    let statusText: String
    let statusStyle: MenuPanelStatusStyle
    if input.config == nil {
        statusText = localizedMenuText(languageCode: input.languageCode, zh: "未配置", en: "Setup")
        statusStyle = .neutral
    } else if input.isExporting {
        statusText = localizedMenuText(languageCode: input.languageCode, zh: "导出中", en: "Exporting")
        statusStyle = .warning
    } else if sourceProblem != nil {
        statusText = t("workspace.needs_access")
        statusStyle = .warning
    } else if primaryRuntimeError != nil {
        statusText = localizedMenuText(languageCode: input.languageCode, zh: "错误", en: "Error")
        statusStyle = .error
    } else if input.isPaused {
        statusText = localizedMenuText(languageCode: input.languageCode, zh: "已暂停", en: "Paused")
        statusStyle = .warning
    } else {
        statusText = t("workspace.connected")
        statusStyle = .success
    }

    let lastExportText = t("menu.last_export")
        .replacingOccurrences(of: "{time}", with: menuRelativeTime(input.lastExportTime, now: input.now))
    let lastBackupText = t("menu.last_backup")
        .replacingOccurrences(of: "{time}", with: menuRelativeTime(input.lastBackupTime, now: input.now))
    let canExportNow = input.config != nil && sourceProblem == nil && !input.isExporting

    var toolTip = "\(appTitle)\n\(summaryText)"
    if let lastExportError {
        toolTip += "\n\(localizedIssueLabel(languageCode: input.languageCode, operation: .export)): \(lastExportError)"
    }
    if let lastBackupError {
        toolTip += "\n\(localizedIssueLabel(languageCode: input.languageCode, operation: .backup)): \(lastBackupError)"
    }

    return MenuPanelSnapshot(
        appTitle: appTitle,
        summaryText: summaryText,
        lastExportText: lastExportText,
        lastBackupText: lastBackupText,
        statusText: statusText,
        statusStyle: statusStyle,
        canExportNow: canExportNow,
        exportFolderName: input.config?.exportPath.lastPathComponent,
        toolTip: toolTip
    )
}

private func localizedMenuText(languageCode: String, zh: String, en: String) -> String {
    languageCode.lowercased().hasPrefix("zh") ? zh : en
}

private func normalizedMessage(_ message: String?) -> String? {
    guard let message else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func firstLine(of message: String) -> String {
    message.components(separatedBy: .newlines).first ?? message
}

private func localizedIssueLabel(languageCode: String, operation: ExportWatcherOperation) -> String {
    switch operation {
    case .export:
        return localizedMenuText(languageCode: languageCode, zh: "导出错误", en: "Export error")
    case .backup:
        return localizedMenuText(languageCode: languageCode, zh: "备份错误", en: "Backup error")
    }
}

private func menuRelativeTime(_ date: Date?, now: Date) -> String {
    guard let date else { return "--" }
    let ago = max(0, now.timeIntervalSince(date))
    if ago < 60 {
        return t("menu.just_now")
    }
    if ago < 3600 {
        return t("menu.min_ago").replacingOccurrences(of: "{mins}", with: "\(Int(ago / 60))")
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

/// Shared relative-time formatter for menus and settings surfaces.
public func formatMenuRelativeTime(_ date: Date?, now: Date = Date()) -> String {
    menuRelativeTime(date, now: now)
}
