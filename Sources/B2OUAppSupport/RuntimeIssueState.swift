import Foundation

public enum ExportWatcherOperation: String, Equatable, Sendable {
    case export
    case backup
}

public struct ExportWatcherUpdate: Equatable, Sendable {
    public var noteCount: Int
    public var operation: ExportWatcherOperation
    public var errorMessage: String?

    public init(noteCount: Int, operation: ExportWatcherOperation, errorMessage: String?) {
        self.noteCount = noteCount
        self.operation = operation
        self.errorMessage = errorMessage
    }
}

public struct RuntimeIssueState: Equatable, Sendable {
    public private(set) var exportError: String?
    public private(set) var backupError: String?

    public init(exportError: String? = nil, backupError: String? = nil) {
        self.exportError = normalizeRuntimeIssue(exportError)
        self.backupError = normalizeRuntimeIssue(backupError)
    }

    public var primaryErrorMessage: String? {
        exportError ?? backupError
    }

    public mutating func apply(_ update: ExportWatcherUpdate) {
        switch update.operation {
        case .export:
            exportError = normalizeRuntimeIssue(update.errorMessage)
        case .backup:
            backupError = normalizeRuntimeIssue(update.errorMessage)
        }
    }

    public mutating func clearAll() {
        exportError = nil
        backupError = nil
    }

    public mutating func clearExportError() {
        exportError = nil
    }

    public mutating func clearBackupError() {
        backupError = nil
    }
}

private func normalizeRuntimeIssue(_ message: String?) -> String? {
    guard let message else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
