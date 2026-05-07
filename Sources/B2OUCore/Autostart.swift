// Autostart.swift — macOS Login Item (LaunchAgent) management for B2OU.

import Foundation

private let label = "net.b2ou.app"
private let launchAgents = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents")
private let plistPath = launchAgents.appendingPathComponent("\(label).plist")

public struct LoginItemToggleOutcome: Equatable, Sendable {
    public let requestedEnabled: Bool
    public let effectiveEnabled: Bool
    public let errorMessage: String?

    public init(requestedEnabled: Bool, effectiveEnabled: Bool, errorMessage: String?) {
        self.requestedEnabled = requestedEnabled
        self.effectiveEnabled = effectiveEnabled
        self.errorMessage = errorMessage
    }

    public var succeeded: Bool {
        errorMessage == nil && effectiveEnabled == requestedEnabled
    }
}

public struct LoginItemControlError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public protocol LoginItemControlling {
    func isEnabled() -> Bool
    func enable() -> Result<Void, LoginItemControlError>
    func disable() -> Result<Void, LoginItemControlError>
}

public struct SystemLoginItemController: LoginItemControlling {
    public init() {}

    public func isEnabled() -> Bool {
        isLoginItem()
    }

    public func enable() -> Result<Void, LoginItemControlError> {
        addLoginItemDetailed()
    }

    public func disable() -> Result<Void, LoginItemControlError> {
        removeLoginItemDetailed()
    }
}

public func applyLoginItemToggle(
    _ enabled: Bool,
    controller: some LoginItemControlling = SystemLoginItemController()
) -> LoginItemToggleOutcome {
    let wasEnabled = controller.isEnabled()
    if wasEnabled == enabled {
        return LoginItemToggleOutcome(
            requestedEnabled: enabled,
            effectiveEnabled: wasEnabled,
            errorMessage: nil
        )
    }

    let result = enabled ? controller.enable() : controller.disable()
    let effectiveEnabled = controller.isEnabled()

    switch result {
    case .success:
        if effectiveEnabled == enabled {
            return LoginItemToggleOutcome(
                requestedEnabled: enabled,
                effectiveEnabled: effectiveEnabled,
                errorMessage: nil
            )
        }
        return LoginItemToggleOutcome(
            requestedEnabled: enabled,
            effectiveEnabled: effectiveEnabled,
            errorMessage: t("menu.start_at_login_state_mismatch")
        )
    case .failure(let message):
        return LoginItemToggleOutcome(
            requestedEnabled: enabled,
            effectiveEnabled: effectiveEnabled,
            errorMessage: message.message.isEmpty ? t("menu.start_at_login_state_mismatch") : message.message
        )
    }
}

private enum AutostartError: LocalizedError {
    case launchctlFailed(args: [String], status: Int32)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let args, let status):
            return "launchctl \(args.joined(separator: " ")) exited with status \(status)."
        }
    }
}

private func findAppBundle() -> URL? {
    var url = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    while url.pathComponents.count > 1 {
        if url.pathExtension == "app" { return url }
        url = url.deletingLastPathComponent()
    }
    return nil
}

private func buildPlist() -> [String: Any] {
    let programArgs: [String]
    if let appBundle = findAppBundle() {
        programArgs = ["/usr/bin/open", "-a", appBundle.path]
    } else {
        programArgs = [ProcessInfo.processInfo.arguments[0]]
    }

    return [
        "Label": label,
        "ProgramArguments": programArgs,
        "RunAtLoad": true,
        "KeepAlive": false,
        "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/b2ou.log").path,
        "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/b2ou.log").path,
    ]
}

public func addLoginItem() -> Bool {
    if case .success = addLoginItemDetailed() {
        return true
    }
    return false
}

public func addLoginItemDetailed() -> Result<Void, LoginItemControlError> {
    do {
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: buildPlist(), format: .xml, options: 0
        )
        try plistData.write(to: plistPath)
        try runLaunchCtl(["load", "-w", plistPath.path])
        return .success(())
    } catch {
        return .failure(LoginItemControlError(error.localizedDescription))
    }
}

public func removeLoginItem() -> Bool {
    if case .success = removeLoginItemDetailed() {
        return true
    }
    return false
}

public func removeLoginItemDetailed() -> Result<Void, LoginItemControlError> {
    let fm = FileManager.default
    guard fm.fileExists(atPath: plistPath.path) else { return .success(()) }
    do {
        try runLaunchCtl(["unload", plistPath.path])
        try fm.removeItem(at: plistPath)
        return .success(())
    } catch {
        return .failure(LoginItemControlError(error.localizedDescription))
    }
}

public func isLoginItem() -> Bool {
    FileManager.default.fileExists(atPath: plistPath.path)
}

private func runLaunchCtl(_ args: [String]) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = args
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw AutostartError.launchctlFailed(args: args, status: task.terminationStatus)
    }
}
