// DesignSystem.swift — Centralized HIG-compliant design constants for B2OU.
//
// All spacing, typography, and shared view factories aligned to Apple's
// Human Interface Guidelines for macOS.

import Cocoa

// MARK: - Design System Constants

enum DS {
    // Spacing (8pt grid)
    static let windowPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 8
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let titlebarTopPadding: CGFloat = 34

    // MARK: - Typography (HIG Text Styles)

    static func largeTitle() -> NSFont { .systemFont(ofSize: 26, weight: .regular) }
    static func title1() -> NSFont { .systemFont(ofSize: 22, weight: .regular) }
    static func title2() -> NSFont { .systemFont(ofSize: 17, weight: .bold) }
    static func title3() -> NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    static func headline() -> NSFont { .systemFont(ofSize: 13, weight: .bold) }
    static func body() -> NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static func callout() -> NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static func subheadline() -> NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static func footnote() -> NSFont { .systemFont(ofSize: 10, weight: .regular) }
    static func caption2() -> NSFont { .systemFont(ofSize: 10, weight: .medium) }

    static func monoDigitLargeTitle() -> NSFont { .monospacedDigitSystemFont(ofSize: 26, weight: .regular) }
    static func monoDigitCaption() -> NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
    static func monoDigitSubheadline() -> NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }

    // MARK: - Export Workspace Palette

    static var groupedBackground: NSColor { adaptive(light: 0xF7F7F8, dark: 0x17171A) }
    static var sidebarBackground: NSColor { adaptive(light: 0xF1F1F3, dark: 0x202024) }
    static var cardBackground: NSColor { adaptive(light: 0xFFFFFF, dark: 0x25252A) }
    static var softCardBackground: NSColor { adaptive(light: 0xFBFBFC, dark: 0x1F1F23) }
    static var line: NSColor { adaptive(light: 0xE5E7EB, dark: 0x3A3A40) }
    static var primaryText: NSColor { adaptive(light: 0x1F2937, dark: 0xF3F4F6) }
    static var secondaryText: NSColor { adaptive(light: 0x6B7280, dark: 0xC6C8D0) }
    static var tertiaryText: NSColor { adaptive(light: 0x9CA3AF, dark: 0x8F929C) }
    static var accentPink: NSColor { adaptive(light: 0xEC4899, dark: 0xF472B6) }
    static var accentPinkSoft: NSColor { adaptive(light: 0xFCE7F3, dark: 0x3B1229) }
    static var warningBackground: NSColor { adaptive(light: 0xFFF7ED, dark: 0x3A2412) }
    static var warningBorder: NSColor { adaptive(light: 0xFED7AA, dark: 0x8A5A2B) }
    static var warningText: NSColor { adaptive(light: 0xB45309, dark: 0xFDBA74) }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: isDark(appearance) ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - Shared Card Surface

final class DSCardView: NSView {
    private let flippedCoordinates: Bool

    override var isFlipped: Bool { flippedCoordinates }
    override var wantsUpdateLayer: Bool { true }

    init(frame frameRect: NSRect, flipped: Bool) {
        flippedCoordinates = flipped
        super.init(frame: frameRect)
        wantsLayer = true
        applyCardStyle()
    }

    required init?(coder: NSCoder) {
        flippedCoordinates = false
        super.init(coder: coder)
        wantsLayer = true
        applyCardStyle()
    }

    override func updateLayer() {
        applyCardStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardStyle()
    }

    private func applyCardStyle() {
        guard let layer else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = isDark
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.50)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.76)
        let border = NSColor.separatorColor.withAlphaComponent(isDark ? 0.26 : 0.30)

        layer.cornerRadius = DS.cardRadius
        if #available(macOS 10.15, *) {
            layer.cornerCurve = .continuous
        }
        layer.masksToBounds = false
        layer.backgroundColor = background.cgColor
        layer.borderWidth = 0.5
        layer.borderColor = border.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = isDark ? 0.16 : 0.04
        layer.shadowRadius = isDark ? 14 : 8
        layer.shadowOffset = NSSize(width: 0, height: isDark ? -2 : -1)
    }
}

final class DSRoundedView: DSFlippedView {
    var fillColor: NSColor { didSet { applyStyle() } }
    var borderColor: NSColor { didSet { applyStyle() } }
    var borderWidth: CGFloat { didSet { applyStyle() } }
    var radius: CGFloat { didSet { applyStyle() } }
    var shadowOpacity: Float { didSet { applyStyle() } }
    var shadowRadius: CGFloat { didSet { applyStyle() } }

    override var wantsUpdateLayer: Bool { true }

    init(
        frame frameRect: NSRect,
        fillColor: NSColor = DS.cardBackground,
        borderColor: NSColor = DS.line,
        borderWidth: CGFloat = 0.7,
        radius: CGFloat = DS.cardRadius,
        shadowOpacity: Float = 0.04,
        shadowRadius: CGFloat = 8
    ) {
        self.fillColor = fillColor
        self.borderColor = borderColor
        self.borderWidth = borderWidth
        self.radius = radius
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        super.init(frame: frameRect)
        wantsLayer = true
        applyStyle()
    }

    required init?(coder: NSCoder) {
        fillColor = DS.cardBackground
        borderColor = DS.line
        borderWidth = 0.7
        radius = DS.cardRadius
        shadowOpacity = 0.04
        shadowRadius = 8
        super.init(coder: coder)
        wantsLayer = true
        applyStyle()
    }

    override func updateLayer() {
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        guard let layer else { return }
        layer.cornerRadius = radius
        if #available(macOS 10.15, *) {
            layer.cornerCurve = .continuous
        }
        layer.backgroundColor = DS.resolved(fillColor, for: effectiveAppearance).cgColor
        layer.borderColor = DS.resolved(borderColor, for: effectiveAppearance).cgColor
        layer.borderWidth = borderWidth
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = shadowOpacity
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = NSSize(width: 0, height: -1)
    }
}

// MARK: - Shared Card Factory

func dsCard(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
    DSCardView(frame: NSRect(x: x, y: y, width: width, height: height), flipped: false)
}

/// Card variant using a FlippedView (y=0 at top, for Settings-style layout).
func dsCardFlipped(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
    let card = DSCardView(frame: NSRect(x: x, y: y, width: width, height: height), flipped: true)
    parent.addSubview(card)
    return card
}

// MARK: - Flipped View (y=0 at top)

class DSFlippedView: NSView {
    var dsBackgroundColor: NSColor? {
        didSet { applyDSBackgroundColor() }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDSBackgroundColor()
    }

    private func applyDSBackgroundColor() {
        guard let dsBackgroundColor else { return }
        wantsLayer = true
        layer?.backgroundColor = DS.resolved(dsBackgroundColor, for: effectiveAppearance).cgColor
    }
}

class DSFlippedVisualEffectView: NSVisualEffectView {
    override var isFlipped: Bool { true }
}

final class DSColorView: NSView {
    var fillColor: NSColor {
        didSet { applyStyle() }
    }

    init(frame frameRect: NSRect, fillColor: NSColor) {
        self.fillColor = fillColor
        super.init(frame: frameRect)
        wantsLayer = true
        applyStyle()
    }

    required init?(coder: NSCoder) {
        fillColor = .clear
        super.init(coder: coder)
        wantsLayer = true
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    private func applyStyle() {
        wantsLayer = true
        layer?.backgroundColor = DS.resolved(fillColor, for: effectiveAppearance).cgColor
    }
}

extension NSView {
    func dsResolvedCGColor(_ color: NSColor) -> CGColor {
        DS.resolved(color, for: effectiveAppearance).cgColor
    }
}
