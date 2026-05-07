import Foundation
import B2OUCore
#if canImport(SQLite3)
import SQLite3
#endif

enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
enum B2OUCoreSmokeTests {
    static func main() throws {
        var checks = 0

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            checks += 1
            if !condition() {
                throw SmokeFailure.failed(message)
            }
        }

        try expect(cleanTitle("path/to:file\\name") == "path-to-file-name", "cleanTitle sanitizes path separators")
        try expect(cleanTitle("") == "Untitled", "cleanTitle falls back to Untitled")
        try expect(cleanTitle(String(repeating: "a", count: 300)).utf8.count <= 240, "cleanTitle caps UTF-8 length")
        try expect(bearHighlightToMd("text ::highlighted:: text") == "text ==highlighted== text", "Bear highlights convert to Markdown")

        let tags = extractTags("Hello #world #nested/tag #multi word tag#")
        try expect(tags.contains("world"), "extractTags finds simple tags")
        try expect(tags.contains("nested/tag"), "extractTags finds nested tags")
        try expect(tags.contains("multi word tag"), "extractTags finds multi-word tags")

        try expect(htmlImgToMarkdown(#"<img src="photo.jpg" alt="My Photo">"#) == "![My Photo](photo.jpg)", "HTML images convert to Markdown")
        try expect(normalizeLocalImageRef("file:///path/to/photo%20name.jpg") == "/path/to/photo name.jpg", "file URLs normalize")
        try expect(firstHeading("# My Title\nSome text") == "My Title", "firstHeading strips Markdown heading markers")

        try expect(yamlEscape("hello") == "hello", "yamlEscape keeps simple text")
        try expect(yamlEscape("").hasPrefix("\""), "yamlEscape quotes empty strings")
        try expect(yamlEscape("title: with colon").hasSuffix("\""), "yamlEscape quotes YAML punctuation")

        let note = BearNote(title: "My Note Title!", text: "", creationDate: 0,
                            modifiedDate: 0, uuid: "ABCDEFGH-1234", pk: 1)
        try expect(generateFilename(note: note, naming: "title") == "My Note Title!", "title naming keeps clean title")
        try expect(generateFilename(note: note, naming: "slug") == "my-note-title", "slug naming trims trailing separators")
        try expect(generateFilename(note: note, naming: "id") == "ABCDEFGH", "id naming uses UUID prefix")
        let frontMatter = generateFrontMatter(
            note: note,
            text: "Hello #world",
            extraFields: [
                ("bear_id", "SHOULD-NOT-LEAK"),
                ("bear_hash", "SHOULD-NOT-LEAK"),
                ("b2ou_source", "SHOULD-NOT-LEAK"),
            ]
        )
        try expect(!frontMatter.contains("bear_id:"), "front matter does not expose Bear IDs")
        try expect(!frontMatter.contains("bear_hash:"), "front matter does not expose Bear hashes")

        let split = try ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/b2ou-md"),
            exportPathTB: URL(fileURLWithPath: "/tmp/b2ou-tb"),
            exportFormat: "both"
        ).splitExportConfigs()
        try expect(split.map(\.exportFormat) == ["md", "tb"], "both format splits into md and tb configs")
        try expect(split[1].assetsPath == nil, "TextBundle split disables shared image repository")

        do {
            _ = try ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/b2ou-md"), exportFormat: "both").splitExportConfigs()
            throw SmokeFailure.failed("missing TextBundle path should throw")
        } catch B2OUError.missingTextBundleFolder {
            checks += 1
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("b2ou-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths: Set<URL> = [
            tmp.appendingPathComponent("note1.md"),
            tmp.appendingPathComponent("sub/note2.md"),
        ]
        writeManifest(exportPath: tmp, paths: paths)
        let manifest = readManifest(exportPath: tmp)
        try expect(manifest.contains("note1.md"), "manifest includes root note")
        try expect(manifest.contains("sub/note2.md"), "manifest includes nested note")

        writeManifest(exportPath: tmp, paths: [tmp.appendingPathComponent("note3.md")])
        let replacedManifest = readManifest(exportPath: tmp)
        try expect(replacedManifest == ["note3.md"], "manifest replacement drops stale entries")

        writeManifest(exportPath: tmp, paths: [])
        try expect(readManifest(exportPath: tmp).isEmpty, "manifest can be emptied after delete-only exports")

        let cleanupRoot = tmp.appendingPathComponent("cleanup")
        try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
        let keepNote = cleanupRoot.appendingPathComponent("Keep.md")
        let staleNote = cleanupRoot.appendingPathComponent("Stale.md")
        try "keep".write(to: keepNote, atomically: true, encoding: .utf8)
        try "stale".write(to: staleNote, atomically: true, encoding: .utf8)
        writeManifest(exportPath: cleanupRoot, paths: [keepNote, staleNote])
        let cleanupRemoved = cleanupStaleNotes(exportPath: cleanupRoot, expectedPaths: [keepNote], onDelete: "remove")
        try expect(
            cleanupRemoved == 1,
            "cleanup removes stale managed files even when no note content changed (got \(cleanupRemoved), manifest \(readManifest(exportPath: cleanupRoot)))"
        )
        try expect(!FileManager.default.fileExists(atPath: staleNote.path), "stale managed file is gone after cleanup")

        try expect(exportSkipDirs.contains(".b2ou-backups"), "backup folder is skipped during export cleanup")
        try expect(exportSkipDirs.contains(syncStateDirectoryName), "sidecar folder is skipped during export cleanup")

        let fakeBearCLI = tmp.appendingPathComponent("fake-bearcli")
        let fakeBearCLIScript = """
        #!/bin/sh
        cat <<'JSON'
        [
          {"id":"UNLOCKED","title":"Unlocked","locked":"false","hash":"h1","modified":"2026-01-01T00:00:00Z"},
          {"id":"LOCKED","title":"Locked","locked":"true","hash":"h2","modified":"2026-01-01T00:00:00Z"},
          {"id":"ZERO","title":"Zero","locked":0,"hash":"h3","modified":"2026-01-01T00:00:00Z"}
        ]
        JSON
        """
        try fakeBearCLIScript.write(to: fakeBearCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBearCLI.path)
        let fakeMetadata = try BearCLIClient(executable: fakeBearCLI).listNoteMetadata()
        try expect(fakeMetadata.map(\.id) == ["UNLOCKED", "ZERO"], "Bear CLI metadata accepts flexible locked values")

        let stateExport = tmp.appendingPathComponent("state-export")
        try FileManager.default.createDirectory(at: stateExport, withIntermediateDirectories: true)
        let stateFiles = [
            "Alpha.md": "alpha",
            "Beta.md": "beta",
            "Same.md": "same fallback",
            "Same - ABCD1234.md": "same explicit",
            "Outside.md": "outside",
        ]
        for (name, content) in stateFiles {
            try content.write(to: stateExport.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        writeManifest(exportPath: stateExport, paths: [
            stateExport.appendingPathComponent("Alpha.md"),
            stateExport.appendingPathComponent("Beta.md"),
            stateExport.appendingPathComponent("Same.md"),
            stateExport.appendingPathComponent("Same - ABCD1234.md"),
        ])
        let stateNotes = [
            BearCLINoteMetadata(id: "AAAA0000-0000-0000-0000-000000000000", title: "Alpha", hash: "ha", modified: "2026-01-01T00:00:00Z"),
            BearCLINoteMetadata(id: "BBBB0000-0000-0000-0000-000000000000", title: "Beta", hash: "hb", modified: "2026-01-01T00:00:00Z"),
            BearCLINoteMetadata(id: "ABCD1234-0000-0000-0000-000000000000", title: "Same", hash: "hc", modified: "2026-01-01T00:00:00Z"),
            BearCLINoteMetadata(id: "EEEE9999-0000-0000-0000-000000000000", title: "Same", hash: "hd", modified: "2026-01-01T00:00:00Z"),
        ]
        let preview = rebuildSyncStatePlan(exportPath: stateExport, bearNotes: stateNotes, write: false)
        try expect(preview.plannedBindings == 4, "state rebuild previews every managed binding")
        try expect(preview.unmanagedExportFiles == 1, "state rebuild leaves unmanaged files outside sync")
        try expect(preview.unboundBearNotes == 0, "state rebuild binds every Bear note in fixture")
        try expect(preview.bindingMethods["unique_clean_title"] == 2, "state rebuild handles unique titles")
        try expect(preview.bindingMethods["uuid_suffix"] == 1, "state rebuild handles UUID suffixes")
        try expect(preview.bindingMethods["duplicate_remainder"] == 1, "state rebuild handles duplicate remainders")
        try expect(!FileManager.default.fileExists(atPath: syncStateURL(exportPath: stateExport).path), "state preview does not write sidecar")

        let written = rebuildSyncStatePlan(exportPath: stateExport, bearNotes: stateNotes, write: true)
        try expect(written.plannedBindings == 4, "state rebuild writes planned bindings")
        try expect(readSyncState(exportPath: stateExport)?.bindings.count == 4, "sidecar state round-trips")

        let alphaOld = makeExportSyncBinding(
            exportPath: stateExport,
            target: stateExport.appendingPathComponent("Alpha.md"),
            bearID: "AAAA0000-0000-0000-0000-000000000000",
            bearHash: "old",
            bearModified: "2026-01-01T00:00:00Z",
            bearTitle: "Alpha"
        )
        let betaBinding = makeExportSyncBinding(
            exportPath: stateExport,
            target: stateExport.appendingPathComponent("Beta.md"),
            bearID: "BBBB0000-0000-0000-0000-000000000000",
            bearHash: "hb",
            bearModified: "2026-01-01T00:00:00Z",
            bearTitle: "Beta"
        )
        let alphaRenamed = stateExport.appendingPathComponent("Alpha Renamed.md")
        try "alpha renamed".write(to: alphaRenamed, atomically: true, encoding: .utf8)
        let alphaNew = makeExportSyncBinding(
            exportPath: stateExport,
            target: alphaRenamed,
            bearID: "AAAA0000-0000-0000-0000-000000000000",
            bearHash: "new",
            bearModified: "2026-01-02T00:00:00Z",
            bearTitle: "Alpha Renamed"
        )
        writeExportSyncState(exportPath: stateExport, bindings: [alphaOld, betaBinding])
        writeExportSyncState(exportPath: stateExport, bindings: [alphaNew], merge: true)
        let mergedPaths = Set(readSyncState(exportPath: stateExport)?.bindings.map(\.obsidianPath) ?? [])
        try expect(mergedPaths.contains("Beta.md"), "sidecar merge keeps unrelated bindings")
        try expect(mergedPaths.contains("Alpha Renamed.md"), "sidecar merge adds updated selected binding")
        try expect(!mergedPaths.contains("Alpha.md"), "sidecar merge removes old path for updated Bear note")

        let dbPath = tmp.appendingPathComponent("source.sqlite")
        try createSQLiteDatabase(at: dbPath)
        let cfg = ExportConfig(exportPath: tmp.appendingPathComponent("export"), bearDB: dbPath)
        try FileManager.default.createDirectory(at: cfg.exportPath, withIntermediateDirectories: true)
        try expect(!shouldReadWithBearCLI(config: cfg), "auto source keeps custom databases on SQLite")
        try expect(
            shouldReadWithBearCLI(config: ExportConfig(
                exportPath: cfg.exportPath,
                bearDB: dbPath,
                bearSource: "bearcli"
            )),
            "explicit bearcli source overrides custom database fallback"
        )
        try "timestamp".write(to: cfg.exportTsFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: dbPath.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                                              ofItemAtPath: cfg.exportTsFile.path)
        try expect(checkDBModified(config: cfg) == false, "unchanged database skips export")

        let walPath = URL(fileURLWithPath: dbPath.path + "-wal")
        try "wal".write(to: walPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)],
                                              ofItemAtPath: walPath.path)
        try expect(checkDBModified(config: cfg), "WAL changes are treated as database changes")

        let backupPath = tmp.appendingPathComponent("backup.sqlite")
        let srcConn = try SQLiteConnection(path: dbPath.path, readOnly: true)
        try srcConn.backupTo(backupPath.path)
        let backupConn = try SQLiteConnection(path: backupPath.path, readOnly: true)
        let backedUpValue = backupConn.queryOne("SELECT value FROM smoke LIMIT 1")?["value"] as? String
        try expect(backedUpValue == "ok", "SQLite backup copies readable data")

        let bearDBPath = tmp.appendingPathComponent("bear-source.sqlite")
        let sourceUnix = 1_700_000_000.0
        try createBearDatabase(
            at: bearDBPath,
            notes: [
                TestBearNote(
                    title: "Dirty",
                    text: "Original content",
                    uuid: "DIRTY-0000-0000-0000-000000000000",
                    modifiedUnix: sourceUnix
                )
            ]
        )
        let dirtyExportRoot = tmp.appendingPathComponent("dirty-export")
        let dirtyConfig = ExportConfig(exportPath: dirtyExportRoot, bearDB: bearDBPath)
        let firstDirtyExport = exportNotes(config: dirtyConfig)
        try expect(firstDirtyExport.changedCount == 1, "first export writes Bear note")
        try expect(!firstDirtyExport.hasConflicts, "first export has no dirty-file conflicts")
        let secondDirtyExport = exportNotes(config: dirtyConfig)
        try expect(secondDirtyExport.changedCount == 0, "unchanged exported file is skipped by fingerprint")
        try expect(!secondDirtyExport.hasConflicts, "unchanged exported file is not treated as conflict")

        let dirtyFile = dirtyExportRoot.appendingPathComponent("Dirty.md")
        try "Edited outside B2OU".write(to: dirtyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: sourceUnix + 60)],
            ofItemAtPath: dirtyFile.path
        )
        let conflictExport = exportNotes(config: dirtyConfig)
        try expect(conflictExport.hasConflicts, "newer external edits stop silent incremental skips")
        try expect(conflictExport.conflictPaths.contains(dirtyFile), "dirty-file conflict reports the edited path")

        let excluded = subPathFromTag(
            basePath: tmp.path,
            filename: "note.md",
            text: "Hello #private",
            makeTagFolders: false,
            multiTagFolders: true,
            onlyExportTags: [],
            excludeTags: ["private"]
        )
        try expect(excluded.isEmpty, "exclude tags apply without tag folders")

        print("B2OUCoreSmokeTests passed \(checks) checks")
    }

    private struct TestBearNote {
        let title: String
        let text: String
        let uuid: String
        let modifiedUnix: Double
    }

    private static func createSQLiteDatabase(at url: URL) throws {
#if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            throw SmokeFailure.failed("could not create smoke SQLite database")
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE smoke(value TEXT);
        INSERT INTO smoke(value) VALUES ('ok');
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            throw SmokeFailure.failed(message)
        }
#else
        throw SmokeFailure.failed("SQLite3 unavailable")
#endif
    }

    private static func createBearDatabase(at url: URL, notes: [TestBearNote]) throws {
#if canImport(SQLite3)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            throw SmokeFailure.failed("could not create Bear fixture database")
        }
        defer { sqlite3_close(db) }

        var sql = """
        CREATE TABLE ZSFNOTE(
          ZTITLE TEXT,
          ZTEXT TEXT,
          ZCREATIONDATE REAL,
          ZMODIFICATIONDATE REAL,
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
        """
        for (index, note) in notes.enumerated() {
            let pk = index + 1
            let modified = note.modifiedUnix - coreDataEpoch
            let created = modified - 60
            sql += """
            INSERT INTO ZSFNOTE(
              ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE,
              ZUNIQUEIDENTIFIER, Z_PK, ZTRASHED, ZARCHIVED
            ) VALUES (
              '\(sqlQuote(note.title))',
              '\(sqlQuote(note.text))',
              \(created),
              \(modified),
              '\(sqlQuote(note.uuid))',
              \(pk),
              0,
              0
            );
            """
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errorMessage)
            throw SmokeFailure.failed(message)
        }
#else
        throw SmokeFailure.failed("SQLite3 unavailable")
#endif
    }

    private static func sqlQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
