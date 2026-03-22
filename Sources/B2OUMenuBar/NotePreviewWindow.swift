// NotePreviewWindow.swift — Note browser with Markdown preview, typography controls,
// day/night mode, split-screen source view, and sort options.
//
// Apple-design-inspired: vibrancy sidebar, unified toolbar, full-size content view
// with titlebar blending, refined typography, and polished layout.

import Cocoa
import WebKit
import B2OUCore

// MARK: - Layout Constants

private let previewWidth:  CGFloat = 1100
private let previewHeight: CGFloat = 720
private let sidebarWidth:  CGFloat = 260
private let toolbarH:      CGFloat = 40
private let bottomBarH:    CGFloat = 36

// MARK: - Sort Mode

private enum SortMode: Int {
    case title = 0
    case dateModified = 1
    case dateCreated = 2
    case wordCount = 3
}

// MARK: - View Mode

private enum ViewMode: Int {
    case preview = 0
    case source = 1
    case split = 2
}

// MARK: - Preview Controller

class NotePreviewController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var store: NoteStore?
    private var filteredNotes: [NoteMetadata] = []
    private var selectedNote: NoteMetadata?

    private var tableView: NSTableView?
    private var webView: WKWebView?
    private var searchField: NSSearchField?
    private var wordCountLabel: NSTextField?
    private var openBearBtn: NSButton?
    private var sortPopup: NSPopUpButton?

    // Split-screen
    private var contentContainer: NSView?
    private var sourceScrollView: NSScrollView?
    private var sourceTextView: NSTextView?
    private var splitDivider: NSView?
    private var viewMode: ViewMode = .preview

    // Typography state
    private var fontFamily = "-apple-system, BlinkMacSystemFont, sans-serif"
    private var fontSize: CGFloat = 15
    private var lineSpacing: CGFloat = 1.6
    private var isDarkMode = false

    // Dynamically populated from system
    private var fontOptions: [(label: String, css: String)] = []
    private let sizeOptions: [CGFloat] = [12, 13, 14, 15, 16, 18, 20, 24]
    private let spacingOptions: [CGFloat] = [1.0, 1.2, 1.4, 1.5, 1.6, 1.8, 2.0]

    private var sortMode: SortMode = .dateModified

    // Date formatter for sidebar cells
    private let cellDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    func show(store: NoteStore) {
        self.store = store
        applySort()

        if let window, window.isVisible {
            tableView?.reloadData()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        fontOptions = Self.detectFonts()
        buildWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        if let tmp = tempHTMLFile { try? FileManager.default.removeItem(at: tmp) }
        window?.close()
        window = nil
    }

    // MARK: - Font Detection

    /// Classify a font family as monospace by checking its traits.
    private static func isMonospace(_ family: String) -> Bool {
        guard let font = NSFont(name: family, size: 13) else { return false }
        let traits = NSFontManager.shared.traits(of: font)
        return traits.contains(.fixedPitchFontMask)
    }

    /// Build a full list of all system-installed font families, grouped into
    /// Sans-serif / Serif / Monospace sections with a "System" default at the top.
    private static func detectFonts() -> [(label: String, css: String)] {
        let fm = NSFontManager.shared
        let families = fm.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        var sansSerif: [(String, String)] = []
        var serif: [(String, String)] = []
        var monospace: [(String, String)] = []

        for family in families {
            // Skip hidden / internal font families
            if family.hasPrefix(".") { continue }

            let cssFamily = "'\(family)'"

            if isMonospace(family) {
                monospace.append((family, "\(cssFamily), monospace"))
            } else {
                // Heuristic: check serif trait on representative font
                if let font = NSFont(name: family, size: 13) {
                    let traits = fm.traits(of: font)
                    if traits.contains(.italicFontMask) == false, family.localizedCaseInsensitiveContains("serif")
                        || family.localizedCaseInsensitiveContains("Georgia")
                        || family.localizedCaseInsensitiveContains("Palatino")
                        || family.localizedCaseInsensitiveContains("Baskerville")
                        || family.localizedCaseInsensitiveContains("Times")
                        || family.localizedCaseInsensitiveContains("Cochin")
                        || family.localizedCaseInsensitiveContains("Garamond") {
                        // Known serif patterns
                        serif.append((family, "\(cssFamily), serif"))
                    } else {
                        // Default: treat as sans-serif
                        sansSerif.append((family, "\(cssFamily), sans-serif"))
                    }
                } else {
                    sansSerif.append((family, "\(cssFamily), sans-serif"))
                }
            }
        }

        var result: [(label: String, css: String)] = []

        // Always start with system default
        result.append((label: "System", css: "-apple-system, BlinkMacSystemFont, sans-serif"))

        // Section headers use an em-dash prefix to visually separate groups
        if !sansSerif.isEmpty {
            result.append((label: "\u{2500}\u{2500} Sans-serif \u{2500}\u{2500}", css: ""))
            result += sansSerif.map { (label: $0.0, css: $0.1) }
        }
        if !serif.isEmpty {
            result.append((label: "\u{2500}\u{2500} Serif \u{2500}\u{2500}", css: ""))
            result += serif.map { (label: $0.0, css: $0.1) }
        }
        if !monospace.isEmpty {
            result.append((label: "\u{2500}\u{2500} Monospace \u{2500}\u{2500}", css: ""))
            result += monospace.map { (label: $0.0, css: $0.1) }
        }

        return result
    }

    // MARK: - Sort

    private func applySort() {
        guard let store else { return }
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var notes = store.notes

        if !query.isEmpty {
            notes = notes.filter { note in
                note.title.lowercased().contains(query)
                    || note.tags.contains { $0.lowercased().contains(query) }
            }
        }

        switch sortMode {
        case .title:
            notes.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .dateModified:
            notes.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .dateCreated:
            notes.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .wordCount:
            notes.sort { $0.wordCount > $1.wordCount }
        }

        filteredNotes = notes
    }

    // MARK: - Build Window

    private func buildWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        let rect = NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window?.title = t("preview.title")
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .visible
        window?.center()
        window?.isReleasedWhenClosed = false
        window?.minSize = NSSize(width: 740, height: 460)
        window?.backgroundColor = .windowBackgroundColor

        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let ch = content.frame.height
        let cw = content.frame.width

        // ── Sidebar with Vibrancy ───────────────────────────────

        let sideY: CGFloat = bottomBarH
        let sideH = ch - toolbarH - bottomBarH

        let sidebarEffect = NSVisualEffectView(frame: NSRect(x: 0, y: sideY, width: sidebarWidth, height: sideH))
        sidebarEffect.autoresizingMask = [.height]
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.material = .sidebar
        sidebarEffect.state = .active
        content.addSubview(sidebarEffect)

        // Sort popup
        var sy = sideH - 34
        sortPopup = NSPopUpButton(frame: NSRect(x: 12, y: sy, width: sidebarWidth - 24, height: 24), pullsDown: false)
        sortPopup?.controlSize = .small
        sortPopup?.font = NSFont.systemFont(ofSize: 11)
        sortPopup?.addItems(withTitles: [
            t("preview.sort_title"),
            t("preview.sort_modified"),
            t("preview.sort_created"),
            t("preview.sort_words"),
        ])
        sortPopup?.selectItem(at: sortMode.rawValue)
        sortPopup?.target = self
        sortPopup?.action = #selector(onSortChanged(_:))
        sortPopup?.autoresizingMask = [.minYMargin, .width]
        sidebarEffect.addSubview(sortPopup!)

        // Search field
        sy -= 30
        searchField = NSSearchField(frame: NSRect(x: 12, y: sy, width: sidebarWidth - 24, height: 26))
        searchField?.controlSize = .small
        searchField?.font = NSFont.systemFont(ofSize: 12)
        searchField?.placeholderString = t("preview.search")
        searchField?.target = self
        searchField?.action = #selector(onSearch(_:))
        searchField?.autoresizingMask = [.minYMargin, .width]
        sidebarEffect.addSubview(searchField!)

        // Table view in scroll view
        let tableScrollH = sy - 6
        let tableScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: tableScrollH))
        tableScroll.autoresizingMask = [.height, .width]
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.scrollerStyle = .overlay

        tableView = NSTableView()
        tableView?.headerView = nil
        tableView?.rowHeight = 48
        tableView?.intercellSpacing = NSSize(width: 0, height: 0)
        tableView?.selectionHighlightStyle = .regular
        tableView?.backgroundColor = .clear
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.width = sidebarWidth - 4
        tableView?.addTableColumn(col)
        tableView?.dataSource = self
        tableView?.delegate = self
        tableScroll.documentView = tableView

        sidebarEffect.addSubview(tableScroll)

        // Vertical divider
        let divider = NSView(frame: NSRect(x: sidebarWidth, y: sideY, width: 1, height: sideH))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.autoresizingMask = [.height]
        content.addSubview(divider)

        // ── Toolbar ─────────────────────────────────────────────

        let toolbar = NSVisualEffectView(frame: NSRect(x: 0, y: ch - toolbarH, width: cw, height: toolbarH))
        toolbar.autoresizingMask = [.width, .minYMargin]
        toolbar.blendingMode = .behindWindow
        toolbar.material = .titlebar
        toolbar.state = .active
        content.addSubview(toolbar)

        // Horizontal divider under toolbar
        let toolDiv = NSView(frame: NSRect(x: 0, y: 0, width: cw, height: 1))
        toolDiv.wantsLayer = true
        toolDiv.layer?.backgroundColor = NSColor.separatorColor.cgColor
        toolDiv.autoresizingMask = [.width]
        toolbar.addSubview(toolDiv)

        var tx: CGFloat = sidebarWidth + 14

        // Font popup (no label — popup title is self-explanatory)
        let fontPopup = NSPopUpButton(frame: NSRect(x: tx, y: 9, width: 180, height: 22), pullsDown: false)
        fontPopup.controlSize = .small
        fontPopup.font = NSFont.systemFont(ofSize: 11)
        for opt in fontOptions {
            fontPopup.addItem(withTitle: opt.label)
            // Disable section header items (they have empty css)
            if opt.css.isEmpty, let item = fontPopup.lastItem {
                item.isEnabled = false
            }
        }
        fontPopup.target = self
        fontPopup.action = #selector(onFontChanged(_:))
        toolbar.addSubview(fontPopup)
        tx += 186

        // Size popup
        let sizePopup = NSPopUpButton(frame: NSRect(x: tx, y: 9, width: 52, height: 22), pullsDown: false)
        sizePopup.controlSize = .small
        sizePopup.font = NSFont.systemFont(ofSize: 11)
        for s in sizeOptions { sizePopup.addItem(withTitle: "\(Int(s))pt") }
        if let idx = sizeOptions.firstIndex(of: fontSize) { sizePopup.selectItem(at: idx) }
        sizePopup.target = self
        sizePopup.action = #selector(onSizeChanged(_:))
        toolbar.addSubview(sizePopup)
        tx += 56

        // Spacing popup
        let spacingPopup = NSPopUpButton(frame: NSRect(x: tx, y: 9, width: 54, height: 22), pullsDown: false)
        spacingPopup.controlSize = .small
        spacingPopup.font = NSFont.systemFont(ofSize: 11)
        for s in spacingOptions { spacingPopup.addItem(withTitle: String(format: "%.1f\u{00d7}", s)) }
        if let idx = spacingOptions.firstIndex(of: lineSpacing) { spacingPopup.selectItem(at: idx) }
        spacingPopup.target = self
        spacingPopup.action = #selector(onSpacingChanged(_:))
        toolbar.addSubview(spacingPopup)
        tx += 60

        // Toolbar separator
        let tbSep = NSView(frame: NSRect(x: tx + 2, y: 10, width: 1, height: 20))
        tbSep.wantsLayer = true
        tbSep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        toolbar.addSubview(tbSep)
        tx += 10

        // Day/Night toggle
        let themeControl = NSSegmentedControl(labels: [t("preview.day_mode"), t("preview.night_mode")],
                                             trackingMode: .selectOne,
                                             target: self,
                                             action: #selector(onThemeChanged(_:)))
        themeControl.frame = NSRect(x: tx, y: 9, width: 100, height: 22)
        themeControl.controlSize = .small
        themeControl.font = NSFont.systemFont(ofSize: 10)
        themeControl.selectedSegment = 0
        toolbar.addSubview(themeControl)
        tx += 106

        // View mode: Preview / Source / Split
        let viewControl = NSSegmentedControl(
            labels: [t("preview.mode_preview"), t("preview.mode_source"), t("preview.mode_split")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(onViewModeChanged(_:)))
        viewControl.frame = NSRect(x: tx, y: 9, width: 150, height: 22)
        viewControl.controlSize = .small
        viewControl.font = NSFont.systemFont(ofSize: 10)
        viewControl.selectedSegment = 0
        toolbar.addSubview(viewControl)

        // ── Content Container ───────────────────────────────────

        let contentX = sidebarWidth + 1
        let contentW = cw - contentX
        contentContainer = NSView(frame: NSRect(x: contentX, y: sideY, width: contentW, height: sideH))
        contentContainer?.autoresizingMask = [.width, .height]
        content.addSubview(contentContainer!)

        // WebView
        webView = WKWebView(frame: contentContainer!.bounds)
        webView?.autoresizingMask = [.width, .height]
        contentContainer?.addSubview(webView!)

        // Source text view
        sourceScrollView = NSScrollView(frame: contentContainer!.bounds)
        sourceScrollView?.autoresizingMask = [.width, .height]
        sourceScrollView?.hasVerticalScroller = true
        sourceScrollView?.drawsBackground = true
        sourceScrollView?.scrollerStyle = .overlay

        sourceTextView = NSTextView(frame: contentContainer!.bounds)
        sourceTextView?.isEditable = false
        sourceTextView?.isSelectable = true
        sourceTextView?.font = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        sourceTextView?.textContainerInset = NSSize(width: 20, height: 20)
        sourceTextView?.isAutomaticQuoteSubstitutionEnabled = false
        sourceTextView?.isAutomaticDashSubstitutionEnabled = false
        sourceTextView?.backgroundColor = .textBackgroundColor
        sourceTextView?.textColor = .textColor
        sourceScrollView?.documentView = sourceTextView
        contentContainer?.addSubview(sourceScrollView!)
        sourceScrollView?.isHidden = true

        // Split divider
        splitDivider = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: sideH))
        splitDivider?.wantsLayer = true
        splitDivider?.layer?.backgroundColor = NSColor.separatorColor.cgColor
        contentContainer?.addSubview(splitDivider!)
        splitDivider?.isHidden = true

        // Load empty state
        let emptyHTML = wrapInHTML("<p style=\"color:#999;text-align:center;margin-top:40%\">\(t("preview.no_selection"))</p>")
        webView?.loadHTMLString(emptyHTML, baseURL: nil)

        // ── Bottom Bar ──────────────────────────────────────────

        let bottomBar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: cw, height: bottomBarH))
        bottomBar.autoresizingMask = [.width]
        bottomBar.blendingMode = .behindWindow
        bottomBar.material = .titlebar
        bottomBar.state = .active
        content.addSubview(bottomBar)

        let hDiv = NSView(frame: NSRect(x: 0, y: bottomBarH - 1, width: cw, height: 1))
        hDiv.wantsLayer = true
        hDiv.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hDiv.autoresizingMask = [.width]
        bottomBar.addSubview(hDiv)

        wordCountLabel = NSTextField(labelWithString: "")
        wordCountLabel?.frame = NSRect(x: 16, y: 10, width: 420, height: 16)
        wordCountLabel?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        wordCountLabel?.textColor = .tertiaryLabelColor
        wordCountLabel?.lineBreakMode = .byTruncatingTail
        bottomBar.addSubview(wordCountLabel!)

        let openEditorBtn = NSButton(frame: NSRect(x: cw - 252, y: 6, width: 116, height: 24))
        openEditorBtn.title = t("preview.open_editor")
        openEditorBtn.bezelStyle = .rounded
        openEditorBtn.controlSize = .small
        openEditorBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        openEditorBtn.target = self
        openEditorBtn.action = #selector(onOpenEditor)
        openEditorBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(openEditorBtn)

        openBearBtn = NSButton(frame: NSRect(x: cw - 130, y: 6, width: 116, height: 24))
        openBearBtn?.title = t("preview.open_bear")
        openBearBtn?.bezelStyle = .rounded
        openBearBtn?.controlSize = .small
        openBearBtn?.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        openBearBtn?.target = self
        openBearBtn?.action = #selector(onOpenBear)
        openBearBtn?.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(openBearBtn!)

        // Observe window resize for split-mode layout
        NotificationCenter.default.addObserver(self, selector: #selector(onWindowResize),
                                              name: NSWindow.didResizeNotification, object: window)

        updateViewLayout()
    }

    // MARK: - View Mode Layout

    private func updateViewLayout() {
        guard let container = contentContainer else { return }
        let w = container.bounds.width
        let h = container.bounds.height

        switch viewMode {
        case .preview:
            sourceScrollView?.isHidden = true
            splitDivider?.isHidden = true
            webView?.isHidden = false
            webView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        case .source:
            sourceScrollView?.isHidden = false
            splitDivider?.isHidden = true
            webView?.isHidden = true
            sourceScrollView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        case .split:
            let halfW = floor(w / 2)
            sourceScrollView?.isHidden = false
            splitDivider?.isHidden = false
            webView?.isHidden = false
            sourceScrollView?.frame = NSRect(x: 0, y: 0, width: halfW - 1, height: h)
            splitDivider?.frame = NSRect(x: halfW - 1, y: 0, width: 1, height: h)
            webView?.frame = NSRect(x: halfW, y: 0, width: w - halfW, height: h)
        }
    }

    // MARK: - Table View Data Source

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredNotes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NoteCell")

        let cell: NSView
        let titleField: NSTextField
        let subtitleField: NSTextField

        if let reused = tableView.makeView(withIdentifier: id, owner: self) {
            cell = reused
            titleField = reused.viewWithTag(1) as! NSTextField
            subtitleField = reused.viewWithTag(2) as! NSTextField
        } else {
            cell = NSView()
            cell.identifier = id

            let tf = NSTextField(labelWithString: "")
            tf.tag = 1
            tf.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.frame = NSRect(x: 12, y: 26, width: sidebarWidth - 24, height: 18)
            tf.autoresizingMask = [.width]
            cell.addSubview(tf)
            titleField = tf

            let sf = NSTextField(labelWithString: "")
            sf.tag = 2
            sf.font = NSFont.systemFont(ofSize: 10)
            sf.textColor = .tertiaryLabelColor
            sf.lineBreakMode = .byTruncatingTail
            sf.frame = NSRect(x: 12, y: 8, width: sidebarWidth - 24, height: 14)
            sf.autoresizingMask = [.width]
            cell.addSubview(sf)
            subtitleField = sf
        }

        let note = filteredNotes[row]
        titleField.stringValue = note.title

        var parts: [String] = []
        if let mod = note.modified {
            parts.append(cellDateFormatter.string(from: mod))
        }
        parts.append(formatCount(note.wordCount, t("preview.words")))
        if !note.tags.isEmpty {
            parts.append(note.tags.prefix(2).joined(separator: ", "))
        }
        subtitleField.stringValue = parts.joined(separator: "  \u{00b7}  ")

        return cell
    }

    // MARK: - Table View Delegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView?.selectedRow ?? -1
        guard row >= 0, row < filteredNotes.count else {
            selectedNote = nil
            return
        }
        selectedNote = filteredNotes[row]
        loadNote(filteredNotes[row])
    }

    // MARK: - Note Loading

    /// Temporary HTML file for WebView preview (enables local image access).
    private var tempHTMLFile: URL?

    private func loadNote(_ note: NoteMetadata) {
        guard let content = try? String(contentsOf: note.filePath, encoding: .utf8) else { return }
        let body = stripFrontMatter(content)

        // Always update both views
        let html = wrapInHTML(markdownToHTML(body))
        sourceTextView?.string = body

        // Write HTML to a temp file so WKWebView can access local images
        // via loadFileURL with read access to the note's directory tree.
        let noteDir = note.filePath.deletingLastPathComponent()
        let tmpFile = noteDir.appendingPathComponent(".b2ou-preview.html")
        do {
            try html.write(to: tmpFile, atomically: true, encoding: .utf8)
            // Grant read access to the export root (parent of note dir) so
            // shared image folders are also accessible.
            let accessRoot = noteDir.deletingLastPathComponent()
            webView?.loadFileURL(tmpFile, allowingReadAccessTo: accessRoot)
            tempHTMLFile = tmpFile
        } catch {
            // Fallback: loadHTMLString (images won't load but text works)
            webView?.loadHTMLString(html, baseURL: noteDir)
        }

        // Status bar
        var info = "\(note.wordCount) \(t("preview.words"))"
        if let mod = note.modified {
            info += "  \u{00b7}  " + cellDateFormatter.string(from: mod)
        }
        wordCountLabel?.stringValue = info
        openBearBtn?.isHidden = note.bearId.isEmpty
    }

    private func refreshPreview() {
        guard let note = selectedNote else { return }
        loadNote(note)
    }

    // MARK: - Actions

    @objc private func onSearch(_ sender: NSSearchField) {
        applySort()
        tableView?.reloadData()
    }

    @objc private func onSortChanged(_ sender: NSPopUpButton) {
        sortMode = SortMode(rawValue: sender.indexOfSelectedItem) ?? .dateModified
        applySort()
        tableView?.reloadData()
    }

    @objc private func onFontChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < fontOptions.count else { return }
        // Ignore section header selections (empty css)
        let css = fontOptions[idx].css
        guard !css.isEmpty else { return }
        fontFamily = css
        refreshPreview()
    }

    @objc private func onSizeChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < sizeOptions.count else { return }
        fontSize = sizeOptions[idx]
        refreshPreview()
    }

    @objc private func onSpacingChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < spacingOptions.count else { return }
        lineSpacing = spacingOptions[idx]
        refreshPreview()
    }

    @objc private func onThemeChanged(_ sender: NSSegmentedControl) {
        isDarkMode = sender.selectedSegment == 1
        refreshPreview()
    }

    @objc private func onViewModeChanged(_ sender: NSSegmentedControl) {
        viewMode = ViewMode(rawValue: sender.selectedSegment) ?? .preview
        updateViewLayout()
    }

    @objc private func onWindowResize(_ notification: Notification) {
        updateViewLayout()
    }

    @objc private func onOpenEditor() {
        guard let note = selectedNote else { return }
        NSWorkspace.shared.open(note.filePath)
    }

    @objc private func onOpenBear() {
        guard let note = selectedNote, !note.bearId.isEmpty,
              let encodedId = note.bearId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "bear://x-callback-url/open-note?id=\(encodedId)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    private func formatCount(_ n: Int, _ unit: String) -> String {
        if n >= 1000 {
            return String(format: "%.1fk %@", Double(n) / 1000.0, unit)
        }
        return "\(n) \(unit)"
    }

    // MARK: - Markdown → HTML

    private func stripFrontMatter(_ content: String) -> String {
        guard content.hasPrefix("---\n") || content.hasPrefix("---\r\n") else { return content }
        let lines = content.components(separatedBy: .newlines)
        for i in 1..<lines.count {
            if lines[i] == "---" {
                return lines[(i + 1)...].joined(separator: "\n")
            }
        }
        return content
    }

    private func markdownToHTML(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var html: [String] = []
        var inCodeBlock = false
        var inUL = false
        var inOL = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code blocks
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    html.append("</code></pre>")
                    inCodeBlock = false
                } else {
                    closeLists(&html, &inUL, &inOL)
                    html.append("<pre><code>")
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                html.append(escapeHTML(line))
                continue
            }

            if trimmed.isEmpty {
                closeLists(&html, &inUL, &inOL)
                continue
            }

            // Headings
            if let (level, text) = parseHeading(trimmed) {
                closeLists(&html, &inUL, &inOL)
                html.append("<h\(level)>\(inlineFormat(text))</h\(level)>")
                continue
            }

            // Horizontal rule
            if trimmed.count >= 3 {
                let chars = trimmed.filter { $0 != " " }
                if chars.count >= 3, Set(chars).count == 1, "-*_".contains(chars.first!) {
                    closeLists(&html, &inUL, &inOL)
                    html.append("<hr>")
                    continue
                }
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                closeLists(&html, &inUL, &inOL)
                let text = trimmed.count > 2 ? String(trimmed.dropFirst(2)) : ""
                html.append("<blockquote><p>\(inlineFormat(text))</p></blockquote>")
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if inOL { html.append("</ol>"); inOL = false }
                if !inUL { html.append("<ul>"); inUL = true }
                html.append("<li>\(inlineFormat(String(trimmed.dropFirst(2))))</li>")
                continue
            }

            // Ordered list
            if let dotIdx = trimmed.firstIndex(of: "."), dotIdx != trimmed.startIndex {
                let prefix = trimmed[trimmed.startIndex..<dotIdx]
                if prefix.allSatisfy({ $0.isNumber }) {
                    let afterDot = trimmed.index(after: dotIdx)
                    if afterDot < trimmed.endIndex && trimmed[afterDot] == " " {
                        if inUL { html.append("</ul>"); inUL = false }
                        if !inOL { html.append("<ol>"); inOL = true }
                        let text = String(trimmed[trimmed.index(after: afterDot)...])
                        html.append("<li>\(inlineFormat(text))</li>")
                        continue
                    }
                }
            }

            // Paragraph
            closeLists(&html, &inUL, &inOL)
            html.append("<p>\(inlineFormat(trimmed))</p>")
        }

        if inCodeBlock { html.append("</code></pre>") }
        closeLists(&html, &inUL, &inOL)
        return html.joined(separator: "\n")
    }

    private func closeLists(_ html: inout [String], _ inUL: inout Bool, _ inOL: inout Bool) {
        if inUL { html.append("</ul>"); inUL = false }
        if inOL { html.append("</ol>"); inOL = false }
    }

    private func parseHeading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level else { return nil }
        let after = line[line.index(line.startIndex, offsetBy: level)]
        guard after == " " else { return nil }
        let text = String(line.dropFirst(level + 1))
        return (level, text)
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func inlineFormat(_ s: String) -> String {
        var r = escapeHTML(s)
        // Images
        r = r.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
                                   with: #"<img src="$2" alt="$1">"#, options: .regularExpression)
        // Links
        r = r.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#,
                                   with: #"<a href="$2">$1</a>"#, options: .regularExpression)
        // Bold
        r = r.replacingOccurrences(of: #"\*\*(.+?)\*\*"#,
                                   with: "<strong>$1</strong>", options: .regularExpression)
        r = r.replacingOccurrences(of: #"__(.+?)__"#,
                                   with: "<strong>$1</strong>", options: .regularExpression)
        // Italic (single *)
        r = r.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#,
                                   with: "<em>$1</em>", options: .regularExpression)
        // Inline code
        r = r.replacingOccurrences(of: #"`([^`]+)`"#,
                                   with: "<code>$1</code>", options: .regularExpression)
        // Strikethrough
        r = r.replacingOccurrences(of: #"~~(.+?)~~"#,
                                   with: "<del>$1</del>", options: .regularExpression)
        // Highlight
        r = r.replacingOccurrences(of: #"==(.+?)=="#,
                                   with: "<mark>$1</mark>", options: .regularExpression)
        return r
    }

    // MARK: - HTML Wrapper

    /// Sanitize a CSS value to prevent injection (strip semicolons, braces, etc.)
    private func cssEscape(_ value: String) -> String {
        value.filter { !";{}()<>\"'\\".contains($0) }
    }

    private func wrapInHTML(_ body: String) -> String {
        let bg = isDarkMode ? "#1c1c1e" : "#ffffff"
        let fg = isDarkMode ? "#e5e5e7" : "#1d1d1f"
        let codeBg = isDarkMode ? "#2c2c2e" : "#f2f2f7"
        let border = isDarkMode ? "#38383a" : "#e5e5ea"
        let link = isDarkMode ? "#64a8ff" : "#0071e3"
        let quote = isDarkMode ? "#98989d" : "#86868b"
        let markBg = isDarkMode ? "#5a4a00" : "#fff3cd"
        let safeFont = cssEscape(fontFamily)

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8">
        <style>
        * { box-sizing: border-box; }
        body {
            font-family: \(safeFont);
            font-size: \(Int(fontSize))px;
            line-height: \(String(format: "%.1f", lineSpacing));
            color: \(fg);
            background: \(bg);
            padding: 32px 40px;
            margin: 0;
            -webkit-font-smoothing: antialiased;
            -webkit-text-size-adjust: 100%;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            margin-top: 1.4em;
            margin-bottom: 0.5em;
            letter-spacing: -0.01em;
        }
        h1 { font-size: 1.8em; font-weight: 700; letter-spacing: -0.02em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid \(border); padding-bottom: 0.3em; }
        h3 { font-size: 1.15em; }
        p { margin: 0.7em 0; }
        a { color: \(link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            background: \(codeBg);
            padding: 2px 6px;
            border-radius: 4px;
            font-family: 'SF Mono', 'Menlo', monospace;
            font-size: 0.86em;
        }
        pre {
            background: \(codeBg);
            padding: 16px 18px;
            border-radius: 8px;
            overflow-x: auto;
            line-height: 1.5;
        }
        pre code {
            background: none;
            padding: 0;
            font-size: 0.86em;
        }
        blockquote {
            border-left: 3px solid \(border);
            margin: 1em 0;
            padding-left: 18px;
            color: \(quote);
        }
        img {
            max-width: 100%;
            border-radius: 8px;
            margin: 10px 0;
        }
        hr {
            border: none;
            border-top: 1px solid \(border);
            margin: 28px 0;
        }
        mark {
            background: \(markBg);
            padding: 1px 4px;
            border-radius: 3px;
        }
        del { opacity: 0.45; }
        ul, ol { padding-left: 24px; }
        li { margin: 5px 0; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}

// MARK: - Module-Level Show Function

private var activePreview: NotePreviewController?

func showNotePreview(store: NoteStore) {
    if activePreview == nil {
        activePreview = NotePreviewController()
    }
    activePreview?.show(store: store)
}
