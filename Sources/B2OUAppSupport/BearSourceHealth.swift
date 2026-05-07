// BearSourceHealth.swift — shared foreground health checks for Bear source access.

import Foundation
import B2OUCore

public enum BearSourceKind: Sendable {
    case bearCLI
    case sqlite
}

public struct BearSourceHealth: Sendable {
    public let isAvailable: Bool
    public let kind: BearSourceKind?
    public let problemMessage: String?

    public init(isAvailable: Bool, kind: BearSourceKind?, problemMessage: String?) {
        self.isAvailable = isAvailable
        self.kind = kind
        self.problemMessage = problemMessage
    }

    public static func evaluate(config: ExportConfig?) -> BearSourceHealth {
        guard let config else {
            return BearSourceHealth(
                isAvailable: false,
                kind: nil,
                problemMessage: t("workspace.bear_source_unconfigured")
            )
        }

        let source = config.bearSource.lowercased()
        if source == "bearcli" {
            let available = BearCLIClient(executable: config.bearCLIPath).isAvailable
            return BearSourceHealth(
                isAvailable: available,
                kind: .bearCLI,
                problemMessage: available ? nil : t("workspace.bear_cli_missing")
            )
        }

        if shouldReadWithBearCLI(config: config) {
            return BearSourceHealth(isAvailable: true, kind: .bearCLI, problemMessage: nil)
        }

        let available = FileManager.default.fileExists(atPath: config.bearDB.path)
        return BearSourceHealth(
            isAvailable: available,
            kind: .sqlite,
            problemMessage: available ? nil : t("workspace.bear_db_missing")
        )
    }

    public var connectedDetail: String {
        if let problemMessage {
            return problemMessage
        }
        switch kind {
        case .bearCLI:
            return t("workspace.bear_cli_available")
        case .sqlite:
            return t("workspace.bear_db_permission")
        case nil:
            return t("workspace.bear_source_unconfigured")
        }
    }
}
