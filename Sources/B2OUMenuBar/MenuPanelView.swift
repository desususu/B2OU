// MenuPanelView.swift - Compact SwiftUI popover panel for the B2OU menu bar app.

import Cocoa
import SwiftUI
import B2OUAppSupport
import B2OUCore

private enum MenuPanelMetrics {
    static let width: CGFloat = 380
    static let height: CGFloat = 708
    static let outerPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 9
    static let headerHeight: CGFloat = 92
    static let controlHeight: CGFloat = 44
    static let rowHeight: CGFloat = 40
    static let dropdownItemHeight: CGFloat = 34
    static let dropdownVerticalPadding: CGFloat = 5
    static let dropdownOuterSpacing: CGFloat = 6
    static let rowCornerRadius: CGFloat = 10
    static let cardCornerRadius: CGFloat = 14
}

final class MenuPanelState: ObservableObject {
    @Published var appTitle = "Exporter for Bear"
    @Published var summaryText = t("menu.starting")
    @Published var lastExportText = ""
    @Published var lastBackupText = ""
    @Published var statusText = ""
    @Published var statusStyle: MenuPanelStatusStyle = .neutral
    @Published var canExportNow = false
    @Published var isExporting = false
    @Published var isPaused = false
    @Published var isLoginItemEnabled = false
    @Published var languageCode = "en"
    @Published var profileNames: [String] = []
    @Published var activeProfileName: String?
    @Published var exportFolderName: String?
}

struct MenuPanelActions {
    let exportNow: () -> Void
    let togglePause: () -> Void
    let openFolder: () -> Void
    let openWorkspace: () -> Void
    let openDashboard: () -> Void
    let changeFolder: () -> Void
    let configure: () -> Void
    let editConfig: () -> Void
    let setLoginItemEnabled: (Bool) -> Void
    let setupProfile: () -> Void
    let selectProfile: (String) -> Void
    let reloadProfiles: () -> Void
    let setLanguage: (String) -> Void
    let resizePanel: (CGFloat) -> Void
    let quit: () -> Void
}

private enum PanelDropdownKind {
    case profile
    case language
}

private struct PanelDropdownItem: Identifiable {
    let id = UUID()
    let title: String
    var isSeparator = false
    var isSelected = false
    var action: (() -> Void)?

    static func action(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> PanelDropdownItem {
        PanelDropdownItem(title: title, isSelected: selected, action: action)
    }

    static var separator: PanelDropdownItem {
        PanelDropdownItem(title: "", isSeparator: true)
    }
}

struct MenuPanelView: View {
    static let preferredSize = NSSize(width: MenuPanelMetrics.width, height: MenuPanelMetrics.height)

    @ObservedObject var model: MenuPanelState
    let actions: MenuPanelActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var activeDropdown: PanelDropdownKind?

    var body: some View {
        ZStack {
            MenuPanelMaterial()
            panelTint

            VStack(alignment: .leading, spacing: MenuPanelMetrics.sectionSpacing) {
                header
                primaryActions

                PanelSection(title: panelText(zh: "\u{5FEB}\u{6377}\u{64CD}\u{4F5C}", en: "Quick Actions")) {
                    PanelActionRow(
                        icon: "folder",
                        title: t("menu.open_folder"),
                        showsChevron: true,
                        action: actions.openFolder
                    )
                    PanelDivider()
                    PanelActionRow(
                        icon: "rectangle.grid.2x2",
                        title: t("menu.workspace"),
                        shortcut: "\u{2318}W",
                        keyboardShortcut: "w",
                        action: actions.openWorkspace
                    )
                    PanelDivider()
                    PanelActionRow(
                        icon: "chart.bar",
                        title: t("menu.dashboard"),
                        showsChevron: true,
                        action: actions.openDashboard
                    )
                    PanelDivider()
                    PanelActionRow(
                        icon: "folder.badge.gearshape",
                        title: t("menu.change_folder"),
                        showsChevron: true,
                        action: actions.changeFolder
                    )
                }

                PanelSection(title: panelText(zh: "\u{914D}\u{7F6E}", en: "Configuration")) {
                    PanelDropdownRow(
                        icon: "person.crop.circle",
                        title: t("menu.profile"),
                        isExpanded: activeDropdown == .profile,
                        items: profileDropdownItems,
                        onToggle: {
                            toggleDropdown(.profile)
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.14)) {
                                activeDropdown = nil
                            }
                        }
                    )
                    PanelDivider()
                    PanelActionRow(
                        icon: "slider.horizontal.3",
                        title: t("menu.configure"),
                        shortcut: "\u{2318},",
                        keyboardShortcut: ",",
                        action: actions.configure
                    )
                    PanelDivider()
                    PanelActionRow(
                        icon: "doc.text",
                        title: t("menu.edit_config"),
                        action: actions.editConfig
                    )
                    PanelDivider()
                    PanelToggleRow(
                        icon: "power",
                        title: t("menu.start_at_login"),
                        isOn: Binding(
                            get: { model.isLoginItemEnabled },
                            set: { actions.setLoginItemEnabled($0) }
                        )
                    )
                }

                PanelSection(title: panelText(zh: "\u{5176}\u{4ED6}", en: "Other")) {
                    PanelDropdownRow(
                        icon: "globe",
                        title: t("menu.language"),
                        isExpanded: activeDropdown == .language,
                        items: languageDropdownItems,
                        onToggle: {
                            toggleDropdown(.language)
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.14)) {
                                activeDropdown = nil
                            }
                        }
                    )
                    PanelDivider()
                    PanelActionRow(
                        icon: "xmark.circle",
                        title: t("menu.quit"),
                        shortcut: "\u{2318}Q",
                        keyboardShortcut: "q",
                        isDestructive: true,
                        action: actions.quit
                    )
                }
            }
            .padding(MenuPanelMetrics.outerPadding)
        }
        .frame(width: Self.preferredSize.width, height: currentPanelHeight)
        .onAppear {
            actions.resizePanel(currentPanelHeight)
        }
        .onChange(of: activeDropdown) { _ in
            actions.resizePanel(currentPanelHeight)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                AppIconMark()

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.appTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    Text(model.summaryText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }

                Spacer(minLength: 8)

                StatusPill(text: model.statusText, style: model.statusStyle)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(model.lastExportText)
                    Text("\u{2022}")
                        .foregroundStyle(.tertiary)
                    Text(model.lastBackupText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.lastExportText)
                    Text(model.lastBackupText)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.leading, 58)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: MenuPanelMetrics.headerHeight, alignment: .topLeading)
        .background(headerBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(headerStroke, lineWidth: 0.8)
        )
        .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
    }

    private var primaryActions: some View {
        VStack(spacing: 8) {
            PrimaryExportButton(
                title: model.isExporting ? t("menu.exporting") : t("menu.export_now"),
                isWorking: model.isExporting,
                action: actions.exportNow
            )
                .disabled(!model.canExportNow)
                .keyboardShortcut("e", modifiers: .command)

            PausePillButton(
                title: model.isPaused ? t("menu.resume") : t("menu.pause"),
                isPaused: model.isPaused,
                action: actions.togglePause
            )
        }
    }

    private func toggleDropdown(_ kind: PanelDropdownKind) {
        withAnimation(.easeOut(duration: 0.16)) {
            activeDropdown = activeDropdown == kind ? nil : kind
        }
    }

    private var currentPanelHeight: CGFloat {
        MenuPanelMetrics.height + activeDropdownExtraHeight
    }

    private var activeDropdownExtraHeight: CGFloat {
        switch activeDropdown {
        case .profile:
            return inlineDropdownHeight(for: profileDropdownItems)
        case .language:
            return inlineDropdownHeight(for: languageDropdownItems)
        case .none:
            return 0
        }
    }

    private func inlineDropdownHeight(for items: [PanelDropdownItem]) -> CGFloat {
        let rows = items.reduce(CGFloat(0)) { total, item in
            total + (item.isSeparator ? 0.6 : MenuPanelMetrics.dropdownItemHeight)
        }
        return rows + MenuPanelMetrics.dropdownVerticalPadding * 2 + MenuPanelMetrics.dropdownOuterSpacing
    }

    private var profileDropdownItems: [PanelDropdownItem] {
        if model.profileNames.isEmpty {
            return [.action(t("menu.setup"), action: actions.setupProfile)]
        }

        var items = model.profileNames.map { name in
            PanelDropdownItem.action(
                name,
                selected: name == model.activeProfileName
            ) {
                actions.selectProfile(name)
            }
        }
        items.append(.separator)
        items.append(.action(t("menu.reload"), action: actions.reloadProfiles))
        return items
    }

    private var languageDropdownItems: [PanelDropdownItem] {
        [
            .action(t("lang.en"), selected: model.languageCode == "en") {
                actions.setLanguage("en")
            },
            .action(t("lang.zh"), selected: model.languageCode == "zh") {
                actions.setLanguage("zh")
            }
        ]
    }

    private func panelText(zh: String, en: String) -> String {
        model.languageCode == "zh" ? zh : en
    }

    private var panelTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.20)
            : Color(nsColor: NSColor(hex: 0xF8F7F5)).opacity(0.92)
    }

    private var headerBackground: some View {
        let accent = Color(nsColor: DS.accentPink)
        let base = colorScheme == .dark
            ? Color.white.opacity(0.075)
            : Color.white.opacity(0.76)
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(base)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(colorScheme == .dark ? 0.20 : 0.15),
                                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.48), lineWidth: 0.8)
                    .padding(0.5)
            )
    }

    private var headerStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color(nsColor: DS.line).opacity(0.70)
    }

    private var shadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08)
    }
}

private struct AppIconMark: View {
    private var iconImage: NSImage? {
        if let url = Bundle.main.url(forResource: "icon_64x64", withExtension: "png", subdirectory: "icons") {
            return NSImage(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png", subdirectory: "icons") {
            return NSImage(contentsOf: url)
        }
        return NSImage(named: NSImage.applicationIconName)
    }

    var body: some View {
        Group {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: DS.accentPink),
                                Color(nsColor: DS.accentPink).opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Text("B")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.white.opacity(0.62), lineWidth: 1)
        )
        .shadow(color: Color(nsColor: DS.accentPink).opacity(0.28), radius: 10, x: 0, y: 5)
        .accessibilityHidden(true)
    }
}

private struct StatusPill: View {
    let text: String
    let style: MenuPanelStatusStyle

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.13))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.26), lineWidth: 0.8)
        )
        .frame(maxWidth: 108)
        .accessibilityLabel(text)
    }

    private var color: Color {
        switch style {
        case .success:
            return Color(nsColor: NSColor(hex: 0x22C55E))
        case .warning:
            return Color(nsColor: NSColor(hex: 0xF59E0B))
        case .neutral:
            return Color(nsColor: DS.secondaryText)
        case .error:
            return Color(nsColor: NSColor(hex: 0xEF4444))
        }
    }
}

private struct PrimaryExportButton: View {
    let title: String
    var isWorking = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                Spacer(minLength: 0)
                Text("\u{2318}E")
                    .font(.system(size: 14, weight: .semibold))
                    .opacity(0.72)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: MenuPanelMetrics.controlHeight)
        }
        .buttonStyle(PrimaryPanelButtonStyle(isHovering: hovering))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct PrimaryPanelButtonStyle: ButtonStyle {
    let isHovering: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .white : Color(nsColor: .secondaryLabelColor))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: gradientColors(isPressed: configuration.isPressed),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(isHovering ? 0.34 : 0.20), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(
                color: Color(nsColor: DS.accentPink).opacity(isEnabled ? (isHovering ? 0.34 : 0.22) : 0),
                radius: isHovering ? 12 : 8,
                x: 0,
                y: isHovering ? 6 : 4
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private func gradientColors(isPressed: Bool) -> [Color] {
        if !isEnabled {
            return [
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                Color(nsColor: .controlBackgroundColor).opacity(0.56)
            ]
        }
        return [
            Color(nsColor: NSColor(hex: 0xF43F9A)).opacity(isPressed ? 0.88 : 1),
            Color(nsColor: DS.accentPink).opacity(isPressed ? 0.84 : 1)
        ]
    }
}

private struct PausePillButton: View {
    let title: String
    let isPaused: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)

                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: isPaused ? "play.circle" : "pause.circle")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 22)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .frame(height: MenuPanelMetrics.controlHeight)
            .padding(.horizontal, 14)
        }
        .buttonStyle(SecondaryPanelButtonStyle(isActive: isPaused, isHovering: hovering))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct SecondaryPanelButtonStyle: ButtonStyle {
    let isActive: Bool
    let isHovering: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let active = Color(nsColor: NSColor(hex: 0xF59E0B))
        let foreground = isActive ? active : Color.primary
        let fill = colorScheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.64)
        let hoverFill = colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.030)

        configuration.label
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? hoverFill.opacity(1.5) : (isHovering ? hoverFill : fill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? active.opacity(0.42) : Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 0.9)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.025), radius: 5, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.987 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)

            VStack(spacing: 0) {
                content
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: MenuPanelMetrics.cardCornerRadius, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MenuPanelMetrics.cardCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.50), lineWidth: 0.8)
                    .padding(0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MenuPanelMetrics.cardCornerRadius, style: .continuous)
                    .stroke(cardStroke, lineWidth: 0.7)
            )
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.045), radius: 12, x: 0, y: 6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.060) : Color.white.opacity(0.78)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color(nsColor: DS.line).opacity(0.70)
    }
}

private struct PanelActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var shortcut: String? = nil
    var keyboardShortcut: Character? = nil
    var showsChevron = false
    var isDestructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if let keyboardShortcut {
                rowButton
                    .keyboardShortcut(KeyEquivalent(keyboardShortcut), modifiers: .command)
            } else {
                rowButton
            }
        }
    }

    private var rowButton: some View {
        Button(action: action) {
            ZStack {
                Color.clear
                PanelRowContent(
                    icon: icon,
                    title: title,
                    subtitle: subtitle,
                    shortcut: shortcut,
                    showsChevron: showsChevron,
                    isDestructive: isDestructive
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: MenuPanelMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuPanelMetrics.rowHeight)
        .background(PanelRowHoverBackground(isHovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: MenuPanelMetrics.rowCornerRadius, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

private struct PanelDropdownRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let isExpanded: Bool
    let items: [PanelDropdownItem]
    let onToggle: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                ZStack {
                    Color.clear
                    PanelRowContent(
                        icon: icon,
                        title: title,
                        subtitle: subtitle,
                        showsChevron: true,
                        isExpanded: isExpanded
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(height: MenuPanelMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: MenuPanelMetrics.rowHeight)
            .background(PanelRowHoverBackground(isHovering: hovering || isExpanded))
            .contentShape(RoundedRectangle(cornerRadius: MenuPanelMetrics.rowCornerRadius, style: .continuous))
            .onHover { hovering = $0 }
            .accessibilityLabel(title)

            if isExpanded {
                PanelDropdownMenu(items: items, onDismiss: onDismiss)
                    .padding(.leading, 42)
                    .padding(.trailing, 8)
                    .padding(.top, MenuPanelMetrics.dropdownOuterSpacing)
                    .zIndex(20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .zIndex(isExpanded ? 10 : 0)
    }
}

private struct PanelDropdownMenu: View {
    let items: [PanelDropdownItem]
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                if item.isSeparator {
                    Rectangle()
                        .fill(separatorColor)
                        .frame(height: 0.6)
                        .padding(.horizontal, 10)
                } else {
                    Button {
                        item.action?()
                        onDismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(nsColor: DS.accentPink))
                                .opacity(item.isSelected ? 1 : 0)
                                .frame(width: 16)

                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PanelDropdownButtonStyle(isSelected: item.isSelected))
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(dropdownBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(borderColor, lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16), radius: 18, x: 0, y: 10)
    }

    private var dropdownBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(colorScheme == .dark ? Color(nsColor: .windowBackgroundColor).opacity(0.92) : Color.white.opacity(0.94))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: DS.accentPink).opacity(colorScheme == .dark ? 0.05 : 0.035))
            )
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color(nsColor: DS.line).opacity(0.80)
    }

    private var separatorColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color(nsColor: DS.line).opacity(0.74)
    }
}

private struct PanelDropdownButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
                    .padding(.horizontal, 5)
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color(nsColor: DS.accentPink).opacity(colorScheme == .dark ? 0.20 : 0.14)
        }
        if isSelected {
            return Color(nsColor: DS.accentPink).opacity(colorScheme == .dark ? 0.13 : 0.08)
        }
        return Color.clear
    }
}

private struct PanelToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(iconTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Color(nsColor: DS.accentPink))
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity)
        .frame(height: MenuPanelMetrics.rowHeight)
        .background(PanelRowHoverBackground(isHovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: MenuPanelMetrics.rowCornerRadius, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var iconTint: Color {
        colorScheme == .dark ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: DS.secondaryText)
    }
}

private struct PanelRowContent: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var shortcut: String? = nil
    var showsChevron = false
    var isDestructive = false
    var isExpanded = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(iconTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isDestructive ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Spacer(minLength: 8)

            Group {
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .lineLimit(1)
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeOut(duration: 0.14), value: isExpanded)
                } else {
                    Color.clear
                }
            }
            .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity)
        .frame(height: MenuPanelMetrics.rowHeight)
    }

    private var iconTint: Color {
        if isDestructive {
            return Color(nsColor: .secondaryLabelColor)
        }
        return colorScheme == .dark ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: DS.secondaryText)
    }
}

private struct PanelRowHoverBackground: View {
    let isHovering: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: MenuPanelMetrics.rowCornerRadius, style: .continuous)
            .fill(isHovering ? hoverFill : Color.clear)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var hoverFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045)
    }
}

private struct PanelDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.075) : Color(nsColor: DS.line).opacity(0.62))
            .frame(height: 0.6)
            .padding(.leading, 50)
            .padding(.trailing, 8)
    }
}

private struct MenuPanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}
