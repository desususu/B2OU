// MenuBarApp.swift — Native macOS menu-bar application for B2OU.
//
// All export logic is called in-process via B2OUCore; SwiftUI owns the visible
// menu and utility-window content.

import Cocoa
import SwiftUI
import B2OUAppSupport
import B2OUCore
import Darwin

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let panelState = MenuPanelState()
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    // State
    private var config: ExportConfig?
    private var profiles: [String: ExportConfig] = [:]
    private var activeProfileName: String?
    private var watcher: ExportWatcher?
    private var isPaused = false
    private var statusTimer: Timer?
    private var noteStore = NoteStore()
    private let scanQueue = DispatchQueue(label: "net.b2ou.notes.scan", qos: .userInitiated)
    private var isWorkspaceScanInFlight = false
    private var isManualExportInFlight = false
    private var runtimeIssues = RuntimeIssueState()
    private var manualLastExportTime: Date?
    private var manualLastExportCount = 0
    private var guiProbeSession: B2OUGUIProbeSession?
    private var guiProbeFolderQueue: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = initLanguage()
        setupStatusItem()
        buildPanel()

        // Deferred startup: load profiles after the run loop is live
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reloadProfiles()
            if self?.config == nil {
                self?.runSetupWizard()
            }
        }

        // Periodically refresh the "Last export: X min ago" text
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        maybeStartGUIProbe()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let iconPath = resolveIcon("menubar"),
               let image = NSImage(contentsOfFile: iconPath) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.title = ""
                button.image = image
            } else {
                button.image = nil
                button.title = "\u{1F43B}" // Bear emoji fallback
            }
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func resolveIcon(_ name: String) -> String? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "icons") {
            return url.path
        }
        // Dev mode: look in resources/icons relative to executable
        let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent()
        let devPath = exe.appendingPathComponent("../resources/icons/\(name).png").standardized
        return FileManager.default.fileExists(atPath: devPath.path) ? devPath.path : nil
    }

    // MARK: - Panel Construction

    private func buildPanel() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = MenuPanelView.preferredSize
        popover.contentViewController = NSHostingController(
            rootView: MenuPanelView(
                model: panelState,
                actions: makePanelActions()
            )
        )
        refreshPanelState()
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        refreshPanelState()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startDismissMonitoring()
    }

    private func closePanel() {
        popover.performClose(nil)
        resizePanel(height: MenuPanelView.preferredSize.height)
        stopDismissMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissMonitoring()
    }

    private func startDismissMonitoring() {
        stopDismissMonitoring()

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if self.eventHitsPopoverOrStatusItem(event) {
                return event
            }
            self.closePanel()
            return event
        }

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePanel()
            }
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func stopDismissMonitoring() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
    }

    private func eventHitsPopoverOrStatusItem(_ event: NSEvent) -> Bool {
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return true
        }

        guard let button = statusItem.button,
              let window = button.window,
              event.window === window else {
            return false
        }

        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }

    private func makePanelActions() -> MenuPanelActions {
        MenuPanelActions(
            exportNow: { [weak self] in
                self?.onExportNow()
            },
            togglePause: { [weak self] in
                self?.onTogglePause()
            },
            openFolder: { [weak self] in
                self?.closePanel()
                self?.onOpenFolder()
            },
            openWorkspace: { [weak self] in
                self?.closePanel()
                self?.onExportWorkspace()
            },
            openDashboard: { [weak self] in
                self?.closePanel()
                self?.onDashboard()
            },
            changeFolder: { [weak self] in
                self?.closePanel()
                self?.onChangeFolder()
            },
            configure: { [weak self] in
                self?.closePanel()
                self?.onConfigure()
            },
            editConfig: { [weak self] in
                self?.closePanel()
                self?.onEditConfig()
            },
            setLoginItemEnabled: { [weak self] enabled in
                self?.setLoginItemEnabled(enabled)
            },
            setupProfile: { [weak self] in
                self?.closePanel()
                self?.onSetup()
            },
            selectProfile: { [weak self] name in
                self?.setProfile(name)
            },
            reloadProfiles: { [weak self] in
                self?.reloadProfiles()
            },
            setLanguage: { [weak self] language in
                if language == "zh" {
                    self?.onSetChinese()
                } else {
                    self?.onSetEnglish()
                }
            },
            resizePanel: { [weak self] height in
                self?.resizePanel(height: height)
            },
            quit: { [weak self] in
                self?.onQuit()
            }
        )
    }

    private func resizePanel(height: CGFloat) {
        popover.contentSize = NSSize(width: MenuPanelView.preferredSize.width, height: height)
    }

    // MARK: - Profile Management

    private func reloadProfiles() {
        profiles = loadProfiles()

        // Re-select the active profile (picks up any config changes from disk)
        if let name = activeProfileName, profiles[name] != nil {
            setProfile(name)
        } else if let firstName = profiles.keys.sorted().first {
            setProfile(firstName)
        } else {
            config = nil
            activeProfileName = nil
            isPaused = false
            runtimeIssues.clearAll()
            watcher?.stop()
            watcher = nil
            refreshIconForCurrentState()
            updateStatus()
        }
        refreshPanelState()
    }

    private func setProfile(_ name: String) {
        guard let cfg = profiles[name] else { return }
        config = cfg
        activeProfileName = name
        runtimeIssues.clearAll()

        if watcher != nil { watcher?.stop() }
        startWatcher()
        refreshIconForCurrentState()
        updateStatus()
    }

    // MARK: - Export Watcher

    private func startWatcher() {
        guard let cfg = config else { return }
        watcher = ExportWatcher(config: cfg) { [weak self] update in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runtimeIssues.apply(update)
                self.refreshIconForCurrentState()
                self.updateStatus()
            }
        }
        watcher?.paused = isPaused
        watcher?.start()
    }

    private func updateStatus() {
        refreshPanelState()
    }

    private func refreshPanelState() {
        let isExporting = isAnyExportInFlight
        let languageCode = getLanguage()
        let snapshot = buildMenuPanelSnapshot(
            MenuPanelSnapshotInput(
                languageCode: languageCode,
                config: config,
                sourceHealth: BearSourceHealth.evaluate(config: config),
                isPaused: isPaused,
                isExporting: isExporting,
                noteCount: max(watcher?.noteCount ?? 0, manualLastExportCount),
                lastExportTime: [watcher?.lastExportTime, manualLastExportTime].compactMap { $0 }.max(),
                lastBackupTime: watcher?.lastBackupTime,
                lastExportError: runtimeIssues.exportError,
                lastBackupError: runtimeIssues.backupError
            )
        )

        panelState.languageCode = languageCode
        panelState.appTitle = snapshot.appTitle
        panelState.isPaused = isPaused
        panelState.isExporting = isExporting
        panelState.canExportNow = snapshot.canExportNow
        panelState.isLoginItemEnabled = isLoginItem()
        panelState.profileNames = profiles.keys.sorted()
        panelState.activeProfileName = activeProfileName
        panelState.exportFolderName = snapshot.exportFolderName
        panelState.summaryText = snapshot.summaryText
        panelState.lastExportText = snapshot.lastExportText
        panelState.lastBackupText = snapshot.lastBackupText
        panelState.statusText = snapshot.statusText
        panelState.statusStyle = snapshot.statusStyle
        statusItem.button?.toolTip = snapshot.toolTip
    }

    private var isAnyExportInFlight: Bool {
        isManualExportInFlight || (watcher?.isExporting ?? false)
    }

    // MARK: - Actions

    @objc private func onExportNow() {
        if config == nil { runSetupWizard(); return }
        triggerExportNow()
    }

    private func triggerExportNow() {
        guard let watcher else { return }
        guard !isAnyExportInFlight else {
            refreshPanelState()
            return
        }
        guard BearSourceHealth.evaluate(config: config).isAvailable else {
            refreshPanelState()
            return
        }
        runtimeIssues.clearExportError()
        watcher.exportNow()
        refreshIconForCurrentState()
        refreshPanelState()
    }

    @objc private func onTogglePause() {
        guard let watcher else { return }
        isPaused.toggle()
        watcher.paused = isPaused
        refreshIconForCurrentState()
        refreshPanelState()
    }

    @objc private func onOpenFolder() {
        guard let cfg = config else { runSetupWizard(); return }
        b2ouOpen(cfg.exportPath)
    }

    @objc private func onExportWorkspace() {
        guard config != nil else { runSetupWizard(); return }
        noteStore.clear()
        showWorkspaceFromCurrentState()
        scanAndShowWorkspace()
    }

    @objc private func onDashboard() {
        guard config != nil else { runSetupWizard(); return }
        noteStore.clear()
        showDashboard(store: noteStore)
        scanAndRun { [weak self] in
            guard let self else { return }
            showDashboard(store: self.noteStore)
        }
    }

    private func scanAndRun(_ action: @escaping () -> Void) {
        guard let cfg = config else { return }
        guard !isWorkspaceScanInFlight else { return }
        isWorkspaceScanInFlight = true
        let store = noteStore
        scanQueue.async { [weak self] in
            store.scan(config: cfg, allowExportFallback: false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isWorkspaceScanInFlight = false
                action()
            }
        }
    }

    private func scanAndShowWorkspace() {
        scanAndRun { [weak self] in
            self?.showWorkspaceFromCurrentState()
        }
    }

    private func showWorkspaceFromCurrentState() {
        guard let cfg = config else { return }
        showExportWorkspace(
            store: noteStore,
            config: cfg,
            lastExportTime: manualLastExportTime ?? watcher?.lastExportTime,
            exportedNoteCount: manualLastExportCount > 0 ? manualLastExportCount : (watcher?.noteCount ?? 0),
            onExportAll: { [weak self] in
                self?.exportAllFromWorkspace()
            },
            onExportSelected: { [weak self] ids in
                self?.exportSelectedNotes(bearIDs: ids)
            },
            onRefreshWorkspace: { [weak self] in
                self?.scanAndShowWorkspace()
            },
            onRebuildState: { [weak self] in
                self?.rebuildWorkspaceState()
            },
            onOpenPreferences: { [weak self] in
                self?.onConfigure()
            }
        )
    }

    @objc private func onSetup() { runSetupWizard() }

    @objc private func onSelectProfile(_ sender: NSMenuItem) {
        setProfile(sender.title)
    }

    @objc private func onReloadProfiles() { reloadProfiles() }

    @objc private func onToggleLogin() {
        _ = setLoginItemEnabled(!isLoginItem())
    }

    @discardableResult
    private func setLoginItemEnabled(_ enabled: Bool, presentAlert: Bool = true) -> LoginItemToggleOutcome {
        let outcome = applyLoginItemToggle(enabled)
        if presentAlert, let message = outcome.errorMessage {
            showLoginItemFailure(message)
        }
        refreshPanelState()
        return outcome
    }

    private func showLoginItemFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("menu.start_at_login_failed_title")
        alert.informativeText = t("menu.start_at_login_failed_msg")
            .replacingOccurrences(of: "{error}", with: message)
        alert.runModal()
    }

    @objc private func onChangeFolder() {
        guard let cfg = config else { runSetupWizard(); return }
        guard let path = pickFolder(prompt: t("wizard.pick_advanced")) else { return }
        var update = ProfileConfigUpdate(config: cfg)
        update.exportPath = path
        guard persistActiveProfile(update) else { return }
        reloadProfiles()
    }

    @objc private func onConfigure() {
        if config == nil { runSetupWizard(); return }
        guard let cfg = config else { return }

        let vals = SettingsValues(
            exportPath: cfg.exportPath.path,
            exportPathTB: cfg.exportPathTB?.path ?? "",
            exportFormat: cfg.exportFormat,
            yamlFrontMatter: cfg.yamlFrontMatter,
            tagFolders: cfg.makeTagFolders,
            hideTags: cfg.hideTags,
            autoStart: isLoginItem(),
            naming: cfg.naming,
            onDelete: cfg.onDelete,
            excludeTags: cfg.excludeTags.joined(separator: ", "),
            backupInterval: cfg.backupInterval,
            backupPath: cfg.backupPath?.path ?? "",
            backupMaxKeep: cfg.backupMaxKeep,
            bearSource: cfg.bearSource,
            bearCLIPath: cfg.bearCLIPath.path == defaultBearCLIPath.path ? "" : cfg.bearCLIPath.path,
            lastBackupSummary: formattedBackupSummary(for: cfg)
        )

        showSettingsPanel(
            values: vals,
            onApply: { [weak self] applied in
                self?.applySettings(applied) ?? false
            },
            onChangeFolder: { [weak self] in
                self?.pickFolder(prompt: t("wizard.pick_prompt"))
            },
            onPickBearCLI: { [weak self] in
                self?.pickBearCLIExecutable()
            }
        )
    }

    private func applySettings(_ v: SettingsValues) -> Bool {
        let excludeList: [String] = v.excludeTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let normalizedSource: String = {
            let s = v.bearSource.lowercased()
            return ["auto", "bearcli", "sqlite"].contains(s) ? s : "auto"
        }()
        let cliTrimmed = v.bearCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearCLIUpdate: String?
        if normalizedSource == "sqlite" {
            bearCLIUpdate = nil
        } else if cliTrimmed.isEmpty {
            bearCLIUpdate = nil
        } else {
            bearCLIUpdate = cliTrimmed
        }

        let update = ProfileConfigUpdate(
            exportPath: v.exportPath,
            exportFormat: v.exportFormat,
            exportPathTB: v.exportPathTB.isEmpty ? nil : v.exportPathTB,
            yamlFrontMatter: v.yamlFrontMatter,
            hideTags: v.hideTags,
            tagFolders: v.tagFolders,
            onDelete: v.onDelete,
            naming: v.naming,
            excludeTags: excludeList.isEmpty ? nil : excludeList,
            backupInterval: v.backupInterval,
            backupPath: v.backupPath.isEmpty ? nil : v.backupPath,
            backupMaxKeep: max(1, v.backupMaxKeep),
            source: normalizedSource,
            bearCLIPath: bearCLIUpdate
        )
        guard persistActiveProfile(update) else { return false }

        // Handle login item
        let loginItemOutcome = setLoginItemEnabled(v.autoStart, presentAlert: false)

        reloadProfiles()
        if let message = loginItemOutcome.errorMessage {
            showLoginItemFailure(message)
            return true
        }
        return true
    }

    private func rebuildWorkspaceState() {
        guard !isAnyExportInFlight else {
            refreshPanelState()
            return
        }
        guard !isWorkspaceScanInFlight else { return }
        guard let cfg = config else { runSetupWizard(); return }

        let client = BearCLIClient(executable: cfg.bearCLIPath)
        guard client.isAvailable else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("workspace.rebuild_state_unavailable_title")
            alert.informativeText = t("workspace.rebuild_state_unavailable_msg")
                .replacingOccurrences(of: "{error}", with: B2OUError.bearCLIUnavailable(client.executable.path).localizedDescription)
            alert.runModal()
            return
        }

        isWorkspaceScanInFlight = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            do {
                let bearNotes = try client.listNoteMetadata(location: "notes")
                let preview = rebuildSyncStatePlan(exportPath: cfg.exportPath, bearNotes: bearNotes, write: false)
                let shouldWrite = DispatchQueue.main.sync {
                    self.shouldWriteRebuiltState(preview)
                }
                guard shouldWrite else {
                    DispatchQueue.main.async {
                        self.isWorkspaceScanInFlight = false
                    }
                    return
                }

                let report = rebuildSyncStatePlan(exportPath: cfg.exportPath, bearNotes: bearNotes, write: true)
                self.noteStore.scan(config: cfg, allowExportFallback: false)

                DispatchQueue.main.async {
                    self.isWorkspaceScanInFlight = false
                    self.showStateRebuildSuccess(report)
                    self.showWorkspaceFromCurrentState()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorkspaceScanInFlight = false
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = t("workspace.rebuild_state_failed_title")
                    alert.informativeText = t("workspace.rebuild_state_failed_msg")
                        .replacingOccurrences(of: "{error}", with: error.localizedDescription)
                    alert.runModal()
                }
            }
        }
    }

    private func shouldWriteRebuiltState(_ report: B2OUStateRebuildReport) -> Bool {
        guard !report.isSafeToWrite else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("workspace.rebuild_state_review_title")
        alert.informativeText = t("workspace.rebuild_state_review_msg")
            .replacingOccurrences(of: "{summary}", with: stateRebuildSummary(report))
        alert.addButton(withTitle: t("workspace.rebuild_state_write_anyway"))
        alert.addButton(withTitle: t("settings.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showStateRebuildSuccess(_ report: B2OUStateRebuildReport) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("workspace.rebuild_state_success_title")
        alert.informativeText = t("workspace.rebuild_state_success_msg")
            .replacingOccurrences(of: "{summary}", with: stateRebuildSummary(report))
        alert.runModal()
    }

    private func stateRebuildSummary(_ report: B2OUStateRebuildReport) -> String {
        let highRisk = report.bindingRiskLevels["high"] ?? 0
        return [
            t("workspace.rebuild_state_summary_bindings").replacingOccurrences(of: "{count}", with: "\(report.plannedBindings)"),
            t("workspace.rebuild_state_summary_unbound_files").replacingOccurrences(of: "{count}", with: "\(report.unboundManagedFiles)"),
            t("workspace.rebuild_state_summary_unbound_notes").replacingOccurrences(of: "{count}", with: "\(report.unboundBearNotes)"),
            t("workspace.rebuild_state_summary_high_risk").replacingOccurrences(of: "{count}", with: "\(highRisk)")
        ].joined(separator: "\n")
    }

    private func exportAllFromWorkspace() {
        if config == nil { runSetupWizard(); return }
        triggerExportNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.scanAndShowWorkspace()
        }
    }

    private func exportSelectedNotes(bearIDs: Set<String>) {
        guard !isAnyExportInFlight else {
            refreshPanelState()
            return
        }
        guard !bearIDs.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("workspace.error_selected_missing_ids_title")
            alert.informativeText = t("workspace.error_selected_missing_ids_msg")
            alert.runModal()
            return
        }
        guard var cfg = config else { runSetupWizard(); return }
        guard BearSourceHealth.evaluate(config: cfg).isAvailable else {
            refreshPanelState()
            return
        }
        cfg.onlyNoteUUIDs = bearIDs
        isManualExportInFlight = true
        runtimeIssues.clearExportError()
        refreshIconForCurrentState()
        refreshPanelState()

        scanQueue.async { [weak self] in
            var totalCount = 0
            var changedCount = 0
            var errorMessage: String?

            do {
                for subConfig in try cfg.splitExportConfigs() {
                    try? FileManager.default.createDirectory(at: subConfig.exportPath, withIntermediateDirectories: true)
                    let result = exportNotes(config: subConfig)
                    guard result.changedCount >= 0 else {
                        throw B2OUError.exportLocked(subConfig.exportPath)
                    }
                    if result.hasConflicts {
                        throw B2OUError.dirtyExportFiles(result.conflictPaths.sorted { $0.path < $1.path })
                    }
                    totalCount = max(totalCount, result.noteCount)
                    changedCount += result.changedCount
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            self?.noteStore.scan(config: cfg, allowExportFallback: false)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isManualExportInFlight = false
                self.runtimeIssues.apply(ExportWatcherUpdate(
                    noteCount: totalCount,
                    operation: .export,
                    errorMessage: errorMessage
                ))
                self.refreshIconForCurrentState()
                if let errorMessage {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = t("workspace.error_export_failed")
                    alert.informativeText = errorMessage
                    alert.runModal()
                } else {
                    self.manualLastExportTime = Date()
                    self.manualLastExportCount = totalCount
                    self.updateStatus()
                    if changedCount == 0 {
                        self.showExportNotice(
                            title: t("workspace.notice_up_to_date_title"),
                            message: t("workspace.notice_up_to_date_msg")
                                .replacingOccurrences(of: "{count}", with: "\(totalCount)")
                        )
                    }
                }
                self.updateStatus()
                self.showWorkspaceFromCurrentState()
            }
        }
    }

    private func showExportNotice(title: String, message: String) {
        if isGUIProbeActive { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func onEditConfig() {
        if let configPath = findConfig() {
            b2ouOpen(configPath)
        } else {
            runSetupWizard()
        }
    }

    @objc private func onSetEnglish() {
        setLanguage("en")
        refreshMenuTitles()
    }

    @objc private func onSetChinese() {
        setLanguage("zh")
        refreshMenuTitles()
    }

    @objc private func onQuit() {
        statusTimer?.invalidate()
        watcher?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Setup Wizard

    private func runSetupWizard() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("wizard.welcome_title")
        alert.informativeText = t("wizard.welcome_msg")
        alert.addButton(withTitle: t("wizard.quick"))
        alert.addButton(withTitle: t("wizard.advanced"))
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            alert.icon = appIcon
        }
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            wizardBeginner()
        } else {
            wizardAdvanced()
        }
    }

    private func wizardBeginner() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = t("wizard.quick_title")
        alert.informativeText = t("wizard.quick_msg")
        alert.addButton(withTitle: t("wizard.choose_folder"))
        alert.runModal()

        guard let path = pickFolder(prompt: t("wizard.pick_prompt")) else {
            let cancel = NSAlert()
            cancel.alertStyle = .warning
            cancel.messageText = t("wizard.cancelled_title")
            cancel.informativeText = t("wizard.cancelled_msg")
            cancel.runModal()
            return
        }

        guard persistActiveProfile(ProfileConfigUpdate(exportPath: path)) else { return }
        setLoginItemEnabled(true)

        reloadProfiles()

        let done = NSAlert()
        done.alertStyle = .informational
        done.messageText = "B2OU \u{2014} " + t("wizard.ready")
        done.informativeText = t("wizard.ready_msg").replacingOccurrences(of: "{path}", with: path)
        done.runModal()
    }

    private func wizardAdvanced() {
        guard let path = pickFolder(prompt: t("wizard.pick_advanced")) else {
            let cancel = NSAlert()
            cancel.alertStyle = .warning
            cancel.messageText = t("wizard.cancelled_title")
            cancel.informativeText = t("wizard.cancelled_msg")
            cancel.runModal()
            return
        }

        guard persistActiveProfile(ProfileConfigUpdate(exportPath: path)) else { return }
        reloadProfiles()
    }

    // MARK: - Helpers

    private func pickFolder(prompt: String) -> String? {
        if isGUIProbeActive, !guiProbeFolderQueue.isEmpty {
            return guiProbeFolderQueue.removeFirst()
        }
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = t("wizard.choose_folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.isExtensionHidden = true
        panel.showsHiddenFiles = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func pickBearCLIExecutable() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = t("settings.bearcli_path")
        panel.prompt = t("settings.bearcli_choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications/Bear.app/Contents/MacOS", isDirectory: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func formattedBackupSummary(for cfg: ExportConfig) -> String {
        guard cfg.backupInterval > 0 else { return "" }
        let backupDir = cfg.backupPath ?? cfg.exportPath.appendingPathComponent(".b2ou-backups")
        let last = watcher?.lastBackupTime ?? latestBackupTime(in: backupDir)
        let rel = formatMenuRelativeTime(last)
        return t("settings.backup_status_last").replacingOccurrences(of: "{time}", with: rel)
    }

    private func persistActiveProfile(_ update: ProfileConfigUpdate) -> Bool {
        do {
            try writeProfileConfig(
                profileName: activeProfileName ?? "default",
                update: update
            )
            return true
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("settings.save_failed_title")
            alert.informativeText = t("settings.save_failed_msg")
                .replacingOccurrences(of: "{error}", with: error.localizedDescription)
            alert.runModal()
            return false
        }
    }

    private func updateIconState(_ state: String) {
        guard let button = statusItem.button else { return }
        switch state {
        case "paused":
            if let path = resolveIcon("menubar_paused"), let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.title = ""
                button.image = img
            } else {
                button.image = nil
                button.title = "\u{275A}\u{275A}"
            }
        case "syncing":
            button.image = nil
            button.title = "\u{21BB}"
        case "error":
            button.image = nil
            button.title = "\u{26A0}\u{FE0E}"
        default: // idle
            if let path = resolveIcon("menubar"), let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.title = ""
                button.image = img
            } else {
                button.image = nil
                button.title = "\u{1F43B}"
            }
        }
    }

    private func refreshIconForCurrentState() {
        if isAnyExportInFlight {
            updateIconState("syncing")
        } else if runtimeIssues.primaryErrorMessage != nil {
            updateIconState("error")
        } else if isPaused {
            updateIconState("paused")
        } else {
            updateIconState("idle")
        }
    }

    private func refreshMenuTitles() {
        refreshPanelState()
    }

    private var isGUIProbeActive: Bool {
        ProcessInfo.processInfo.environment["B2OU_GUI_PROBE_REPORT"] != nil
    }
}

private struct B2OUGUIProbeStep: Codable {
    let name: String
    let passed: Bool
    let detail: String
}

private struct B2OUGUIProbeReport: Codable {
    let startedAt: String
    let finishedAt: String
    let steps: [B2OUGUIProbeStep]
}

private final class B2OUGUIProbeSession {
    let reportURL: URL
    let startedAt = ISO8601DateFormatter().string(from: Date())
    var steps: [B2OUGUIProbeStep] = []

    init(reportURL: URL) {
        self.reportURL = reportURL
    }
}

private extension AppDelegate {
    func maybeStartGUIProbe() {
        guard let rawPath = ProcessInfo.processInfo.environment["B2OU_GUI_PROBE_REPORT"],
              !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let rawFolders = ProcessInfo.processInfo.environment["B2OU_GUI_PICK_FOLDERS"] ?? ""
        guiProbeFolderQueue = rawFolders
            .replacingOccurrences(of: ":::", with: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guiProbeSession = B2OUGUIProbeSession(
            reportURL: URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        )
        installB2OUExternalActionRecorder(
            openHandler: { _ in },
            revealHandler: { _ in }
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.runGUIProbeStartup()
        }
    }

    func runGUIProbeStartup() {
        let exportedCount = exportedMarkdownFileCount(at: config?.exportPath)
        recordGUIProbeStep(
            "startup loads profile and exports notes",
            passed: config != nil && activeProfileName != nil && watcher != nil && exportedCount >= 2,
            detail: "profile=\(activeProfileName ?? "nil"), exported_markdown=\(exportedCount), watcher_note_count=\(watcher?.noteCount ?? 0)"
        )
        guard config != nil else {
            finishGUIProbe()
            return
        }

        runGUIProbeMenuExternalActions()
        runGUIProbeProfileMenu()
        runGUIProbeChangeFolderMenu()
        runGUIProbeExternalTargets()

        onConfigure()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.runGUIProbeSettingsWindow()
        }
    }

    func runGUIProbeSettingsWindow() {
        let titles = windowTitles()
        recordGUIProbeStep(
            "settings window opens",
            passed: titles.contains(t("settings.title")),
            detail: titles.joined(separator: " | ")
        )

        guard let cfg = config else {
            finishGUIProbe()
            return
        }
        let updatedMarkdownRoot = cfg.exportPath.deletingLastPathComponent().appendingPathComponent("export-md-updated")
        let expectedTextBundleRoot = cfg.exportPathTB?.path ?? ""
        let expectedFormat = cfg.exportFormat
        var updated = currentSettingsValues(from: cfg)
        updated.exportPath = updatedMarkdownRoot.path
        _ = applySettings(updated)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.runGUIProbeSettingsSave(
                expectedMarkdownRoot: updatedMarkdownRoot.path,
                expectedTextBundleRoot: expectedTextBundleRoot,
                expectedFormat: expectedFormat
            )
        }
    }

    func runGUIProbeSettingsSave(
        expectedMarkdownRoot: String,
        expectedTextBundleRoot: String,
        expectedFormat: String
    ) {
        let configMatches = config?.exportPath.path == expectedMarkdownRoot
            && config?.exportPathTB?.path == expectedTextBundleRoot
            && config?.exportFormat == expectedFormat
        recordGUIProbeStep(
            "settings save preserves non-folder profile rules",
            passed: configMatches,
            detail: "md=\(config?.exportPath.path ?? "nil"), tb=\(config?.exportPathTB?.path ?? "nil"), format=\(config?.exportFormat ?? "nil")"
        )
        guard configMatches else {
            finishGUIProbe()
            return
        }

        triggerExportNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.runGUIProbeManualExport(expectedMarkdownRoot: expectedMarkdownRoot)
        }
    }

    func runGUIProbeManualExport(expectedMarkdownRoot: String) {
        let exportedCount = exportedMarkdownFileCount(at: config?.exportPath)
        recordGUIProbeStep(
            "manual export reaches updated markdown root",
            passed: runtimeIssues.exportError == nil && config?.exportPath.path == expectedMarkdownRoot && exportedCount >= 2,
            detail: "export_error=\(runtimeIssues.exportError ?? "nil"), exported_markdown=\(exportedCount)"
        )

        onExportWorkspace()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runGUIProbeWorkspaceWindow()
        }
    }

    func runGUIProbeWorkspaceWindow() {
        let titles = windowTitles()
        recordGUIProbeStep(
            "workspace window opens with source-backed notes",
            passed: titles.contains(t("workspace.title")) && noteStore.notes.count >= 2,
            detail: "titles=\(titles.joined(separator: " | ")), notes=\(noteStore.notes.count)"
        )

        let noteCountBeforeRefresh = noteStore.notes.count
        scanAndShowWorkspace()
        let refreshed = noteStore.notes.count == noteCountBeforeRefresh && noteCountBeforeRefresh > 0
        recordGUIProbeStep(
            "workspace refresh keeps the reviewed note set available",
            passed: refreshed,
            detail: "before=\(noteCountBeforeRefresh), after=\(noteStore.notes.count)"
        )

        onConfigure()
        let preferencesVisible = windowTitles().contains(t("settings.title"))
        recordGUIProbeStep(
            "workspace preferences button routes back to settings",
            passed: preferencesVisible,
            detail: windowTitles().joined(separator: " | ")
        )

        let previousExportTime = manualLastExportTime
        exportAllFromWorkspace()
        let fullExportRan = manualLastExportTime != nil || watcher?.lastExportTime != nil || previousExportTime != nil
        recordGUIProbeStep(
            "workspace full-scope export stays runnable",
            passed: runtimeIssues.exportError == nil && fullExportRan,
            detail: "export_error=\(runtimeIssues.exportError ?? "nil"), last_export=\((manualLastExportTime ?? watcher?.lastExportTime)?.description ?? "nil")"
        )

        onDashboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.runGUIProbeDashboardWindow()
        }
    }

    func runGUIProbeDashboardWindow() {
        let titles = windowTitles()
        recordGUIProbeStep(
            "dashboard window opens",
            passed: titles.contains(t("dashboard.title")),
            detail: titles.joined(separator: " | ")
        )

        showNotePreview(store: noteStore, selecting: noteStore.notes.first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.runGUIProbeNoteBrowserWindow()
        }
    }

    func runGUIProbeNoteBrowserWindow() {
        let titles = windowTitles()
        recordGUIProbeStep(
            "note browser window opens",
            passed: titles.contains(t("preview.title")),
            detail: titles.joined(separator: " | ")
        )

        onSetChinese()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.runGUIProbeChineseRefresh()
        }
    }

    func runGUIProbeChineseRefresh() {
        let titles = windowTitles()
        let expected = [t("settings.title"), t("workspace.title"), t("dashboard.title"), t("preview.title")]
        let passed = expected.allSatisfy { titles.contains($0) }
        recordGUIProbeStep(
            "open windows refresh after switching to Chinese",
            passed: passed,
            detail: titles.joined(separator: " | ")
        )

        onSetEnglish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.runGUIProbeEnglishRefresh()
        }
    }

    func runGUIProbeEnglishRefresh() {
        let titles = windowTitles()
        let expected = [t("settings.title"), t("workspace.title"), t("dashboard.title"), t("preview.title")]
        let passed = expected.allSatisfy { titles.contains($0) }
        recordGUIProbeStep(
            "open windows refresh after switching back to English",
            passed: passed,
            detail: titles.joined(separator: " | ")
        )

        onTogglePause()
        let pausedState = isPaused
        onTogglePause()
        let resumedState = !isPaused
        recordGUIProbeStep(
            "pause and resume keep the watcher controllable",
            passed: pausedState && resumedState,
            detail: "paused_after_first_toggle=\(pausedState), paused_after_second_toggle=\(isPaused)"
        )

        runGUIProbeLoginItemToggle()

        runGUIProbeDeepExternalTargets()
        runGUIProbeMissingSourceLinkScenario()

        runGUIProbeSelectedExportAndValidation()
    }

    func runGUIProbeSelectedExportAndValidation() {
        guard let firstID = noteStore.notes.first?.bearId, !firstID.isEmpty, let cfg = config else {
            recordGUIProbeStep(
                "selected export keeps sidecar mappings intact",
                passed: false,
                detail: "missing selected Bear ID or config"
            )
            finishGUIProbe()
            return
        }

        exportSelectedNotes(bearIDs: [firstID])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            let distinctBearIDs = Set(readSyncState(exportPath: cfg.exportPath)?.bindings.map(\.bearID) ?? [])
            self.recordGUIProbeStep(
                "selected export keeps sidecar mappings intact",
                passed: self.runtimeIssues.exportError == nil && distinctBearIDs.count >= 2 && distinctBearIDs.contains(firstID),
                detail: "export_error=\(self.runtimeIssues.exportError ?? "nil"), mapped_ids=\(distinctBearIDs.sorted().joined(separator: ","))"
            )

            let validationIssue = validateSettingsInput(
                SettingsValidationInput(
                    exportPath: cfg.exportPath.path,
                    exportPathTB: cfg.exportPathTB?.path ?? "",
                    exportFormat: cfg.exportFormat,
                    backupInterval: 30,
                    backupPath: cfg.exportPath.path
                )
            )
            self.recordGUIProbeStep(
                "settings validation rejects backup/export path reuse",
                passed: validationIssue == .backupFolderConflictsWithExport,
                detail: "issue=\(validationIssue?.rawValue ?? "nil")"
            )
            self.finishGUIProbe()
        }
    }

    func currentSettingsValues(from cfg: ExportConfig) -> SettingsValues {
        SettingsValues(
            exportPath: cfg.exportPath.path,
            exportPathTB: cfg.exportPathTB?.path ?? "",
            exportFormat: cfg.exportFormat,
            yamlFrontMatter: cfg.yamlFrontMatter,
            tagFolders: cfg.makeTagFolders,
            hideTags: cfg.hideTags,
            autoStart: isLoginItem(),
            naming: cfg.naming,
            onDelete: cfg.onDelete,
            excludeTags: cfg.excludeTags.joined(separator: ", "),
            backupInterval: cfg.backupInterval,
            backupPath: cfg.backupPath?.path ?? "",
            backupMaxKeep: cfg.backupMaxKeep,
            bearSource: cfg.bearSource,
            bearCLIPath: cfg.bearCLIPath.path == defaultBearCLIPath.path ? "" : cfg.bearCLIPath.path,
            lastBackupSummary: formattedBackupSummary(for: cfg)
        )
    }

    func exportedMarkdownFileCount(at root: URL?) -> Int {
        guard let root else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension.lowercased() == "md" {
                count += 1
            }
        }
        return count
    }

    func windowTitles() -> [String] {
        NSApp.windows
            .map(\.title)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
    }

    func recordGUIProbeStep(_ name: String, passed: Bool, detail: String) {
        guiProbeSession?.steps.append(
            B2OUGUIProbeStep(
                name: name,
                passed: passed,
                detail: detail
            )
        )
    }

    func finishGUIProbe() {
        guard let session = guiProbeSession else { return }
        let report = B2OUGUIProbeReport(
            startedAt: session.startedAt,
            finishedAt: ISO8601DateFormatter().string(from: Date()),
            steps: session.steps
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? FileManager.default.createDirectory(
                at: session.reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: session.reportURL, options: .atomic)
        }
        guiProbeSession = nil
        resetB2OUExternalActionRecorder()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    func runGUIProbeMenuExternalActions() {
        guard let cfg = config else { return }
        captureExternalAction(
            "menu open folder targets the active export root",
            expectedKind: .open,
            expectedTargets: [cfg.exportPath.absoluteString]
        ) {
            onOpenFolder()
        }

        if let configURL = findConfig() {
            captureExternalAction(
                "menu edit config targets the resolved profile file",
                expectedKind: .open,
                expectedTargets: [configURL.absoluteString]
            ) {
                onEditConfig()
            }
        } else {
            recordGUIProbeStep(
                "menu edit config targets the resolved profile file",
                passed: false,
                detail: "config file not found"
            )
        }
    }

    func runGUIProbeProfileMenu() {
        let names = Set(profiles.keys)
        guard names.contains("secondary") else {
            recordGUIProbeStep(
                "profile menu can switch between configured profiles",
                passed: false,
                detail: "secondary profile missing from fixture"
            )
            return
        }

        setProfile("secondary")
        let switched = activeProfileName == "secondary"
        reloadProfiles()
        let reloaded = activeProfileName == "secondary"
        setProfile("default")
        let restored = activeProfileName == "default"
        recordGUIProbeStep(
            "profile menu can switch and reload profiles",
            passed: switched && reloaded && restored,
            detail: "switched=\(switched), reloaded=\(reloaded), restored=\(restored), profiles=\(profiles.keys.sorted().joined(separator: ","))"
        )
    }

    func runGUIProbeChangeFolderMenu() {
        guard let original = config else { return }
        let expectedNext = guiProbeFolderQueue.first
        onChangeFolder()
        let changed = expectedNext != nil && config?.exportPath.path == expectedNext
        let preserved = config?.exportFormat == original.exportFormat
            && config?.exportPathTB?.path == original.exportPathTB?.path
            && config?.onDelete == original.onDelete
            && config?.naming == original.naming
        recordGUIProbeStep(
            "menu change folder updates only the export root",
            passed: changed && preserved,
            detail: "changed_to=\(config?.exportPath.path ?? "nil"), preserved_rules=\(preserved)"
        )
    }

    func runGUIProbeExternalTargets() {
        captureExternalAction(
            "settings update link targets the releases page",
            expectedKind: .open,
            expectedTargets: [b2ouReleasesURL.absoluteString]
        ) {
            b2ouOpen(b2ouReleasesURL)
        }

        captureExternalAction(
            "settings project link targets the project page",
            expectedKind: .open,
            expectedTargets: [b2ouProjectPageURL.absoluteString]
        ) {
            b2ouOpen(b2ouProjectPageURL)
        }
    }

    func runGUIProbeDeepExternalTargets() {
        guard let note = noteStore.notes.first else { return }
        captureExternalAction(
            "dashboard and note browser export-file buttons target the selected file",
            expectedKind: .open,
            expectedTargets: [note.filePath.absoluteString]
        ) {
            b2ouOpen(note.filePath)
        }

        captureExternalAction(
            "note browser reveal button targets the selected file in Finder",
            expectedKind: .reveal,
            expectedTargets: [note.filePath.absoluteString]
        ) {
            b2ouReveal([note.filePath])
        }

        if let bearURL = b2ouBearNoteURL(noteID: note.bearId) {
            captureExternalAction(
                "note browser Bear button targets the callback URL",
                expectedKind: .open,
                expectedTargets: [bearURL.absoluteString]
            ) {
                b2ouOpen(bearURL)
            }
        } else {
            recordGUIProbeStep(
                "note browser Bear button targets the callback URL",
                passed: false,
                detail: "selected note did not produce a Bear callback URL"
            )
        }
    }

    func runGUIProbeMissingSourceLinkScenario() {
        guard let cfg = config else { return }
        let stateURL = syncStateURL(exportPath: cfg.exportPath)
        let originalStateData = try? Data(contentsOf: stateURL)
        try? FileManager.default.removeItem(at: stateURL)
        noteStore.scan(exportPath: cfg.exportPath)
        showWorkspaceFromCurrentState()
        let hasMissingLinks = notesContainMissingSourceLinks(noteStore.notes)
        if let originalStateData {
            try? FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? originalStateData.write(to: stateURL, options: .atomic)
        }
        recordGUIProbeStep(
            "workspace rebuild button appears when notes lose source links",
            passed: hasMissingLinks,
            detail: "notes=\(noteStore.notes.count), missing_links=\(hasMissingLinks)"
        )
        noteStore.scan(config: cfg, allowExportFallback: false)
    }

    func runGUIProbeLoginItemToggle() {
        let original = isLoginItem()
        let toggled = setLoginItemEnabled(!original, presentAlert: false)
        let restored = setLoginItemEnabled(original, presentAlert: false)
        let effectiveOriginal = isLoginItem()
        recordGUIProbeStep(
            "start-at-login toggle can round-trip and restore the original state",
            passed: toggled.effectiveEnabled == !original
                && toggled.errorMessage == nil
                && restored.effectiveEnabled == original
                && restored.errorMessage == nil
                && effectiveOriginal == original,
            detail: "original=\(original), toggled=\(toggled.effectiveEnabled), restored=\(restored.effectiveEnabled), final=\(effectiveOriginal), toggle_error=\(toggled.errorMessage ?? "nil"), restore_error=\(restored.errorMessage ?? "nil")"
        )
    }

    func captureExternalAction(
        _ name: String,
        expectedKind: B2OUExternalActionKind,
        expectedTargets: [String],
        perform action: () -> Void
    ) {
        let before = currentB2OUExternalActionRecords().count
        action()
        let records = currentB2OUExternalActionRecords()
        guard records.count > before else {
            recordGUIProbeStep(name, passed: false, detail: "no external action was recorded")
            return
        }
        let record = records[before]
        let passed = record.kind == expectedKind && record.targets == expectedTargets
        recordGUIProbeStep(
            name,
            passed: passed,
            detail: "kind=\(record.kind.rawValue), targets=\(record.targets.joined(separator: " | "))"
        )
    }
}

// MARK: - Export Watcher (background thread)

class ExportWatcher {
    private static let backupAttachmentStoreName = ".attachment-store"
    private static let interruptedBackupGrace: TimeInterval = 30 * 60

    private let config: ExportConfig
    private let onUpdate: ((ExportWatcherUpdate) -> Void)?
    private let lock = NSLock()
    private var _running = false
    private var _paused = false
    private var thread: Thread?
    private var _lastExportTime: Date?
    private var _noteCount = 0
    private var _lastBackupTime: Date?
    private var _lastBackupAttemptTime: Date?
    private var _isExporting = false

    var lastExportTime: Date? { lock.lock(); defer { lock.unlock() }; return _lastExportTime }
    var noteCount: Int { lock.lock(); defer { lock.unlock() }; return _noteCount }
    var lastBackupTime: Date? { lock.lock(); defer { lock.unlock() }; return _lastBackupTime }
    var isExporting: Bool { lock.lock(); defer { lock.unlock() }; return _isExporting }

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); defer { lock.unlock() }; _paused = newValue }
    }

    private var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); defer { lock.unlock() }; _running = newValue }
    }

    private func beginExporting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_isExporting else { return false }
        _isExporting = true
        return true
    }

    private func setExporting(_ exporting: Bool) {
        lock.lock()
        _isExporting = exporting
        lock.unlock()
    }

    private func reportUpdate(_ operation: ExportWatcherOperation, errorMessage: String?) {
        onUpdate?(ExportWatcherUpdate(
            noteCount: noteCount,
            operation: operation,
            errorMessage: errorMessage
        ))
    }

    init(config: ExportConfig, onUpdate: ((ExportWatcherUpdate) -> Void)? = nil) {
        self.config = config
        self.onUpdate = onUpdate
        restorePersistedStatus()
    }

    func start() {
        guard !running else { return }
        running = true
        thread = Thread { [weak self] in self?.loop() }
        thread?.start()
    }

    func stop() { running = false }

    func exportNow() {
        Thread.detachNewThread { [weak self] in
            autoreleasepool { _ = self?.doExport() }
        }
    }

    private func loop() {
        var lastSignature = (lastModified: 0.0, byteCount: Int64(-1))
        var lastExportUnix: Double = 0
        var consecutiveFailures = 0
        var idleSleep = 2.0
        let idleMax = 30.0

        while running {
            let shouldSleep: Bool = autoreleasepool {
                // Check scheduled backup (runs even when paused to maintain schedule)
                checkScheduledBackup()

                if !paused {
                    let sig = sourceSignature(config: config)
                    if sig == lastSignature || sig.byteCount < 0 {
                        Thread.sleep(forTimeInterval: idleSleep)
                        idleSleep = min(idleMax, idleSleep * 1.5)
                        return false
                    }
                    idleSleep = 2.0

                    let interval = 10.0 * pow(2.0, Double(min(consecutiveFailures, 4)))
                    let elapsed = Date().timeIntervalSince1970 - lastExportUnix
                    if lastExportUnix > 0 && elapsed < interval {
                        Thread.sleep(forTimeInterval: min(2.0, interval - elapsed))
                        return false
                    }

                    if lastSignature.byteCount >= 0 {
                        var waited = 0.0
                        while running && waited < 9 {
                            if sourceIsQuiet(config: config, quietSeconds: 3.0) { break }
                            Thread.sleep(forTimeInterval: 1.0)
                            waited += 1.0
                        }
                    }

                    if doExport() {
                        consecutiveFailures = 0
                    } else {
                        consecutiveFailures += 1
                    }
                    lastSignature = sourceSignature(config: config)
                    lastExportUnix = Date().timeIntervalSince1970
                }
                return true
            }
            if shouldSleep {
                Thread.sleep(forTimeInterval: 2.0)
            }
        }
    }

    // MARK: - Scheduled Backup

    private func checkScheduledBackup() {
        guard config.backupInterval > 0 else { return }

        let intervalSecs = TimeInterval(config.backupInterval * 60)
        let now = Date()
        guard markBackupAttemptIfDue(now: now, intervalSecs: intervalSecs) else { return }

        let backupDir = config.backupPath ?? config.exportPath.appendingPathComponent(".b2ou-backups")
        guard !backupConflictsWithExportRoots(backupDir, exportRoots: (try? config.splitExportConfigs().map(\.exportPath)) ?? [config.exportPath]) else {
            reportUpdate(.backup, errorMessage: t("menu.backup_folder_conflict"))
            return
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        // Restrictive permissions on backup directory
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir.path)

        guard let lockFd = acquireBackupLock(in: backupDir) else { return }
        defer { releaseBackupLock(lockFd) }
        cleanupInterruptedBackupsExtended(in: backupDir)
        pruneAttachmentStore(in: backupDir)

        if shouldReadWithBearCLI(config: config) {
            do {
                try createBearCLIBackup(in: backupDir, now: now)
                lock.lock()
                _lastBackupTime = now
                lock.unlock()
                _ = rotateBackups(in: backupDir, maxKeep: config.backupMaxKeep)
                pruneAttachmentStore(in: backupDir)
                reportUpdate(.backup, errorMessage: nil)
                return
            } catch {
                if config.bearSource.lowercased() == "bearcli" {
                    reportUpdate(.backup, errorMessage: backupFailureMessage(error))
                    return
                }
            }
        }

        let destPath = makeBackupURL(in: backupDir)
        let tmpPath = backupDir.appendingPathComponent(".\(destPath.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            let conn = try SQLiteConnection(path: config.bearDB.path, readOnly: true)
            try conn.backupTo(tmpPath.path)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath.path)
            try fm.moveItem(at: tmpPath, to: destPath)
            if !isNonEmptyFile(at: destPath, minimumBytes: 512) {
                try? fm.removeItem(at: destPath)
                throw NSError(
                    domain: "B2OUBackup",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Verified SQLite backup is empty or too small"]
                )
            }
            lock.lock()
            _lastBackupTime = now
            lock.unlock()
            _ = rotateBackups(in: backupDir, maxKeep: config.backupMaxKeep)
            pruneAttachmentStore(in: backupDir)
            reportUpdate(.backup, errorMessage: nil)
        } catch {
            try? fm.removeItem(at: tmpPath)
            reportUpdate(.backup, errorMessage: backupFailureMessage(error))
        }
    }

    private func markBackupAttemptIfDue(now: Date, intervalSecs: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let last = [_lastBackupTime, _lastBackupAttemptTime].compactMap { $0 }.max()
        if let last, now.timeIntervalSince(last) < intervalSecs {
            return false
        }
        _lastBackupAttemptTime = now
        return true
    }

    private func makeBackupURL(in dir: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss_SSS"
        let stamp = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8))
        return dir.appendingPathComponent("bear-backup-\(stamp)-\(suffix).sqlite")
    }

    private func makeBearCLIBackupURL(in dir: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss_SSS"
        let stamp = formatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8))
        return dir.appendingPathComponent("bear-backup-\(stamp)-\(suffix).bearclibackup")
    }

    private func backupFailureMessage(_ error: Error) -> String {
        t("menu.backup_failed").replacingOccurrences(of: "{error}", with: error.localizedDescription)
    }

    private func createBearCLIBackup(in backupDir: URL, now: Date) throws {
        let fm = FileManager.default
        let client = BearCLIClient(executable: config.bearCLIPath)
        let destPath = makeBearCLIBackupURL(in: backupDir)
        let tmpPath = backupDir.appendingPathComponent(".\(destPath.lastPathComponent).tmp-\(UUID().uuidString)")
        let notesPath = tmpPath.appendingPathComponent("notes.json")
        let attachmentsPath = tmpPath.appendingPathComponent("attachments.json")
        let storeRoot = backupDir.appendingPathComponent(Self.backupAttachmentStoreName)
        let incomingRoot = storeRoot.appendingPathComponent(".incoming").appendingPathComponent(UUID().uuidString)

        try fm.createDirectory(at: tmpPath, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpPath.path)
        try fm.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeRoot.path)
        defer { try? fm.removeItem(at: incomingRoot) }

        do {
            try client.writeNotesSnapshot(location: "all", to: notesPath)
            let index = try client.noteAttachmentIndex(location: "all")
            var attachmentCount = 0
            var attachmentsIndex: [BearCLIBackupAttachmentRecord] = []

            for note in index {
                let attachments: [BearCLIAttachment]
                if note.needsAttachmentListRefresh {
                    attachments = (try? client.listAttachments(noteID: note.id)) ?? note.attachments
                } else {
                    attachments = note.attachments
                }

                for attachment in attachments {
                    let filename = (attachment.filename as NSString).lastPathComponent
                    guard !filename.isEmpty else { continue }
                    let incoming = incomingRoot.appendingPathComponent(UUID().uuidString)
                    try client.saveAttachment(noteID: note.id, filename: attachment.filename, to: incoming)
                    let fingerprint = fileFingerprint(incoming)
                    guard !fingerprint.hash.isEmpty else {
                        try? fm.removeItem(at: incoming)
                        continue
                    }

                    let stored = attachmentStoreURL(for: fingerprint.hash, in: storeRoot)
                    try fm.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: stored.path) {
                        try? fm.removeItem(at: incoming)
                    } else {
                        try fm.moveItem(at: incoming, to: stored)
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stored.path)
                    }

                    attachmentsIndex.append(BearCLIBackupAttachmentRecord(
                        noteID: note.id,
                        filename: filename,
                        originalFilename: attachment.filename,
                        size: attachment.size ?? fingerprint.size,
                        sha256: fingerprint.hash,
                        storePath: syncRelativePath(from: backupDir, to: stored)
                    ))
                    attachmentCount += 1
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let attachmentData = try encoder.encode(attachmentsIndex.sorted {
                if $0.noteID == $1.noteID { return $0.filename < $1.filename }
                return $0.noteID < $1.noteID
            })
            try attachmentData.write(to: attachmentsPath, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: attachmentsPath.path)

            let iso = ISO8601DateFormatter()
            let manifest: [String: Any] = [
                "format": "b2ou-bearcli-backup",
                "version": 2,
                "created": iso.string(from: now),
                "bearcli": config.bearCLIPath.path,
                "notes_location": "all",
                "attachment_count": attachmentCount,
                "attachments_index": "attachments.json",
                "attachment_storage": "deduplicated-store",
                "attachment_store": Self.backupAttachmentStoreName,
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: tmpPath.appendingPathComponent("manifest.json"), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpPath.appendingPathComponent("manifest.json").path)

            try fm.moveItem(at: tmpPath, to: destPath)
            guard
                fm.fileExists(atPath: destPath.appendingPathComponent("manifest.json").path),
                fm.fileExists(atPath: destPath.appendingPathComponent("notes.json").path)
            else {
                try? fm.removeItem(at: destPath)
                throw NSError(
                    domain: "B2OUBackup",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Bear CLI backup bundle is incomplete"]
                )
            }
        } catch {
            try? fm.removeItem(at: tmpPath)
            pruneAttachmentStore(in: backupDir)
            throw error
        }
    }

    private func isNonEmptyFile(at url: URL, minimumBytes: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value >= minimumBytes
    }

    private func restorePersistedStatus() {
        let exportTimes = ((try? config.splitExportConfigs()) ?? [config]).compactMap { cfg -> Date? in
            let attrs = try? FileManager.default.attributesOfItem(atPath: cfg.exportTsFile.path)
            return attrs?[.modificationDate] as? Date
        }
        _lastExportTime = exportTimes.max()

        let backupDir = config.backupPath ?? config.exportPath.appendingPathComponent(".b2ou-backups")
        _lastBackupTime = latestBackupTime(in: backupDir)
    }

    private func cleanupInterruptedBackupsExtended(in dir: URL) {
        _ = cleanupInterruptedBackups(in: dir)
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.interruptedBackupGrace)
        let incoming = dir.appendingPathComponent(Self.backupAttachmentStoreName).appendingPathComponent(".incoming")
        guard let incomingDirs = try? fm.contentsOfDirectory(
            at: incoming,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        for url in incomingDirs {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func attachmentStoreURL(for hash: String, in storeRoot: URL) -> URL {
        let prefix = String(hash.prefix(2))
        return storeRoot.appendingPathComponent(prefix).appendingPathComponent(hash)
    }

    private func pruneAttachmentStore(in dir: URL) {
        let fm = FileManager.default
        let storeRoot = dir.appendingPathComponent(Self.backupAttachmentStoreName)
        guard fm.fileExists(atPath: storeRoot.path) else { return }

        var referenced = Set<String>()
        for backup in completeBackupURLs(in: dir) where backup.pathExtension == "bearclibackup" {
            let indexURL = backup.appendingPathComponent("attachments.json")
            guard let data = try? Data(contentsOf: indexURL),
                  let records = try? JSONDecoder().decode([BearCLIBackupAttachmentRecord].self, from: data) else {
                continue
            }
            referenced.formUnion(records.map(\.sha256))
        }

        guard let enumerator = fm.enumerator(
            at: storeRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return }

        var directories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if url.lastPathComponent == ".incoming" {
                    enumerator.skipDescendants()
                } else {
                    directories.append(url)
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if !referenced.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }

        for dirURL in directories.sorted(by: { $0.path > $1.path }) {
            if (try? fm.contentsOfDirectory(atPath: dirURL.path).isEmpty) == true {
                try? fm.removeItem(at: dirURL)
            }
        }
    }


    @discardableResult
    private func doExport() -> Bool {
        guard beginExporting() else { return true }
        reportUpdate(.export, errorMessage: nil)

        var errorMsg: String? = nil
        defer {
            setExporting(false)
            reportUpdate(.export, errorMessage: errorMsg)
        }

        do {
            let configs = try config.splitExportConfigs()
            var totalCount = 0
            for cfg in configs {
                try? FileManager.default.createDirectory(at: cfg.exportPath, withIntermediateDirectories: true)
                let result = exportNotes(config: cfg)
                guard result.changedCount >= 0 else {
                    throw B2OUError.exportLocked(cfg.exportPath)
                }
                if result.hasConflicts {
                    throw B2OUError.dirtyExportFiles(result.conflictPaths.sorted { $0.path < $1.path })
                }
                writeTimestamps(config: cfg)
                var removed = 0
                if cfg.onlyNoteUUIDs.isEmpty {
                    removed = cleanupStaleNotes(
                        exportPath: cfg.exportPath,
                        expectedPaths: result.expectedPaths,
                        onDelete: cfg.onDelete
                    )
                    writeManifest(exportPath: cfg.exportPath, paths: result.expectedPaths)
                }
                if result.changedCount > 0 || removed > 0 {
                    if maintenanceDue(exportPath: cfg.exportPath) {
                        if cfg.exportImageRepository { _ = cleanupOrphanRootImages(config: cfg) }
                        _ = purgeOldTrash(exportPath: cfg.exportPath)
                        touchMaintenance(exportPath: cfg.exportPath)
                    }
                }
                totalCount = max(totalCount, result.noteCount)
            }
            lock.lock()
            defer { lock.unlock() }
            _noteCount = totalCount
            _lastExportTime = Date()
        } catch {
            errorMsg = error.localizedDescription
        }

        return errorMsg == nil
    }
}

private struct BearCLIBackupAttachmentRecord: Codable {
    let noteID: String
    let filename: String
    let originalFilename: String
    let size: Int64
    let sha256: String
    let storePath: String

    private enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case filename
        case originalFilename = "original_filename"
        case size
        case sha256
        case storePath = "store_path"
    }
}

// MARK: - Entry Point

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // Menu bar only, no Dock icon
        app.run()
    }
}
