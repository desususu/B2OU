// B2OUBundler - Swift build helper for the release CLI and macOS app bundle.

import Foundation

@main
struct B2OUBundler {
    private static let appName = "B2OU"
    private static let version = "7.0.0"

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let args = Set(CommandLine.arguments.dropFirst())

        if args.contains("clean") {
            try clean(root: root)
            return
        }

        if args.contains("cli") {
            try buildCLI(root: root)
            return
        }

        try buildApp(root: root)
    }

    private static func buildApp(root: URL) throws {
        log("Resolving Swift package dependencies")
        try run("swift", ["package", "resolve"], currentDirectory: root)

        log("Building release binaries")
        try run("swift", ["build", "-c", "release", "--product", "b2ou"], currentDirectory: root)
        try run("swift", ["build", "-c", "release", "--product", "B2OUMenuBar"], currentDirectory: root)

        let dist = root.appendingPathComponent("dist")
        let app = dist.appendingPathComponent("\(appName).app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")

        try resetDirectory(dist)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let release = root.appendingPathComponent(".build/release")
        try copyReplacing(
            release.appendingPathComponent("B2OUMenuBar"),
            to: macOS.appendingPathComponent(appName)
        )
        try strip(macOS.appendingPathComponent(appName))

        try copyReplacing(release.appendingPathComponent("b2ou"), to: dist.appendingPathComponent("b2ou"))
        try strip(dist.appendingPathComponent("b2ou"))

        try copyResources(from: root.appendingPathComponent("resources"), to: resources)
        try writeInfoPlist(to: contents.appendingPathComponent("Info.plist"))
        try signIfAvailable(app)

        log("Built \(app.path)")
        log("Built \(dist.appendingPathComponent("b2ou").path)")
    }

    private static func buildCLI(root: URL) throws {
        log("Building release CLI")
        try run("swift", ["build", "-c", "release", "--product", "b2ou"], currentDirectory: root)
        let dist = root.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        let target = dist.appendingPathComponent("b2ou")
        try copyReplacing(root.appendingPathComponent(".build/release/b2ou"), to: target)
        try strip(target)
        log("Built \(target.path)")
    }

    private static func clean(root: URL) throws {
        for path in [".build", "dist", "resources/icon.iconset"] {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        log("Cleaned build artifacts")
    }

    private static func copyResources(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let icons = source.appendingPathComponent("icons")
        if fm.fileExists(atPath: icons.path) {
            let targetIcons = destination.appendingPathComponent("icons")
            try fm.createDirectory(at: targetIcons, withIntermediateDirectories: true)
            for entry in try fm.contentsOfDirectory(at: icons, includingPropertiesForKeys: nil) where entry.pathExtension == "png" {
                try copyReplacing(entry, to: targetIcons.appendingPathComponent(entry.lastPathComponent))
            }
        }

        let icns = source.appendingPathComponent("B2OU.icns")
        if fm.fileExists(atPath: icns.path) {
            try copyReplacing(icns, to: destination.appendingPathComponent("B2OU.icns"))
        }
    }

    private static func writeInfoPlist(to url: URL) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>B2OU</string>
            <key>CFBundleDisplayName</key>
            <string>B2OU - Bear Export</string>
            <key>CFBundleIdentifier</key>
            <string>net.b2ou.app</string>
            <key>CFBundleVersion</key>
            <string>\(version)</string>
            <key>CFBundleShortVersionString</key>
            <string>\(version)</string>
            <key>CFBundleExecutable</key>
            <string>B2OU</string>
            <key>CFBundleIconFile</key>
            <string>B2OU</string>
            <key>LSUIElement</key>
            <true/>
            <key>NSHumanReadableCopyright</key>
            <string>MIT License</string>
            <key>LSMinimumSystemVersion</key>
            <string>13.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
        try plist.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func resetDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func copyReplacing(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func strip(_ binary: URL) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/strip") else { return }
        try run("/usr/bin/strip", ["-x", binary.path], currentDirectory: binary.deletingLastPathComponent(), allowFailure: true)
    }

    private static func signIfAvailable(_ app: URL) throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/codesign") else { return }
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path], currentDirectory: app.deletingLastPathComponent(), allowFailure: true)
    }

    private static func run(
        _ command: String,
        _ arguments: [String],
        currentDirectory: URL,
        allowFailure: Bool = false
    ) throws {
        let process = Process()
        process.currentDirectoryURL = currentDirectory
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + arguments
        }
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            throw BundlerError.commandFailed(command, process.terminationStatus)
        }
    }

    private static func log(_ message: String) {
        print("[bundler] \(message)")
    }
}

private enum BundlerError: LocalizedError {
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let status):
            return "\(command) failed with exit status \(status)"
        }
    }
}
