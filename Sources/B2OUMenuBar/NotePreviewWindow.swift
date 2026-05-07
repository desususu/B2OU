// NotePreviewWindow.swift - SwiftUI note browser and Markdown preview.

import Cocoa
import SwiftUI
import WebKit
import B2OUAppSupport
import B2OUCore
import Down

private enum SortMode: Int, CaseIterable {
    case title = 0
    case dateModified = 1
    case dateCreated = 2
    case wordCount = 3

    var title: String {
        switch self {
        case .title: return t("preview.sort_title")
        case .dateModified: return t("preview.sort_modified")
        case .dateCreated: return t("preview.sort_created")
        case .wordCount: return t("preview.sort_words")
        }
    }
}

private enum ViewMode: Int, CaseIterable {
    case preview = 0
    case source = 1
    case split = 2

    var title: String {
        switch self {
        case .preview: return t("preview.mode_preview")
        case .source: return t("preview.mode_source")
        case .split: return t("preview.mode_split")
        }
    }
}

enum NoteBrowserFilter: Int, CaseIterable {
    case all = 0
    case withImages = 1
    case untagged = 2
    case missingImages = 3
    case duplicateTitles = 4
    case missingBearId = 5

    func localizedTitle() -> String {
        switch self {
        case .all: return t("preview.filter_all")
        case .withImages: return t("preview.filter_images")
        case .untagged: return t("preview.filter_untagged")
        case .missingImages: return t("preview.filter_missing_images")
        case .duplicateTitles: return t("preview.filter_duplicate_titles")
        case .missingBearId: return t("preview.filter_missing_bear")
        }
    }
}

private final class NotePreviewController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<NotePreviewRootView>?
    private var languageObserver: NSObjectProtocol?

    func show(store: NoteStore, selecting note: NoteMetadata?, filter: NoteBrowserFilter) {
        let root = NotePreviewRootView(store: store, initialSelection: note, initialFilter: filter)
        if let window, let hostingController {
            hostingController.rootView = root
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 170, y: 150, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = t("preview.title")
        window.minSize = NSSize(width: 880, height: 560)
        window.titlebarAppearsTransparent = true
        window.delegate = self

        let hostingController = NSHostingController(rootView: root)
        window.contentViewController = hostingController
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)

        self.window = window
        self.hostingController = hostingController
        if languageObserver == nil {
            languageObserver = makeB2OULanguageObserver { [weak self] in
                self?.window?.title = t("preview.title")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeB2OULanguageObserver(&languageObserver)
        window = nil
        hostingController = nil
    }
}

private struct NotePreviewRootView: View {
    @ObservedObject var store: NoteStore
    let initialSelection: NoteMetadata?
    let initialFilter: NoteBrowserFilter

    @State private var searchText = ""
    @State private var filter: NoteBrowserFilter
    @State private var sortMode: SortMode = .dateModified
    @State private var viewMode: ViewMode = .preview
    @State private var fontSize = 16.0
    @State private var lineSpacing = 1.55
    @State private var darkPreview = false
    @State private var selectedPath: URL?

    init(store: NoteStore, initialSelection: NoteMetadata?, initialFilter: NoteBrowserFilter) {
        self.store = store
        self.initialSelection = initialSelection
        self.initialFilter = initialFilter
        _filter = State(initialValue: initialFilter)
        _selectedPath = State(initialValue: initialSelection?.filePath)
    }

    private var notes: [NoteMetadata] { store.notes }
    private var duplicateTitleKeys: Set<String> {
        var counts: [String: Int] = [:]
        for note in notes {
            let key = note.normalizedTitleKey
            if !key.isEmpty { counts[key, default: 0] += 1 }
        }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }
    private var queryTokens: [String] {
        searchText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    private var availableFilters: [NoteBrowserFilter] {
        let hasMissingSourceLinks = notesContainMissingSourceLinks(notes)
        return NoteBrowserFilter.allCases.filter { hasMissingSourceLinks || $0 != .missingBearId }
    }
    private var filteredNotes: [NoteMetadata] {
        let duplicateKeys = duplicateTitleKeys
        var result = notes.filter { matchesFilter($0, duplicateKeys: duplicateKeys) }
        if !queryTokens.isEmpty {
            result = result.filter { matchesSearch($0, tokens: queryTokens) }
        }
        switch sortMode {
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .dateModified:
            result.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .dateCreated:
            result.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .wordCount:
            result.sort { $0.wordCount > $1.wordCount }
        }
        return result
    }
    private var selectedNote: NoteMetadata? {
        guard let selectedPath else { return filteredNotes.first }
        return filteredNotes.first { $0.filePath == selectedPath } ?? filteredNotes.first
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                browserControls
                List(filteredNotes, id: \.filePath, selection: $selectedPath) { note in
                    NotePreviewRow(note: note, queryTokens: queryTokens)
                        .tag(note.filePath)
                }
                .listStyle(.sidebar)
                resultFooter
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            if let selectedNote {
                NoteDetailView(
                    note: selectedNote,
                    queryTokens: queryTokens,
                    viewMode: $viewMode,
                    fontSize: $fontSize,
                    lineSpacing: $lineSpacing,
                    darkPreview: $darkPreview
                )
            } else {
                EmptyNoteSelectionView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker(t("preview.view"), selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Stepper(value: $fontSize, in: 12...24, step: 1) {
                    Text("\(Int(fontSize))")
                        .monospacedDigit()
                }
                .frame(width: 86)

                Button {
                    darkPreview.toggle()
                } label: {
                    Image(systemName: darkPreview ? "moon.fill" : "sun.max")
                }
                .help(t("preview.theme"))
            }
        }
        .onAppear {
            repairFilter()
            if selectedPath == nil {
                selectedPath = initialSelection?.filePath ?? filteredNotes.first?.filePath
            }
        }
        .onChange(of: filter) { _ in repairSelection() }
        .onChange(of: sortMode) { _ in repairSelection() }
        .onChange(of: searchText) { _ in repairSelection() }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 880, minHeight: 560)
        .b2ouRefreshesOnLanguageChange()
    }

    private var browserControls: some View {
        VStack(spacing: 10) {
            TextField(t("preview.search"), text: $searchText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("", selection: $filter) {
                    ForEach(availableFilters, id: \.self) { item in
                        Text(item.localizedTitle()).tag(item)
                    }
                }
                .labelsHidden()
                Picker("", selection: $sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
            }
        }
        .padding(12)
    }

    private var resultFooter: some View {
        Text(t("preview.result_count").replacingOccurrences(of: "{count}", with: "\(filteredNotes.count)"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func repairFilter() {
        if !availableFilters.contains(filter) {
            filter = .all
        }
    }

    private func repairSelection() {
        repairFilter()
        guard !filteredNotes.isEmpty else {
            selectedPath = nil
            return
        }
        if let selectedPath, filteredNotes.contains(where: { $0.filePath == selectedPath }) {
            return
        }
        selectedPath = filteredNotes.first?.filePath
    }

    private func matchesFilter(_ note: NoteMetadata, duplicateKeys: Set<String>) -> Bool {
        switch filter {
        case .all:
            return true
        case .withImages:
            return note.hasImages
        case .untagged:
            return note.tags.isEmpty
        case .missingImages:
            return note.missingImageRefs > 0
        case .duplicateTitles:
            return duplicateKeys.contains(note.normalizedTitleKey)
        case .missingBearId:
            return note.bearId.isEmpty
        }
    }

    private func matchesSearch(_ note: NoteMetadata, tokens: [String]) -> Bool {
        tokens.allSatisfy { token in
            note.title.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || note.tags.joined(separator: " ").range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || note.sourceMarkdown.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

private struct NotePreviewRow: View {
    let note: NoteMetadata
    let queryTokens: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                if note.hasImages {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
                if note.missingImageRefs > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Text(rowDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let snippet = searchSnippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var rowDetail: String {
        var parts = ["\(note.wordCount) \(t("preview.words"))"]
        if let modified = note.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .omitted))
        }
        if !note.tags.isEmpty {
            parts.append(note.tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
        }
        return parts.joined(separator: "  ")
    }

    private var searchSnippet: String? {
        guard let token = queryTokens.first(where: {
            note.sourceMarkdown.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }), let range = note.sourceMarkdown.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let start = note.sourceMarkdown.index(range.lowerBound, offsetBy: -40, limitedBy: note.sourceMarkdown.startIndex) ?? note.sourceMarkdown.startIndex
        let end = note.sourceMarkdown.index(range.upperBound, offsetBy: 80, limitedBy: note.sourceMarkdown.endIndex) ?? note.sourceMarkdown.endIndex
        var snippet = String(note.sourceMarkdown[start..<end])
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if start > note.sourceMarkdown.startIndex { snippet = "..." + snippet }
        if end < note.sourceMarkdown.endIndex { snippet += "..." }
        return snippet
    }
}

private struct NoteDetailView: View {
    let note: NoteMetadata
    let queryTokens: [String]
    @Binding var viewMode: ViewMode
    @Binding var fontSize: Double
    @Binding var lineSpacing: Double
    @Binding var darkPreview: Bool

    private var bodyText: String {
        if note.isBearSourceBacked {
            return note.sourceMarkdown
        }
        if let content = try? String(contentsOf: note.filePath, encoding: .utf8) {
            return stripFrontMatter(content)
        }
        return note.sourceMarkdown
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            switch viewMode {
            case .preview:
                MarkdownPreviewWebView(
                    markdown: bodyText,
                    baseURL: note.filePath.deletingLastPathComponent(),
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    darkMode: darkPreview,
                    highlightTerms: queryTokens
                )
                .id(note.filePath)
            case .source:
                SourceTextView(text: bodyText, fontSize: fontSize)
            case .split:
                HSplitView {
                    MarkdownPreviewWebView(
                        markdown: bodyText,
                        baseURL: note.filePath.deletingLastPathComponent(),
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        darkMode: darkPreview,
                        highlightTerms: queryTokens
                    )
                    .id("preview-\(note.filePath)")
                    SourceTextView(text: bodyText, fontSize: fontSize)
                }
            }
        }
    }

    private var detailHeader: some View {
        let actions = noteActionAvailability(for: note)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(metaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Button {
                        b2ouOpen(note.filePath)
                    } label: {
                        Label(t("preview.open_editor"), systemImage: "square.and.pencil")
                    }
                    .disabled(!actions.canOpenExportedFile)
                    Button {
                        b2ouReveal([note.filePath])
                    } label: {
                        Label(t("preview.reveal_finder"), systemImage: "finder")
                    }
                    .disabled(!actions.canRevealExportedFile)
                    Button {
                        openInBear(note)
                    } label: {
                        Label(t("preview.open_bear"), systemImage: "link")
                    }
                    .disabled(!actions.canOpenInBear)
                }
            }
            if !note.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(note.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(18)
    }

    private var metaText: String {
        var parts = ["\(note.wordCount) \(t("preview.words"))"]
        if let modified = note.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        if note.missingImageRefs > 0 {
            parts.append(t("preview.missing_images").replacingOccurrences(of: "{count}", with: "\(note.missingImageRefs)"))
        }
        return parts.joined(separator: "  ")
    }

    private func openInBear(_ note: NoteMetadata) {
        guard let url = b2ouBearNoteURL(noteID: note.bearId) else { return }
        b2ouOpen(url)
    }
}

private struct SourceTextView: View {
    let text: String
    let fontSize: Double

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? t("workspace.no_preview_text") : text)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct EmptyNoteSelectionView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(t("preview.no_selection_title"))
                .font(.title3.weight(.semibold))
            Text(t("preview.no_selection_detail"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MarkdownPreviewWebView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL
    let fontSize: Double
    let lineSpacing: Double
    let darkMode: Bool
    let highlightTerms: [String]

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(wrapHTML(markdownToHTML(markdown)), baseURL: baseURL)
    }

    private func markdownToHTML(_ markdown: String) -> String {
        do {
            return try Down(markdownString: markdown).toHTML()
        } catch {
            return "<pre>\(escapeHTML(markdown))</pre>"
        }
    }

    private func wrapHTML(_ body: String) -> String {
        let bg = darkMode ? "#1c1c1e" : "#ffffff"
        let fg = darkMode ? "#e5e5e7" : "#1d1d1f"
        let muted = darkMode ? "#98989d" : "#6e6e73"
        let codeBg = darkMode ? "#2c2c2e" : "#f2f2f7"
        let border = darkMode ? "#38383a" : "#e5e5ea"
        let markJSON = jsonArrayLiteral(highlightTerms)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        * { box-sizing: border-box; }
        html, body { background: \(bg); }
        body {
            color: \(fg);
            font: \(Int(fontSize))px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            line-height: \(String(format: "%.2f", lineSpacing));
            margin: 0 auto;
            max-width: 860px;
            padding: 42px 52px;
            -webkit-font-smoothing: antialiased;
        }
        h1, h2, h3 { letter-spacing: 0; line-height: 1.2; }
        h1 { font-size: 1.9em; }
        h2 { border-bottom: 1px solid \(border); padding-bottom: .25em; }
        a { color: #0a84ff; }
        blockquote { color: \(muted); border-left: 3px solid \(border); margin-left: 0; padding-left: 1em; }
        code { background: \(codeBg); border-radius: 4px; padding: 2px 5px; }
        pre { background: \(codeBg); border-radius: 6px; overflow-x: auto; padding: 14px; }
        img { max-width: 100%; border-radius: 6px; }
        mark { background: #fff3a3; color: #1d1d1f; border-radius: 2px; padding: 0 2px; }
        </style>
        </head>
        <body>
        \(body)
        <script>
        const terms = \(markJSON);
        if (terms.length) {
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          for (const node of nodes) {
            let html = node.nodeValue;
            for (const term of terms) {
              if (!term) continue;
              const escaped = term.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&");
              html = html.replace(new RegExp(escaped, "gi"), match => `<mark>${match}</mark>`);
            }
            if (html !== node.nodeValue) {
              const span = document.createElement("span");
              span.innerHTML = html;
              node.parentNode.replaceChild(span, node);
            }
          }
        }
        </script>
        </body>
        </html>
        """
    }

    private func jsonArrayLiteral(_ values: [String]) -> String {
        let trimmed = values.map { String($0.prefix(80)) }.filter { !$0.isEmpty }
        guard let data = try? JSONSerialization.data(withJSONObject: trimmed, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

private func stripFrontMatter(_ content: String) -> String {
    guard content.hasPrefix("---\n") || content.hasPrefix("---\r\n") || content.hasPrefix("---\r") else { return content }
    let lines = content.components(separatedBy: .newlines)
    for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
        return lines[(i + 1)...].joined(separator: "\n")
    }
    return content
}

private func escapeHTML(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

private var activePreview: NotePreviewController?

func showNotePreview(store: NoteStore, selecting note: NoteMetadata? = nil, filter: NoteBrowserFilter = .all) {
    if activePreview == nil {
        activePreview = NotePreviewController()
    }
    activePreview?.show(store: store, selecting: note, filter: filter)
}
