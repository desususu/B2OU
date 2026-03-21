// NotePreviewWindow.swift — Note browser with Markdown preview, typography controls,
// and day/night mode toggle.
//
// Provides a split-view window: searchable note list on the left, rendered Markdown
// preview on the right via WKWebView. Users can customize font, size, line spacing,
// and switch between light/dark themes.

import Cocoa
import WebKit
import B2OUCore

// MARK: - Layout Constants

private let previewWidth:  CGFloat = 960
private let previewHeight: CGFloat = 640
private let sidebarWidth:  CGFloat = 240
private let toolbarH:      CGFloat = 36
private let bottomBarH:    CGFloat = 32

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

    // Typography state
    private var fontFamily = "-apple-system, BlinkMacSystemFont, sans-serif"
    private var fontSize: CGFloat = 15
    private var lineSpacing: CGFloat = 1.6
    private var isDarkMode = false

    private let fontOptions: [(label: String, css: String)] = [
        ("System",   "-apple-system, BlinkMacSystemFont, sans-serif"),
        ("Menlo",    "'Menlo', monospace"),
        ("Georgia",  "'Georgia', serif"),
        ("Palatino", "'Palatino', serif"),
    ]
    private let sizeOptions: [CGFloat] = [12, 13, 14, 15, 16, 18, 20]
    private let spacingOptions: [CGFloat] = [1.0, 1.2, 1.4, 1.5, 1.6, 1.8, 2.0]

    func show(store: NoteStore) {
        self.store = store
        filteredNotes = store.notes.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        if let window, window.isVisible {
            tableView?.reloadData()
            window.makeKeyAndOrderFront(nil)
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

    // MARK: - Build Window

    private func buildWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let rect = NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window?.title = t("preview.title")
        window?.center()
        window?.isReleasedWhenClosed = false
        window?.minSize = NSSize(width: 640, height: 400)

        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let ch = content.frame.height
        let cw = content.frame.width

        // ── Toolbar ─────────────────────────────────────────────

        let toolbar = NSView(frame: NSRect(x: 0, y: ch - toolbarH, width: cw, height: toolbarH))
        toolbar.autoresizingMask = [.width, .minYMargin]
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(toolbar)

        var tx: CGFloat = 12

        // Font popup
        let fontLabel = NSTextField(labelWithString: t("preview.font"))
        fontLabel.frame = NSRect(x: tx, y: 8, width: 32, height: 18)
        fontLabel.font = NSFont.systemFont(ofSize: 11)
        toolbar.addSubview(fontLabel)
        tx += 34

        let fontPopup = NSPopUpButton(frame: NSRect(x: tx, y: 4, width: 110, height: 24), pullsDown: false)
        fontPopup.font = NSFont.systemFont(ofSize: 11)
        for opt in fontOptions { fontPopup.addItem(withTitle: opt.label) }
        fontPopup.target = self
        fontPopup.action = #selector(onFontChanged(_:))
        toolbar.addSubview(fontPopup)
        tx += 118

        // Size popup
        let sizeLabel = NSTextField(labelWithString: t("preview.size"))
        sizeLabel.frame = NSRect(x: tx, y: 8, width: 28, height: 18)
        sizeLabel.font = NSFont.systemFont(ofSize: 11)
        toolbar.addSubview(sizeLabel)
        tx += 30

        let sizePopup = NSPopUpButton(frame: NSRect(x: tx, y: 4, width: 60, height: 24), pullsDown: false)
        sizePopup.font = NSFont.systemFont(ofSize: 11)
        for s in sizeOptions { sizePopup.addItem(withTitle: "\(Int(s))") }
        if let idx = sizeOptions.firstIndex(of: fontSize) { sizePopup.selectItem(at: idx) }
        sizePopup.target = self
        sizePopup.action = #selector(onSizeChanged(_:))
        toolbar.addSubview(sizePopup)
        tx += 68

        // Spacing popup
        let spacingLabel = NSTextField(labelWithString: t("preview.spacing"))
        spacingLabel.frame = NSRect(x: tx, y: 8, width: 42, height: 18)
        spacingLabel.font = NSFont.systemFont(ofSize: 11)
        toolbar.addSubview(spacingLabel)
        tx += 44

        let spacingPopup = NSPopUpButton(frame: NSRect(x: tx, y: 4, width: 60, height: 24), pullsDown: false)
        spacingPopup.font = NSFont.systemFont(ofSize: 11)
        for s in spacingOptions { spacingPopup.addItem(withTitle: String(format: "%.1f", s)) }
        if let idx = spacingOptions.firstIndex(of: lineSpacing) { spacingPopup.selectItem(at: idx) }
        spacingPopup.target = self
        spacingPopup.action = #selector(onSpacingChanged(_:))
        toolbar.addSubview(spacingPopup)
        tx += 68

        // Day/Night segmented control
        let themeControl = NSSegmentedControl(labels: [t("preview.day_mode"), t("preview.night_mode")],
                                             trackingMode: .selectOne,
                                             target: self,
                                             action: #selector(onThemeChanged(_:)))
        themeControl.frame = NSRect(x: tx + 12, y: 5, width: 120, height: 22)
        themeControl.font = NSFont.systemFont(ofSize: 11)
        themeControl.selectedSegment = 0
        toolbar.addSubview(themeControl)

        // ── Sidebar ─────────────────────────────────────────────

        let sideY = bottomBarH
        let sideH = ch - toolbarH - bottomBarH

        let sidebarView = NSView(frame: NSRect(x: 0, y: sideY, width: sidebarWidth, height: sideH))
        sidebarView.autoresizingMask = [.height]
        content.addSubview(sidebarView)

        // Search field
        searchField = NSSearchField(frame: NSRect(x: 8, y: sideH - 30, width: sidebarWidth - 16, height: 24))
        searchField?.font = NSFont.systemFont(ofSize: 12)
        searchField?.placeholderString = t("preview.search")
        searchField?.target = self
        searchField?.action = #selector(onSearch(_:))
        searchField?.autoresizingMask = [.minYMargin, .width]
        sidebarView.addSubview(searchField!)

        // Table view in scroll view
        let tableScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: sideH - 36))
        tableScroll.autoresizingMask = [.height, .width]
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        tableView = NSTableView()
        tableView?.headerView = nil
        tableView?.rowHeight = 28
        tableView?.intercellSpacing = NSSize(width: 0, height: 1)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.width = sidebarWidth - 20
        tableView?.addTableColumn(col)
        tableView?.dataSource = self
        tableView?.delegate = self
        tableScroll.documentView = tableView

        sidebarView.addSubview(tableScroll)

        // Vertical divider
        let divider = NSView(frame: NSRect(x: sidebarWidth, y: sideY, width: 1, height: sideH))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.autoresizingMask = [.height]
        content.addSubview(divider)

        // ── Content Pane ────────────────────────────────────────

        let contentX = sidebarWidth + 1
        let contentW = cw - contentX

        webView = WKWebView(frame: NSRect(x: contentX, y: sideY, width: contentW, height: sideH))
        webView?.autoresizingMask = [.width, .height]
        content.addSubview(webView!)

        // Load empty state
        let emptyHTML = wrapInHTML("<p style=\"color:#999;text-align:center;margin-top:40%\">\(t("preview.no_selection"))</p>")
        webView?.loadHTMLString(emptyHTML, baseURL: nil)

        // ── Bottom Bar ──────────────────────────────────────────

        let bottomBar = NSView(frame: NSRect(x: 0, y: 0, width: cw, height: bottomBarH))
        bottomBar.autoresizingMask = [.width]
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.addSubview(bottomBar)

        // Horizontal divider
        let hDiv = NSView(frame: NSRect(x: 0, y: bottomBarH - 1, width: cw, height: 1))
        hDiv.wantsLayer = true
        hDiv.layer?.backgroundColor = NSColor.separatorColor.cgColor
        hDiv.autoresizingMask = [.width]
        bottomBar.addSubview(hDiv)

        wordCountLabel = NSTextField(labelWithString: "")
        wordCountLabel?.frame = NSRect(x: 12, y: 6, width: 200, height: 18)
        wordCountLabel?.font = NSFont.systemFont(ofSize: 11)
        wordCountLabel?.textColor = .secondaryLabelColor
        bottomBar.addSubview(wordCountLabel!)

        let openEditorBtn = NSButton(frame: NSRect(x: cw - 260, y: 3, width: 120, height: 24))
        openEditorBtn.title = t("preview.open_editor")
        openEditorBtn.bezelStyle = .rounded
        openEditorBtn.font = NSFont.systemFont(ofSize: 11)
        openEditorBtn.target = self
        openEditorBtn.action = #selector(onOpenEditor)
        openEditorBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(openEditorBtn)

        openBearBtn = NSButton(frame: NSRect(x: cw - 130, y: 3, width: 120, height: 24))
        openBearBtn?.title = t("preview.open_bear")
        openBearBtn?.bezelStyle = .rounded
        openBearBtn?.font = NSFont.systemFont(ofSize: 11)
        openBearBtn?.target = self
        openBearBtn?.action = #selector(onOpenBear)
        openBearBtn?.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(openBearBtn!)
    }

    // MARK: - Table View Data Source

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredNotes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("NoteCell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.lineBreakMode = .byTruncatingTail
            cell.font = NSFont.systemFont(ofSize: 12)
        }
        cell.stringValue = filteredNotes[row].title
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

    private func loadNote(_ note: NoteMetadata) {
        guard let content = try? String(contentsOf: note.filePath, encoding: .utf8) else { return }
        let body = stripFrontMatter(content)
        let html = wrapInHTML(markdownToHTML(body))
        webView?.loadHTMLString(html, baseURL: note.filePath.deletingLastPathComponent())

        wordCountLabel?.stringValue = "\(note.wordCount) \(t("preview.words"))"
        openBearBtn?.isHidden = note.bearId.isEmpty
    }

    private func refreshPreview() {
        guard let note = selectedNote else { return }
        loadNote(note)
    }

    // MARK: - Actions

    @objc private func onSearch(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard let store else { return }

        if query.isEmpty {
            filteredNotes = store.notes.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } else {
            filteredNotes = store.notes.filter { note in
                note.title.lowercased().contains(query)
                    || note.tags.contains { $0.lowercased().contains(query) }
            }.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        tableView?.reloadData()
    }

    @objc private func onFontChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < fontOptions.count else { return }
        fontFamily = fontOptions[idx].css
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

    @objc private func onOpenEditor() {
        guard let note = selectedNote else { return }
        NSWorkspace.shared.open(note.filePath)
    }

    @objc private func onOpenBear() {
        guard let note = selectedNote, !note.bearId.isEmpty,
              let url = URL(string: "bear://x-callback-url/open-note?id=\(note.bearId)") else { return }
        NSWorkspace.shared.open(url)
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

    func wrapInHTML(_ body: String) -> String {
        let bg = isDarkMode ? "#1e1e1e" : "#ffffff"
        let fg = isDarkMode ? "#e0e0e0" : "#1d1d1f"
        let codeBg = isDarkMode ? "#2d2d2d" : "#f5f5f5"
        let border = isDarkMode ? "#444" : "#e0e0e0"
        let link = isDarkMode ? "#4da6ff" : "#0066cc"
        let quote = isDarkMode ? "#aaa" : "#666"
        let markBg = isDarkMode ? "#5a4a00" : "#fff3cd"

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8">
        <style>
        body {
            font-family: \(fontFamily);
            font-size: \(Int(fontSize))px;
            line-height: \(String(format: "%.1f", lineSpacing));
            color: \(fg);
            background: \(bg);
            padding: 20px 28px;
            margin: 0;
            -webkit-font-smoothing: antialiased;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            margin-top: 1.2em;
            margin-bottom: 0.4em;
        }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid \(border); padding-bottom: 0.2em; }
        h3 { font-size: 1.2em; }
        p { margin: 0.6em 0; }
        a { color: \(link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            background: \(codeBg);
            padding: 2px 5px;
            border-radius: 3px;
            font-family: 'SF Mono', 'Menlo', monospace;
            font-size: 0.88em;
        }
        pre {
            background: \(codeBg);
            padding: 14px;
            border-radius: 6px;
            overflow-x: auto;
        }
        pre code {
            background: none;
            padding: 0;
            font-size: 0.88em;
        }
        blockquote {
            border-left: 3px solid \(border);
            margin: 0.8em 0;
            padding-left: 16px;
            color: \(quote);
        }
        img {
            max-width: 100%;
            border-radius: 6px;
            margin: 8px 0;
        }
        hr {
            border: none;
            border-top: 1px solid \(border);
            margin: 24px 0;
        }
        mark {
            background: \(markBg);
            padding: 1px 3px;
            border-radius: 2px;
        }
        del { opacity: 0.5; }
        ul, ol { padding-left: 24px; }
        li { margin: 4px 0; }
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
