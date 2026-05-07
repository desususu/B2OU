import B2OUCore
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

enum RegressionFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

struct TestRunner {
    var checks = 0
    var tests = 0

    mutating func run(_ name: String, _ body: (inout TestRunner) throws -> Void) throws {
        tests += 1
        do {
            try body(&self)
        } catch {
            throw RegressionFailure.failed("\(name): \(error)")
        }
    }

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() {
            throw RegressionFailure.failed(message)
        }
    }

    mutating func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
        checks += 1
        if lhs != rhs {
            throw RegressionFailure.failed("\(message) (got \(lhs), expected \(rhs))")
        }
    }

    mutating func expectClose(_ lhs: Double, _ rhs: Double, accuracy: Double, _ message: String) throws {
        checks += 1
        if abs(lhs - rhs) > accuracy {
            throw RegressionFailure.failed("\(message) (got \(lhs), expected \(rhs))")
        }
    }
}

@main
enum B2OUCoreRegressionTests {
    static func main() throws {
        var runner = TestRunner()

        try runner.run("SQLite readers exclude inactive notes", testSQLiteReadersExcludeInactiveNotes)
        try runner.run("Markdown filename and tag hiding edge cases", testMarkdownFilenameAndTagHiding)
        try runner.run("Profile parser handles inline comments", testProfileParser)
        try runner.run("TextBundle keeps missing attachments intact", testTextBundleMissingAttachments)
        try runner.run("Export handles tags assets duplicates and dirty state", testExportStateAndAssets)
        try runner.run("Cleanup removes managed stale files only", testCleanupManagedStaleFiles)
        try runner.run("Export refuses unsafe existing targets and broken schemas", testExportSafetyBoundaries)
        try runner.run("Bear CLI attachment failures keep original references", testBearCLIAttachmentFailuresKeepReferences)
        try runner.run("Clean uses manifest and ignores unsafe entries", testCleanUsesManifest)
        try runner.run("Path sanitization contains names and tag folders", testPathSanitizationBoundaries)
        try runner.run("Watch signatures include WAL quiet windows", testWatchSourceSignature)

        print("B2OUCoreRegressionTests passed \(runner.checks) checks across \(runner.tests) tests")
    }

    private static func testSQLiteReadersExcludeInactiveNotes(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("bear.sqlite")
        let activeModified = 1_700_000_000.0
        try createBearDatabase(
            at: dbURL,
            notes: [
                FixtureNote(
                    title: "Active",
                    text: "Body",
                    uuid: "ACTIVE",
                    modifiedUnix: activeModified,
                    attachments: [("active.png", "IMG-A")]
                ),
                FixtureNote(title: "Trashed", text: "Body", uuid: "TRASHED", modifiedUnix: activeModified + 1, trashed: 1),
                FixtureNote(
                    title: "Archived",
                    text: "Body",
                    uuid: "ARCHIVED",
                    modifiedUnix: activeModified + 2,
                    archived: 1,
                    attachments: [("archived.png", "IMG-Z")]
                ),
                FixtureNote(title: "Encrypted", text: "Body", uuid: "ENCRYPTED", modifiedUnix: activeModified + 3, encrypted: 1),
            ]
        )

        let conn = try SQLiteConnection(path: dbURL.path, readOnly: true)

        try t.expectEqual(Set(iterNotes(conn: conn).map(\.uuid)), Set(["ACTIVE"]), "iterNotes exports only active notes")
        try t.expectEqual(getNoteByUUID(conn: conn, uuid: "ACTIVE")?.title, "Active", "active UUID lookup works")
        try t.expect(getNoteByUUID(conn: conn, uuid: "TRASHED") == nil, "trashed notes are hidden from UUID lookup")
        try t.expect(getNoteByUUID(conn: conn, uuid: "ARCHIVED") == nil, "archived notes are hidden from UUID lookup")
        try t.expect(getNoteByUUID(conn: conn, uuid: "ENCRYPTED") == nil, "encrypted notes are hidden from UUID lookup")
        try t.expect(getNoteByTitle(conn: conn, title: "Encrypted") == nil, "encrypted notes are hidden from title lookup")
        try t.expect(getNoteModification(conn: conn, uuid: "ARCHIVED") == nil, "archived notes are hidden from modification lookup")
        try t.expectEqual(getNoteFilesByUUID(conn: conn, noteUUID: "ACTIVE").map(\.filename), ["active.png"], "active attachments are readable")
        try t.expect(getNoteFilesByUUID(conn: conn, noteUUID: "ARCHIVED").isEmpty, "archived attachments are not returned")

        let signature = bearDBSignature(dbPath: dbURL)
        try t.expectEqual(signature.noteCount, 1, "Bear DB signature counts only active notes")
        try t.expectClose(signature.maxMod, activeModified, accuracy: 0.001, "Bear DB signature uses active max modification")
    }

    private static func testMarkdownFilenameAndTagHiding(_ t: inout TestRunner) throws {
        try t.expectEqual(cleanTitle("Report::"), "Report", "cleanTitle removes repeated trailing separators")
        try t.expectEqual(cleanTitle("::"), "Untitled", "cleanTitle falls back when sanitization empties the title")

        let hidden = hideTags(
            """
            #work
            Body
              #nested/tag
            # Heading
            ## Heading
            #multi word tag#
            """
        )

        try t.expect(!hidden.contains("#work"), "hideTags removes tag line at start of text")
        try t.expect(!hidden.contains("#nested/tag"), "hideTags removes indented tag lines")
        try t.expect(!hidden.contains("#multi word tag#"), "hideTags removes multi-word tag lines")
        try t.expect(hidden.contains("# Heading"), "hideTags preserves level-one Markdown headings")
        try t.expect(hidden.contains("## Heading"), "hideTags preserves deeper Markdown headings")
        try t.expect(hidden.contains("Body"), "hideTags preserves body text")
    }

    private static func testProfileParser(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
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

        let config = try loadProfile(name: "obsidian", configPath: configURL.path)
        try t.expectEqual(config.exportPath.path, out.path, "profile out keeps quoted # characters")
        try t.expectEqual(config.exportPathTB?.path, outTB.path, "profile out-tb supports literal strings")
        try t.expectEqual(config.bearSource, "sqlite", "profile source is parsed")
        try t.expectEqual(config.bearCLIPath.path, bearCLI.path, "profile bearcli path keeps quoted # characters")
        try t.expectEqual(config.exportFormat, "both", "profile format is parsed")
        try t.expect(config.makeTagFolders, "profile tag folder flag is parsed")
        try t.expectEqual(config.onlyExportTags, ["work/project", "ideas, maybe"], "profile arrays keep comma inside quoted strings")
        try t.expectEqual(config.excludeTags, ["archive # literal"], "profile arrays keep # inside quoted strings")
        try t.expectEqual(config.backupInterval, 15, "profile numeric values allow inline comments")
    }

    private static func testTextBundleMissingAttachments(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("empty.sqlite")
        try createSQLiteDatabase(at: dbURL)
        let conn = try SQLiteConnection(path: dbURL.path, readOnly: true)
        let assets = root.appendingPathComponent("bundle-assets")
        let bearImages = root.appendingPathComponent("bear-images")
        let bearFiles = root.appendingPathComponent("bear-files")

        let input = """
        before [image:MISSING/photo.png]
        [file:MISSING/doc.pdf]
        ![alt](photo.png)
        [doc](doc.pdf)
        [empty]( )
        """

        let output = processExportImagesTextbundle(
            text: input,
            bundleAssets: assets,
            conn: conn,
            notePK: 1,
            bearImagePath: bearImages,
            bearFilePath: bearFiles,
            fileMap: [
                "photo.png": "MISSING",
                "doc.pdf": "MISSING",
            ]
        )

        try t.expectEqual(output, input, "missing TextBundle attachments keep original references")
        try t.expect(
            !FileManager.default.fileExists(atPath: assets.appendingPathComponent("MISSING_photo.png").path),
            "missing image asset is not materialized"
        )
        try t.expect(
            !FileManager.default.fileExists(atPath: assets.appendingPathComponent("MISSING_doc.pdf").path),
            "missing file asset is not materialized"
        )
    }

    private static func testExportStateAndAssets(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("bear.sqlite")
        let bearImages = root.appendingPathComponent("bear-images")
        let exportRoot = root.appendingPathComponent("export")
        let sourceModified = 1_700_000_000.0

        let imageSource = bearImages.appendingPathComponent("IMG-1/photo.png")
        try FileManager.default.createDirectory(at: imageSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: imageSource)

        try createBearDatabase(
            at: dbURL,
            notes: [
                FixtureNote(
                    title: "Same",
                    text: "Body #work/project\n![Pic](photo.png)",
                    uuid: "AAAAAAAA-0000-0000-0000-000000000000",
                    modifiedUnix: sourceModified,
                    attachments: [("photo.png", "IMG-1")]
                ),
                FixtureNote(
                    title: "Same",
                    text: "Second #work/project",
                    uuid: "BBBBBBBB-0000-0000-0000-000000000000",
                    modifiedUnix: sourceModified + 10
                ),
            ]
        )

        let config = ExportConfig(
            exportPath: exportRoot,
            bearDB: dbURL,
            bearImagePath: bearImages,
            bearSource: "sqlite",
            exportFormat: "md",
            makeTagFolders: true,
            yamlFrontMatter: true
        )

        let first = exportNotes(config: config)
        try t.expectEqual(first.noteCount, 2, "export counts source notes once")
        try t.expectEqual(first.changedCount, 4, "export writes root and tag-folder copies")
        try t.expect(!first.hasConflicts, "first export has no conflicts")

        let rootFirst = exportRoot.appendingPathComponent("Same.md")
        let rootSecond = exportRoot.appendingPathComponent("Same - BBBBBBBB.md")
        let tagFirst = exportRoot.appendingPathComponent("work/project/Same.md")
        let tagSecond = exportRoot.appendingPathComponent("work/project/Same - BBBBBBBB.md")

        for path in [rootFirst, rootSecond, tagFirst, tagSecond] {
            try t.expect(FileManager.default.fileExists(atPath: path.path), "expected export at \(path.path)")
        }

        let markdown = try String(contentsOf: rootFirst, encoding: .utf8)
        try t.expect(markdown.contains("BearImages/IMG-1/photo.png"), "Markdown export rewrites local image to asset repository")
        try t.expect(!markdown.contains("bear_id:"), "front matter does not leak Bear IDs")
        try t.expect(
            FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("BearImages/IMG-1/photo.png").path),
            "image asset is copied to export repository"
        )
        try t.expectEqual(readSyncState(exportPath: exportRoot)?.bindings.count, 4, "sync state records every exported path")

        let second = exportNotes(config: config)
        try t.expectEqual(second.changedCount, 0, "unchanged files skip through fingerprint state")
        try t.expect(!second.hasConflicts, "unchanged files are not conflicts")

        try "Edited outside B2OU".write(to: rootFirst, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: sourceModified + 120)],
            ofItemAtPath: rootFirst.path
        )

        let conflict = exportNotes(config: config)
        try t.expect(conflict.hasConflicts, "newer external edits become sync conflicts")
        try t.expect(conflict.conflictPaths.contains(rootFirst), "conflict result reports edited path")
    }

    private static func testCleanupManagedStaleFiles(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let exportRoot = root.appendingPathComponent("export")
        let keep = exportRoot.appendingPathComponent("tags/Keep.md")
        let stale = exportRoot.appendingPathComponent("tags/Stale.md")
        let manual = exportRoot.appendingPathComponent("tags/Manual.md")
        let bundle = exportRoot.appendingPathComponent("old/Bundle.textbundle")
        let bundleText = bundle.appendingPathComponent("text.md")
        let onlyStale = exportRoot.appendingPathComponent("empty-tag/OnlyStale.md")

        for file in [keep, stale, manual, bundleText, onlyStale] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.lastPathComponent.write(to: file, atomically: true, encoding: .utf8)
        }
        writeManifest(exportPath: exportRoot, paths: [keep, stale, bundle, onlyStale])

        let removed = cleanupStaleNotes(exportPath: exportRoot, expectedPaths: [keep], onDelete: "remove")

        try t.expectEqual(removed, 3, "cleanup removes stale managed Markdown, TextBundle, and empty-tag file")
        try t.expect(FileManager.default.fileExists(atPath: keep.path), "cleanup keeps expected managed note")
        try t.expect(FileManager.default.fileExists(atPath: manual.path), "cleanup keeps unmanaged user file")
        try t.expect(!FileManager.default.fileExists(atPath: stale.path), "cleanup removes stale managed Markdown")
        try t.expect(!FileManager.default.fileExists(atPath: bundle.path), "cleanup removes stale managed TextBundle")
        try t.expect(
            !FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent("empty-tag").path),
            "cleanup prunes empty tag directories"
        )
    }

    private static func testWatchSourceSignature(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("watch.sqlite")
        try createBearDatabase(
            at: dbURL,
            notes: [
                FixtureNote(title: "Watch", text: "Body", uuid: "WATCH", modifiedUnix: 1_700_000_000.0),
            ]
        )

        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        try "wal".write(to: wal, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: dbURL.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: wal.path)

        let config = ExportConfig(exportPath: root.appendingPathComponent("out"), bearDB: dbURL, bearSource: "sqlite")
        let signature = sourceSignature(config: config)
        try t.expectClose(signature.lastModified, 2_000, accuracy: 0.001, "watch signature includes WAL mtime")
        try t.expect(signature.byteCount >= 3, "watch signature includes WAL bytes")

        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: wal.path)
        try t.expect(!sourceIsQuiet(config: config, quietSeconds: 60), "watch quiet check notices recent WAL writes")

        let old = Date(timeIntervalSinceNow: -120)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dbURL.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: wal.path)
        try t.expect(sourceIsQuiet(config: config, quietSeconds: 60), "watch quiet check passes after source settles")
    }

    private static func testExportSafetyBoundaries(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("bear.sqlite")
        let exportRoot = root.appendingPathComponent("export")
        let sourceModified = 1_700_000_000.0
        try createBearDatabase(
            at: dbURL,
            notes: [
                FixtureNote(
                    title: "Manual",
                    text: "Bear content",
                    uuid: "MANUAL-0000-0000-0000-000000000000",
                    modifiedUnix: sourceModified
                ),
            ]
        )

        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let manualFile = exportRoot.appendingPathComponent("Manual.md")
        try "User content".write(to: manualFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: sourceModified - 3_600)],
            ofItemAtPath: manualFile.path
        )

        let config = ExportConfig(exportPath: exportRoot, bearDB: dbURL, bearSource: "sqlite")
        let conflict = exportNotes(config: config)
        try t.expect(conflict.hasConflicts, "pre-existing unmanaged target is reported as a conflict")
        try t.expectEqual(
            try String(contentsOf: manualFile, encoding: .utf8),
            "User content",
            "pre-existing unmanaged file is not overwritten even when older than Bear"
        )

        let first = exportNotes(config: ExportConfig(exportPath: root.appendingPathComponent("managed"), bearDB: dbURL, bearSource: "sqlite"))
        try t.expectEqual(first.changedCount, 1, "managed fixture exports once")
        let managedFile = root.appendingPathComponent("managed/Manual.md")
        try "Local edit with old mtime".write(to: managedFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: sourceModified - 7_200)],
            ofItemAtPath: managedFile.path
        )
        let rollbackConflict = exportNotes(config: ExportConfig(exportPath: root.appendingPathComponent("managed"), bearDB: dbURL, bearSource: "sqlite"))
        try t.expect(rollbackConflict.hasConflicts, "hash guard catches local edits even when mtime moves backward")
        try t.expectEqual(
            try String(contentsOf: managedFile, encoding: .utf8),
            "Local edit with old mtime",
            "mtime rollback conflict does not overwrite local edits"
        )

        let brokenDB = root.appendingPathComponent("broken-schema.sqlite")
        try createBrokenBearDatabase(at: brokenDB)
        let brokenExport = exportNotes(config: ExportConfig(exportPath: root.appendingPathComponent("broken-out"), bearDB: brokenDB, bearSource: "sqlite"))
        try t.expectEqual(brokenExport.changedCount, -1, "schema drift fails the export instead of treating it as zero notes")
        try t.expectEqual(brokenExport.noteCount, 0, "schema drift does not report a successful empty export")
        try t.expect(
            brokenExport.errorMessage?.contains("schema") == true,
            "schema drift carries a clear error message"
        )

        let missingBearCLI = exportNotes(config: ExportConfig(
            exportPath: root.appendingPathComponent("bearcli-out"),
            bearCLIPath: root.appendingPathComponent("missing-bearcli"),
            bearSource: "bearcli"
        ))
        try t.expectEqual(missingBearCLI.changedCount, -1, "explicit missing Bear CLI fails instead of falling through silently")
        try t.expect(
            missingBearCLI.errorMessage?.contains("Bear CLI is not available") == true,
            "explicit missing Bear CLI reports the real failure"
        )
    }

    private static func testBearCLIAttachmentFailuresKeepReferences(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeBearCLI = root.appendingPathComponent("fake-bearcli")
        let script = """
        #!/bin/sh
        echo "attachment save failed" >&2
        exit 42
        """
        try script.write(to: fakeBearCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBearCLI.path)

        let markdown = """
        ![pic](photo.png)
        [doc](doc.pdf)
        """
        let client = BearCLIClient(executable: fakeBearCLI)
        let processed = processExportImagesUsingBearCLI(
            text: markdown,
            filepath: root.appendingPathComponent("Note"),
            noteID: "NOTE-1",
            attachments: [
                BearCLIAttachment(filename: "photo.png", size: 3),
                BearCLIAttachment(filename: "doc.pdf", size: 3),
            ],
            bearCLI: client,
            assetsPath: root.appendingPathComponent("BearImages"),
            exportPath: root
        )
        try t.expectEqual(processed, markdown, "failed Bear CLI saves leave Markdown references untouched")
        try t.expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("BearImages/NOTE-1/photo.png").path),
            "failed Bear CLI image save does not create a broken asset"
        )

        let tbProcessed = processExportImagesTextbundleUsingBearCLI(
            text: markdown,
            bundleAssets: root.appendingPathComponent("bundle/assets"),
            noteID: "NOTE-1",
            attachments: [
                BearCLIAttachment(filename: "photo.png", size: 3),
                BearCLIAttachment(filename: "doc.pdf", size: 3),
            ],
            bearCLI: client
        )
        try t.expectEqual(tbProcessed, markdown, "failed Bear CLI TextBundle saves leave references untouched")
    }

    private static func testCleanUsesManifest(_ t: inout TestRunner) throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let exportRoot = root.appendingPathComponent("export")
        let managed = exportRoot.appendingPathComponent("Managed.md")
        let manual = exportRoot.appendingPathComponent("Manual.md")
        let nested = exportRoot.appendingPathComponent("tag/Nested.md")
        let outside = root.appendingPathComponent("Outside.md")
        let image = exportRoot.appendingPathComponent("BearImages/img.png")

        for file in [managed, manual, nested, outside, image] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.lastPathComponent.write(to: file, atomically: true, encoding: .utf8)
        }
        try "timestamp".write(to: exportRoot.appendingPathComponent(".export-time.log"), atomically: true, encoding: .utf8)
        writeManifest(exportPath: exportRoot, paths: [managed, nested])
        try "../Outside.md\n/absolute.md\nManaged.md\n".write(
            to: exportRoot.appendingPathComponent(manifestName),
            atomically: true,
            encoding: .utf8
        )

        let result = cleanManagedExport(exportPath: exportRoot, keepImages: false)
        try t.expectEqual(result.removedFiles, 1, "clean removes only safe manifest-managed entries")
        try t.expect(!FileManager.default.fileExists(atPath: managed.path), "clean removes manifest-managed file")
        try t.expect(FileManager.default.fileExists(atPath: nested.path), "overwritten manifest entry not present is not guessed")
        try t.expect(FileManager.default.fileExists(atPath: manual.path), "clean keeps unmanaged user Markdown")
        try t.expect(FileManager.default.fileExists(atPath: outside.path), "clean ignores path traversal manifest entries")
        try t.expect(!FileManager.default.fileExists(atPath: image.path), "clean removes BearImages when requested")
        try t.expect(!FileManager.default.fileExists(atPath: exportRoot.appendingPathComponent(".export-time.log").path), "clean resets timestamp sentinel")
    }

    private static func testPathSanitizationBoundaries(_ t: inout TestRunner) throws {
        let titleCases: [(String, String)] = [
            ("../escape", "-escape"),
            (".env", "env"),
            ("CON", "CON-note"),
            ("bad*?:\"<>|name\n", "bad-name"),
            ("  .  ", "Untitled"),
        ]
        for (input, expected) in titleCases {
            try t.expectEqual(cleanTitle(input), expected, "cleanTitle safely normalizes \(input.debugDescription)")
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = subPathFromTags(
            basePath: root.path,
            filename: "Note",
            tags: ["../escape", "/absolute/path", ".hidden", "safe/../../final"],
            makeTagFolders: true,
            multiTagFolders: true,
            onlyExportTags: [],
            excludeTags: []
        )

        for path in paths {
            try t.expect(path == root.appendingPathComponent("Note").path || path.hasPrefix(root.path + "/"), "tag path stays inside export root: \(path)")
            let rel = String(path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            try t.expect(!rel.split(separator: "/").contains(".."), "tag path removes traversal components: \(path)")
        }
        try t.expect(paths.contains(root.appendingPathComponent("escape/Note").path), "relative traversal tag is contained")
        try t.expect(paths.contains(root.appendingPathComponent("absolute/path/Note").path), "absolute-looking tag is made relative")
        try t.expect(paths.contains(root.appendingPathComponent("_hidden/Note").path), "hidden tag folders are prefixed")
        try t.expect(paths.contains(root.appendingPathComponent("safe/final/Note").path), "nested traversal components are removed")
    }
}

private struct FixtureNote {
    let title: String
    let text: String
    let uuid: String
    let modifiedUnix: Double
    var trashed: Int = 0
    var archived: Int = 0
    var encrypted: Int = 0
    var attachments: [(filename: String, uuid: String)] = []
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("b2ou-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func createSQLiteDatabase(at url: URL) throws {
#if canImport(SQLite3)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else {
        throw RegressionFailure.failed("could not create SQLite database")
    }
    defer { sqlite3_close(db) }
    try execSQL(
        """
        CREATE TABLE smoke(value TEXT);
        INSERT INTO smoke(value) VALUES ('ok');
        """,
        db: db
    )
#else
    throw RegressionFailure.failed("SQLite3 unavailable")
#endif
}

private func createBrokenBearDatabase(at url: URL) throws {
#if canImport(SQLite3)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else {
        throw RegressionFailure.failed("could not create broken Bear fixture database")
    }
    defer { sqlite3_close(db) }
    try execSQL(
        """
        CREATE TABLE ZSFNOTE(
          ZTITLE TEXT,
          ZUNIQUEIDENTIFIER TEXT,
          Z_PK INTEGER,
          ZTRASHED INTEGER,
          ZARCHIVED INTEGER
        );
        CREATE TABLE ZSFNOTEFILE(
          ZNOTE INTEGER,
          ZFILENAME TEXT,
          ZUNIQUEIDENTIFIER TEXT
        );
        """,
        db: db
    )
#else
    throw RegressionFailure.failed("SQLite3 unavailable")
#endif
}

private func createBearDatabase(at url: URL, notes: [FixtureNote]) throws {
#if canImport(SQLite3)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else {
        throw RegressionFailure.failed("could not create Bear fixture database")
    }
    defer { sqlite3_close(db) }

    try execSQL(
        """
        CREATE TABLE ZSFNOTE(
          ZTITLE TEXT,
          ZTEXT TEXT,
          ZCREATIONDATE REAL,
          ZMODIFICATIONDATE REAL,
          ZUNIQUEIDENTIFIER TEXT,
          Z_PK INTEGER,
          ZTRASHED INTEGER,
          ZARCHIVED INTEGER,
          ZENCRYPTED INTEGER
        );
        CREATE TABLE ZSFNOTEFILE(
          ZNOTE INTEGER,
          ZFILENAME TEXT,
          ZUNIQUEIDENTIFIER TEXT
        );
        """,
        db: db
    )

    for (index, note) in notes.enumerated() {
        let pk = index + 1
        let modified = note.modifiedUnix - coreDataEpoch
        let created = modified - 60
        try execSQL(
            """
            INSERT INTO ZSFNOTE(
              ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE,
              ZUNIQUEIDENTIFIER, Z_PK, ZTRASHED, ZARCHIVED, ZENCRYPTED
            ) VALUES (
              '\(sqlQuote(note.title))',
              '\(sqlQuote(note.text))',
              \(created),
              \(modified),
              '\(sqlQuote(note.uuid))',
              \(pk),
              \(note.trashed),
              \(note.archived),
              \(note.encrypted)
            );
            """,
            db: db
        )

        for attachment in note.attachments {
            try execSQL(
                """
                INSERT INTO ZSFNOTEFILE(ZNOTE, ZFILENAME, ZUNIQUEIDENTIFIER)
                VALUES (\(pk), '\(sqlQuote(attachment.filename))', '\(sqlQuote(attachment.uuid))');
                """,
                db: db
            )
        }
    }
#else
    throw RegressionFailure.failed("SQLite3 unavailable")
#endif
}

#if canImport(SQLite3)
private func execSQL(_ sql: String, db: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
        sqlite3_free(errorMessage)
        throw RegressionFailure.failed(message)
    }
}
#endif

private func sqlQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}
