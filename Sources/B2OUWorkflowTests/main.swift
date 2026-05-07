import Foundation
import B2OUAppSupport
import B2OUCore
#if canImport(SQLite3)
import SQLite3
#endif

enum WorkflowFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

struct WorkflowRunner {
    var checks = 0
    var tests = 0

    mutating func run(_ name: String, _ body: (inout WorkflowRunner) throws -> Void) throws {
        tests += 1
        do {
            try body(&self)
        } catch {
            throw WorkflowFailure.failed("\(name): \(error)")
        }
    }

    mutating func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() {
            throw WorkflowFailure.failed(message)
        }
    }

    mutating func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
        checks += 1
        if lhs != rhs {
            throw WorkflowFailure.failed("\(message) (got \(lhs), expected \(rhs))")
        }
    }
}

@main
enum B2OUWorkflowTests {
    static func main() throws {
        var runner = WorkflowRunner()

        try runner.run("Feature contract IDs are unique", testFeatureContractIDs)
        try runner.run("Primary UI features have backend coverage", testPrimaryUICoverage)
        try runner.run("Dashboard is reachable from the menu panel", testDashboardReachability)
        try runner.run("Workspace routes persistent edits to Preferences", testWorkspaceSettingsHandoff)
        try runner.run("Menu snapshot distinguishes setup from source access", testMenuSnapshotSetupState)
        try runner.run("Menu snapshot surfaces source problems before stale summaries", testMenuSnapshotSourceProblem)
        try runner.run("Menu snapshot trims blank errors and summarizes real ones", testMenuSnapshotErrorPresentation)
        try runner.run("Menu snapshot surfaces backup errors when export is healthy", testMenuSnapshotBackupError)
        try runner.run("Bear source health reports unconfigured state", testUnconfiguredHealth)
        try runner.run("Bear source health reports missing Bear CLI", testMissingBearCLIHealth)
        try runner.run("Bear source health reports missing SQLite source", testMissingSQLiteHealth)
        try runner.run("Runtime issue state keeps export and backup errors separate", testRuntimeIssueState)
        try runner.run("Login item toggle reports failures and state mismatches", testLoginItemToggleOutcome)
        try runner.run("Language changes publish a live refresh signal", testLanguageChangeNotification)
        try runner.run("Note actions follow real export-file availability", testNoteActionAvailability)
        try runner.run("Settings validation blocks export and backup path conflicts", testSettingsValidation)
        try runner.run("External actions record the expected targets", testExternalActionRecording)
        try runner.run("Deep GUI actions stay covered by feature contracts", testDeepActionContracts)
        try runner.run("NoteStore prefers Bear source before export fallback", testNoteStorePrefersBearSource)
        try runner.run("NoteStore reads sidecar mappings from exported notes", testNoteStoreSidecarScan)
        try runner.run("NoteStore fallback behavior is explicit", testNoteStoreFallbackBehavior)
        try runner.run("Backup rotation removes excess backups", testBackupRotation)
        try runner.run("Backup lock prevents concurrent backups", testBackupLocking)
        try runner.run("Interrupted backup cleanup removes stale tmp files", testBackupInterruptedCleanup)
        try runner.run("Backup idempotency: repeated rotation is stable", testBackupRotationIdempotent)
        try runner.run("Backup result reports success and error states", testBackupResultReporting)

        print("B2OUWorkflowTests passed \(runner.checks) checks across \(runner.tests) tests")
    }

    private static func testFeatureContractIDs(_ r: inout WorkflowRunner) throws {
        let ids = b2ouFeatureContracts.map(\.id)
        try r.expectEqual(Set(ids).count, ids.count, "feature contract IDs should be unique")
    }

    private static func testPrimaryUICoverage(_ r: inout WorkflowRunner) throws {
        let missing = primaryUIFeatureContracts().filter { $0.state == .missingBackend }
        try r.expect(missing.isEmpty, "primary UI features should not ship without backend coverage")
    }

    private static func testDashboardReachability(_ r: inout WorkflowRunner) throws {
        let dashboard = primaryUIFeatureContracts().first { $0.id == "menu.dashboard" }
        try r.expectEqual(dashboard?.state, .implemented, "dashboard should be reachable from the primary menu")
    }

    private static func testWorkspaceSettingsHandoff(_ r: inout WorkflowRunner) throws {
        let overlappingPrimaryUI = primaryUIFeatureContracts().filter { $0.state == .overlapsSettings }
        try r.expect(overlappingPrimaryUI.isEmpty, "primary UI should not ship with overlapping settings editors")

        let workspacePreferences = b2ouFeatureContracts.first { $0.id == "workspace.open_preferences" }
        try r.expectEqual(workspacePreferences?.state, .implemented, "workspace should hand off persistent edits to Preferences")

        let applyRules = b2ouFeatureContracts.first { $0.id == "workspace.apply_rules" }
        try r.expect(applyRules == nil, "workspace should no longer persist profile rules directly")
    }

    private static func testMenuSnapshotSetupState(_ r: inout WorkflowRunner) throws {
        let snapshot = buildMenuPanelSnapshot(
            MenuPanelSnapshotInput(
                languageCode: "en",
                config: nil,
                sourceHealth: BearSourceHealth.evaluate(config: nil),
                isPaused: false,
                isExporting: false,
                noteCount: 0,
                lastExportTime: nil,
                lastBackupTime: nil,
                lastExportError: nil,
                lastBackupError: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        try r.expectEqual(snapshot.summaryText, t("menu.no_profile"), "missing profile should show no-profile summary")
        try r.expectEqual(snapshot.statusText, "Setup", "missing profile should show setup status")
        try r.expectEqual(snapshot.statusStyle, .neutral, "missing profile should use neutral status style")
        try r.expect(!snapshot.canExportNow, "missing profile should disable export now")
    }

    private static func testMenuSnapshotSourceProblem(_ r: inout WorkflowRunner) throws {
        let config = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/b2ou-menu-health"),
            bearDB: URL(fileURLWithPath: "/tmp/b2ou-menu-health/missing.sqlite"),
            bearSource: "sqlite"
        )
        let snapshot = buildMenuPanelSnapshot(
            MenuPanelSnapshotInput(
                languageCode: "en",
                config: config,
                sourceHealth: BearSourceHealth.evaluate(config: config),
                isPaused: false,
                isExporting: false,
                noteCount: 12,
                lastExportTime: Date(timeIntervalSince1970: 1_700_000_000 - 30),
                lastBackupTime: nil,
                lastExportError: "Old export error",
                lastBackupError: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        try r.expectEqual(snapshot.summaryText, t("workspace.bear_db_missing"), "source problems should override stale exported-count summaries")
        try r.expectEqual(snapshot.statusText, t("workspace.needs_access"), "source problems should show needs-access status")
        try r.expectEqual(snapshot.statusStyle, .warning, "source problems should use warning style")
        try r.expect(!snapshot.canExportNow, "source problems should disable export now")
    }

    private static func testMenuSnapshotErrorPresentation(_ r: inout WorkflowRunner) throws {
        let config = ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/b2ou-menu-error"))
        let healthy = BearSourceHealth(isAvailable: true, kind: .sqlite, problemMessage: nil)

        let blankErrorSnapshot = buildMenuPanelSnapshot(
            MenuPanelSnapshotInput(
                languageCode: "en",
                config: config,
                sourceHealth: healthy,
                isPaused: false,
                isExporting: false,
                noteCount: 0,
                lastExportTime: nil,
                lastBackupTime: nil,
                lastExportError: " \n ",
                lastBackupError: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        try r.expectEqual(
            blankErrorSnapshot.summaryText,
            t("menu.exporting_to").replacingOccurrences(of: "{folder}", with: config.exportPath.lastPathComponent),
            "blank errors should be ignored in the menu summary"
        )
        try r.expectEqual(blankErrorSnapshot.statusText, t("workspace.connected"), "blank errors should not force error status")

        let errorSnapshot = buildMenuPanelSnapshot(
            MenuPanelSnapshotInput(
                languageCode: "en",
                config: config,
                sourceHealth: healthy,
                isPaused: false,
                isExporting: false,
                noteCount: 0,
                lastExportTime: nil,
                lastBackupTime: nil,
                lastExportError: "First line\nSecond line",
                lastBackupError: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        try r.expectEqual(errorSnapshot.summaryText, "First line", "menu summary should use the first line of a multi-line error")
        try r.expectEqual(errorSnapshot.statusStyle, .error, "real sync errors should use error style")
        try r.expect(errorSnapshot.toolTip.contains("Second line"), "menu tooltip should preserve the full error details")
    }

    private static func testMenuSnapshotBackupError(_ r: inout WorkflowRunner) throws {
        let config = ExportConfig(exportPath: URL(fileURLWithPath: "/tmp/b2ou-menu-backup"))
        let healthy = BearSourceHealth(isAvailable: true, kind: .sqlite, problemMessage: nil)

        let snapshot = buildMenuPanelSnapshot(
            MenuPanelSnapshotInput(
                languageCode: "en",
                config: config,
                sourceHealth: healthy,
                isPaused: false,
                isExporting: false,
                noteCount: 5,
                lastExportTime: Date(timeIntervalSince1970: 1_700_000_000 - 120),
                lastBackupTime: nil,
                lastExportError: nil,
                lastBackupError: "Backup failed: disk full",
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        try r.expectEqual(snapshot.summaryText, "Backup failed: disk full", "backup errors should surface when export is otherwise healthy")
        try r.expectEqual(snapshot.statusStyle, .error, "backup errors should use error style")
        try r.expect(snapshot.toolTip.contains("Backup error"), "backup errors should be labeled in the tooltip")
    }

    private static func testUnconfiguredHealth(_ r: inout WorkflowRunner) throws {
        let health = BearSourceHealth.evaluate(config: nil)

        try r.expect(!health.isAvailable, "nil config should not report an available source")
        try r.expect(health.kind == nil, "nil config should not report a source kind")
        try r.expectEqual(health.problemMessage, t("workspace.bear_source_unconfigured"), "nil config should use the unconfigured message")
    }

    private static func testMissingBearCLIHealth(_ r: inout WorkflowRunner) throws {
        let config = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/b2ou-health-cli"),
            bearCLIPath: URL(fileURLWithPath: "/tmp/b2ou-health-cli/missing-bearcli"),
            bearSource: "bearcli"
        )
        let health = BearSourceHealth.evaluate(config: config)

        try r.expect(!health.isAvailable, "missing explicit Bear CLI should not report available")
        try r.expectEqual(health.problemMessage, t("workspace.bear_cli_missing"), "missing Bear CLI should report the right message")
        switch health.kind {
        case .bearCLI?:
            break
        default:
            throw WorkflowFailure.failed("missing Bear CLI should report Bear CLI as the source kind")
        }
    }

    private static func testMissingSQLiteHealth(_ r: inout WorkflowRunner) throws {
        let config = ExportConfig(
            exportPath: URL(fileURLWithPath: "/tmp/b2ou-health-db"),
            bearDB: URL(fileURLWithPath: "/tmp/b2ou-health-db/missing.sqlite"),
            bearSource: "sqlite"
        )
        let health = BearSourceHealth.evaluate(config: config)

        try r.expect(!health.isAvailable, "missing explicit SQLite source should not report available")
        try r.expectEqual(health.problemMessage, t("workspace.bear_db_missing"), "missing SQLite source should report the right message")
        switch health.kind {
        case .sqlite?:
            break
        default:
            throw WorkflowFailure.failed("missing SQLite source should report SQLite as the source kind")
        }
    }

    private static func testRuntimeIssueState(_ r: inout WorkflowRunner) throws {
        var state = RuntimeIssueState()

        state.apply(ExportWatcherUpdate(noteCount: 0, operation: .export, errorMessage: "Export failed"))
        try r.expectEqual(state.exportError, "Export failed", "export updates should populate the export error channel")
        try r.expectEqual(state.primaryErrorMessage, "Export failed", "export errors should be prioritized")

        state.apply(ExportWatcherUpdate(noteCount: 0, operation: .backup, errorMessage: nil))
        try r.expectEqual(state.exportError, "Export failed", "backup success should not clear export errors")
        try r.expectEqual(state.backupError, nil, "successful backup updates should clear backup errors only")

        state.apply(ExportWatcherUpdate(noteCount: 0, operation: .backup, errorMessage: "Backup failed"))
        try r.expectEqual(state.backupError, "Backup failed", "backup updates should populate the backup error channel")

        state.apply(ExportWatcherUpdate(noteCount: 0, operation: .export, errorMessage: nil))
        try r.expectEqual(state.exportError, nil, "export success should clear export errors")
        try r.expectEqual(state.primaryErrorMessage, "Backup failed", "backup errors should remain visible after export recovery")

        state.apply(ExportWatcherUpdate(noteCount: 0, operation: .backup, errorMessage: " \n "))
        try r.expectEqual(state.backupError, nil, "blank backup errors should normalize to nil")
        try r.expectEqual(state.primaryErrorMessage, nil, "cleared backup errors should remove the remaining runtime issue")
    }

    private static func testLoginItemToggleOutcome(_ r: inout WorkflowRunner) throws {
        let alreadyEnabled = FakeLoginItemController(enabled: true)
        let noOp = applyLoginItemToggle(true, controller: alreadyEnabled)
        try r.expect(noOp.succeeded, "no-op login item changes should succeed")
        try r.expectEqual(noOp.effectiveEnabled, true, "no-op login item changes should preserve the current state")

        let failedEnable = FakeLoginItemController(
            enabled: false,
            enableResult: .failure(LoginItemControlError("launchctl denied access"))
        )
        let enableFailure = applyLoginItemToggle(true, controller: failedEnable)
        try r.expect(!enableFailure.succeeded, "failed login item enables should report failure")
        try r.expectEqual(enableFailure.errorMessage, "launchctl denied access", "login item failures should preserve the underlying error")
        try r.expectEqual(enableFailure.effectiveEnabled, false, "failed login item enables should keep the old state visible")

        let mismatchedDisable = FakeLoginItemController(
            enabled: true,
            disableResult: .success(()),
            disableSetsState: false
        )
        let mismatch = applyLoginItemToggle(false, controller: mismatchedDisable)
        try r.expect(!mismatch.succeeded, "state mismatches after a reported success should still fail")
        try r.expectEqual(
            mismatch.errorMessage,
            t("menu.start_at_login_state_mismatch"),
            "login item mismatches should use the dedicated mismatch message"
        )
        try r.expectEqual(mismatch.effectiveEnabled, true, "state mismatches should expose the actual effective state")
    }

    private static func testLanguageChangeNotification(_ r: inout WorkflowRunner) throws {
        let original = getLanguage()
        let target = original == "en" ? "zh" : "en"
        var observedLanguages: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .b2ouLanguageDidChange,
            object: nil,
            queue: nil
        ) { notification in
            observedLanguages.append((notification.object as? String) ?? "")
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            if getLanguage() != original {
                setLanguage(original)
            }
        }

        setLanguage(target)
        try r.expectEqual(getLanguage(), target, "setLanguage should switch the active language immediately")
        try r.expectEqual(observedLanguages, [target], "language changes should publish one refresh notification with the effective language")

        observedLanguages.removeAll()
        setLanguage(target)
        try r.expect(observedLanguages.isEmpty, "setting the same language again should not emit duplicate refresh notifications")
    }

    private static func testNoteActionAvailability(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-note-actions")
        defer { try? FileManager.default.removeItem(at: root) }

        let missingExport = NoteMetadata(
            title: "Source-only",
            created: nil,
            modified: nil,
            tags: [],
            wordCount: 10,
            charCount: 40,
            filePath: root.appendingPathComponent("Source-only.md"),
            bearId: "SOURCE-1",
            hasImages: false,
            missingImageRefs: 0,
            bodyText: "body",
            sourceMarkdown: "body",
            sourceKind: .bearSource
        )
        let sourceActions = noteActionAvailability(for: missingExport)
        try r.expect(!sourceActions.canOpenExportedFile, "source-backed notes should not offer export-file actions before export exists")
        try r.expect(!sourceActions.canRevealExportedFile, "source-backed notes should not reveal a file that does not exist")
        try r.expect(sourceActions.canOpenInBear, "source-backed notes should still support opening in Bear")
        try r.expect(!notesContainMissingSourceLinks([missingExport]), "source-backed notes should not be treated as missing source links")

        let exportedURL = root.appendingPathComponent("Exported.md")
        try "exported".write(to: exportedURL, atomically: true, encoding: .utf8)
        let exportedNote = NoteMetadata(
            title: "Exported",
            created: nil,
            modified: nil,
            tags: [],
            wordCount: 10,
            charCount: 40,
            filePath: exportedURL,
            bearId: "",
            hasImages: false,
            missingImageRefs: 0,
            bodyText: "body",
            sourceMarkdown: "body",
            sourceKind: .exportedMarkdown
        )
        let exportedActions = noteActionAvailability(for: exportedNote)
        try r.expect(exportedActions.canOpenExportedFile, "existing exported files should offer editor actions")
        try r.expect(exportedActions.canRevealExportedFile, "existing exported files should offer reveal actions")
        try r.expect(!exportedActions.canOpenInBear, "notes without Bear IDs should not offer Bear actions")
        try r.expect(notesContainMissingSourceLinks([exportedNote]), "export-only notes without Bear IDs should surface missing source links")
    }

    private static func testSettingsValidation(_ r: inout WorkflowRunner) throws {
        let missingMarkdown = validateSettingsInput(
            SettingsValidationInput(
                exportPath: "",
                exportPathTB: "/tmp/textbundles",
                exportFormat: "md",
                backupInterval: 0,
                backupPath: ""
            )
        )
        try r.expectEqual(missingMarkdown, .markdownFolderMissing, "markdown exports should require a Markdown folder")

        let bothConflict = validateSettingsInput(
            SettingsValidationInput(
                exportPath: "/tmp/export",
                exportPathTB: "/tmp/export",
                exportFormat: "both",
                backupInterval: 0,
                backupPath: ""
            )
        )
        try r.expectEqual(bothConflict, .bothFormatsShareFolder, "both-format exports should require distinct folders")

        let backupConflict = validateSettingsInput(
            SettingsValidationInput(
                exportPath: "/tmp/export-md",
                exportPathTB: "/tmp/export-tb",
                exportFormat: "both",
                backupInterval: 30,
                backupPath: "/tmp/export-tb"
            )
        )
        try r.expectEqual(backupConflict, .backupFolderConflictsWithExport, "backup folders should not be allowed to reuse any active export root")

        let valid = validateSettingsInput(
            SettingsValidationInput(
                exportPath: "/tmp/export-md",
                exportPathTB: "/tmp/export-tb",
                exportFormat: "both",
                backupInterval: 30,
                backupPath: "/tmp/export-md/.b2ou-backups"
            )
        )
        try r.expect(valid == nil, "separate backup folders should validate successfully")
    }

    private static func testExternalActionRecording(_ r: inout WorkflowRunner) throws {
        installB2OUExternalActionRecorder(
            openHandler: { _ in },
            revealHandler: { _ in }
        )
        defer { resetB2OUExternalActionRecorder() }

        let fileURL = URL(fileURLWithPath: "/tmp/b2ou-export.md")
        b2ouOpen(fileURL)
        b2ouReveal([fileURL])
        if let bearURL = b2ouBearNoteURL(noteID: "NOTE 42") {
            b2ouOpen(bearURL)
        }

        let records = currentB2OUExternalActionRecords()
        try r.expectEqual(records.count, 3, "external action recorder should capture open and reveal calls")
        try r.expectEqual(records[0], B2OUExternalActionRecord(kind: .open, targets: [fileURL.absoluteString]), "file opens should preserve the exact target URL")
        try r.expectEqual(records[1], B2OUExternalActionRecord(kind: .reveal, targets: [fileURL.absoluteString]), "reveal actions should preserve the exact target URL")
        try r.expect(records[2].targets.first?.contains("bear://x-callback-url/open-note?id=NOTE%2042") == true, "Bear note opens should percent-encode note IDs in the callback URL")
        try r.expectEqual(b2ouReleasesURL.absoluteString, "https://github.com/desususu/B2OU/releases", "release-page buttons should target the releases URL")
        try r.expectEqual(b2ouProjectPageURL.absoluteString, "https://github.com/desususu/B2OU", "project-page buttons should target the project URL")
        try r.expect(b2ouBearNoteURL(noteID: "") == nil, "empty Bear IDs should not build callback URLs")
    }

    private static func testDeepActionContracts(_ r: inout WorkflowRunner) throws {
        let expectedImplementedIDs = [
            "menu.language",
            "workspace.rebuild_state",
            "workspace.reveal_exported_file",
            "dashboard.open_exported_file",
            "note_browser.open_exported_file",
            "note_browser.reveal_exported_file",
            "note_browser.open_in_bear",
        ]
        for id in expectedImplementedIDs {
            let contract = b2ouFeatureContracts.first { $0.id == id }
            try r.expectEqual(contract?.state, .implemented, "\(id) should stay covered by an implemented feature contract")
        }

        let externalSurfaceIDs = [
            "settings.check_updates",
            "settings.project_page",
        ]
        for id in externalSurfaceIDs {
            let contract = b2ouFeatureContracts.first { $0.id == id }
            try r.expectEqual(contract?.state, .externalLink, "\(id) should stay documented as an external system action")
        }
    }

    private static func testNoteStorePrefersBearSource(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-store-source-first")
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("bear.sqlite")
        try createWorkflowBearDatabase(
            at: dbURL,
            notes: [
                WorkflowFixtureNote(
                    title: "Source Truth",
                    text: "Body #work",
                    uuid: "SOURCE-1",
                    modifiedUnix: 1_700_000_000
                )
            ]
        )

        let exportRoot = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try """
        ---
        title: "Exported Copy"
        ---

        exported
        """.write(
            to: exportRoot.appendingPathComponent("Exported Copy.md"),
            atomically: true,
            encoding: .utf8
        )

        let config = ExportConfig(
            exportPath: exportRoot,
            bearDB: dbURL,
            bearSource: "sqlite"
        )

        let store = NoteStore()
        store.scan(config: config, allowExportFallback: true)

        try r.expectEqual(store.notes.count, 1, "available Bear source should avoid mixing in exported Markdown fallback")
        try r.expectEqual(store.notes.first?.title, "Source Truth", "workspace should prefer Bear-source note metadata")
        try r.expectEqual(store.notes.first?.sourceKind, .bearSource, "workspace should mark source-first notes as Bear-backed")
    }

    private static func testNoteStoreSidecarScan(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-store-sidecar")
        defer { try? FileManager.default.removeItem(at: root) }

        let noteURL = root.appendingPathComponent("Mapped Note.md")
        try """
        ---
        title: "Mapped Note"
        tags:
          - work
        ---

        Body text
        ![Missing](missing.png)
        """.write(to: noteURL, atomically: true, encoding: .utf8)

        let state = B2OUSyncState(
            exportRoot: root.path,
            bindings: [
                B2OUSyncBinding(
                    obsidianPath: "Mapped Note.md",
                    bearID: "NOTE-1",
                    matchMethod: "export",
                    riskLevel: "low",
                    managedByManifest: true
                )
            ]
        )
        try writeSyncState(state, exportPath: root)

        let store = NoteStore()
        store.scan(exportPath: root)

        try r.expectEqual(store.notes.count, 1, "sidecar scan should load one exported note")
        try r.expectEqual(store.notes.first?.title, "Mapped Note", "sidecar scan should use YAML title")
        try r.expectEqual(store.notes.first?.bearId, "NOTE-1", "sidecar scan should read Bear ID from sidecar")
        try r.expectEqual(store.stats?.missingBearIds, 0, "sidecar scan should count the note as mapped")
        try r.expectEqual(store.stats?.missingImageRefs, 1, "sidecar scan should count unresolved image references")
        try r.expectEqual(store.stats?.tagFrequency.first?.tag, "work", "sidecar scan should preserve tags")
    }

    private static func testNoteStoreFallbackBehavior(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-store-fallback")
        defer { try? FileManager.default.removeItem(at: root) }

        let noteURL = root.appendingPathComponent("Fallback.md")
        try "Fallback body".write(to: noteURL, atomically: true, encoding: .utf8)

        let config = ExportConfig(
            exportPath: root,
            bearDB: root.appendingPathComponent("missing.sqlite"),
            bearSource: "sqlite"
        )

        let store = NoteStore()
        store.scan(config: config, allowExportFallback: true)
        try r.expectEqual(store.notes.count, 1, "fallback scan should load exported Markdown when allowed")
        try r.expectEqual(store.notes.first?.title, "Fallback", "fallback scan should derive title from filename")

        store.scan(config: config, allowExportFallback: false)
        try r.expect(store.notes.isEmpty, "disabling fallback should clear the workspace when the source is unavailable")
    }

    // MARK: - Backup Workflow Tests

    private static func testBackupRotation(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-bk-rotate")
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let backupDir = root.appendingPathComponent(".b2ou-backups")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Create maxKeep+3 mock backup files
        let maxKeep = 5
        for i in 0..<(maxKeep + 3) {
            let url = backupDir.appendingPathComponent("bear-backup-2025-01-\(String(format: "%02d", i + 1))-\(UUID().uuidString.prefix(8)).sqlite")
            try Data("mock sqlite backup \(i)".utf8).write(to: url)
            Thread.sleep(forTimeInterval: 0.01) // ensure distinct creation timestamps
        }

        let allBefore = completeBackupURLs(in: backupDir)
        try r.expectEqual(allBefore.count, maxKeep + 3, "should have all backups before rotation")

        let removed = rotateBackups(in: backupDir, maxKeep: maxKeep)
        try r.expectEqual(removed, 3, "rotation should remove 3 excess backups")
        try r.expectEqual(completeBackupURLs(in: backupDir).count, maxKeep, "should keep exactly maxKeep backups after rotation")
    }

    private static func testBackupLocking(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-bk-lock")
        defer { try? FileManager.default.removeItem(at: root) }

        let backupDir = root.appendingPathComponent(".b2ou-backups")

        guard let fd1 = acquireBackupLock(in: backupDir) else {
            throw WorkflowFailure.failed("first lock acquisition should succeed")
        }
        defer { releaseBackupLock(fd1) }

        let fd2 = acquireBackupLock(in: backupDir)
        try r.expect(fd2 == nil, "second lock acquisition should fail while first holds the lock")

        // Also test the lock file has restrictive permissions
        let lockPath = backupDir.appendingPathComponent(backupLockName)
        let attrs = try FileManager.default.attributesOfItem(atPath: lockPath.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try r.expect(perms == 0o600, "backup lock file should have 0600 permissions")
    }

    private static func testBackupInterruptedCleanup(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-bk-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let backupDir = root.appendingPathComponent(".b2ou-backups")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Create a stale tmp file (old modification date)
        let staleTmp = backupDir.appendingPathComponent(".bear-backup-2020-01-01_000000_000-abc123.tmp-\(UUID().uuidString)")
        try Data("stale interrupted backup".utf8).write(to: staleTmp)
        // Set modification date to very old
        let pastDate = Date(timeIntervalSince1970: 0)
        try fm.setAttributes([.modificationDate: pastDate], ofItemAtPath: staleTmp.path)

        // Create a recent tmp file (should NOT be cleaned up)
        let recentTmp = backupDir.appendingPathComponent(".bear-backup-recent.tmp-\(UUID().uuidString)")
        try Data("recent".utf8).write(to: recentTmp)

        let removed = cleanupInterruptedBackups(in: backupDir)
        try r.expectEqual(removed, 1, "should clean up exactly 1 stale interrupted backup")
        try r.expect(!fm.fileExists(atPath: staleTmp.path), "stale tmp file should be removed")
        try r.expect(fm.fileExists(atPath: recentTmp.path), "recent tmp file should not be removed")
    }

    private static func testBackupRotationIdempotent(_ r: inout WorkflowRunner) throws {
        let root = try makeTemporaryDirectory(prefix: "b2ou-bk-idem")
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        let backupDir = root.appendingPathComponent(".b2ou-backups")
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let maxKeep = 3
        for i in 0..<maxKeep {
            let url = backupDir.appendingPathComponent("bear-backup-2025-01-\(String(format: "%02d", i + 1))-\(UUID().uuidString.prefix(8)).sqlite")
            try Data("mock \(i)".utf8).write(to: url)
            Thread.sleep(forTimeInterval: 0.01)
        }

        // First rotation should not remove anything
        let removed1 = rotateBackups(in: backupDir, maxKeep: maxKeep)
        try r.expectEqual(removed1, 0, "first rotation should not remove any backups when count <= maxKeep")

        // Second rotation should also not remove anything (idempotent)
        let removed2 = rotateBackups(in: backupDir, maxKeep: maxKeep)
        try r.expectEqual(removed2, 0, "second rotation should also remove nothing")
        try r.expectEqual(completeBackupURLs(in: backupDir).count, maxKeep, "backup count should remain stable after multiple rotations")
    }

    private static func testBackupResultReporting(_ r: inout WorkflowRunner) throws {
        // Success case
        let success = BackupResult(
            success: true,
            backupURL: URL(fileURLWithPath: "/tmp/backups/test.sqlite"),
            rotationRemovedCount: 2
        )
        try r.expect(success.success, "success result should report success=true")
        try r.expectEqual(success.rotationRemovedCount, 2, "success result should preserve rotation count")
        try r.expect(success.errorMessage == nil, "success result should have no error message")

        // Error case
        let failure = BackupResult(
            success: false,
            errorMessage: "Disk full",
            cleanedInterruptedCount: 1
        )
        try r.expect(!failure.success, "failure result should report success=false")
        try r.expectEqual(failure.errorMessage, "Disk full", "failure result should preserve error message")
        try r.expectEqual(failure.cleanedInterruptedCount, 1, "failure result should preserve cleanup count")
        try r.expect(failure.backupURL == nil, "failed backup should have no URL")
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FakeLoginItemController: LoginItemControlling {
    private(set) var enabled: Bool
    private let enableResult: Result<Void, LoginItemControlError>
    private let disableResult: Result<Void, LoginItemControlError>
    private let enableSetsState: Bool
    private let disableSetsState: Bool

    init(
        enabled: Bool,
        enableResult: Result<Void, LoginItemControlError> = .success(()),
        disableResult: Result<Void, LoginItemControlError> = .success(()),
        enableSetsState: Bool = true,
        disableSetsState: Bool = true
    ) {
        self.enabled = enabled
        self.enableResult = enableResult
        self.disableResult = disableResult
        self.enableSetsState = enableSetsState
        self.disableSetsState = disableSetsState
    }

    func isEnabled() -> Bool {
        enabled
    }

    func enable() -> Result<Void, LoginItemControlError> {
        if case .success = enableResult, enableSetsState {
            enabled = true
        }
        return enableResult
    }

    func disable() -> Result<Void, LoginItemControlError> {
        if case .success = disableResult, disableSetsState {
            enabled = false
        }
        return disableResult
    }
}

private struct WorkflowFixtureNote {
    let title: String
    let text: String
    let uuid: String
    let modifiedUnix: Double
}

private func createWorkflowBearDatabase(at url: URL, notes: [WorkflowFixtureNote]) throws {
#if canImport(SQLite3)
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db else {
        throw WorkflowFailure.failed("Could not open SQLite database at \(url.path)")
    }
    defer { sqlite3_close(db) }

    try execWorkflowSQL(
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
        try execWorkflowSQL(
            """
            INSERT INTO ZSFNOTE(
              ZTITLE, ZTEXT, ZCREATIONDATE, ZMODIFICATIONDATE,
              ZUNIQUEIDENTIFIER, Z_PK, ZTRASHED, ZARCHIVED, ZENCRYPTED
            ) VALUES (
              '\(workflowSQLQuote(note.title))',
              '\(workflowSQLQuote(note.text))',
              \(created),
              \(modified),
              '\(workflowSQLQuote(note.uuid))',
              \(pk),
              0,
              0,
              0
            );
            """,
            db: db
        )
    }
#else
    throw WorkflowFailure.failed("SQLite3 is unavailable in this environment")
#endif
}

#if canImport(SQLite3)
private func execWorkflowSQL(_ sql: String, db: OpaquePointer) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown sqlite error"
        sqlite3_free(errorMessage)
        throw WorkflowFailure.failed(message)
    }
}
#endif

private func workflowSQLQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}
