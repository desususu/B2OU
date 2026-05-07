// Profile.swift — TOML profile loader for b2ou.
//
// Discovers and parses b2ou.toml config files with [profile.*] sections,
// converting each into an ExportConfig.

import Foundation

// MARK: - Config Discovery

private let searchPaths: [URL] = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return [
        cwd.appendingPathComponent("b2ou.toml"),
        home.appendingPathComponent(".config/b2ou/b2ou.toml"),
        home.appendingPathComponent("b2ou.toml"),
    ]
}()

public func findConfig(explicit: String? = nil) -> URL? {
    if let explicit, !explicit.isEmpty {
        let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    for candidate in searchPaths {
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

// MARK: - Minimal TOML Parser

/// A minimal TOML parser that handles the subset used by b2ou.toml:
/// - [section.subsection] table headers
/// - key = "string"
/// - key = true/false
/// - key = ["array", "of", "strings"]
private struct SimpleTOML {
    static func parse(_ content: String) -> [String: Any] {
        var root: [String: Any] = [:]
        var currentPath: [String] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = stripInlineComment(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Table header: [profile.default]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("[[") {
                let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentPath = inner.components(separatedBy: ".")
                continue
            }

            // Key = value
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            let value = parseValue(rawValue)

            setNestedValue(&root, path: currentPath + [key], value: value)
        }

        return root
    }

    private static func parseValue(_ raw: String) -> Any {
        // Boolean
        if raw == "true" { return true }
        if raw == "false" { return false }

        // String: "..."
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return unescapeDoubleQuoted(String(raw.dropFirst().dropLast()))
        }

        // Literal string: '...'
        if raw.hasPrefix("'") && raw.hasSuffix("'") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }

        // Array: ["a", "b"]
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast())
            return splitArrayItems(inner).compactMap { item -> String? in
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return parseValue(trimmed) as? String
            }
        }

        // Number
        if let d = Double(raw) { return d }

        return raw
    }

    private static func stripInlineComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false

        for ch in line {
            if let currentQuote = quote {
                result.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" && currentQuote == "\"" {
                    escaped = true
                } else if ch == currentQuote {
                    quote = nil
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                result.append(ch)
            } else if ch == "#" {
                break
            } else {
                result.append(ch)
            }
        }

        return result
    }

    private static func unescapeDoubleQuoted(_ value: String) -> String {
        var s = value
        s = s.replacingOccurrences(of: "\\\\", with: "\u{0000}")
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\t", with: "\t")
        s = s.replacingOccurrences(of: "\u{0000}", with: "\\")
        return s
    }

    private static func splitArrayItems(_ inner: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for ch in inner {
            if let currentQuote = quote {
                current.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" && currentQuote == "\"" {
                    escaped = true
                } else if ch == currentQuote {
                    quote = nil
                }
                continue
            }

            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items
    }

    private static func setNestedValue(_ dict: inout [String: Any], path: [String], value: Any) {
        guard !path.isEmpty else { return }
        if path.count == 1 {
            dict[path[0]] = value
            return
        }
        let key = path[0]
        var nested = (dict[key] as? [String: Any]) ?? [:]
        setNestedValue(&nested, path: Array(path.dropFirst()), value: value)
        dict[key] = nested
    }
}

// MARK: - Profile Parsing

private func parseProfile(name: String, data: [String: Any]) throws -> ExportConfig {
    guard let out = data["out"] as? String, !out.isEmpty else {
        throw B2OUError.missingOutputPath(name)
    }

    var fmt = (data["format"] as? String) ?? "md"
    if fmt == "textbundle" { fmt = "tb" }

    let outTB = data["out-tb"] as? String
    if fmt == "both" && (outTB == nil || outTB!.isEmpty) {
        throw B2OUError.missingOutputPath("\(name) (out-tb)")
    }

    let backupPathStr = data["backup-path"] as? String
    var backupInterval = 0
    if let v = data["backup-interval"] as? Double { backupInterval = Int(v) }
    else if let v = data["backup-interval"] as? Int64 { backupInterval = Int(v) }
    var backupMaxKeep = 24
    if let v = data["backup-max-keep"] as? Double { backupMaxKeep = Int(v) }
    else if let v = data["backup-max-keep"] as? Int64 { backupMaxKeep = Int(v) }
    let bearCLIPath = (data["bearcli-path"] as? String)
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultBearCLIPath

    return ExportConfig(
        exportPath: URL(fileURLWithPath: (out as NSString).expandingTildeInPath),
        exportPathTB: outTB.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
        bearCLIPath: bearCLIPath,
        bearSource: (data["source"] as? String) ?? "auto",
        exportFormat: fmt,
        makeTagFolders: (data["tag-folders"] as? Bool) ?? false,
        multiTagFolders: (data["multi-tag-folders"] as? Bool) ?? true,
        hideTags: (data["hide-tags"] as? Bool) ?? false,
        onlyExportTags: (data["only-tags"] as? [String]) ?? [],
        excludeTags: (data["exclude-tags"] as? [String]) ?? [],
        yamlFrontMatter: (data["yaml-front-matter"] as? Bool) ?? false,
        naming: (data["naming"] as? String) ?? "title",
        onDelete: (data["on-delete"] as? String) ?? "trash",
        backupInterval: backupInterval,
        backupPath: backupPathStr.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
        backupMaxKeep: backupMaxKeep
    )
}

public func loadProfiles(configPath: String? = nil) -> [String: ExportConfig] {
    guard let path = findConfig(explicit: configPath) else { return [:] }
    guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [:] }

    let data = SimpleTOML.parse(content)
    guard let profiles = data["profile"] as? [String: Any] else { return [:] }

    var result: [String: ExportConfig] = [:]
    for (name, section) in profiles {
        guard let sectionDict = section as? [String: Any] else { continue }
        do {
            result[name] = try parseProfile(name: name, data: sectionDict)
        } catch {
            // Skip invalid profiles
        }
    }
    return result
}

public func loadProfile(name: String, configPath: String? = nil) throws -> ExportConfig {
    let profiles = loadProfiles(configPath: configPath)
    guard let cfg = profiles[name] else {
        throw B2OUError.profileNotFound(name, available: profiles.keys.sorted())
    }
    return cfg
}
