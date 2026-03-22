// DashboardWindow.swift — Statistics dashboard with writing heatmap and Note of the Day.
//
// Apple-design-inspired layout: full-size content view with titlebar vibrancy,
// card-based sections, SF Pro typography hierarchy, and generous whitespace.

import Cocoa
import B2OUCore

// MARK: - Layout Constants

private let dashWidth:  CGFloat = 740
private let dashHeight: CGFloat = 780
private let dashPad:    CGFloat = 32
private let sectionGap: CGFloat = 16
private let cardPad:    CGFloat = 20
private let cardRadius: CGFloat = 12

// MARK: - Flipped View (y=0 at top)

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Card View

private func makeCard(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
    let card = NSView(frame: NSRect(x: x, y: y, width: width, height: height))
    card.wantsLayer = true
    card.layer?.cornerRadius = cardRadius
    card.layer?.masksToBounds = true
    if #available(macOS 14.0, *) {
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
    } else {
        card.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.6).cgColor
    }
    card.layer?.borderWidth = 0.5
    card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
    return card
}

// MARK: - Heatmap View

private let cellSize: CGFloat = 10
private let cellGap:  CGFloat = 2
private let cellStep: CGFloat = 12   // cellSize + cellGap
private let weeksShown = 52
private let dayLabelW: CGFloat = 26  // space for Mon/Wed/Fri labels
private let monthLabelH: CGFloat = 16 // space for month labels above grid

class HeatmapView: NSView {
    var activityDays: [Date: Int] = [:]
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let emptyColor = isDark
            ? NSColor(white: 0.18, alpha: 1)
            : NSColor(white: 0.91, alpha: 1)
        let greens: [NSColor] = isDark
            ? [
                NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.22, alpha: 1),
                NSColor(calibratedRed: 0.14, green: 0.52, blue: 0.30, alpha: 1),
                NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.38, alpha: 1),
                NSColor(calibratedRed: 0.22, green: 0.82, blue: 0.46, alpha: 1),
              ]
            : [
                NSColor(calibratedRed: 0.62, green: 0.84, blue: 0.56, alpha: 1),
                NSColor(calibratedRed: 0.38, green: 0.72, blue: 0.42, alpha: 1),
                NSColor(calibratedRed: 0.20, green: 0.58, blue: 0.30, alpha: 1),
                NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.18, alpha: 1),
              ]

        let labelColor = isDark
            ? NSColor(white: 0.45, alpha: 1)
            : NSColor(white: 0.55, alpha: 1)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .regular)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: labelColor,
        ]

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let startDate = cal.date(byAdding: .day, value: -(weeksShown * 7), to: today) else { return }
        let weekday = cal.component(.weekday, from: startDate)
        guard let alignedStart = cal.date(byAdding: .day, value: -(weekday - 1), to: startDate) else { return }

        // Draw day-of-week labels (Mon, Wed, Fri)
        let dayNames = ["", "M", "", "W", "", "F", ""]
        for (i, name) in dayNames.enumerated() {
            guard !name.isEmpty else { continue }
            let y = monthLabelH + CGFloat(i) * cellStep + 1
            (name as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: labelAttrs)
        }

        // Draw month labels
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMM"
        var lastMonth = -1
        var currentDate = alignedStart
        for week in 0..<weeksShown {
            let month = cal.component(.month, from: currentDate)
            if month != lastMonth {
                let x = dayLabelW + CGFloat(week) * cellStep
                let label = monthFormatter.string(from: currentDate)
                (label as NSString).draw(at: NSPoint(x: x, y: 0), withAttributes: labelAttrs)
                lastMonth = month
            }
            currentDate = cal.date(byAdding: .day, value: 7, to: currentDate) ?? currentDate
        }

        // Draw grid cells
        currentDate = alignedStart
        for week in 0..<weeksShown {
            for day in 0..<7 {
                let count = activityDays[currentDate] ?? 0
                let color: NSColor
                if count == 0 { color = emptyColor }
                else if count == 1 { color = greens[0] }
                else if count <= 3 { color = greens[1] }
                else if count <= 6 { color = greens[2] }
                else { color = greens[3] }

                let x = dayLabelW + CGFloat(week) * cellStep
                let y = monthLabelH + CGFloat(day) * cellStep
                let rect = NSRect(x: x, y: y, width: cellSize, height: cellSize)

                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

                currentDate = cal.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
            }
        }
    }

    static func requiredSize() -> NSSize {
        NSSize(width: dayLabelW + CGFloat(weeksShown) * cellStep - cellGap,
               height: monthLabelH + 7 * cellStep - cellGap)
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

        // Full-size content view for titlebar blending
        let style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        let rect = NSRect(x: 0, y: 0, width: dashWidth, height: dashHeight)
        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window?.title = t("dashboard.title")
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .visible
        window?.center()
        window?.isReleasedWhenClosed = false
        window?.backgroundColor = .windowBackgroundColor

        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        // Vibrancy background
        let vibrancy = NSVisualEffectView(frame: content.bounds)
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.blendingMode = .behindWindow
        vibrancy.material = .sidebar
        vibrancy.state = .active
        content.addSubview(vibrancy)

        // Scroll view
        let scrollView = NSScrollView(frame: content.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        content.addSubview(scrollView)

        // Flipped document view (y=0 at top, increases downward)
        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: dashWidth, height: 0))
        scrollView.documentView = docView

        let w = dashWidth - dashPad * 2
        var cy: CGFloat = dashPad + 28  // extra top space for titlebar

        // ── Headline Stats Card ──────────────────────────────────

        let statsCardH: CGFloat = 96
        let statsCard = makeCard(x: dashPad, y: cy, width: w, height: statsCardH)
        docView.addSubview(statsCard)

        let statW = w / 3

        for (i, (value, label)) in [
            (formatNumber(stats.totalNotes), t("dashboard.total_notes")),
            (formatNumber(stats.totalWords), t("dashboard.total_words")),
            (formatNumber(stats.averageWords), t("dashboard.avg_words")),
        ].enumerated() {
            let x = CGFloat(i) * statW

            let numLabel = NSTextField(labelWithString: value)
            numLabel.frame = NSRect(x: x + 6, y: 18, width: statW - 12, height: 36)
            numLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
            numLabel.alignment = .center
            numLabel.textColor = .labelColor
            numLabel.lineBreakMode = .byTruncatingTail
            statsCard.addSubview(numLabel)

            let descLabel = NSTextField(labelWithString: label.uppercased())
            descLabel.frame = NSRect(x: x + 6, y: 56, width: statW - 12, height: 16)
            descLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            descLabel.textColor = .tertiaryLabelColor
            descLabel.alignment = .center
            descLabel.lineBreakMode = .byTruncatingTail
            statsCard.addSubview(descLabel)

            // Subtle vertical divider between stat columns
            if i < 2 {
                let div = NSView(frame: NSRect(x: x + statW - 0.5, y: 24, width: 1, height: statsCardH - 48))
                div.wantsLayer = true
                div.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
                statsCard.addSubview(div)
            }
        }
        cy += statsCardH + sectionGap

        // ── Top Tags Card ────────────────────────────────────────

        if !stats.tagFrequency.isEmpty {
            let topTags = Array(stats.tagFrequency.prefix(8))
            let tagRows = CGFloat(topTags.count)
            let tagCardH: CGFloat = 36 + tagRows * 26 + 14

            let tagCard = makeCard(x: dashPad, y: cy, width: w, height: tagCardH)
            docView.addSubview(tagCard)

            let sectionTitle = NSTextField(labelWithString: t("dashboard.top_tags"))
            sectionTitle.frame = NSRect(x: cardPad, y: 12, width: w - cardPad * 2, height: 18)
            sectionTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            sectionTitle.textColor = .secondaryLabelColor
            tagCard.addSubview(sectionTitle)

            let maxCount = topTags.first?.count ?? 1
            let tagLabelW: CGFloat = 140
            let barStartX: CGFloat = cardPad + tagLabelW + 10
            let countLabelW: CGFloat = 48
            let barMaxW: CGFloat = w - barStartX - countLabelW - cardPad
            var ty: CGFloat = 38

            for tag in topTags {
                let tagLabel = NSTextField(labelWithString: tag.tag)
                tagLabel.frame = NSRect(x: cardPad, y: ty, width: tagLabelW, height: 18)
                tagLabel.font = NSFont.systemFont(ofSize: 11)
                tagLabel.alignment = .right
                tagLabel.lineBreakMode = .byTruncatingTail
                tagLabel.textColor = .labelColor
                tagCard.addSubview(tagLabel)

                let barW = max(4, barMaxW * CGFloat(tag.count) / CGFloat(maxCount))
                let barView = NSView(frame: NSRect(x: barStartX, y: ty + 3, width: barW, height: 12))
                barView.wantsLayer = true
                barView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
                barView.layer?.cornerRadius = 3
                tagCard.addSubview(barView)

                let countLabel = NSTextField(labelWithString: "\(tag.count)")
                countLabel.frame = NSRect(x: w - cardPad - countLabelW, y: ty, width: countLabelW, height: 18)
                countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                countLabel.textColor = .tertiaryLabelColor
                countLabel.alignment = .right
                tagCard.addSubview(countLabel)

                ty += 26
            }
            cy += tagCardH + sectionGap
        }

        // ── Longest Notes Card ───────────────────────────────────

        if !stats.longestNotes.isEmpty {
            let noteRows = CGFloat(stats.longestNotes.count)
            let longCardH: CGFloat = 36 + noteRows * 24 + 14

            let longCard = makeCard(x: dashPad, y: cy, width: w, height: longCardH)
            docView.addSubview(longCard)

            let sectionTitle = NSTextField(labelWithString: t("dashboard.longest_notes"))
            sectionTitle.frame = NSRect(x: cardPad, y: 12, width: w - cardPad * 2, height: 18)
            sectionTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            sectionTitle.textColor = .secondaryLabelColor
            longCard.addSubview(sectionTitle)

            let wordsColW: CGFloat = 70
            var ny: CGFloat = 38
            for entry in stats.longestNotes {
                let noteLabel = NSTextField(labelWithString: entry.title)
                noteLabel.frame = NSRect(x: cardPad, y: ny, width: w - cardPad * 2 - wordsColW - 8, height: 18)
                noteLabel.font = NSFont.systemFont(ofSize: 11)
                noteLabel.lineBreakMode = .byTruncatingTail
                noteLabel.textColor = .labelColor
                longCard.addSubview(noteLabel)

                let wordsLabel = NSTextField(labelWithString: formatNumber(entry.words))
                wordsLabel.frame = NSRect(x: w - cardPad - wordsColW, y: ny, width: wordsColW, height: 18)
                wordsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                wordsLabel.textColor = .tertiaryLabelColor
                wordsLabel.alignment = .right
                longCard.addSubview(wordsLabel)

                ny += 24
            }
            cy += longCardH + sectionGap
        }

        // ── Writing Activity Heatmap Card ────────────────────────

        let heatSize = HeatmapView.requiredSize()
        let heatCardH: CGFloat = 36 + heatSize.height + 20

        let heatCard = makeCard(x: dashPad, y: cy, width: w, height: heatCardH)
        docView.addSubview(heatCard)

        let actTitle = NSTextField(labelWithString: t("dashboard.activity"))
        actTitle.frame = NSRect(x: cardPad, y: 12, width: w - cardPad * 2, height: 18)
        actTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        actTitle.textColor = .secondaryLabelColor
        heatCard.addSubview(actTitle)

        let heatmap = HeatmapView(frame: NSRect(
            x: (w - heatSize.width) / 2,
            y: 36,
            width: heatSize.width,
            height: heatSize.height
        ))
        heatmap.activityDays = stats.activityDays
        heatCard.addSubview(heatmap)
        cy += heatCardH + sectionGap

        // ── Note of the Day Card ─────────────────────────────────

        if let noteOfDay {
            let nodCardH: CGFloat = 100

            let nodCard = makeCard(x: dashPad, y: cy, width: w, height: nodCardH)
            docView.addSubview(nodCard)

            let sectionTitle = NSTextField(labelWithString: t("dashboard.note_of_day"))
            sectionTitle.frame = NSRect(x: cardPad, y: 12, width: w - cardPad * 2, height: 18)
            sectionTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            sectionTitle.textColor = .secondaryLabelColor
            nodCard.addSubview(sectionTitle)

            let btnW: CGFloat = 110
            let noteTitle = NSTextField(labelWithString: "\u{201c}\(noteOfDay.title)\u{201d}")
            noteTitle.frame = NSRect(x: cardPad, y: 36, width: w - cardPad * 2 - btnW - 12, height: 20)
            noteTitle.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            noteTitle.lineBreakMode = .byTruncatingTail
            noteTitle.textColor = .labelColor
            nodCard.addSubview(noteTitle)

            var infoY: CGFloat = 60
            if let created = noteOfDay.created {
                let ago = agoString(from: created)
                let agoLabel = NSTextField(labelWithString:
                    t("dashboard.written_ago").replacingOccurrences(of: "{time}", with: ago))
                agoLabel.frame = NSRect(x: cardPad, y: infoY, width: w - cardPad * 2 - btnW - 12, height: 16)
                agoLabel.font = NSFont.systemFont(ofSize: 11)
                agoLabel.textColor = .tertiaryLabelColor
                nodCard.addSubview(agoLabel)
                infoY += 18
            }

            let openBtn = NSButton(frame: NSRect(x: w - cardPad - btnW, y: 40, width: btnW - 4, height: 26))
            openBtn.title = t("dashboard.open_editor")
            openBtn.bezelStyle = .rounded
            openBtn.controlSize = .small
            openBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            openBtn.target = self
            openBtn.action = #selector(onOpenNoteOfDay)
            nodCard.addSubview(openBtn)

            cy += nodCardH + sectionGap
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
