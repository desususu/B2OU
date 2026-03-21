// DashboardWindow.swift — Statistics dashboard with writing heatmap and Note of the Day.
//
// Displays aggregate statistics computed from exported notes: headline numbers,
// tag frequency bars, longest notes, a GitHub-style activity heatmap, and a
// "Note of the Day" resurfacing feature.
//
// Uses a flipped document view (y=0 at top) for natural top-to-bottom layout.

import Cocoa
import B2OUCore

// MARK: - Layout Constants

private let dashWidth:  CGFloat = 640
private let dashHeight: CGFloat = 700
private let dashPad:    CGFloat = 24
private let sectionGap: CGFloat = 22

// MARK: - Flipped View (y=0 at top)

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Heatmap View

private let cellSize: CGFloat = 11
private let cellGap:  CGFloat = 2
private let cellStep: CGFloat = 13   // cellSize + cellGap
private let weeksShown = 52

class HeatmapView: NSView {
    var activityDays: [Date: Int] = [:]
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let emptyColor = isDark
            ? NSColor(white: 0.22, alpha: 1)
            : NSColor(white: 0.91, alpha: 1)
        let greens: [NSColor] = isDark
            ? [
                NSColor(calibratedRed: 0.15, green: 0.40, blue: 0.15, alpha: 1),
                NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.20, alpha: 1),
                NSColor(calibratedRed: 0.25, green: 0.70, blue: 0.25, alpha: 1),
                NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.30, alpha: 1),
              ]
            : [
                NSColor(calibratedRed: 0.60, green: 0.85, blue: 0.60, alpha: 1),
                NSColor(calibratedRed: 0.35, green: 0.72, blue: 0.35, alpha: 1),
                NSColor(calibratedRed: 0.15, green: 0.58, blue: 0.15, alpha: 1),
                NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.00, alpha: 1),
              ]

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(weeksShown * 7), to: today) else { return }
        let weekday = cal.component(.weekday, from: startDate)
        guard let alignedStart = cal.date(byAdding: .day, value: -(weekday - 1), to: startDate) else { return }

        var currentDate = alignedStart
        for week in 0..<weeksShown {
            for day in 0..<7 {
                let count = activityDays[currentDate] ?? 0
                let color: NSColor
                if count == 0 { color = emptyColor }
                else if count == 1 { color = greens[0] }
                else if count <= 3 { color = greens[1] }
                else if count <= 6 { color = greens[2] }
                else { color = greens[3] }

                let x = CGFloat(week) * cellStep
                let y = CGFloat(day) * cellStep
                let rect = NSRect(x: x, y: y, width: cellSize, height: cellSize)

                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

                currentDate = cal.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
            }
        }
    }

    static func requiredSize() -> NSSize {
        NSSize(width: CGFloat(weeksShown) * cellStep - cellGap,
               height: 7 * cellStep - cellGap)
    }
}

// MARK: - Dashboard Controller

class DashboardController: NSObject {
    private var window: NSWindow?
    private var store: NoteStore?
    private var noteOfDay: NoteMetadata?

    func show(store: NoteStore) {
        self.store = store

        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        buildAndShow()
    }

    func close() {
        window?.close()
        window = nil
    }

    private func buildAndShow() {
        guard let store, let stats = store.stats else { return }
        noteOfDay = store.noteOfTheDay()

        let style: NSWindow.StyleMask = [.titled, .closable]
        let rect = NSRect(x: 0, y: 0, width: dashWidth, height: dashHeight)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window?.title = t("dashboard.title")
        window?.center()
        window?.isReleasedWhenClosed = false

        guard let content = window?.contentView else { return }

        // Scroll view
        let scrollView = NSScrollView(frame: content.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        content.addSubview(scrollView)

        // Flipped document view (y=0 at top, increases downward)
        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: dashWidth, height: 0))
        scrollView.documentView = docView

        let w = dashWidth - dashPad * 2
        var cy = dashPad

        // ── Headline Stats ──────────────────────────────────────

        let statW = w / 3

        for (i, (value, label)) in [
            (formatNumber(stats.totalNotes), t("dashboard.total_notes")),
            (formatNumber(stats.totalWords), t("dashboard.total_words")),
            (formatNumber(stats.averageWords), t("dashboard.avg_words")),
        ].enumerated() {
            let x = dashPad + CGFloat(i) * statW

            let numLabel = NSTextField(labelWithString: value)
            numLabel.frame = NSRect(x: x, y: cy, width: statW, height: 32)
            numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
            numLabel.alignment = .center
            docView.addSubview(numLabel)

            let descLabel = NSTextField(labelWithString: label)
            descLabel.frame = NSRect(x: x, y: cy + 34, width: statW, height: 18)
            descLabel.font = NSFont.systemFont(ofSize: 12)
            descLabel.textColor = .secondaryLabelColor
            descLabel.alignment = .center
            docView.addSubview(descLabel)
        }
        cy += 56 + sectionGap

        // ── Top Tags ────────────────────────────────────────────

        if !stats.tagFrequency.isEmpty {
            let tagTitle = NSTextField(labelWithString: t("dashboard.top_tags"))
            tagTitle.frame = NSRect(x: dashPad, y: cy, width: w, height: 20)
            tagTitle.font = NSFont.boldSystemFont(ofSize: 13)
            docView.addSubview(tagTitle)
            cy += 24

            let topTags = Array(stats.tagFrequency.prefix(10))
            let maxCount = topTags.first?.count ?? 1

            for tag in topTags {
                let tagLabel = NSTextField(labelWithString: tag.tag)
                tagLabel.frame = NSRect(x: dashPad, y: cy, width: 140, height: 18)
                tagLabel.font = NSFont.systemFont(ofSize: 11)
                tagLabel.alignment = .right
                tagLabel.lineBreakMode = .byTruncatingTail
                docView.addSubview(tagLabel)

                let barMaxW: CGFloat = w - 210
                let barW = max(4, barMaxW * CGFloat(tag.count) / CGFloat(maxCount))
                let barView = NSView(frame: NSRect(x: dashPad + 148, y: cy + 2, width: barW, height: 14))
                barView.wantsLayer = true
                barView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                barView.layer?.cornerRadius = 3
                docView.addSubview(barView)

                let countLabel = NSTextField(labelWithString: "\(tag.count)")
                countLabel.frame = NSRect(x: dashPad + 156 + barW, y: cy, width: 40, height: 18)
                countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                countLabel.textColor = .secondaryLabelColor
                docView.addSubview(countLabel)

                cy += 22
            }
            cy += sectionGap
        }

        // ── Longest Notes ───────────────────────────────────────

        if !stats.longestNotes.isEmpty {
            let longTitle = NSTextField(labelWithString: t("dashboard.longest_notes"))
            longTitle.frame = NSRect(x: dashPad, y: cy, width: w, height: 20)
            longTitle.font = NSFont.boldSystemFont(ofSize: 13)
            docView.addSubview(longTitle)
            cy += 24

            for entry in stats.longestNotes {
                let noteLabel = NSTextField(labelWithString: entry.title)
                noteLabel.frame = NSRect(x: dashPad + 8, y: cy, width: w - 80, height: 18)
                noteLabel.font = NSFont.systemFont(ofSize: 11)
                noteLabel.lineBreakMode = .byTruncatingTail
                docView.addSubview(noteLabel)

                let wordsLabel = NSTextField(labelWithString: formatNumber(entry.words))
                wordsLabel.frame = NSRect(x: dashPad + w - 70, y: cy, width: 70, height: 18)
                wordsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                wordsLabel.textColor = .secondaryLabelColor
                wordsLabel.alignment = .right
                docView.addSubview(wordsLabel)

                cy += 20
            }
            cy += sectionGap
        }

        // ── Writing Activity Heatmap ────────────────────────────

        let actTitle = NSTextField(labelWithString: t("dashboard.activity"))
        actTitle.frame = NSRect(x: dashPad, y: cy, width: w, height: 20)
        actTitle.font = NSFont.boldSystemFont(ofSize: 13)
        docView.addSubview(actTitle)
        cy += 26

        let heatSize = HeatmapView.requiredSize()
        let heatmap = HeatmapView(frame: NSRect(
            x: dashPad + (w - heatSize.width) / 2,
            y: cy,
            width: heatSize.width,
            height: heatSize.height
        ))
        heatmap.activityDays = stats.activityDays
        docView.addSubview(heatmap)
        cy += heatSize.height + sectionGap

        // ── Note of the Day ─────────────────────────────────────

        if let noteOfDay {
            let nodTitle = NSTextField(labelWithString: t("dashboard.note_of_day"))
            nodTitle.frame = NSRect(x: dashPad, y: cy, width: w, height: 20)
            nodTitle.font = NSFont.boldSystemFont(ofSize: 13)
            docView.addSubview(nodTitle)
            cy += 26

            let noteTitle = NSTextField(labelWithString: "\u{201c}\(noteOfDay.title)\u{201d}")
            noteTitle.frame = NSRect(x: dashPad + 8, y: cy, width: w - 16, height: 20)
            noteTitle.font = NSFont.systemFont(ofSize: 13)
            noteTitle.lineBreakMode = .byTruncatingTail
            docView.addSubview(noteTitle)
            cy += 22

            if let created = noteOfDay.created {
                let ago = agoString(from: created)
                let agoLabel = NSTextField(labelWithString:
                    t("dashboard.written_ago").replacingOccurrences(of: "{time}", with: ago))
                agoLabel.frame = NSRect(x: dashPad + 8, y: cy, width: w - 16, height: 16)
                agoLabel.font = NSFont.systemFont(ofSize: 11)
                agoLabel.textColor = .secondaryLabelColor
                docView.addSubview(agoLabel)
                cy += 20
            }

            cy += 6
            let openBtn = NSButton(frame: NSRect(x: dashPad + 8, y: cy, width: 140, height: 24))
            openBtn.title = t("dashboard.open_editor")
            openBtn.bezelStyle = .rounded
            openBtn.target = self
            openBtn.action = #selector(onOpenNoteOfDay)
            docView.addSubview(openBtn)
            cy += 30 + sectionGap
        }

        // Set document view to exact content height
        cy += dashPad
        docView.frame = NSRect(x: 0, y: 0, width: dashWidth, height: cy)

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Actions

    @objc private func onOpenNoteOfDay() {
        if let note = noteOfDay {
            NSWorkspace.shared.open(note.filePath)
        }
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func agoString(from date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days < 1 { return t("dashboard.today") }
        if days < 30 { return "\(days) " + t("dashboard.days") }
        let months = days / 30
        if months < 12 { return "\(months) " + t("dashboard.months") }
        let years = months / 12
        return "\(years) " + t("dashboard.years")
    }
}

// MARK: - Module-Level Show Function

private var activeDashboard: DashboardController?

func showDashboard(store: NoteStore) {
    if activeDashboard == nil {
        activeDashboard = DashboardController()
    }
    activeDashboard?.show(store: store)
}
