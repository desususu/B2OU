// MenuBarApp.swift — Native macOS menu-bar application for B2OU.
//
// This replaces both the Python/rumps menu bar AND the old Swift shell-out
// approach. All export logic is now called in-process via B2OUCore.

import Cocoa
import B2OUCore

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    // Menu items (kept for dynamic updates)
    private var statusMenuItem: NSMenuItem!
    private var lastExportMenuItem: NSMenuItem!
    private var exportNowItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var openFolderItem: NSMenuItem!
    private var profileMenu: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var changeFolderItem: NSMenuItem!
    private var configureItem: NSMenuItem!
    private var editConfigItem: NSMenuItem!
    private var langEnItem: NSMenuItem!
    private var langZhItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    // Dashboard / Preview
    private var dashboardItem: NSMenuItem!
    private var browseItem: NSMenuItem!

    // State
    private var config: ExportConfig?
    private var profiles: [String: ExportConfig] = [:]
    private var activeProfileName: String?
    private var watcher: ExportWatcher?
    private var isPaused = false
    private var statusTimer: Timer?
    private var noteStore = NoteStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = initLanguage()
        setupStatusItem()
        buildMenu()

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
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let iconPath = resolveIcon("menubar"),
               let image = NSImage(contentsOfFile: iconPath) {
                image.size = NSSize(width: 18, height: 18)
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "\u{1F43B}" // Bear emoji fallback
            }
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

    // MARK: - Menu Construction

    private func buildMenu() {
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: t("menu.starting"), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastExportMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastExportMenuItem.isEnabled = false
        menu.addItem(lastExportMenuItem)

        menu.addItem(.separator())

        exportNowItem = NSMenuItem(title: t("menu.export_now"), action: #selector(onExportNow), keyEquivalent: "e")
        exportNowItem.target = self
        menu.addItem(exportNowItem)

        pauseItem = NSMenuItem(title: t("menu.pause"), action: #selector(onTogglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        openFolderItem = NSMenuItem(title: t("menu.open_folder"), action: #selector(onOpenFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        dashboardItem = NSMenuItem(title: t("menu.dashboard"), action: #selector(onDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        menu.addItem(dashboardItem)

        browseItem = NSMenuItem(title: t("menu.browse_notes"), action: #selector(onBrowseNotes), keyEquivalent: "b")
        browseItem.target = self
        menu.addItem(browseItem)

        menu.addItem(.separator())

        // Profile submenu
        profileMenu = NSMenuItem(title: t("menu.profile"), action: nil, keyEquivalent: "")
        profileMenu.submenu = NSMenu()
        menu.addItem(profileMenu)

        loginItem = NSMenuItem(title: t("menu.start_at_login"), action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItem() ? .on : .off
        menu.addItem(loginItem)

        changeFolderItem = NSMenuItem(title: t("menu.change_folder"), action: #selector(onChangeFolder), keyEquivalent: "")
        changeFolderItem.target = self
        menu.addItem(changeFolderItem)

        configureItem = NSMenuItem(title: t("menu.configure"), action: #selector(onConfigure), keyEquivalent: ",")
        configureItem.target = self
        menu.addItem(configureItem)

        editConfigItem = NSMenuItem(title: t("menu.edit_config"), action: #selector(onEditConfig), keyEquivalent: "")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        menu.addItem(.separator())

        // Language submenu
        let langMenu = NSMenuItem(title: t("menu.language"), action: nil, keyEquivalent: "")
        let langSubmenu = NSMenu()

        langEnItem = NSMenuItem(title: t("lang.en"), action: #selector(onSetEnglish), keyEquivalent: "")
        langEnItem.target = self
        langEnItem.state = getLanguage() == "en" ? .on : .off
        langSubmenu.addItem(langEnItem)

        langZhItem = NSMenuItem(title: t("lang.zh"), action: #selector(onSetChinese), keyEquivalent: "")
        langZhItem.target = self
        langZhItem.state = getLanguage() == "zh" ? .on : .off
        langSubmenu.addItem(langZhItem)

        langMenu.submenu = langSubmenu
        menu.addItem(langMenu)

        menu.addItem(.separator())

        quitItem = NSMenuItem(title: t("menu.quit"), action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Profile Management

    private func reloadProfiles() {
        profiles = loadProfiles()
        let submenu = NSMenu()

        if profiles.isEmpty {
            let setupItem = NSMenuItem(title: t("menu.setup"), action: #selector(onSetup), keyEquivalent: "")
            setupItem.target = self
            submenu.addItem(setupItem)
        } else {
            for name in profiles.keys.sorted() {
                let item = NSMenuItem(title: name, action: #selector(onSelectProfile(_:)), keyEquivalent: "")
                item.target = self
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let reloadItem = NSMenuItem(title: t("menu.reload"), action: #selector(onReloadProfiles), keyEquivalent: "")
            reloadItem.target = self
            submenu.addItem(reloadItem)
        }

        profileMenu.submenu = submenu

        // Re-select the active profile (picks up any config changes from disk)
        if let name = activeProfileName, profiles[name] != nil {
            setProfile(name)
        } else if let firstName = profiles.keys.sorted().first {
            setProfile(firstName)
        }
    }

    private func setProfile(_ name: String) {
        guard let cfg = profiles[name] else { return }
        config = cfg
        activeProfileName = name

        if let submenu = profileMenu.submenu {
            for item in submenu.items {
                item.state = item.title == name ? .on : .off
            }
        }

        updateStatus()
        if watcher != nil { watcher?.stop() }
        startWatcher()
    }

    // MARK: - Export Watcher

    private func startWatcher() {
        guard let cfg = config else { return }
        watcher = ExportWatcher(config: cfg) { [weak self] noteCount, error in
            DispatchQueue.main.async {
                self?.updateStatus()
            }
        }
        watcher?.start()
    }

    private func updateStatus() {
        guard let cfg = config else {
            statusMenuItem.title = t("menu.no_profile")
            lastExportMenuItem.title = ""
            return
        }

        if let watcher, watcher.noteCount > 0 {
            statusMenuItem.title = t("menu.notes_exported")
                .replacingOccurrences(of: "{count}", with: "\(watcher.noteCount)")
        } else {
            statusMenuItem.title = t("menu.exporting_to")
                .replacingOccurrences(of: "{folder}", with: cfg.exportPath.lastPathComponent)
        }

        if let watcher, let lastExport = watcher.lastExportTime {
            let ago = Date().timeIntervalSince(lastExport)
            let timeStr: String
            if ago < 60 {
                timeStr = t("menu.just_now")
            } else if ago < 3600 {
                timeStr = t("menu.min_ago").replacingOccurrences(of: "{mins}", with: "\(Int(ago / 60))")
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                timeStr = formatter.string(from: lastExport)
            }
            var statusLine = t("menu.last_export").replacingOccurrences(of: "{time}", with: timeStr)
            if let lastBackup = watcher.lastBackupTime {
                let backupAgo = Date().timeIntervalSince(lastBackup)
                let backupStr: String
                if backupAgo < 60 {
                    backupStr = t("menu.just_now")
                } else if backupAgo < 3600 {
                    backupStr = t("menu.min_ago").replacingOccurrences(of: "{mins}", with: "\(Int(backupAgo / 60))")
                } else {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "HH:mm"
                    backupStr = fmt.string(from: lastBackup)
                }
                statusLine += "  \u{2022}  " + t("menu.last_backup").replacingOccurrences(of: "{time}", with: backupStr)
            }
            lastExportMenuItem.title = statusLine
        } else {
            lastExportMenuItem.title = ""
        }
    }

    // MARK: - Actions

    @objc private func onExportNow() {
        if config == nil { runSetupWizard(); return }
        watcher?.exportNow()
    }

    @objc private func onTogglePause() {
        guard let watcher else { return }
        isPaused.toggle()
        watcher.paused = isPaused
        pauseItem.title = isPaused ? t("menu.resume") : t("menu.pause")
        updateIconState(isPaused ? "paused" : "idle")
    }

    @objc private func onOpenFolder() {
        guard let cfg = config else { runSetupWizard(); return }
        NSWorkspace.shared.open(cfg.exportPath)
    }

    @objc private func onDashboard() {
        guard config != nil else { runSetupWizard(); return }
        scanAndRun { [weak self] in
            guard let self else { return }
            showDashboard(store: self.noteStore)
        }
    }

    @objc private func onBrowseNotes() {
        guard config != nil else { runSetupWizard(); return }
        scanAndRun { [weak self] in
            guard let self else { return }
            showNotePreview(store: self.noteStore)
        }
    }

    private func scanAndRun(_ action: @escaping () -> Void) {
        guard let cfg = config else { return }
        Thread.detachNewThread { [weak self] in
            self?.noteStore.scan(exportPath: cfg.exportPath)
            DispatchQueue.main.async { action() }
        }
    }

    @objc private func onSetup() { runSetupWizard() }

    @objc private func onSelectProfile(_ sender: NSMenuItem) {
        setProfile(sender.title)
    }

    @objc private func onReloadProfiles() { reloadProfiles() }

    @objc private func onToggleLogin() {
        if loginItem.state == .on {
            _ = removeLoginItem()
            loginItem.state = .off
        } else {
            _ = addLoginItem()
            loginItem.state = .on
        }
    }

    @objc private func onChangeFolder() {
        guard let path = pickFolder(prompt: t("wizard.pick_advanced")) else { return }
        writeConfigFile(exportPath: path)
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
            backupPath: cfg.backupPath?.path ?? ""
        )

        showSettingsPanel(
            values: vals,
            onApply: { [weak self] applied in
                self?.applySettings(applied)
            },
            onChangeFolder: { [weak self] in
                self?.pickFolder(prompt: t("wizard.pick_prompt"))
            }
        )
    }

    private func applySettings(_ v: SettingsValues) {
        let excludeList: [String] = v.excludeTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        writeConfigFile(
            exportPath: v.exportPath,
            exportFormat: v.exportFormat,
            exportPathTB: v.exportFormat == "both" ? v.exportPathTB : nil,
            yamlFrontMatter: v.yamlFrontMatter,
            hideTags: v.hideTags,
            tagFolders: v.tagFolders,
            onDelete: v.onDelete,
            naming: v.naming,
            excludeTags: excludeList.isEmpty ? nil : excludeList,
            backupInterval: v.backupInterval,
            backupPath: v.backupPath.isEmpty ? nil : v.backupPath
        )

        // Handle login item
        if v.autoStart {
            _ = addLoginItem()
            loginItem.state = .on
        } else {
            _ = removeLoginItem()
            loginItem.state = .off
        }

        reloadProfiles()

        // Confirmation alert
        let alert = NSAlert()
        alert.messageText = t("settings.applied_title")
        if v.exportFormat == "both" {
            alert.informativeText = t("settings.applied_msg_both")
                .replacingOccurrences(of: "{path_md}", with: v.exportPath)
                .replacingOccurrences(of: "{path_tb}", with: v.exportPathTB)
        } else {
            alert.informativeText = t("settings.applied_msg")
                .replacingOccurrences(of: "{path}", with: v.exportPath)
        }
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func onEditConfig() {
        if let configPath = findConfig() {
            NSWorkspace.shared.open(configPath)
        } else {
            runSetupWizard()
        }
    }

    @objc private func onSetEnglish() {
        setLanguage("en")
        langEnItem.state = .on
        langZhItem.state = .off
        refreshMenuTitles()
    }

    @objc private func onSetChinese() {
        setLanguage("zh")
        langEnItem.state = .off
        langZhItem.state = .on
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
        alert.messageText = t("wizard.welcome_title")
        alert.informativeText = t("wizard.welcome_msg")
        alert.addButton(withTitle: t("wizard.quick"))
        alert.addButton(withTitle: t("wizard.advanced"))
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
        alert.messageText = t("wizard.quick_title")
        alert.informativeText = t("wizard.quick_msg")
        alert.addButton(withTitle: t("wizard.choose_folder"))
        alert.runModal()

        guard let path = pickFolder(prompt: t("wizard.pick_prompt")) else {
            let cancel = NSAlert()
            cancel.messageText = t("wizard.cancelled_title")
            cancel.informativeText = t("wizard.cancelled_msg")
            cancel.runModal()
            return
        }

        writeConfigFile(exportPath: path)
        _ = addLoginItem()
        loginItem.state = .on

        reloadProfiles()

        let done = NSAlert()
        done.messageText = "B2OU — " + t("wizard.ready")
        done.informativeText = t("wizard.ready_msg").replacingOccurrences(of: "{path}", with: path)
        done.alertStyle = .informational
        done.runModal()
    }

    private func wizardAdvanced() {
        guard let path = pickFolder(prompt: t("wizard.pick_advanced")) else {
            let cancel = NSAlert()
            cancel.messageText = t("wizard.cancelled_title")
            cancel.informativeText = t("wizard.cancelled_msg")
            cancel.runModal()
            return
        }

        writeConfigFile(exportPath: path)
        reloadProfiles()
    }

    // MARK: - Helpers

    private func pickFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func writeConfigFile(
        exportPath: String,
        exportFormat: String = "md",
        exportPathTB: String? = nil,
        yamlFrontMatter: Bool = false,
        hideTags: Bool = false,
        tagFolders: Bool = false,
        onDelete: String = "trash",
        naming: String = "title",
        excludeTags: [String]? = nil,
        backupInterval: Int = 0,
        backupPath: String? = nil
    ) {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/b2ou")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configFile = configDir.appendingPathComponent("b2ou.toml")

        var lines = [
            "# B2OU \u{2014} Bear note export configuration",
            "",
            "[profile.default]",
            "out = \"\(tomlEscape(exportPath))\"",
            "format = \"\(tomlEscape(exportFormat))\"",
            "on-delete = \"\(tomlEscape(onDelete))\"",
            "naming = \"\(tomlEscape(naming))\"",
        ]
        if exportFormat == "both", let tb = exportPathTB {
            lines.append("out-tb = \"\(tomlEscape(tb))\"")
        }
        if yamlFrontMatter { lines.append("yaml-front-matter = true") }
        if hideTags { lines.append("hide-tags = true") }
        if tagFolders { lines.append("tag-folders = true") }
        if let tags = excludeTags, !tags.isEmpty {
            let tagsStr = tags.map { "\"\(tomlEscape($0))\"" }.joined(separator: ", ")
            lines.append("exclude-tags = [\(tagsStr)]")
        }
        if backupInterval > 0 {
            lines.append("backup-interval = \(backupInterval)")
        }
        if let bp = backupPath, !bp.isEmpty {
            lines.append("backup-path = \"\(tomlEscape(bp))\"")
        }
        lines.append("")

        try? lines.joined(separator: "\n").write(to: configFile, atomically: true, encoding: .utf8)
    }

    private func tomlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func updateIconState(_ state: String) {
        guard let button = statusItem.button else { return }
        switch state {
        case "paused":
            if let path = resolveIcon("menubar_paused"), let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "\u{275A}\u{275A}"
            }
        case "error":
            button.title = "\u{26A0}\u{FE0E}"
        default: // idle
            if let path = resolveIcon("menubar"), let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "\u{1F43B}"
            }
        }
    }

    private func refreshMenuTitles() {
        statusMenuItem.title = t("menu.starting")
        exportNowItem.title = t("menu.export_now")
        pauseItem.title = isPaused ? t("menu.resume") : t("menu.pause")
        openFolderItem.title = t("menu.open_folder")
        dashboardItem.title = t("menu.dashboard")
        browseItem.title = t("menu.browse_notes")
        profileMenu.title = t("menu.profile")
        loginItem.title = t("menu.start_at_login")
        changeFolderItem.title = t("menu.change_folder")
        configureItem.title = t("menu.configure")
        editConfigItem.title = t("menu.edit_config")
        langEnItem.title = t("lang.en")
        langZhItem.title = t("lang.zh")
        quitItem.title = t("menu.quit")
        updateStatus()

        // Rebuild profile submenu labels without restarting the watcher
        let submenu = NSMenu()
        if profiles.isEmpty {
            let setupItem = NSMenuItem(title: t("menu.setup"), action: #selector(onSetup), keyEquivalent: "")
            setupItem.target = self
            submenu.addItem(setupItem)
        } else {
            for name in profiles.keys.sorted() {
                let item = NSMenuItem(title: name, action: #selector(onSelectProfile(_:)), keyEquivalent: "")
                item.target = self
                item.state = name == activeProfileName ? .on : .off
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let reloadItem = NSMenuItem(title: t("menu.reload"), action: #selector(onReloadProfiles), keyEquivalent: "")
            reloadItem.target = self
            submenu.addItem(reloadItem)
        }
        profileMenu.submenu = submenu
    }
}

// MARK: - Export Watcher (background thread)

class ExportWatcher {
    private let config: ExportConfig
    private let onUpdate: ((Int, String?) -> Void)?
    private let lock = NSLock()
    private var _running = false
    private var _paused = false
    private var thread: Thread?
    private var _lastExportTime: Date?
    private var _noteCount = 0
    private var _lastBackupTime: Date?

    var lastExportTime: Date? { lock.lock(); defer { lock.unlock() }; return _lastExportTime }
    var noteCount: Int { lock.lock(); defer { lock.unlock() }; return _noteCount }
    var lastBackupTime: Date? { lock.lock(); defer { lock.unlock() }; return _lastBackupTime }

    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _paused }
        set { lock.lock(); _paused = newValue; lock.unlock() }
    }

    private var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }

    init(config: ExportConfig, onUpdate: ((Int, String?) -> Void)? = nil) {
        self.config = config
        self.onUpdate = onUpdate
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
        var lastSignature: (Double, Int) = (0.0, -1)
        var lastExportUnix: Double = 0
        var consecutiveFailures = 0
        var idleSleep = 2.0
        let idleMax = 30.0

        while running {
            let shouldSleep: Bool = autoreleasepool {
                // Check scheduled backup (runs even when paused to maintain schedule)
                checkScheduledBackup()

                if !paused {
                    let sig = bearDBSignature(dbPath: config.bearDB)
                    if sig == lastSignature || sig.noteCount < 0 {
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

                    if lastSignature.1 >= 0 {
                        var waited = 0.0
                        while running && waited < 9 {
                            if dbIsQuiet(dbPath: config.bearDB, quietSeconds: 3.0) { break }
                            Thread.sleep(forTimeInterval: 1.0)
                            waited += 1.0
                        }
                    }

                    if doExport() {
                        consecutiveFailures = 0
                    } else {
                        consecutiveFailures += 1
                    }
                    lastSignature = bearDBSignature(dbPath: config.bearDB)
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
        if let last = _lastBackupTime, Date().timeIntervalSince(last) < intervalSecs {
            return
        }

        let backupDir = config.backupPath ?? config.exportPath.appendingPathComponent(".b2ou-backups")
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        // Restrictive permissions on backup directory
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir.path)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let filename = "bear-backup-\(formatter.string(from: Date())).sqlite"
        let destPath = backupDir.appendingPathComponent(filename)

        do {
            let conn = try SQLiteConnection(path: config.bearDB.path, readOnly: true)
            try conn.backupTo(destPath.path)
            // Set restrictive permissions on backup file
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destPath.path)
            lock.lock()
            _lastBackupTime = Date()
            lock.unlock()
            rotateBackups(in: backupDir)
        } catch {
            // Backup failed silently — will retry next interval
        }

        onUpdate?(noteCount, nil)
    }

    private func rotateBackups(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("bear-backup-") && $0.pathExtension == "sqlite" })
            .sorted(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }) else { return }

        let maxKeep = max(1, config.backupMaxKeep)
        if files.count > maxKeep {
            for file in files[maxKeep...] {
                try? fm.removeItem(at: file)
            }
        }
    }

    @discardableResult
    private func doExport() -> Bool {
        var errorMsg: String? = nil
        do {
            let configs = try config.splitExportConfigs()
            var totalCount = 0
            for cfg in configs {
                try? FileManager.default.createDirectory(at: cfg.exportPath, withIntermediateDirectories: true)
                let result = exportNotes(config: cfg)
                guard result.changedCount >= 0 else { continue }
                writeTimestamps(config: cfg)
                if result.changedCount > 0 {
                    _ = cleanupStaleNotes(exportPath: cfg.exportPath, expectedPaths: result.expectedPaths, onDelete: cfg.onDelete)
                    if maintenanceDue(exportPath: cfg.exportPath) {
                        if cfg.exportImageRepository { _ = cleanupOrphanRootImages(config: cfg) }
                        _ = purgeOldTrash(exportPath: cfg.exportPath)
                        touchMaintenance(exportPath: cfg.exportPath)
                    }
                }
                if !result.expectedPaths.isEmpty {
                    writeManifest(exportPath: cfg.exportPath, paths: result.expectedPaths)
                }
                totalCount = max(totalCount, result.noteCount)
            }
            lock.lock()
            _noteCount = totalCount
            _lastExportTime = Date()
            lock.unlock()
        } catch {
            errorMsg = error.localizedDescription
        }

        onUpdate?(noteCount, errorMsg)
        return errorMsg == nil
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
