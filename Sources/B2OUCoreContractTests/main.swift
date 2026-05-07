import Foundation
import B2OUCore

enum ContractFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

struct ContractRunner {
    var checks = 0
    var tests = 0

    mutating func run(_ name: String, _ body: (inout ContractRunner) throws -> Void) throws {
        tests += 1
        do {
            try body(&self)
        } catch {
            throw ContractFailure.failed("\(name): \(error)")
        }
    }

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() {
            throw ContractFailure.failed(message)
        }
    }

    mutating func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
        checks += 1
        if lhs != rhs {
            throw ContractFailure.failed("\(message) (got \(lhs), expected \(rhs))")
        }
    }

    mutating func expectThrows(_ message: String, _ body: () throws -> Void) throws {
        checks += 1
        do {
            try body()
        } catch is ContractFailure {
            throw ContractFailure.failed(message)
        } catch {
            return
        }
        throw ContractFailure.failed(message)
    }
}

private enum B2OUCoreContractTests {
    static func run() throws {
        var runner = ContractRunner()

        try runner.run("Default config is conservative", testDefaultConfig)
        try runner.run("Both-format config validates and splits", testBothFormatConfig)
        try runner.run("Profile parser keeps inline comments out of values", testProfileParser)
        try runner.run("Markdown normalization covers key GUI-facing rules", testMarkdownNormalization)
        try runner.run("Front matter hides private sync identifiers", testFrontMatterPrivacy)
        try runner.run("Manifest writes relative paths and replaces old entries", testManifestRoundTrip)
        try runner.run("Cleanup removes only stale manifest-managed files", testCleanupBoundary)
        try runner.run("Profile writer preserves existing settings on folder-only changes", testProfileWriterPreservesExistingSettings)
        try runner.run("Profile writer updates one profile without dropping unknown keys", testProfileWriterScopedUpdate)
        try runner.run("Sidecar merge preserves unrelated selected-export bindings", testSidecarMerge)
        try runner.run("Dirty exported files stop silent incremental skips", testDirtyFileGuard)

        print("B2OUCoreContractTests passed \(runner.checks) checks across \(runner.tests) tests")
    }

    private static func testDefaultConfig(_ t: inout ContractRunner) throws {
        let cfg = ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/test"))

        try t.expectEqual(cfg.exportFormat, "md", "default export format is Markdown")
        try t.expectEqual(cfg.naming, "title", "default naming uses title")
        try t.expectEqual(cfg.onDelete, "trash", "default delete handling uses trash")
        try t.expectEqual(cfg.assetsPath?.lastPathComponent, "BearImages", "default assets folder is BearImages")
        try t.expect(!cfg.makeTagFolders, "tag folders are off by default")
        try t.expect(!cfg.yamlFrontMatter, "YAML front matter is off by default")
        try t.expect(!cfg.hideTags, "visible tags are preserved by default")
        try t.expect(cfg.multiTagFolders, "multi-tag folder expansion is on by default")
    }

    private static func testBothFormatConfig(_ t: inout ContractRunner) throws {
        let cfg = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/b2ou-md"),
            exportPathTB: URL(fileURLWithPath: "/tmp/b2ou-tb"),
            exportFormat: "both"
        )

        let configs = try cfg.splitExportConfigs()
        try t.expectEqual(configs.map(\.exportFormat), ["md", "tb"], "both format splits to md and tb")
        try t.expectEqual(configs[0].assetsPath?.lastPathComponent, "BearImages", "Markdown split keeps image repository")
        try t.expect(configs[1].assetsPath == nil, "TextBundle split disables shared image repository")

        try t.expectThrows("both format without out-tb should fail") {
            _ = try ExportConfig(
                exportPath: URL(fileURLWithPath: "/tmp/b2ou-md"),
                exportFormat: "both"
            ).splitExportConfigs()
        }

        try t.expectThrows("both format with same output folders should fail") {
            _ = try ExportConfig(
                exportPath: URL(fileURLWithPath: "/tmp/b2ou-same"),
                exportPathTB: URL(fileURLWithPath: "/tmp/b2ou-same"),
                exportFormat: "both"
            ).splitExportConfigs()
        }
    }

    private static func testProfileParser(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-profile")
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("b2ou.toml")
        let out = root.appendingPathComponent("Vault #1")
        let outTB = root.appendingPathComponent("Bundles #2")
        let bearCLI = root.appendingPathComponent("bearcli # custom")
        let toml = """
        [profile.obsidian] # profile comment
        out = "\(out.path)" # inline comment after a quoted string
        format = "both"
        out-tb = '\(outTB.path)'
        source = "sqlite" # force SQLite for this profile
        bearcli-path = "\(bearCLI.path)"
        tag-folders = true
        only-tags = ["work/project", "ideas, maybe"] # comma inside quoted string
        exclude-tags = ['archive # literal']
        backup-interval = 15 # numeric comment
        """
        try toml.write(to: configURL, atomically: true, encoding: .utf8)

        let cfg = try loadProfile(name: "obsidian", configPath: configURL.path)
        try t.expectEqual(cfg.exportPath.path, out.path, "profile out keeps quoted # characters")
        try t.expectEqual(cfg.exportPathTB?.path, outTB.path, "profile out-tb supports literal strings")
        try t.expectEqual(cfg.bearCLIPath.path, bearCLI.path, "profile bearcli path keeps quoted # characters")
        try t.expectEqual(cfg.bearSource, "sqlite", "profile source is parsed")
        try t.expectEqual(cfg.exportFormat, "both", "profile format is parsed")
        try t.expect(cfg.makeTagFolders, "profile tag folder flag is parsed")
        try t.expectEqual(cfg.onlyExportTags, ["work/project", "ideas, maybe"], "profile arrays keep comma inside quoted strings")
        try t.expectEqual(cfg.excludeTags, ["archive # literal"], "profile arrays keep # inside quoted strings")
        try t.expectEqual(cfg.backupInterval, 15, "profile numeric values allow inline comments")
    }

    private static func testMarkdownNormalization(_ t: inout ContractRunner) throws {
        try t.expectEqual(cleanTitle("path/to:file\\name"), "path-to-file-name", "cleanTitle sanitizes path separators")
        try t.expectEqual(cleanTitle(""), "Untitled", "cleanTitle falls back to Untitled")
        try t.expectEqual(cleanTitle("../escape"), "-escape", "cleanTitle contains relative traversal")
        try t.expect(cleanTitle(String(repeating: "a", count: 300)).utf8.count <= 240, "cleanTitle caps UTF-8 length")
        try t.expectEqual(bearHighlightToMd("text ::highlighted:: text"), "text ==highlighted== text", "Bear highlights convert to Markdown")

        let tags = extractTags("Hello #world #nested/tag #multi word tag#")
        try t.expect(tags.contains("world"), "extractTags finds simple tags")
        try t.expect(tags.contains("nested/tag"), "extractTags finds nested tags")
        try t.expect(tags.contains("multi word tag"), "extractTags finds multi-word tags")

        try t.expectEqual(htmlImgToMarkdown(#"<img src="photo.jpg" alt="My Photo">"#), "![My Photo](photo.jpg)", "HTML images convert")
        try t.expectEqual(normalizeLocalImageRef("file:///path/to/photo%20name.jpg"), "/path/to/photo name.jpg", "file URLs normalize")
        try t.expectEqual(firstHeading("# My Title\nSome text"), "My Title", "first heading strips Markdown marker")
    }

    private static func testFrontMatterPrivacy(_ t: inout ContractRunner) throws {
        let note = BearNote(title: "My Note", text: "", creationDate: 0, modifiedDate: 0, uuid: "ABCDEFGH-1234", pk: 1)
        let frontMatter = generateFrontMatter(
            note: note,
            text: "Hello #world",
            extraFields: [
                ("bear_id", "SHOULD-NOT-LEAK"),
                ("bear_hash", "SHOULD-NOT-LEAK"),
                ("b2ou_source", "SHOULD-NOT-LEAK"),
                ("safe_field", "visible"),
            ]
        )

        try t.expect(!frontMatter.contains("bear_id:"), "front matter does not expose Bear IDs")
        try t.expect(!frontMatter.contains("bear_hash:"), "front matter does not expose Bear hashes")
        try t.expect(!frontMatter.contains("b2ou_source:"), "front matter does not expose B2OU source metadata")
        try t.expect(frontMatter.contains("safe_field: visible"), "front matter keeps allowed custom fields")
    }

    private static func testManifestRoundTrip(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-manifest")
        defer { try? FileManager.default.removeItem(at: root) }

        writeManifest(exportPath: root, paths: [
            root.appendingPathComponent("note1.md"),
            root.appendingPathComponent("sub/note2.md"),
        ])
        try t.expectEqual(readManifest(exportPath: root), ["note1.md", "sub/note2.md"], "manifest writes relative paths")

        writeManifest(exportPath: root, paths: [root.appendingPathComponent("note3.md")])
        try t.expectEqual(readManifest(exportPath: root), ["note3.md"], "manifest replacement drops stale entries")

        writeManifest(exportPath: root, paths: [])
        try t.expect(readManifest(exportPath: root).isEmpty, "manifest can be emptied")
    }

    private static func testCleanupBoundary(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }

        let exportRoot = root.appendingPathComponent("export")
        let keep = exportRoot.appendingPathComponent("tags/Keep.md")
        let stale = exportRoot.appendingPathComponent("tags/Stale.md")
        let manual = exportRoot.appendingPathComponent("tags/Manual.md")

        for file in [keep, stale, manual] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.lastPathComponent.write(to: file, atomically: true, encoding: .utf8)
        }
        writeManifest(exportPath: exportRoot, paths: [keep, stale])

        let removed = cleanupStaleNotes(exportPath: exportRoot, expectedPaths: [keep], onDelete: "remove")

        try t.expectEqual(removed, 1, "cleanup removes one stale managed file")
        try t.expect(FileManager.default.fileExists(atPath: keep.path), "cleanup keeps expected managed file")
        try t.expect(FileManager.default.fileExists(atPath: manual.path), "cleanup keeps unmanaged user file")
        try t.expect(!FileManager.default.fileExists(atPath: stale.path), "cleanup removes stale managed file")
    }

    private static func testProfileWriterPreservesExistingSettings(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-profile-preserve")
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("b2ou.toml")
        let initial = """
        [profile.main]
        out = "/Original/Markdown"
        format = "both"
        out-tb = "/Original/TextBundle"
        yaml-front-matter = true
        tag-folders = true
        hide-tags = true
        naming = "slug"
        on-delete = "remove"
        exclude-tags = ["private"]
        backup-interval = 60
        backup-max-keep = 8
        """
        try initial.write(to: configURL, atomically: true, encoding: .utf8)

        var update = ProfileConfigUpdate(config: try loadProfile(name: "main", configPath: configURL.path))
        update.exportPath = "/Moved/Markdown"
        try writeProfileConfig(profileName: "main", update: update, configFile: configURL)

        let updated = try loadProfile(name: "main", configPath: configURL.path)
        let content = try String(contentsOf: configURL, encoding: .utf8)

        try t.expectEqual(updated.exportPath.path, "/Moved/Markdown", "folder-only change should update Markdown destination")
        try t.expectEqual(updated.exportFormat, "both", "folder-only change should preserve export format")
        try t.expectEqual(updated.exportPathTB?.path, "/Original/TextBundle", "folder-only change should preserve TextBundle destination")
        try t.expect(updated.yamlFrontMatter, "folder-only change should preserve front matter")
        try t.expect(updated.makeTagFolders, "folder-only change should preserve tag folders")
        try t.expect(updated.hideTags, "folder-only change should preserve hide-tags")
        try t.expectEqual(updated.naming, "slug", "folder-only change should preserve naming")
        try t.expectEqual(updated.onDelete, "remove", "folder-only change should preserve delete policy")
        try t.expectEqual(updated.excludeTags, ["private"], "folder-only change should preserve exclude tags")
        try t.expectEqual(updated.backupInterval, 60, "folder-only change should preserve backup interval")
        try t.expect(content.contains("backup-max-keep = 8"), "folder-only change should preserve unknown profile keys")
    }

    private static func testProfileWriterScopedUpdate(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-profile-update")
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("b2ou.toml")
        let initial = """
        # top comment

        [profile.alpha]
        out = "/Alpha"
        format = "both"
        out-tb = "/AlphaTB"
        custom-alpha = "keep alpha"

        [profile.beta]
        out = "/Beta"
        format = "tb"
        out-tb = "/BetaTB"
        hide-tags = true
        backup-interval = 30
        custom-beta = "keep beta"
        # beta comment
        """
        try initial.write(to: configURL, atomically: true, encoding: .utf8)

        let update = ProfileConfigUpdate(
            exportPath: "/Beta/New",
            exportFormat: "md",
            exportPathTB: nil,
            yamlFrontMatter: false,
            hideTags: false,
            tagFolders: false,
            onDelete: "trash",
            naming: "date-title",
            excludeTags: nil,
            backupInterval: 0,
            backupPath: nil,
            source: "auto",
            bearCLIPath: nil
        )
        try writeProfileConfig(profileName: "beta", update: update, configFile: configURL)

        let alpha = try loadProfile(name: "alpha", configPath: configURL.path)
        let beta = try loadProfile(name: "beta", configPath: configURL.path)
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let betaSection = section(named: "beta", in: content)

        try t.expectEqual(alpha.exportPath.path, "/Alpha", "updating beta should leave alpha destination unchanged")
        try t.expectEqual(alpha.exportFormat, "both", "updating beta should leave alpha format unchanged")
        try t.expectEqual(alpha.exportPathTB?.path, "/AlphaTB", "updating beta should leave alpha TextBundle path unchanged")
        try t.expectEqual(beta.exportPath.path, "/Beta/New", "scoped update should rewrite target profile destination")
        try t.expectEqual(beta.exportFormat, "md", "scoped update should rewrite target profile format")
        try t.expect(beta.exportPathTB == nil, "scoped update should remove out-tb when leaving both/tb formats")
        try t.expectEqual(beta.naming, "date-title", "scoped update should rewrite writable keys")
        try t.expectEqual(beta.onDelete, "trash", "scoped update should keep explicit delete strategy")
        try t.expectEqual(beta.backupInterval, 0, "scoped update should drop writable backup interval when disabled")
        try t.expect(content.contains("custom-alpha = \"keep alpha\""), "scoped update should preserve other profile custom keys")
        try t.expect(content.contains("custom-beta = \"keep beta\""), "scoped update should preserve target profile custom keys")
        try t.expect(content.contains("# beta comment"), "scoped update should preserve target profile comments")
        try t.expect(!betaSection.contains("out-tb ="), "scoped update should remove stale TextBundle output from target profile")
        try t.expect(!betaSection.contains("hide-tags = true"), "scoped update should remove disabled writable keys from target profile")
    }

    private static func testSidecarMerge(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }

        let alpha = root.appendingPathComponent("Alpha.md")
        let beta = root.appendingPathComponent("Beta.md")
        let alphaRenamed = root.appendingPathComponent("Alpha Renamed.md")
        try "alpha".write(to: alpha, atomically: true, encoding: .utf8)
        try "beta".write(to: beta, atomically: true, encoding: .utf8)
        try "alpha renamed".write(to: alphaRenamed, atomically: true, encoding: .utf8)

        let alphaOld = makeExportSyncBinding(
            exportPath: root,
            target: alpha,
            bearID: "AAAA0000-0000-0000-0000-000000000000",
            bearHash: "old",
            bearModified: "2026-01-01T00:00:00Z",
            bearTitle: "Alpha"
        )
        let betaBinding = makeExportSyncBinding(
            exportPath: root,
            target: beta,
            bearID: "BBBB0000-0000-0000-0000-000000000000",
            bearHash: "hb",
            bearModified: "2026-01-01T00:00:00Z",
            bearTitle: "Beta"
        )
        let alphaNew = makeExportSyncBinding(
            exportPath: root,
            target: alphaRenamed,
            bearID: "AAAA0000-0000-0000-0000-000000000000",
            bearHash: "new",
            bearModified: "2026-01-02T00:00:00Z",
            bearTitle: "Alpha Renamed"
        )

        writeExportSyncState(exportPath: root, bindings: [alphaOld, betaBinding])
        writeExportSyncState(exportPath: root, bindings: [alphaNew], merge: true)

        let mergedPaths = Set(readSyncState(exportPath: root)?.bindings.map(\.obsidianPath) ?? [])
        try t.expect(mergedPaths.contains("Beta.md"), "sidecar merge keeps unrelated bindings")
        try t.expect(mergedPaths.contains("Alpha Renamed.md"), "sidecar merge adds selected update")
        try t.expect(!mergedPaths.contains("Alpha.md"), "sidecar merge removes old path for updated Bear note")
    }

    private static func testDirtyFileGuard(_ t: inout ContractRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-dirty")
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("bear.sqlite")
        let sourceUnix = 1_700_000_000.0
        try createBearDatabase(
            at: dbURL,
            notes: [
                FixtureNote(
                    title: "Dirty",
                    text: "Original content",
                    uuid: "DIRTY-0000-0000-0000-000000000000",
                    modifiedUnix: sourceUnix
                )
            ]
        )

        let exportRoot = root.appendingPathComponent("export")
        let config = ExportConfig(exportPath: exportRoot, bearDB: dbURL, bearSource: "sqlite")

        let first = exportNotes(config: config)
        try t.expectEqual(first.noteCount, 1, "first export counts Bear note")
        try t.expectEqual(first.changedCount, 1, "first export writes Bear note")
        try t.expect(!first.hasConflicts, "first export has no conflicts")

        let second = exportNotes(config: config)
        try t.expectEqual(second.changedCount, 0, "unchanged export skips by fingerprint")
        try t.expect(!second.hasConflicts, "unchanged export is not a conflict")

        let dirtyFile = exportRoot.appendingPathComponent("Dirty.md")
        try "Edited outside B2OU".write(to: dirtyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: sourceUnix + 60)],
            ofItemAtPath: dirtyFile.path
        )

        let conflict = exportNotes(config: config)
        try t.expect(conflict.hasConflicts, "newer external edits become conflicts")
        try t.expect(conflict.conflictPaths.contains(dirtyFile), "dirty-file conflict reports edited path")
    }

    private static func section(named profileName: String, in content: String) -> String {
        let header = "[profile.\(profileName)]"
        let lines = content.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            return ""
        }
        var end = start + 1
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("[[") {
                break
            }
            end += 1
        }
        return lines[start..<end].joined(separator: "\n")
    }
}

try B2OUCoreContractTests.run()
