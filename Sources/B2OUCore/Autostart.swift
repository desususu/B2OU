// Autostart.swift — macOS Login Item (LaunchAgent) management for B2OU.

import Foundation

private let label = "net.b2ou.app"
private let launchAgents = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents")
private let plistPath = launchAgents.appendingPathComponent("\(label).plist")

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
    do {
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: buildPlist(), format: .xml, options: 0
        )
        try plistData.write(to: plistPath)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["load", "-w", plistPath.path]
        try task.run()
        task.waitUntilExit()
        return true
    } catch {
        return false
    }
}

public func removeLoginItem() -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: plistPath.path) else { return true }
    do {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistPath.path]
        try task.run()
        task.waitUntilExit()
        try fm.removeItem(at: plistPath)
        return true
    } catch {
        return false
    }
}

public func isLoginItem() -> Bool {
    FileManager.default.fileExists(atPath: plistPath.path)
}
