// DashboardWindow.swift - SwiftUI statistics dashboard.

import Cocoa
import SwiftUI
import B2OUAppSupport
import B2OUCore

private final class DashboardController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<DashboardView>?
    private var languageObserver: NSObjectProtocol?

    func show(store: NoteStore) {
        let root = DashboardView(store: store)
        if let window, let hostingController {
            hostingController.rootView = root
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 180, y: 180, width: 980, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = t("dashboard.title")
        window.minSize = NSSize(width: 820, height: 560)
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
                self?.window?.title = t("dashboard.title")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeB2OULanguageObserver(&languageObserver)
        window = nil
        hostingController = nil
        if activeDashboard === self {
            activeDashboard = nil
        }
    }
}

private struct DashboardView: View {
    @ObservedObject var store: NoteStore
    @Environment(\.colorScheme) private var colorScheme

    private var stats: NoteStatistics? { store.stats }
    private var noteOfDay: NoteMetadata? { store.noteOfTheDay() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let stats {
                    keyMetricsRow(stats)
                    activityAndTagsRow(stats)
                    insightsAndHealthRow(stats)
                    noteOfDaySection
                } else {
                    emptyState
                }
            }
            .padding(28)
        }
        .background(backgroundGradient)
        .frame(minWidth: 820, minHeight: 560)
        .tint(Color(nsColor: DS.accentPink))
        .b2ouRefreshesOnLanguageChange()
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let stats, stats.healthIssueCount > 0 {
                Circle()
                    .fill(Color.orange.opacity(0.04))
                    .frame(width: 500)
                    .offset(x: 300, y: -200)
                    .blur(radius: 80)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 80, height: 80)
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
            Text(t("preview.no_results_title"))
                .font(.title2.weight(.semibold))
            Text(t("preview.no_results_detail"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(nsColor: DS.accentPink), Color(nsColor: DS.accentPink).opacity(0.7)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 36, height: 36)
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(t("dashboard.title"))
                        .font(.system(size: 28, weight: .bold))
                }
                if let stats {
                    HStack(spacing: 16) {
                        Label("\(formatNumber(stats.totalNotes)) \(t("dashboard.total_notes").lowercased())", systemImage: "doc.text")
                        Label("\(formatCompact(stats.totalWords)) \(t("dashboard.total_words").lowercased())", systemImage: "text.word.spacing")
                        if stats.healthIssueCount > 0 {
                            Label("\(stats.healthIssueCount) issues", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showNotePreview(store: store)
            } label: {
                Label(t("dashboard.open_browser"), systemImage: "book.pages")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Key Metrics Row

    private func keyMetricsRow(_ stats: NoteStatistics) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ModernMetricCard(
                title: t("dashboard.total_notes"),
                value: formatNumber(stats.totalNotes),
                icon: "doc.text.fill",
                color: Color(nsColor: DS.accentPink),
                subtitle: stats.thisWeekNotes > 0 ? "+\(stats.thisWeekNotes) this week" : nil
            )
            ModernMetricCard(
                title: t("dashboard.total_words"),
                value: formatCompact(stats.totalWords),
                icon: "text.word.spacing",
                color: Color(nsColor: DS.accentPink),
                subtitle: stats.todayWords > 0 ? "\(formatCompact(stats.todayWords)) today" : nil
            )
            ModernMetricCard(
                title: t("dashboard.avg_words"),
                value: formatNumber(stats.averageWords),
                icon: "align.horizontal.center",
                color: Color(nsColor: DS.secondaryText),
                subtitle: "median \(formatNumber(stats.medianWords))"
            )
            ModernMetricCard(
                title: t("dashboard.notes_with_media"),
                value: "\(formatNumber(stats.notesWithImages))/\(formatNumber(stats.notesWithLinks))",
                icon: "photo.on.rectangle.angled",
                color: Color(nsColor: DS.secondaryText),
                subtitle: "images / links"
            )
        }
    }

    // MARK: - Activity + Tags Row

    private func activityAndTagsRow(_ stats: NoteStatistics) -> some View {
        HStack(alignment: .top, spacing: 14) {
            activityCard(stats)
                .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity)
            tagsCard(stats)
                .frame(minWidth: 240, idealWidth: 340, maxWidth: .infinity)
        }
    }

    private func activityCard(_ stats: NoteStatistics) -> some View {
        DashboardCard(title: t("dashboard.activity"), icon: "calendar", accent: Color(nsColor: DS.accentPink)) {
            VStack(alignment: .leading, spacing: 14) {
                activityHeatmap(activityDays: stats.activityDays)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stats.writingStreak)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .foregroundStyle(stats.writingStreak > 0 ? .green : .secondary)
                        Text(stats.writingStreak == 1
                             ? t("dashboard.streak_day")
                             : t("dashboard.streak_days"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if stats.thisWeekNotes > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(stats.thisWeekNotes)")
                                .font(.title2.weight(.bold).monospacedDigit())
                            Text(t("dashboard.this_week"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if stats.thisWeekWords > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatCompact(stats.thisWeekWords))
                                .font(.title2.weight(.bold).monospacedDigit())
                            Text(t("dashboard.words_this_week"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if stats.uniqueTags > 0 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(stats.uniqueTags)")
                                .font(.title2.weight(.bold).monospacedDigit())
                            Text(t("dashboard.unique_tags"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func activityHeatmap(activityDays: [Date: Int]) -> some View {
        let days = recentDays()
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<14, id: \.self) { col in
                        let idx = row * 14 + col
                        if idx < days.count {
                            let day = days[idx]
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(heatmapColor(for: activityDays[Calendar.current.startOfDay(for: day), default: 0]))
                                .frame(width: 13, height: 13)
                                .help(day.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
        }
    }

    private func tagsCard(_ stats: NoteStatistics) -> some View {
        DashboardCard(title: t("dashboard.top_tags"), icon: "tag", accent: Color(nsColor: DS.accentPink)) {
            if stats.tagFrequency.isEmpty {
                Text(t("workspace.tags_empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stats.tagFrequency.prefix(6), id: \.tag) { item in
                        HStack(spacing: 10) {
                            TagBadge(tag: item.tag)
                            Spacer()
                            Text(formatNumber(item.count))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if stats.uniqueTags > 6 {
                        Text("+\(stats.uniqueTags - 6) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: - Insights + Health Row

    private func insightsAndHealthRow(_ stats: NoteStatistics) -> some View {
        HStack(alignment: .top, spacing: 14) {
            healthCard(stats)
                .frame(minWidth: 280, idealWidth: 360, maxWidth: .infinity)
            longestNotesCard(stats)
                .frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity)
        }
    }

    private func healthCard(_ stats: NoteStatistics) -> some View {
        DashboardCard(
            title: t("dashboard.health"),
            icon: stats.healthIssueCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
            accent: stats.healthIssueCount == 0 ? .green : .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(stats.healthIssueCount == 0
                         ? t("dashboard.ready")
                         : t("dashboard.needs_review"))
                        .font(.headline)
                        .foregroundStyle(stats.healthIssueCount == 0 ? .green : .orange)
                    Spacer()
                    if stats.healthIssueCount > 0 {
                        Text("\(stats.healthIssueCount)")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }

                let issues: [(String, Int, String, NoteBrowserFilter)] = [
                    (t("dashboard.untagged"), stats.untaggedNotes, "tag.slash", .untagged),
                    (t("dashboard.missing_images"), stats.missingImageRefs, "photo.badge.exclamationmark", .missingImages),
                    (t("dashboard.duplicate_titles"), stats.duplicateTitleNotes, "doc.on.doc.fill", .duplicateTitles),
                ] + (stats.missingBearIds > 0
                    ? [(t("dashboard.missing_bear"), stats.missingBearIds, "link.badge.plus", NoteBrowserFilter.missingBearId)]
                    : [])

                ForEach(issues, id: \.0) { issue in
                    HealthIssuePill(
                        title: issue.0,
                        count: issue.1,
                        icon: issue.2,
                        filter: issue.3,
                        store: store
                    )
                }
            }
        }
    }

    private func longestNotesCard(_ stats: NoteStatistics) -> some View {
        DashboardCard(title: t("dashboard.longest_notes"), icon: "text.alignleft", accent: .purple) {
            VStack(alignment: .leading, spacing: 8) {
                if stats.longestNotes.isEmpty {
                    Text(t("preview.no_results_title"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(stats.longestNotes.enumerated()), id: \.offset) { i, note in
                        HStack(spacing: 10) {
                            Text("\(i + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .leading)
                            Text(note.title)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                            Text("\(formatNumber(note.words)) \(t("preview.words"))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Note of the Day

    private var noteOfDaySection: some View {
        Group {
            if let note = noteOfDay {
                let actions = noteActionAvailability(for: note)
                DashboardCard(title: t("dashboard.note_of_day"), icon: "sparkles", accent: .yellow) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.title)
                                .font(.title3.weight(.semibold))
                                .lineLimit(2)
                            Text(compactSnippet(from: note.sourceMarkdown))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Text("\(note.wordCount) \(t("preview.words"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !note.tags.isEmpty {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                                        TagBadge(tag: tag, compact: true)
                                    }
                                }
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Button {
                                b2ouOpen(note.filePath)
                            } label: {
                                Label(t("dashboard.open_editor"), systemImage: "square.and.pencil")
                                    .frame(width: 120)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!actions.canOpenExportedFile)
                            Button {
                                showNotePreview(store: store, selecting: note)
                            } label: {
                                Label(t("dashboard.open_browser"), systemImage: "book.pages")
                                    .frame(width: 120)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                DashboardCard(title: t("dashboard.note_of_day"), icon: "sparkles", accent: .yellow) {
                    Text(t("preview.no_selection_detail"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Supporting Views

private struct ModernMetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LinearGradient(
                    colors: [color.opacity(0.18), color.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 1)
        )
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: DS.line).opacity(0.7), lineWidth: 0.7)
        )
        .overlay(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent.opacity(0.06), Color.clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .allowsHitTesting(false)
        }
    }
}

private struct TagBadge: View {
    let tag: String
    var compact = false

    var body: some View {
        Text("#\(tag)")
            .font(compact ? .caption2 : .caption)
            .fontWeight(.medium)
            .foregroundStyle(Color(nsColor: DS.accentPink))
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule()
                    .fill(Color(nsColor: DS.accentPinkSoft))
            )
    }
}

private struct HealthIssuePill: View {
    let title: String
    let count: Int
    let icon: String
    let filter: NoteBrowserFilter
    let store: NoteStore

    var body: some View {
        Button {
            showNotePreview(store: store, filter: filter)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.12)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(count > 0 ? Color.orange.opacity(0.04) : Color.clear)
        )
        .disabled(count == 0)
    }
}

// MARK: - Shared helpers

private func recentDays() -> [Date] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    return (0..<70).compactMap { calendar.date(byAdding: .day, value: -69 + $0, to: today) }
}

private func heatmapColor(for count: Int) -> Color {
    switch count {
    case 0: return Color(nsColor: .separatorColor).opacity(0.25)
    case 1: return .green.opacity(0.35)
    case 2: return .green.opacity(0.48)
    case 3...4: return .green.opacity(0.62)
    case 5...7: return .green.opacity(0.78)
    default: return .green.opacity(0.95)
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

private func compactSnippet(from text: String, limit: Int = 280) -> String {
    let body = stripFrontMatter(text)
    let compact = body
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard !compact.isEmpty else { return t("preview.no_selection_detail") }
    if compact.count <= limit { return compact }
    return String(compact.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
}

private func formatNumber(_ value: Int) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func formatCompact(_ value: Int) -> String {
    if value >= 1_000_000 {
        let v = Double(value) / 1_000_000.0
        return v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fM", v)
            : String(format: "%.1fM", v)
    }
    if value >= 10_000 {
        return String(format: "%.0fK", Double(value) / 1000.0)
    }
    if value >= 1000 {
        let v = Double(value) / 1000.0
        return v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fK", v)
            : String(format: "%.1fK", v)
    }
    return formatNumber(value)
}

private var activeDashboard: DashboardController?

func showDashboard(store: NoteStore) {
    if activeDashboard == nil {
        activeDashboard = DashboardController()
    }
    activeDashboard?.show(store: store)
}
