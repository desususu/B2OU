// B2OUMenuBar.swift — Lightweight native macOS menu-bar app for B2OU
//
// This tiny Swift app replaces the Python/rumps menu bar, reducing RAM
// from ~300MB to ~5MB.  It launches the Python CLI as a subprocess for
// actual export work and reads status via a JSON file.
//
// Build:  swiftc -O -o B2OUMenuBar swift/B2OUMenuBar.swift -framework Cocoa
// Usage:  ./B2OUMenuBar  (or embed in .app bundle)

import Cocoa

// MARK: - Constants

private let kAppName = "B2OU"
private let kBundleId = "net.b2ou.app"
private let kStatusFileName = "status.json"
private let kConfigFileName = "b2ou.toml"
private let kLaunchAgentLabel = "net.b2ou.app"
private let kLanguagePrefKey = "B2OULanguage"
private let kStatusPollInterval: TimeInterval = 3.0
private let kMenuBarIconSize: CGFloat = 18

// MARK: - i18n

private struct Strings {
    static var lang: String = "en"

    private static let en: [String: String] = [
        "menu.starting": "Starting...",
        "menu.export_now": "Export Now",
        "menu.pause": "Pause",
        "menu.resume": "Resume",
        "menu.open_folder": "Open Export Folder",
        "menu.start_at_login": "Start at Login",
        "menu.configure": "Settings...",
        "menu.edit_config": "Edit Config File...",
        "menu.quit": "Quit",
        "menu.language": "Language",
        "menu.no_profile": "No profile configured",
        "menu.notes_exported": "%d notes exported",
        "menu.exporting_to": "Exporting to %@",
        "menu.last_export": "Last export: %@",
        "menu.just_now": "just now",
        "menu.min_ago": "%d min ago",
        "menu.idle": "Watching for changes...",
        "menu.exporting": "Exporting...",
        "menu.error": "Export error",
        "menu.error_python": "Python not found",
        "menu.error_launch": "Failed to launch export",
        "menu.stopped": "Export stopped",
        "wizard.welcome_title": "Welcome to B2OU",
        "wizard.welcome_msg": "B2OU keeps your Bear notes automatically backed up as Markdown files.\n\nChoose an export folder to get started.",
        "wizard.choose_folder": "Choose Folder",
        "wizard.cancel": "Cancel",
        "wizard.ready_title": "Ready!",
        "wizard.ready_msg": "Your notes will be exported to:\n%@",
        "settings.title": "B2OU Settings",
        "settings.export_folder": "Export Folder:",
        "settings.export_folders": "Export Folders",
        "settings.export_folder_md": "Markdown Folder:",
        "settings.export_folder_tb": "TextBundle Folder:",
        "settings.change": "Change...",
        "settings.format": "Export Format",
        "settings.format_md": "Markdown (.md)",
        "settings.format_tb": "TextBundle (.textbundle)",
        "settings.format_note": "If you export both formats, choose different folders.",
        "settings.yaml": "YAML Front Matter",
        "settings.tag_folders": "Organize by Tag Folders",
        "settings.hide_tags": "Hide Tags in Notes",
        "settings.auto_start": "Start at Login",
        "settings.naming": "File Naming:",
        "settings.on_delete": "When Note Deleted:",
        "settings.exclude_tags": "Exclude Tags:",
        "settings.exclude_placeholder": "e.g. private, draft, work/internal",
        "settings.format_none": "Select at least one export format.",
        "settings.folder_md_missing": "Please choose a Markdown export folder.",
        "settings.folder_tb_missing": "Please choose a TextBundle export folder.",
        "settings.folder_not_same": "Markdown and TextBundle folders must be different.",
        "settings.cancel": "Cancel",
        "settings.apply": "Apply",
        "help.format": "Markdown (.md): Plain files with shared images folder. Best for Obsidian.\n\nTextBundle: Each note bundles its own images. Best for Ulysses.\n\nYou can enable both formats, but they must export to different folders.",
        "help.yaml": "Add YAML front matter (title, tags, dates) at the top of each exported note.\n\nUseful for Hugo, Jekyll, and Obsidian metadata queries.",
        "help.tag_folders": "Create subfolders based on Bear tags.\n\nExample: #work/meetings → work/meetings/ folder.",
        "help.hide_tags": "Remove #tag lines from exported Markdown.\n\nTags are still preserved in YAML front matter if enabled.",
        "help.naming": "How exported files are named:\n\n• title — My Note Title.md\n• slug — my-note-title.md\n• date-title — 2024-01-15-my-note-title.md\n• id — 12345678.md",
        "help.on_delete": "What happens when a Bear note is trashed:\n\n• trash — Move to .b2ou-trash/ (recoverable)\n• remove — Delete permanently\n• keep — Never remove stale files",
        "help.exclude_tags": "Comma-separated Bear tags to skip.\n\nExample: private, draft, work/internal\n\nNested tags use / separator.",
        "help.auto_start": "Automatically launch B2OU when you log in.",
        "help.export_folder": "The folder where your Bear notes will be exported.\n\nChoose any folder — a common choice is inside your Obsidian vault or iCloud Drive.",
        "help.export_folder_md": "Folder for Markdown exports.\n\nChoose any folder — a common choice is inside your Obsidian vault or iCloud Drive.",
        "help.export_folder_tb": "Folder for TextBundle exports.\n\nWhen exporting both formats, choose a different folder from Markdown.",
    ]

    private static let zh: [String: String] = [
        "menu.starting": "启动中...",
        "menu.export_now": "立即导出",
        "menu.pause": "暂停",
        "menu.resume": "继续",
        "menu.open_folder": "打开导出文件夹",
        "menu.start_at_login": "开机启动",
        "menu.configure": "设置...",
        "menu.edit_config": "编辑配置文件...",
        "menu.quit": "退出",
        "menu.language": "语言",
        "menu.no_profile": "未配置导出方案",
        "menu.notes_exported": "已导出 %d 篇笔记",
        "menu.exporting_to": "导出到 %@",
        "menu.last_export": "上次导出: %@",
        "menu.just_now": "刚刚",
        "menu.min_ago": "%d 分钟前",
        "menu.idle": "正在监视变更...",
        "menu.exporting": "正在导出...",
        "menu.error": "导出错误",
        "menu.error_python": "未找到 Python",
        "menu.error_launch": "无法启动导出进程",
        "menu.stopped": "导出已停止",
        "wizard.welcome_title": "欢迎使用 B2OU",
        "wizard.welcome_msg": "B2OU 可以自动将 Bear 笔记备份为 Markdown 文件。\n\n请选择导出文件夹以开始。",
        "wizard.choose_folder": "选择文件夹",
        "wizard.cancel": "取消",
        "wizard.ready_title": "就绪！",
        "wizard.ready_msg": "笔记将导出到:\n%@",
        "settings.title": "B2OU 设置",
        "settings.export_folder": "导出文件夹:",
        "settings.export_folders": "导出文件夹",
        "settings.export_folder_md": "Markdown 文件夹:",
        "settings.export_folder_tb": "TextBundle 文件夹:",
        "settings.change": "更改...",
        "settings.format": "导出格式",
        "settings.format_md": "Markdown (.md)",
        "settings.format_tb": "TextBundle (.textbundle)",
        "settings.format_note": "同时导出两种格式时，请选择不同的文件夹。",
        "settings.yaml": "YAML 元数据",
        "settings.tag_folders": "按标签分文件夹",
        "settings.hide_tags": "隐藏笔记中的标签",
        "settings.auto_start": "开机启动",
        "settings.naming": "文件命名:",
        "settings.on_delete": "笔记删除时:",
        "settings.exclude_tags": "排除标签:",
        "settings.exclude_placeholder": "例如: private, draft, work/internal",
        "settings.format_none": "请至少选择一种导出格式。",
        "settings.folder_md_missing": "请选择 Markdown 导出文件夹。",
        "settings.folder_tb_missing": "请选择 TextBundle 导出文件夹。",
        "settings.folder_not_same": "Markdown 与 TextBundle 的文件夹不能相同。",
        "settings.cancel": "取消",
        "settings.apply": "应用",
        "help.format": "Markdown (.md): 纯 Markdown 文件，图片存放在共享文件夹中。适合 Obsidian。\n\nTextBundle: 每篇笔记包含内嵌图片。适合 Ulysses。\n\n可同时导出两种格式，但必须使用不同文件夹。",
        "help.yaml": "在每篇导出笔记顶部添加 YAML 元数据（标题、标签、日期）。\n\n适用于静态网站生成器和 Obsidian 元数据查询。",
        "help.tag_folders": "根据 Bear 标签创建子文件夹。\n\n例如: #work/meetings → work/meetings/ 文件夹。",
        "help.hide_tags": "从导出的 Markdown 内容中移除 #标签。\n\n如果启用了 YAML 元数据，标签仍会保留在元数据中。",
        "help.naming": "导出文件的命名方式:\n\n• title — 我的笔记.md\n• slug — my-note-title.md\n• date-title — 2024-01-15-my-note-title.md\n• id — 12345678.md",
        "help.on_delete": "当 Bear 中的笔记被删除时:\n\n• trash — 移到 .b2ou-trash/（可恢复）\n• remove — 永久删除\n• keep — 不删除旧文件",
        "help.exclude_tags": "用逗号分隔的 Bear 标签列表，这些标签的笔记不会被导出。\n\n示例: private, draft, work/internal",
        "help.auto_start": "登录 Mac 时自动启动 B2OU。",
        "help.export_folder": "导出 Bear 笔记的目标文件夹。\n\n可以选择任意文件夹，常见选择是 Obsidian 保库或 iCloud Drive 中的文件夹。",
        "help.export_folder_md": "Markdown 导出的目标文件夹。\n\n可选择任意文件夹，常见选择是 Obsidian 保库或 iCloud Drive 中的文件夹。",
        "help.export_folder_tb": "TextBundle 导出的目标文件夹。\n\n如同时导出两种格式，请与 Markdown 选择不同文件夹。",
    ]

    static func t(_ key: String) -> String {
        let table = (lang == "zh") ? zh : en
        return table[key] ?? en[key] ?? key
    }

    static func detectLanguage() -> String {
        if let saved = UserDefaults.standard.string(forKey: kLanguagePrefKey),
           saved == "en" || saved == "zh" {
            return saved
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh" : "en"
    }

    static func setLanguage(_ lang: String) {
        self.lang = lang
        UserDefaults.standard.set(lang, forKey: kLanguagePrefKey)
    }
}

// MARK: - Status File

private struct ExportStatus: Codable {
    let state: String
    let note_count: Int
    let last_update: String?
    let error: String?
    let export_path: String?
}

// MARK: - Config (TOML)

private struct B2OUConfig {
    var exportPath: String = ""
    var exportPathTB: String = ""
    var format: String = "md"
    var yamlFrontMatter: Bool = false
    var tagFolders: Bool = false
    var hideTags: Bool = false
    var naming: String = "title"
    var onDelete: String = "trash"
    var excludeTags: String = ""

    static func configDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/b2ou")
    }

    static func configFile() -> URL {
        return configDir().appendingPathComponent(kConfigFileName)
    }

    /// Search the same paths Python does: cwd, ~/.config/b2ou/, ~/
    static func findConfigFile() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(kConfigFileName),
            configFile(),
            home.appendingPathComponent(kConfigFileName),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func load() -> B2OUConfig? {
        guard let file = findConfigFile() else { return nil }
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        var cfg = B2OUConfig()
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix("[") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count != 2 { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var val = parts[1].trimmingCharacters(in: .whitespaces)
            // Remove quotes
            if val.hasPrefix("\"") && val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
            }
            // Expand ~ in paths
            if (key == "out" || key == "out-tb") && val.hasPrefix("~") {
                val = (val as NSString).expandingTildeInPath
            }
            switch key {
            case "out": cfg.exportPath = val
            case "out-tb": cfg.exportPathTB = val
            case "format":
                cfg.format = (val == "textbundle") ? "tb" : val
            case "yaml-front-matter": cfg.yamlFrontMatter = (val == "true")
            case "tag-folders": cfg.tagFolders = (val == "true")
            case "hide-tags": cfg.hideTags = (val == "true")
            case "naming": cfg.naming = val
            case "on-delete": cfg.onDelete = val
            case "exclude-tags":
                let inner = val.replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                cfg.excludeTags = inner
            default: break
            }
        }
        return cfg
    }

    func save() {
        let dir = B2OUConfig.configDir()
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        var lines = [
            "# B2OU — Bear note export configuration",
            "",
            "[profile.default]",
            "out = \"\(exportPath)\"",
        ]
        if !exportPathTB.isEmpty {
            lines.append("out-tb = \"\(exportPathTB)\"")
        }
        lines.append(contentsOf: [
            "format = \"\(format)\"",
            "on-delete = \"\(onDelete)\"",
            "naming = \"\(naming)\"",
        ])
        if yamlFrontMatter { lines.append("yaml-front-matter = true") }
        if tagFolders { lines.append("tag-folders = true") }
        if hideTags { lines.append("hide-tags = true") }
        let tags = excludeTags.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            let quoted = tags.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("exclude-tags = [\(quoted)]")
        }
        lines.append("")
        let content = lines.joined(separator: "\n")
        try? content.write(to: B2OUConfig.configFile(),
                           atomically: true, encoding: .utf8)
    }
}

// MARK: - LaunchAgent

private struct LaunchAgent {
    static let plistURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/LaunchAgents/\(kLaunchAgentLabel).plist")
    }()

    static func isInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install(appPath: String) {
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": kLaunchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: plistURL)
    }

    static func remove() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistURL.path]
        try? task.run()
        task.waitUntilExit()
        try? FileManager.default.removeItem(at: plistURL)
    }
}

// MARK: - Python CLI Process Manager

private class ExportProcess {
    private var process: Process?
    private var stderrPipe: Pipe?
    private(set) var isRunning = false
    private(set) var lastError: String?
    var onStateChange: (() -> Void)?

    /// Find the Python CLI executable.
    /// Returns (executable, base arguments) or nil.
    func findPython() -> (String, [String])? {
        // 1. Bundled CLI inside .app (check both MacOS/ and Resources/)
        if let bundlePath = Bundle.main.executablePath {
            let macosDir = (bundlePath as NSString).deletingLastPathComponent
            // Check for wrapper script or direct binary
            for name in ["b2ou-cli", "b2ou-cli-dist/b2ou-cli"] {
                let path = (macosDir as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: path) {
                    return (path, [])
                }
            }
        }
        if let resPath = Bundle.main.resourcePath {
            let cliPath = (resPath as NSString).appendingPathComponent("b2ou-cli")
            if FileManager.default.isExecutableFile(atPath: cliPath) {
                return (cliPath, [])
            }
        }

        // 2. Use `which python3` to find the user's Python, respecting their PATH
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichTask.arguments = ["python3"]
        // Inherit user's shell PATH for pyenv/homebrew/conda
        var env = ProcessInfo.processInfo.environment
        if let path = env["PATH"] {
            // Ensure common paths are included
            let extras = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.pyenv/shims",
                          "\(NSHomeDirectory())/.local/bin"]
            let combined = (extras + [path]).joined(separator: ":")
            env["PATH"] = combined
        }
        whichTask.environment = env
        let pipe = Pipe()
        whichTask.standardOutput = pipe
        whichTask.standardError = FileHandle.nullDevice
        do {
            try whichTask.run()
            whichTask.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let pythonPath = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pythonPath.isEmpty &&
                FileManager.default.isExecutableFile(atPath: pythonPath) {
                return (pythonPath, ["-m", "b2ou"])
            }
        } catch {}

        // 3. Hardcoded fallback paths
        for python in ["/opt/homebrew/bin/python3",
                       "/usr/local/bin/python3",
                       "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: python) {
                return (python, ["-m", "b2ou"])
            }
        }

        return nil
    }

    func start(profile: String = "default", statusFile: URL,
               configFile: URL? = nil) {
        guard !isRunning else { return }
        guard let (exe, baseArgs) = findPython() else {
            NSLog("B2OU: Cannot find Python CLI")
            lastError = Strings.t("menu.error_python")
            onStateChange?()
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        var args = baseArgs + [
            "export", "--profile", profile, "--watch",
            "--status-file", statusFile.path,
        ]
        // Pass explicit config path so Python finds the right file
        if let cfgPath = configFile ?? B2OUConfig.findConfigFile() {
            args += ["--config", cfgPath.path]
        }
        proc.arguments = args

        // Inherit user environment (PATH, PYTHONPATH, virtualenv)
        var env = ProcessInfo.processInfo.environment
        if let path = env["PATH"] {
            let extras = ["/opt/homebrew/bin", "/usr/local/bin",
                          "\(NSHomeDirectory())/.pyenv/shims",
                          "\(NSHomeDirectory())/.local/bin"]
            env["PATH"] = (extras + [path]).joined(separator: ":")
        }
        proc.environment = env

        proc.standardOutput = FileHandle.nullDevice

        // Capture stderr for error reporting
        let errPipe = Pipe()
        proc.standardError = errPipe
        stderrPipe = errPipe

        proc.terminationHandler = { [weak self] p in
            let exitCode = p.terminationStatus
            if exitCode != 0 {
                // Read stderr for error details
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let msg = errStr?.isEmpty == false ? errStr! : "exit code \(exitCode)"
                NSLog("B2OU: Export process failed: %@", msg)
                self?.lastError = String(msg.prefix(200))
            }
            self?.isRunning = false
            DispatchQueue.main.async { self?.onStateChange?() }
        }

        NSLog("B2OU: Starting: %@ %@", exe, args.joined(separator: " "))

        do {
            try proc.run()
            process = proc
            isRunning = true
            lastError = nil
        } catch {
            NSLog("B2OU: Failed to start export: %@", error.localizedDescription)
            lastError = error.localizedDescription
            onStateChange?()
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            isRunning = false
            return
        }
        proc.terminate()
        process = nil
        isRunning = false
    }
}

// MARK: - Info Popover Helper

private func showInfoPopover(relativeTo button: NSView, text: String) {
    let popover = NSPopover()
    let vc = NSViewController()

    let maxWidth: CGFloat = 320
    let maxHeight: CGFloat = 240
    let padding: CGFloat = 12
    let font = NSFont.systemFont(ofSize: 12)

    let attr = NSAttributedString(string: text, attributes: [.font: font])
    let bounding = attr.boundingRect(
        with: NSSize(width: maxWidth - padding * 2,
                     height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let textHeight = ceil(bounding.height)
    let contentHeight = min(textHeight + padding * 2, maxHeight)

    let contentView = NSView(frame: NSRect(x: 0, y: 0,
                                           width: maxWidth,
                                           height: contentHeight))

    let scroll = NSScrollView(frame: contentView.bounds)
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = (textHeight + padding * 2) > maxHeight
    scroll.autoresizingMask = [.width, .height]

    let textView = NSTextView(frame: NSRect(x: 0, y: 0,
                                            width: maxWidth,
                                            height: max(textHeight + padding * 2,
                                                        contentHeight)))
    textView.drawsBackground = false
    textView.isEditable = false
    textView.isSelectable = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: padding, height: padding)
    textView.font = font
    textView.string = text
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false

    scroll.documentView = textView
    contentView.addSubview(scroll)

    vc.view = contentView
    popover.contentViewController = vc
    popover.behavior = .transient
    popover.contentSize = NSSize(width: maxWidth, height: contentHeight)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
}

// MARK: - Settings Window

private class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var checkMD: NSButton!
    private var checkTB: NSButton!
    private var toggleYAML: NSSwitch!
    private var toggleTagFolders: NSSwitch!
    private var toggleHideTags: NSSwitch!
    private var toggleAutoStart: NSSwitch!
    private var popupNaming: NSPopUpButton!
    private var popupDelete: NSPopUpButton!
    private var fieldExclude: NSTextField!
    private var folderLabelMD: NSTextField!
    private var folderLabelTB: NSTextField!
    private var changeBtnMD: NSButton!
    private var changeBtnTB: NSButton!

    // Store info buttons and their help keys for click handling
    private var infoButtons: [NSButton: String] = [:]

    private var config: B2OUConfig
    private var onApply: ((B2OUConfig) -> Void)?
    private var mdPath: String = ""
    private var tbPath: String = ""

    init(config: B2OUConfig, onApply: @escaping (B2OUConfig) -> Void) {
        self.config = config
        self.onApply = onApply
        if config.format == "tb" {
            self.mdPath = ""
            self.tbPath = config.exportPathTB.isEmpty ? config.exportPath
                                                     : config.exportPathTB
        } else {
            self.mdPath = config.exportPath
            self.tbPath = config.exportPathTB
        }
        super.init()
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        buildWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    // MARK: Build UI

    private let winW: CGFloat = 520
    private let winH: CGFloat = 680
    private let pad: CGFloat = 24
    private let rowH: CGFloat = 28
    private let rowGap: CGFloat = 8
    private let sectionGap: CGFloat = 16

    private func buildWindow() {
        let contentW = winW - pad * 2
        let style: NSWindow.StyleMask = [.titled, .closable]
        let rect = NSRect(x: 200, y: 200, width: winW, height: winH)

        let w = NSWindow(contentRect: rect, styleMask: style,
                         backing: .buffered, defer: false)
        w.title = Strings.t("settings.title")
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self

        guard let content = w.contentView else { return }
        let ch = content.frame.height
        var cy = ch - pad
        let x0 = pad
        let right = winW - pad

        @discardableResult
        func addLabel(_ text: String, x: CGFloat, y: CGFloat,
                      width: CGFloat = 220, bold: Bool = false,
                      small: Bool = false, wrap: Bool = false) -> NSTextField {
            let label: NSTextField
            if wrap {
                label = NSTextField(wrappingLabelWithString: text)
            } else {
                label = NSTextField(labelWithString: text)
            }
            label.frame = NSRect(x: x, y: y, width: width, height: rowH)
            if bold {
                label.font = NSFont.boldSystemFont(ofSize: 13)
            } else if small {
                label.font = NSFont.systemFont(ofSize: 11)
                label.textColor = NSColor.secondaryLabelColor
            } else {
                label.font = NSFont.systemFont(ofSize: 13)
            }
            content.addSubview(label)
            return label
        }

        func addInfoButton(_ helpKey: String, x: CGFloat, y: CGFloat) {
            let btn = NSButton(frame: NSRect(x: x, y: y, width: 24, height: rowH))
            btn.title = "ⓘ"
            btn.isBordered = false
            btn.font = NSFont.systemFont(ofSize: 15)
            btn.target = self
            btn.action = #selector(onInfoClicked(_:))
            infoButtons[btn] = helpKey
            content.addSubview(btn)
        }

        let infoX = right - 28

        // ── Export Folders ──
        cy -= rowH
        addLabel(Strings.t("settings.export_folders"), x: x0, y: cy, bold: true)

        cy -= rowH
        addLabel(Strings.t("settings.export_folder_md"), x: x0, y: cy)
        addInfoButton("help.export_folder_md", x: infoX, y: cy)

        cy -= rowH
        folderLabelMD = addLabel(mdPath.isEmpty ? "..." : mdPath,
                                 x: x0, y: cy, width: contentW - 90)
        folderLabelMD.lineBreakMode = .byTruncatingMiddle

        changeBtnMD = NSButton(frame: NSRect(x: right - 80, y: cy,
                                             width: 80, height: rowH))
        changeBtnMD.title = Strings.t("settings.change")
        changeBtnMD.bezelStyle = .rounded
        changeBtnMD.target = self
        changeBtnMD.action = #selector(onChangeFolderMD)
        content.addSubview(changeBtnMD)

        cy -= rowGap

        cy -= rowH
        addLabel(Strings.t("settings.export_folder_tb"), x: x0, y: cy)
        addInfoButton("help.export_folder_tb", x: infoX, y: cy)

        cy -= rowH
        folderLabelTB = addLabel(tbPath.isEmpty ? "..." : tbPath,
                                 x: x0, y: cy, width: contentW - 90)
        folderLabelTB.lineBreakMode = .byTruncatingMiddle

        changeBtnTB = NSButton(frame: NSRect(x: right - 80, y: cy,
                                             width: 80, height: rowH))
        changeBtnTB.title = Strings.t("settings.change")
        changeBtnTB.bezelStyle = .rounded
        changeBtnTB.target = self
        changeBtnTB.action = #selector(onChangeFolderTB)
        content.addSubview(changeBtnTB)

        cy -= sectionGap

        // ── Export Format ──
        cy -= rowH
        addLabel(Strings.t("settings.format"), x: x0, y: cy, bold: true)
        addInfoButton("help.format", x: infoX, y: cy)

        cy -= rowH
        checkMD = NSButton(checkboxWithTitle: Strings.t("settings.format_md"),
                           target: self, action: #selector(onFormatToggle))
        checkMD.frame = NSRect(x: x0 + 12, y: cy, width: 180, height: rowH)
        content.addSubview(checkMD)

        checkTB = NSButton(checkboxWithTitle: Strings.t("settings.format_tb"),
                           target: self, action: #selector(onFormatToggle))
        checkTB.frame = NSRect(x: x0 + 188, y: cy, width: 240, height: rowH)
        content.addSubview(checkTB)

        switch config.format {
        case "both":
            checkMD.state = .on
            checkTB.state = .on
        case "tb":
            checkMD.state = .off
            checkTB.state = .on
        default:
            checkMD.state = .on
            checkTB.state = .off
        }

        cy -= rowH
        addLabel(Strings.t("settings.format_note"), x: x0 + 12, y: cy,
                 width: contentW - 12, small: true)

        cy -= sectionGap

        // ── Toggle rows ──
        let toggleX = right - 60 - 28

        func addToggleRow(_ labelKey: String, helpKey: String,
                          state: Bool) -> NSSwitch {
            cy -= rowH
            addLabel(Strings.t(labelKey), x: x0, y: cy)
            let toggle = NSSwitch(frame: NSRect(x: toggleX, y: cy + 2,
                                                width: 40, height: 22))
            toggle.state = state ? .on : .off
            content.addSubview(toggle)
            addInfoButton(helpKey, x: infoX, y: cy)
            cy -= rowGap
            return toggle
        }

        toggleYAML = addToggleRow("settings.yaml", helpKey: "help.yaml",
                                  state: config.yamlFrontMatter)
        toggleTagFolders = addToggleRow("settings.tag_folders",
                                        helpKey: "help.tag_folders",
                                        state: config.tagFolders)
        toggleHideTags = addToggleRow("settings.hide_tags",
                                      helpKey: "help.hide_tags",
                                      state: config.hideTags)
        toggleAutoStart = addToggleRow("settings.auto_start",
                                       helpKey: "help.auto_start",
                                       state: LaunchAgent.isInstalled())

        cy -= sectionGap - rowGap

        // ── Popup rows ──
        let popupX = right - 172 - 28
        let popupW: CGFloat = 150

        let namingKeys = ["title", "slug", "date-title", "id"]
        cy -= rowH
        addLabel(Strings.t("settings.naming"), x: x0, y: cy)
        popupNaming = NSPopUpButton(frame: NSRect(x: popupX, y: cy,
                                                  width: popupW, height: rowH),
                                    pullsDown: false)
        popupNaming.addItems(withTitles: namingKeys)
        if let idx = namingKeys.firstIndex(of: config.naming) {
            popupNaming.selectItem(at: idx)
        }
        content.addSubview(popupNaming)
        addInfoButton("help.naming", x: infoX, y: cy)

        cy -= rowGap

        let deleteKeys = ["trash", "remove", "keep"]
        cy -= rowH
        addLabel(Strings.t("settings.on_delete"), x: x0, y: cy)
        popupDelete = NSPopUpButton(frame: NSRect(x: popupX, y: cy,
                                                  width: popupW, height: rowH),
                                    pullsDown: false)
        popupDelete.addItems(withTitles: deleteKeys)
        if let idx = deleteKeys.firstIndex(of: config.onDelete) {
            popupDelete.selectItem(at: idx)
        }
        content.addSubview(popupDelete)
        addInfoButton("help.on_delete", x: infoX, y: cy)

        cy -= sectionGap

        // ── Exclude Tags ──
        cy -= rowH
        addLabel(Strings.t("settings.exclude_tags"), x: x0, y: cy, bold: true)
        addInfoButton("help.exclude_tags", x: infoX, y: cy)

        cy -= rowH
        fieldExclude = NSTextField(frame: NSRect(x: x0, y: cy,
                                                 width: contentW, height: rowH))
        fieldExclude.font = NSFont.systemFont(ofSize: 13)
        fieldExclude.stringValue = config.excludeTags
        fieldExclude.placeholderString = Strings.t("settings.exclude_placeholder")
        content.addSubview(fieldExclude)

        // Example text
        cy -= 44
        addLabel(Strings.t("help.exclude_tags"), x: x0 + 4, y: cy,
                 width: contentW - 8, small: true, wrap: true)

        // ── Buttons ──
        let btnY: CGFloat = pad
        let btnW: CGFloat = 90

        let applyBtn = NSButton(frame: NSRect(x: right - btnW, y: btnY,
                                              width: btnW, height: 32))
        applyBtn.title = Strings.t("settings.apply")
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        applyBtn.target = self
        applyBtn.action = #selector(onApplyClicked)
        content.addSubview(applyBtn)

        let cancelBtn = NSButton(frame: NSRect(x: right - btnW * 2 - 12, y: btnY,
                                               width: btnW, height: 32))
        cancelBtn.title = Strings.t("settings.cancel")
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.target = self
        cancelBtn.action = #selector(onCancelClicked)
        content.addSubview(cancelBtn)

        self.window = w
    }

    // MARK: Actions

    @objc func onInfoClicked(_ sender: NSButton) {
        guard let helpKey = infoButtons[sender] else { return }
        showInfoPopover(relativeTo: sender, text: Strings.t(helpKey))
    }

    @objc func onFormatToggle() {
        // Keep at least one format selectable; validation happens on Apply.
    }

    @objc func onChangeFolderMD() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = Strings.t("wizard.choose_folder")
        if panel.runModal() == .OK, let url = panel.url {
            mdPath = url.path
            folderLabelMD.stringValue = url.path
        }
    }

    @objc func onChangeFolderTB() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = Strings.t("wizard.choose_folder")
        if panel.runModal() == .OK, let url = panel.url {
            tbPath = url.path
            folderLabelTB.stringValue = url.path
        }
    }

    @objc func onApplyClicked() {
        let mdOn = (checkMD.state == .on)
        let tbOn = (checkTB.state == .on)

        if !mdOn && !tbOn {
            showAlert(Strings.t("settings.format_none"))
            return
        }
        if mdOn && mdPath.isEmpty {
            showAlert(Strings.t("settings.folder_md_missing"))
            return
        }
        if tbOn && tbPath.isEmpty {
            showAlert(Strings.t("settings.folder_tb_missing"))
            return
        }
        if mdOn && tbOn && mdPath == tbPath {
            showAlert(Strings.t("settings.folder_not_same"))
            return
        }

        if mdOn && tbOn {
            config.format = "both"
            config.exportPath = mdPath
            config.exportPathTB = tbPath
        } else if mdOn {
            config.format = "md"
            config.exportPath = mdPath
            config.exportPathTB = tbPath
        } else {
            config.format = "tb"
            config.exportPath = tbPath
            config.exportPathTB = tbPath
        }
        config.yamlFrontMatter = (toggleYAML.state == .on)
        config.tagFolders = (toggleTagFolders.state == .on)
        config.hideTags = (toggleHideTags.state == .on)
        config.naming = popupNaming.titleOfSelectedItem ?? "title"
        config.onDelete = popupDelete.titleOfSelectedItem ?? "trash"
        config.excludeTags = fieldExclude.stringValue

        // Handle auto-start
        if toggleAutoStart.state == .on {
            LaunchAgent.install(appPath: Bundle.main.bundlePath)
        } else {
            LaunchAgent.remove()
        }

        window?.close()
        onApply?(config)
    }

    @objc func onCancelClicked() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

// MARK: - App Delegate

@objc class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var exportProcess = ExportProcess()
    private var statusTimer: Timer?
    private var settingsController: SettingsWindowController?

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var lastExportMenuItem: NSMenuItem!
    private var exportNowItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var openFolderItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var configureItem: NSMenuItem!
    private var editConfigItem: NSMenuItem!
    private var langMenuItem: NSMenuItem!
    private var langEnItem: NSMenuItem!
    private var langZhItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    private var isPaused = false
    private var currentStatus: ExportStatus?

    private var statusFileURL: URL {
        return B2OUConfig.configDir().appendingPathComponent(kStatusFileName)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Strings.lang = Strings.detectLanguage()

        // Ensure config dir exists for status file
        try? FileManager.default.createDirectory(
            at: B2OUConfig.configDir(),
            withIntermediateDirectories: true)

        exportProcess.onStateChange = { [weak self] in
            self?.updateStatusDisplay()
        }

        setupStatusItem()
        buildMenu()

        // Check for config, run setup if needed
        if let cfg = B2OUConfig.load(), !cfg.exportPath.isEmpty {
            startExport()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.runSetupWizard()
            }
        }

        // Poll status file
        statusTimer = Timer.scheduledTimer(withTimeInterval: kStatusPollInterval,
                                           repeats: true) { [weak self] _ in
            self?.readStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        exportProcess.stop()
        try? FileManager.default.removeItem(at: statusFileURL)
    }

    // MARK: Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)

        if let icon = loadMenuBarIcon() {
            icon.isTemplate = true
            // Must set size for proper menu bar rendering
            icon.size = NSSize(width: kMenuBarIconSize, height: kMenuBarIconSize)
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "🐻"
        }
    }

    private func loadMenuBarIcon() -> NSImage? {
        // 1. Bundle resources (inside .app)
        if let path = Bundle.main.path(forResource: "menubar",
                                        ofType: "png",
                                        inDirectory: "resources/icons") {
            let img = NSImage(contentsOfFile: path)
            // Try to load @2x for retina
            if let path2x = Bundle.main.path(forResource: "menubar@2x",
                                              ofType: "png",
                                              inDirectory: "resources/icons"),
               let img2x = NSImage(contentsOfFile: path2x) {
                // Combine into a multi-representation image
                let combined = NSImage(size: NSSize(width: kMenuBarIconSize,
                                                     height: kMenuBarIconSize))
                if let rep1x = img?.representations.first {
                    combined.addRepresentation(rep1x)
                }
                for rep in img2x.representations {
                    combined.addRepresentation(rep)
                }
                return combined
            }
            return img
        }

        // 2. Relative to executable (development mode)
        let exe = ProcessInfo.processInfo.arguments[0]
        var base = (exe as NSString).deletingLastPathComponent
        // Walk up to find resources/icons/
        for _ in 0..<5 {
            let iconPath = (base as NSString)
                .appendingPathComponent("resources/icons/menubar.png")
            if FileManager.default.fileExists(atPath: iconPath) {
                return NSImage(contentsOfFile: iconPath)
            }
            base = (base as NSString).deletingLastPathComponent
        }

        return nil
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()

        statusMenuItem = menu.addItem(withTitle: Strings.t("menu.starting"),
                                      action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        lastExportMenuItem = menu.addItem(withTitle: "", action: nil,
                                          keyEquivalent: "")
        lastExportMenuItem.isEnabled = false
        lastExportMenuItem.isHidden = true

        menu.addItem(.separator())

        exportNowItem = menu.addItem(
            withTitle: Strings.t("menu.export_now"),
            action: #selector(onExportNow), keyEquivalent: "e")
        exportNowItem.target = self

        pauseItem = menu.addItem(withTitle: Strings.t("menu.pause"),
                                 action: #selector(onTogglePause),
                                 keyEquivalent: "")
        pauseItem.target = self

        openFolderItem = menu.addItem(
            withTitle: Strings.t("menu.open_folder"),
            action: #selector(onOpenFolder), keyEquivalent: "")
        openFolderItem.target = self

        menu.addItem(.separator())

        loginItem = menu.addItem(withTitle: Strings.t("menu.start_at_login"),
                                 action: #selector(onToggleLogin),
                                 keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAgent.isInstalled() ? .on : .off

        configureItem = menu.addItem(withTitle: Strings.t("menu.configure"),
                                     action: #selector(onConfigure),
                                     keyEquivalent: ",")
        configureItem.target = self

        editConfigItem = menu.addItem(
            withTitle: Strings.t("menu.edit_config"),
            action: #selector(onEditConfig), keyEquivalent: "")
        editConfigItem.target = self

        menu.addItem(.separator())

        // Language submenu
        let langMenu = NSMenu()
        langEnItem = langMenu.addItem(withTitle: "English",
                                      action: #selector(onSetEnglish),
                                      keyEquivalent: "")
        langEnItem.target = self
        langEnItem.state = (Strings.lang == "en") ? .on : .off

        langZhItem = langMenu.addItem(withTitle: "中文",
                                      action: #selector(onSetChinese),
                                      keyEquivalent: "")
        langZhItem.target = self
        langZhItem.state = (Strings.lang == "zh") ? .on : .off

        langMenuItem = menu.addItem(withTitle: Strings.t("menu.language"),
                                    action: nil, keyEquivalent: "")
        langMenuItem.submenu = langMenu

        menu.addItem(.separator())

        quitItem = menu.addItem(withTitle: Strings.t("menu.quit"),
                                action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self

        statusItem.menu = menu
    }

    private func refreshMenuTitles() {
        exportNowItem.title = Strings.t("menu.export_now")
        pauseItem.title = isPaused ? Strings.t("menu.resume")
                                   : Strings.t("menu.pause")
        openFolderItem.title = Strings.t("menu.open_folder")
        loginItem.title = Strings.t("menu.start_at_login")
        configureItem.title = Strings.t("menu.configure")
        editConfigItem.title = Strings.t("menu.edit_config")
        langMenuItem.title = Strings.t("menu.language")
        quitItem.title = Strings.t("menu.quit")
        // Don't reset statusMenuItem — preserve current export status
        updateStatusDisplay()
    }

    // MARK: Export Process

    private func startExport() {
        exportProcess.stop()
        exportProcess.start(statusFile: statusFileURL)
    }

    private func readStatus() {
        guard let data = try? Data(contentsOf: statusFileURL),
              let status = try? JSONDecoder().decode(ExportStatus.self,
                                                     from: data) else {
            return
        }
        currentStatus = status
        DispatchQueue.main.async { self.updateStatusDisplay() }
    }

    private func updateStatusDisplay() {
        // If process died with an error, show it
        if !exportProcess.isRunning, let err = exportProcess.lastError {
            statusMenuItem.title = Strings.t("menu.error") + ": " + err
            return
        }

        guard let s = currentStatus else {
            if exportProcess.isRunning {
                statusMenuItem.title = Strings.t("menu.starting")
            } else if let cfg = B2OUConfig.load(), !cfg.exportPath.isEmpty {
                let folder = (cfg.exportPath as NSString).lastPathComponent
                statusMenuItem.title = String(
                    format: Strings.t("menu.exporting_to"), folder)
            } else {
                statusMenuItem.title = Strings.t("menu.no_profile")
            }
            return
        }

        switch s.state {
        case "idle":
            if s.note_count > 0 {
                statusMenuItem.title = String(
                    format: Strings.t("menu.notes_exported"), s.note_count)
            } else {
                statusMenuItem.title = Strings.t("menu.idle")
            }
        case "exporting":
            statusMenuItem.title = Strings.t("menu.exporting")
        case "error":
            statusMenuItem.title = Strings.t("menu.error")
                + (s.error.map { ": \($0)" } ?? "")
        case "watching":
            statusMenuItem.title = Strings.t("menu.idle")
        case "stopped":
            statusMenuItem.title = Strings.t("menu.stopped")
        default:
            statusMenuItem.title = s.state
        }

        // Parse last_update timestamp (Python writes ISO format without TZ)
        if let lastUpdate = s.last_update, s.state != "watching" {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            df.locale = Locale(identifier: "en_US_POSIX")
            if let date = df.date(from: lastUpdate) {
                let ago = Date().timeIntervalSince(date)
                let timeStr: String
                if ago < 60 {
                    timeStr = Strings.t("menu.just_now")
                } else if ago < 3600 {
                    timeStr = String(format: Strings.t("menu.min_ago"),
                                     Int(ago / 60))
                } else {
                    let displayFmt = DateFormatter()
                    displayFmt.dateFormat = "HH:mm"
                    timeStr = displayFmt.string(from: date)
                }
                lastExportMenuItem.title = String(
                    format: Strings.t("menu.last_export"), timeStr)
                lastExportMenuItem.isHidden = false
            }
        }
    }

    // MARK: Menu Actions

    @objc func onExportNow() {
        if B2OUConfig.load() == nil {
            runSetupWizard()
            return
        }
        exportProcess.stop()
        currentStatus = nil
        startExport()
    }

    @objc func onTogglePause() {
        isPaused = !isPaused
        if isPaused {
            exportProcess.stop()
            pauseItem.title = Strings.t("menu.resume")
            statusMenuItem.title = Strings.t("menu.stopped")
        } else {
            startExport()
            pauseItem.title = Strings.t("menu.pause")
        }
    }

    @objc func onOpenFolder() {
        if let cfg = B2OUConfig.load(), !cfg.exportPath.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: cfg.exportPath))
        }
    }

    @objc func onToggleLogin() {
        if LaunchAgent.isInstalled() {
            LaunchAgent.remove()
            loginItem.state = .off
        } else {
            LaunchAgent.install(appPath: Bundle.main.bundlePath)
            loginItem.state = .on
        }
    }

    @objc func onConfigure() {
        // Close any existing settings window first
        settingsController?.close()
        let cfg = B2OUConfig.load() ?? B2OUConfig()
        settingsController = SettingsWindowController(config: cfg) {
            [weak self] newCfg in
            newCfg.save()
            self?.exportProcess.stop()
            self?.currentStatus = nil
            self?.startExport()
        }
        settingsController?.show()
    }

    @objc func onEditConfig() {
        if let file = B2OUConfig.findConfigFile() {
            NSWorkspace.shared.open(file)
        } else {
            runSetupWizard()
        }
    }

    @objc func onSetEnglish() {
        Strings.setLanguage("en")
        langEnItem.state = .on
        langZhItem.state = .off
        refreshMenuTitles()
    }

    @objc func onSetChinese() {
        Strings.setLanguage("zh")
        langEnItem.state = .off
        langZhItem.state = .on
        refreshMenuTitles()
    }

    @objc func onQuit() {
        exportProcess.stop()
        NSApp.terminate(nil)
    }

    // MARK: Setup Wizard

    private func runSetupWizard() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = Strings.t("wizard.welcome_title")
        alert.informativeText = Strings.t("wizard.welcome_msg")
        alert.addButton(withTitle: Strings.t("wizard.choose_folder"))
        alert.addButton(withTitle: Strings.t("wizard.cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = Strings.t("wizard.choose_folder")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var cfg = B2OUConfig()
        cfg.exportPath = url.path
        cfg.save()

        LaunchAgent.install(appPath: Bundle.main.bundlePath)
        loginItem.state = .on

        startExport()

        let done = NSAlert()
        done.messageText = Strings.t("wizard.ready_title")
        done.informativeText = String(format: Strings.t("wizard.ready_msg"),
                                      url.path)
        done.runModal()
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// No Dock icon — set in Info.plist, also set here for development
app.setActivationPolicy(.accessory)

app.run()
