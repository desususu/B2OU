// ExportWorkspaceWindow.swift - SwiftUI export workspace.

import Cocoa
import SwiftUI
import B2OUAppSupport
import B2OUCore

private enum WorkspaceScope: Int, CaseIterable, Hashable {
    case all = 0
    case recent = 1
    case withImages = 2
    case untagged = 3
    case missingImages = 4
    case duplicateTitles = 5
    case missingBearID = 6

    var title: String {
        switch self {
        case .all: return t("workspace.scope.all.title")
        case .recent: return t("workspace.scope.recent.title")
        case .withImages: return t("workspace.scope.with_attachments.title")
        case .untagged: return t("workspace.scope.untagged.title")
        case .missingImages: return t("workspace.scope.missing_images.title")
        case .duplicateTitles: return t("workspace.scope.duplicate_titles.title")
        case .missingBearID: return t("workspace.scope.missing_bear_id.title")
        }
    }

    var detail: String {
        switch self {
        case .all: return t("workspace.scope.all.detail")
        case .recent: return t("workspace.scope.recent.detail")
        case .withImages: return t("workspace.scope.with_attachments.detail")
        case .untagged: return t("workspace.scope.untagged.detail")
        case .missingImages: return t("workspace.scope.missing_images.detail")
        case .duplicateTitles: return t("workspace.scope.duplicate_titles.detail")
        case .missingBearID: return t("workspace.scope.missing_bear_id.detail")
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .recent: return "clock"
        case .withImages: return "paperclip"
        case .untagged: return "tag.slash"
        case .missingImages: return "photo.badge.exclamationmark"
        case .duplicateTitles: return "doc.on.doc"
        case .missingBearID: return "link.badge.plus"
        }
    }
}

private enum WorkspaceLibraryMode: Int, CaseIterable, Hashable {
    case all = 0
    case recent = 1
    case favorites = 2

    var title: String {
        switch self {
        case .all: return t("workspace.library.all")
        case .recent: return t("workspace.library.recent")
        case .favorites: return t("workspace.library.favorites")
        }
    }
}

private struct WorkspaceAttachmentPreview: Identifiable {
    let id = UUID()
    let noteTitle: String
    let attachments: [WorkspaceAttachment]
}

private struct WorkspaceAttachment: Identifiable {
    let id = UUID()
    let name: String
    let reference: String
    let url: URL?
    let isImage: Bool
}

private struct ExportWorkspaceState {
    let store: NoteStore
    let config: ExportConfig
    let lastExportTime: Date?
    let exportedNoteCount: Int
    let onExportAll: () -> Void
    let onExportSelected: (Set<String>) -> Void
    let onRefreshWorkspace: () -> Void
    let onRebuildState: () -> Void
    let onOpenPreferences: () -> Void
}

private final class ExportWorkspaceController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<ExportWorkspaceRootView>?
    private var languageObserver: NSObjectProtocol?

    func show(state: ExportWorkspaceState) {
        let root = ExportWorkspaceRootView(state: state)
        if let window, let hostingController {
            hostingController.rootView = root
            window.title = t("workspace.title")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 96, width: 1360, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = t("workspace.title")
        window.minSize = NSSize(width: 960, height: 620)
        window.isReleasedWhenClosed = false
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
                self?.window?.title = t("workspace.title")
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        removeB2OULanguageObserver(&languageObserver)
        window = nil
        hostingController = nil
    }
}

private struct ExportWorkspaceRootView: View {
    let state: ExportWorkspaceState

    @State private var activeScope: WorkspaceScope = .all
    @State private var libraryMode: WorkspaceLibraryMode = .all
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var isInspectorVisible = false
    @State private var selectedPaths: Set<URL> = []
    @State private var attachmentPreview: WorkspaceAttachmentPreview?
    @State private var sortOrder: WorkspaceSortOrder = .modified
    @AppStorage("workspace.favoriteNotePaths") private var favoriteNotePathsData = ""

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Derived Data

    private var notes: [NoteMetadata] { state.store.notes }
    private var stats: NoteStatistics? { state.store.stats }
    private var health: BearSourceHealth { BearSourceHealth.evaluate(config: state.config) }
    private var exportPath: String { state.config.exportPath.path }
    private var workspaceNoteCount: Int {
        state.exportedNoteCount > 0 ? state.exportedNoteCount : (stats?.totalNotes ?? notes.count)
    }
    private var hasMissingSourceLinks: Bool {
        notesContainMissingSourceLinks(notes)
    }
    private var scopesForBar: [WorkspaceScope] {
        WorkspaceScope.allCases.filter { hasMissingSourceLinks || $0 != .missingBearID }
    }
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
    private var filteredNotes: [NoteMetadata] {
        let duplicateKeys = duplicateTitleKeys
        var result = notes.filter { matchesScope($0, duplicateKeys: duplicateKeys) }
        switch libraryMode {
        case .all: break
        case .recent:
            let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
            result = result.filter { ($0.modified ?? .distantPast) >= cutoff }
        case .favorites:
            result = result.filter { favoriteNotePaths.contains($0.filePath.path) }
        }
        if let selectedTag {
            result = result.filter { $0.tags.contains(selectedTag) }
        }
        if !queryTokens.isEmpty {
            result = result.filter { note in
                queryTokens.allSatisfy { token in
                    note.title.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        || note.tags.joined(separator: " ").range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        || note.sourceMarkdown.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        switch sortOrder {
        case .title:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .modified:
            result.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .words:
            result.sort { $0.wordCount > $1.wordCount }
        case .created:
            result.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        }
        return result
    }
    private var selectedNotes: [NoteMetadata] {
        notes.filter { selectedPaths.contains($0.filePath) }
    }
    private var previewNote: NoteMetadata? {
        selectedNotes.first ?? filteredNotes.first
    }
    private var missingSelectedIDs: Int {
        selectedNotes.filter { $0.bearId.isEmpty }.count
    }
    private var favoriteNotePaths: Set<String> {
        Set(favoriteNotePathsData.split(separator: "\n").map(String.init))
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            scopeBar
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                contentArea
                    .frame(minWidth: 380, idealWidth: 680, maxWidth: .infinity)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: DS.groupedBackground))
        .tint(WorkspacePalette.accent)
        .frame(minWidth: 960, minHeight: 620)
        .onChange(of: activeScope) { _ in repairSelection() }
        .onChange(of: libraryMode) { _ in repairSelection() }
        .onChange(of: searchText) { _ in repairSelection() }
        .onChange(of: selectedTag) { _ in repairSelection() }
        .onChange(of: sortOrder) { _ in repairSelection() }
        .sheet(item: $attachmentPreview) { preview in
            WorkspaceAttachmentPreviewSheet(preview: preview)
        }
        .b2ouRefreshesOnLanguageChange()
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WorkspacePalette.accent)
            Text(t("workspace.title"))
                .font(.system(size: 15, weight: .semibold))

            searchField
                .frame(maxWidth: 340)

            Spacer()

            if !health.isAvailable {
                bearNotAvailableWarning
            } else {
                connectionBadge
            }

            Button {
                state.onRefreshWorkspace()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16)
            }
            .help(t("workspace.refresh_bear"))
            .buttonStyle(.borderless)
            .disabled(!health.isAvailable)

            Button {
                state.onOpenPreferences()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 16)
            }
            .help(t("workspace.preferences"))
            .buttonStyle(.borderless)

            Button {
                state.onExportAll()
            } label: {
                Label(t("workspace.export_full_scope"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!health.isAvailable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(t("workspace.search_placeholder"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }

    private var bearNotAvailableWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(t("workspace.bear_unavailable_short"))
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.orange.opacity(0.10)))
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(t("workspace.connected"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Scope Bar

    private var scopeBar: some View {
        HStack(spacing: 6) {
            ForEach(scopesForBar, id: \.self) { scope in
                ScopeChip(
                    title: scope.title,
                    count: count(for: scope),
                    icon: scope.icon,
                    isSelected: activeScope == scope,
                    hasIssues: scope == .missingImages || scope == .missingBearID || scope == .duplicateTitles || scope == .untagged
                ) {
                    activeScope = scope
                }
            }
            Spacer()

            Picker("", selection: $libraryMode) {
                ForEach(WorkspaceLibraryMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)

            Spacer()

            Menu {
                ForEach(WorkspaceSortOrder.allCases, id: \.self) { order in
                    Button {
                        sortOrder = order
                    } label: {
                        HStack {
                            Text(order.title)
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                    Text(sortOrder.title)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: DS.sidebarBackground).opacity(0.5))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarNotesList
            Divider()
            sidebarTagCloud
        }
        .background(Color(nsColor: DS.sidebarBackground))
    }

    private var sidebarNotesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(filteredNotes.count) \(t("workspace.notes"))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectedPaths.isEmpty {
                    Button(t("workspace.deselect_all")) {
                        selectedPaths = []
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkspacePalette.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let pinned = filteredNotes.filter { isFavorite($0) }
                    let normal = filteredNotes.filter { !isFavorite($0) }

                    if !pinned.isEmpty {
                        WorkspaceSidebarLabel(t("workspace.pinned_notes"))
                        ForEach(pinned, id: \.filePath) { note in
                            WorkspaceNoteRowNew(
                                note: note,
                                isFavorite: true,
                                isSelected: selectedPaths.contains(note.filePath),
                                queryTokens: queryTokens
                            ) {
                                toggleSelection(note)
                            } onPreview: {
                                selectOnly(note)
                            }
                        }
                    }

                    WorkspaceSidebarLabel(libraryMode == .favorites ? t("workspace.favorites") : t("workspace.notes"))
                    if filteredNotes.isEmpty {
                        emptyFilterResults
                    } else {
                        ForEach(normal, id: \.filePath) { note in
                            WorkspaceNoteRowNew(
                                note: note,
                                isFavorite: false,
                                isSelected: selectedPaths.contains(note.filePath),
                                queryTokens: queryTokens
                            ) {
                                toggleSelection(note)
                            } onPreview: {
                                selectOnly(note)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyFilterResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .padding(.top, 32)
            Text(t("preview.no_results_detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !searchText.isEmpty {
                Button(t("workspace.clear_search")) {
                    searchText = ""
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(WorkspacePalette.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var sidebarTagCloud: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                WorkspaceSidebarLabel(t("workspace.tags"))
                Spacer()
                if selectedTag != nil {
                    Button {
                        selectedTag = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkspacePalette.accent)
                }
            }
            .padding(.horizontal, 8)

            if let tags = stats?.tagFrequency, !tags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tags.prefix(12), id: \.tag) { item in
                        Button {
                            withAnimation(.easeOut(duration: 0.12)) {
                                selectedTag = selectedTag == item.tag ? nil : item.tag
                            }
                        } label: {
                            WorkspaceTagChip(
                                tag: item.tag,
                                count: item.count,
                                isSelected: selectedTag == item.tag
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text(t("workspace.tags_empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.softCardBackground).opacity(0.72))
    }

    // MARK: - Content Area

    private var contentArea: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if let previewNote {
                        previewCard(for: previewNote)
                    } else {
                        emptyPreview
                    }

                    if isInspectorVisible {
                        inspectorCards
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: DS.groupedBackground))
    }

    private func previewCard(for note: NoteMetadata) -> some View {
        let actions = noteActionAvailability(for: note)
        return VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(2)
                    HStack(spacing: 12) {
                        if let mod = note.modified {
                            Text(dateString(mod))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("\(note.wordCount) \(t("preview.words"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if note.charCount > 0 {
                            Text("\(note.charCount) \(t("preview.chars"))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !note.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(note.tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                        .foregroundStyle(WorkspacePalette.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(WorkspacePalette.accentSoft))
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 8)

                VStack(spacing: 4) {
                    Button {
                        toggleFavorite(note)
                    } label: {
                        Image(systemName: isFavorite(note) ? "star.fill" : "star")
                    }
                    .help(isFavorite(note) ? t("workspace.unfavorite_note") : t("workspace.favorite_note"))
                    .buttonStyle(WorkspacePreviewIconButtonStyle(isActive: isFavorite(note)))

                    Button {
                        attachmentPreview = makeAttachmentPreview(for: note)
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .help(t("workspace.preview_attachments"))
                    .buttonStyle(WorkspacePreviewIconButtonStyle(isActive: note.hasImages))

                    Menu {
                        Button(t("workspace.reveal_note")) { revealNoteInFinder(note) }
                            .disabled(!actions.canRevealExportedFile)
                        Button(t("workspace.open_editor")) { b2ouOpen(note.filePath) }
                            .disabled(!actions.canOpenExportedFile)
                        Button(t("workspace.open_bear")) { openInBear(note) }
                            .disabled(!actions.canOpenInBear)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 30, height: 30)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(18)

            Rectangle()
                .fill(Color(nsColor: DS.line).opacity(0.6))
                .frame(height: 0.6)

            // Markdown preview
            MarkEditMarkdownPreview(
                markdown: note.sourceMarkdown,
                baseURL: note.filePath.deletingLastPathComponent()
            )
            .frame(minHeight: 300, maxHeight: .infinity)
        }
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 3)
    }

    private var emptyPreview: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(WorkspacePalette.accentSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundStyle(WorkspacePalette.accent)
            }
            Text(t("workspace.no_selection_preview"))
                .font(.headline)
            Text(t("workspace.preview_optional"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }

    private var inspectorCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            inspectorExportCard
            inspectorIssuesCard
            inspectorStatusCard
        }
    }

    private var inspectorExportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WorkspacePalette.accent)
                Text(t("workspace.export_actions"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isInspectorVisible = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button {
                    let ids = Set(selectedNotes.map(\.bearId).filter { !$0.isEmpty })
                    state.onExportSelected(ids)
                } label: {
                    Label(t("workspace.export_selected"), systemImage: "arrow.up.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedNotes.isEmpty || missingSelectedIDs > 0 || !health.isAvailable)

                Button {
                    state.onExportAll()
                } label: {
                    Label(t("workspace.export_full_scope"), systemImage: "tray.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!health.isAvailable)
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(exportPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }

    private var inspectorIssuesCard: some View {
        let warningCount = selectedWarningCount(selectedNotes)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: warningCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(warningCount > 0 ? .orange : .green)
                Text(t("workspace.export_status"))
                    .font(.subheadline.weight(.semibold))
            }

            if !health.isAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("workspace.bear_unavailable_title"))
                            .font(.callout.weight(.medium))
                        Text(t("workspace.bear_unavailable_fix"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(t("workspace.open_preferences")) {
                            state.onOpenPreferences()
                        }
                        .controlSize(.small)
                        .padding(.top, 2)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
            }

            if missingSelectedIDs > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("workspace.missing_bear_ids_title"))
                            .font(.callout.weight(.medium))
                        Text(t("workspace.missing_bear_ids_fix"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if hasMissingSourceLinks {
                            Button {
                                state.onRebuildState()
                            } label: {
                                Label(t("workspace.rebuild_state"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
            }

            if warningCount == 0 && health.isAvailable && missingSelectedIDs == 0 {
                Text(t("workspace.no_blocking_issues"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }

    private var inspectorStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(t("workspace.summary"))
                    .font(.subheadline.weight(.semibold))
            }

            statusRow(icon: "doc.text", label: t("workspace.status_available"), value: "\(workspaceNoteCount)")
            statusRow(icon: "checkmark.circle", label: t("workspace.status_selected"), value: "\(selectedNotes.count)")
            statusRow(icon: "clock.arrow.circlepath", label: t("workspace.status_last_export"), value: lastExportText())

            if state.lastExportTime != nil {
                Text(t("workspace.format_export_path")
                    .replacingOccurrences(of: "{format}", with: exportFormatText)
                    .replacingOccurrences(of: "{path}", with: exportPath))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }

    private func statusRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }

    private var exportFormatText: String {
        switch state.config.exportFormat {
        case "tb": return "TextBundle"
        case "both": return "Markdown + TextBundle"
        default: return "Markdown"
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        let warningCount = selectedWarningCount(selectedNotes)
        return HStack(spacing: 16) {
            Label(
                health.isAvailable ? t("workspace.status_connection_healthy") : t("workspace.status_bear_unavailable"),
                systemImage: health.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(health.isAvailable ? .green : .orange)

            Spacer()

            Text("\(filteredNotes.count) / \(workspaceNoteCount) \(t("workspace.notes").lowercased())")
                .foregroundStyle(.secondary)

            if !selectedPaths.isEmpty {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(selectedPaths.count) \(t("workspace.selected"))")
                    .foregroundStyle(WorkspacePalette.accent)
            }

            if warningCount > 0 {
                Text("·")
                    .foregroundStyle(.tertiary)
                Label("\(warningCount) \(t("workspace.warnings"))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func isFavorite(_ note: NoteMetadata) -> Bool {
        favoriteNotePaths.contains(note.filePath.path)
    }

    private func toggleFavorite(_ note: NoteMetadata) {
        var paths = favoriteNotePaths
        let path = note.filePath.path
        if paths.contains(path) {
            paths.remove(path)
        } else {
            paths.insert(path)
        }
        favoriteNotePathsData = paths.sorted().joined(separator: "\n")
    }

    private func selectOnly(_ note: NoteMetadata) {
        selectedPaths = [note.filePath]
    }

    private func toggleSelection(_ note: NoteMetadata) {
        if selectedPaths.contains(note.filePath) {
            selectedPaths.remove(note.filePath)
        } else {
            selectedPaths.insert(note.filePath)
        }
        if selectedPaths.isEmpty {
            selectedPaths = [note.filePath]
        }
    }

    private func revealNoteInFinder(_ note: NoteMetadata) {
        guard noteActionAvailability(for: note).canRevealExportedFile else { return }
        b2ouReveal([note.filePath])
    }

    private func openInBear(_ note: NoteMetadata) {
        guard let url = b2ouBearNoteURL(noteID: note.bearId) else { return }
        b2ouOpen(url)
    }

    private func makeAttachmentPreview(for note: NoteMetadata) -> WorkspaceAttachmentPreview {
        WorkspaceAttachmentPreview(noteTitle: note.title, attachments: attachments(for: note))
    }

    private func attachments(for note: NoteMetadata) -> [WorkspaceAttachment] {
        let baseURL = note.filePath.deletingLastPathComponent()
        var seen = Set<String>()
        let references = markdownAttachmentReferences(in: note.sourceMarkdown).filter { reference in
            guard isPotentialAttachmentReference(reference) else { return false }
            let key = reference.removingPercentEncoding ?? reference
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        return references.map { reference in
            let resolved = resolveAttachmentReference(reference, note: note, baseURL: baseURL)
            let name = resolved?.lastPathComponent ?? attachmentDisplayName(from: reference)
            return WorkspaceAttachment(
                name: name,
                reference: reference,
                url: resolved,
                isImage: isImageAttachment(name: name, reference: reference)
            )
        }
    }

    private func isPotentialAttachmentReference(_ reference: String) -> Bool {
        let decoded = (reference.removingPercentEncoding ?? reference)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = decoded.lowercased()
        if lower.isEmpty
            || lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("data:")
            || lower.hasPrefix("bear://")
            || lower.hasPrefix("mailto:")
            || lower.hasPrefix("#") {
            return false
        }

        if bearAttachmentParts(from: decoded) != nil {
            return true
        }

        return !(decoded as NSString).pathExtension.isEmpty
    }

    private func resolveAttachmentReference(_ reference: String, note: NoteMetadata, baseURL: URL) -> URL? {
        let decoded = (reference.removingPercentEncoding ?? reference)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = decoded.lowercased()
        guard !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://"),
              !lower.hasPrefix("data:") else {
            return nil
        }

        let candidates = attachmentCandidateURLs(for: decoded, note: note, baseURL: baseURL)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func attachmentCandidateURLs(for reference: String, note: NoteMetadata, baseURL: URL) -> [URL] {
        var candidates: [URL] = []
        let exportURL = URL(fileURLWithPath: exportPath)
        let assetsURL = state.config.assetsPath ?? exportURL.appendingPathComponent("BearImages")
        let textBundleURL = note.filePath.pathExtension.lowercased() == "textbundle"
            ? note.filePath
            : URL(fileURLWithPath: note.filePath.deletingPathExtension().path + ".textbundle")
        let textBundleAssets = textBundleURL.appendingPathComponent("assets")

        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            if !candidates.contains(standardized) {
                candidates.append(standardized)
            }
        }

        if reference.hasPrefix("file://"), let url = URL(string: reference) {
            add(url)
            return candidates
        }
        if reference.hasPrefix("/") {
            add(URL(fileURLWithPath: reference))
            return candidates
        }

        if let bearParts = bearAttachmentParts(from: reference) {
            add(assetsURL.appendingPathComponent(bearParts.folder).appendingPathComponent(bearParts.filename))
            add(textBundleAssets.appendingPathComponent(bearParts.filename))
            if !note.bearId.isEmpty {
                add(assetsURL.appendingPathComponent(safeBearCLIAssetFolderName(noteID: note.bearId)).appendingPathComponent(bearParts.filename))
            }
        }

        add(baseURL.appendingPathComponent(reference))
        add(exportURL.appendingPathComponent(reference))
        add(assetsURL.appendingPathComponent(reference))
        add(textBundleAssets.appendingPathComponent((reference as NSString).lastPathComponent))
        if !note.bearId.isEmpty {
            add(assetsURL.appendingPathComponent(safeBearCLIAssetFolderName(noteID: note.bearId)).appendingPathComponent((reference as NSString).lastPathComponent))
        }
        return candidates
    }

    private func markdownAttachmentReferences(in markdown: String) -> [String] {
        let patterns = [
            #"!\[[^\]]*\]\(([^)]+)\)"#,
            #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#,
            #"\[file:(.+?)\]"#,
            #"\[image:(.+?)\]"#,
            #"(?<!!)\[[^\]]+\]\(([^)]+)\)"#
        ]
        let nsMarkdown = markdown as NSString
        var references: [String] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(location: 0, length: nsMarkdown.length)
            regex.enumerateMatches(in: markdown, options: [], range: range) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let raw = nsMarkdown.substring(with: match.range(at: 1))
                let cleaned = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
                if !cleaned.isEmpty {
                    references.append(cleaned)
                }
            }
        }

        return references
    }

    private func bearAttachmentParts(from reference: String) -> (folder: String, filename: String)? {
        let stripped = reference
            .replacingOccurrences(of: "[image:", with: "")
            .replacingOccurrences(of: "[file:", with: "")
            .replacingOccurrences(of: "]", with: "")
        let parts = stripped.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return (parts[0], parts[1])
        }
        return nil
    }

    private func attachmentDisplayName(from reference: String) -> String {
        if let parts = bearAttachmentParts(from: reference) {
            return parts.filename
        }
        return (reference as NSString).lastPathComponent.isEmpty ? reference : (reference as NSString).lastPathComponent
    }

    private func isImageAttachment(name: String, reference: String) -> Bool {
        if reference.lowercased().hasPrefix("[image:") { return true }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        return imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func repairSelection() {
        if !scopesForBar.contains(activeScope) {
            activeScope = .all
        }
        selectedPaths = selectedPaths.intersection(Set(filteredNotes.map(\.filePath)))
    }

    private func boolText(_ enabled: Bool) -> String {
        enabled ? t("workspace.enabled") : t("workspace.disabled")
    }

    private func matchesScope(_ note: NoteMetadata, duplicateKeys: Set<String>) -> Bool {
        switch activeScope {
        case .all:
            return true
        case .recent:
            guard let modified = note.modified else { return false }
            let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
            return modified >= cutoff
        case .withImages:
            return note.hasImages
        case .untagged:
            return note.tags.isEmpty
        case .missingImages:
            return note.missingImageRefs > 0
        case .duplicateTitles:
            return duplicateKeys.contains(note.normalizedTitleKey)
        case .missingBearID:
            return note.bearId.isEmpty
        }
    }

    private func count(for scope: WorkspaceScope) -> Int {
        let duplicateKeys = duplicateTitleKeys
        return notes.filter { note in
            switch scope {
            case .all:
                return true
            case .recent:
                guard let modified = note.modified else { return false }
                let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
                return modified >= cutoff
            case .withImages:
                return note.hasImages
            case .untagged:
                return note.tags.isEmpty
            case .missingImages:
                return note.missingImageRefs > 0
            case .duplicateTitles:
                return duplicateKeys.contains(note.normalizedTitleKey)
            case .missingBearID:
                return note.bearId.isEmpty
            }
        }.count
    }

    private func selectedWarningCount(_ notes: [NoteMetadata]) -> Int {
        let duplicateKeys = duplicateTitleKeys
        return notes.reduce(0) { count, note in
            count + (note.missingImageRefs > 0 ? 1 : 0)
                + (note.bearId.isEmpty ? 1 : 0)
                + (duplicateKeys.contains(note.normalizedTitleKey) ? 1 : 0)
        }
    }

    private func lastExportText() -> String {
        guard let last = state.lastExportTime else { return t("workspace.not_yet") }
        let seconds = max(0, Int(Date().timeIntervalSince(last)))
        if seconds < 60 { return t("workspace.just_now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: last, relativeTo: Date())
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return t("workspace.no_date") }
        if Calendar.current.isDateInToday(date) {
            return t("workspace.today_time").replacingOccurrences(
                of: "{time}",
                with: date.formatted(date: .omitted, time: .shortened)
            )
        }
        if Calendar.current.isDateInYesterday(date) { return t("workspace.yesterday") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct WorkspaceSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum WorkspacePalette {
    static let accent = Color(nsColor: DS.accentPink)
    static let accentSoft = Color(nsColor: DS.accentPinkSoft)
}

private enum WorkspaceSortOrder: Int, CaseIterable {
    case modified = 0
    case title = 1
    case words = 2
    case created = 3

    var title: String {
        switch self {
        case .modified: return t("workspace.sort_modified")
        case .title: return t("workspace.sort_title")
        case .words: return t("workspace.sort_words")
        case .created: return t("workspace.sort_created")
        }
    }
}

private extension WorkspaceScope {
    func titleWithCount(_ count: Int) -> String {
        "\(title) (\(count))"
    }
}

private struct ScopeChip: View {
    let title: String
    let count: Int
    let icon: String
    let isSelected: Bool
    let hasIssues: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? WorkspacePalette.accent : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? WorkspacePalette.accent : .primary)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? WorkspacePalette.accentSoft : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? WorkspacePalette.accent.opacity(0.25) : Color.clear, lineWidth: 0.8)
        )
        .onHover { hovering = $0 }
        .help("\(title) (\(count))")
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var totalHeight: CGFloat = 0
        for row in rows {
            var maxH: CGFloat = 0
            for item in row {
                let s = item.sizeThatFits(.unspecified)
                if s.height > maxH { maxH = s.height }
            }
            totalHeight += maxH
        }
        if rows.count > 1 {
            totalHeight += CGFloat(rows.count - 1) * spacing
        }
        return CGSize(width: proposal.width ?? 0, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowSizes = row.map { $0.sizeThatFits(.unspecified) }
            for (item, size) in zip(row, rowSizes) {
                item.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += (rowSizes.map(\.height).max() ?? 0) + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? 0
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty && currentWidth + size.width > maxWidth {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}

private struct WorkspaceSidebarLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
    }
}

private struct WorkspaceScopeRow: View {
    let scope: WorkspaceScope
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: scope.icon)
                .frame(width: 17)
                .foregroundStyle(isSelected ? WorkspacePalette.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(scope.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(scope.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            isSelected ? WorkspacePalette.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }
}

private struct WorkspaceTagChip: View {
    let tag: String
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text("#\(tag)")
                .lineLimit(1)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSelected ? WorkspacePalette.accent : Color.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? WorkspacePalette.accentSoft : Color(nsColor: DS.cardBackground),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? WorkspacePalette.accent.opacity(0.30) : Color(nsColor: DS.line), lineWidth: 0.7)
        )
        .foregroundStyle(isSelected ? WorkspacePalette.accent : Color.primary)
    }
}

private struct WorkspaceInspectorCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content
                .font(.callout)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 10, x: 0, y: 3)
    }
}

private struct WorkspacePreviewIconButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isActive ? WorkspacePalette.accent : Color.secondary)
            .frame(width: 30, height: 30)
            .background(
                (configuration.isPressed || isActive)
                    ? WorkspacePalette.accentSoft
                    : Color(nsColor: DS.softCardBackground).opacity(0.68),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isActive ? WorkspacePalette.accent.opacity(0.22) : Color(nsColor: DS.line).opacity(0.55), lineWidth: 0.7)
            )
    }
}

private struct WorkspaceSettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                settingTitle
                Spacer(minLength: 8)
                content
            }

            VStack(alignment: .leading, spacing: 6) {
                settingTitle
                content
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var settingTitle: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

private struct WorkspaceStatusMetricRow: View {
    let title: String
    let value: String
    var isWarning = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(isWarning ? Color.orange : Color.primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct WorkspaceEmptyPreview: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(WorkspacePalette.accent)
            Text(t("workspace.no_selection_preview"))
                .font(.headline)
            Text(t("workspace.preview_optional"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }
}

private struct WorkspaceAttachmentPreviewSheet: View {
    let preview: WorkspaceAttachmentPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("workspace.attachments"))
                        .font(.headline)
                    Text(preview.noteTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(preview.attachments.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(18)

            Divider()

            if preview.attachments.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(t("workspace.no_attachments"))
                        .font(.headline)
                    Text(t("workspace.no_attachments_detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(width: 680, height: 420)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(preview.attachments) { attachment in
                            WorkspaceAttachmentTile(attachment: attachment)
                        }
                    }
                    .padding(16)
                }
                .frame(width: 720, height: 480)
            }
        }
        .background(Color(nsColor: DS.groupedBackground))
    }
}

private struct WorkspaceAttachmentTile: View {
    let attachment: WorkspaceAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            attachmentPreview
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: DS.softCardBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(attachment.url?.path ?? t("workspace.attachment_unresolved"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let url = attachment.url {
                HStack {
                    Button(t("workspace.open_attachment")) {
                        b2ouOpen(url)
                    }
                    Button(t("workspace.reveal_attachment")) {
                        b2ouReveal([url])
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: DS.cardBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: DS.line), lineWidth: 0.7)
        )
    }

    @ViewBuilder private var attachmentPreview: some View {
        if attachment.isImage,
           let url = attachment.url,
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            VStack(spacing: 8) {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .font(.system(size: 32))
                    .foregroundStyle(attachment.url == nil ? Color.orange : Color.secondary)
                if attachment.url == nil {
                    Text(t("workspace.attachment_unresolved"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WorkspaceNoteRowNew: View {
    let note: NoteMetadata
    let isFavorite: Bool
    let isSelected: Bool
    let queryTokens: [String]
    let onToggleSelect: () -> Void
    let onPreview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                onToggleSelect()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? WorkspacePalette.accent : Color.secondary.opacity(0.65))
            }
            .buttonStyle(.plain)
            .frame(width: 18)

            Button {
                onPreview()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(WorkspacePalette.accent)
                        }
                        Text(note.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if note.missingImageRefs > 0 || note.bearId.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("\(note.wordCount) w")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if !note.tags.isEmpty {
                            Text(note.tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? WorkspacePalette.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }
}

private struct WorkspaceNoteRow: View {
    let note: NoteMetadata
    let isFavorite: Bool
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(WorkspacePalette.accent)
                }
                Text(note.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(dateText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if note.hasImages {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if note.missingImageRefs > 0 || note.bearId.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(compact(note.sourceMarkdown, limit: 82))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            isSelected ? WorkspacePalette.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? WorkspacePalette.accent.opacity(0.22) : Color.clear, lineWidth: 0.7)
        )
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts = ["\(note.wordCount) \(t("preview.words"))"]
        if !note.tags.isEmpty {
            parts.append(note.tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
        }
        return parts.joined(separator: "  ")
    }

    private var dateText: String {
        guard let modified = note.modified else { return "" }
        return modified.formatted(date: .numeric, time: .omitted)
    }
}

private func compact(_ value: String, limit: Int) -> String {
    let singleLine = value
        .replacingOccurrences(of: "\n", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard singleLine.count > limit else { return singleLine }
    return String(singleLine.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
}

private var activeExportWorkspace: ExportWorkspaceController?

func showExportWorkspace(
    store: NoteStore,
    config: ExportConfig,
    lastExportTime: Date?,
    exportedNoteCount: Int,
    onExportAll: @escaping () -> Void,
    onExportSelected: @escaping (Set<String>) -> Void,
    onRefreshWorkspace: @escaping () -> Void,
    onRebuildState: @escaping () -> Void,
    onOpenPreferences: @escaping () -> Void
) {
    if activeExportWorkspace == nil {
        activeExportWorkspace = ExportWorkspaceController()
    }
    activeExportWorkspace?.show(
        state: ExportWorkspaceState(
            store: store,
            config: config,
            lastExportTime: lastExportTime,
            exportedNoteCount: exportedNoteCount,
            onExportAll: onExportAll,
            onExportSelected: onExportSelected,
            onRefreshWorkspace: onRefreshWorkspace,
            onRebuildState: onRebuildState,
            onOpenPreferences: onOpenPreferences
        )
    )
}
