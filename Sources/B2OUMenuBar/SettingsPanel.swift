// SettingsPanel.swift - Modern macOS settings window for B2OU.

import Cocoa
import SwiftUI
import B2OUAppSupport
import B2OUCore

// MARK: - Settings Values

struct SettingsValues {
    var exportPath: String
    var exportPathTB: String
    var exportFormat: String
    var yamlFrontMatter: Bool
    var tagFolders: Bool
    var hideTags: Bool
    var autoStart: Bool
    var naming: String
    var onDelete: String
    var excludeTags: String
    var backupInterval: Int
    var backupPath: String
    /// Number of completed backups to retain when scheduled backup is enabled.
    var backupMaxKeep: Int
    /// `auto`, `bearcli`, or `sqlite` — how B2OU reads Bear notes.
    var bearSource: String
    /// Optional override path for `bearcli`; empty uses Bear’s default location.
    var bearCLIPath: String
    /// Display-only summary shown on the backup card (e.g. last backup time).
    var lastBackupSummary: String
}

// MARK: - Callbacks

typealias SettingsApplyCallback = (SettingsValues) -> Bool
typealias FolderPickerCallback = () -> String?
typealias ExecutablePickerCallback = () -> String?

// MARK: - Constants

private let settingsWindowSize = NSSize(width: 1060, height: 780)
private let settingsWindowMinSize = NSSize(width: 1024, height: 768)

private let helpTags: [Int: String] = [
    0: "help.format",
    1: "help.export_folder_md",
    2: "help.export_folder_tb",
    3: "help.yaml",
    4: "help.tag_folders",
    5: "help.hide_tags",
    6: "help.auto_start",
    7: "help.naming",
    8: "help.on_delete",
    9: "help.exclude_tags",
    10: "help.backup_interval",
    11: "help.bear_source",
]

private func settingsCopy(zh: String, en: String) -> String {
    getLanguage() == "zh" ? zh : en
}

private func helpText(for tag: Int) -> String {
    guard let key = helpTags[tag] else { return "" }
    return t(key)
}

// MARK: - Settings Panel Controller

final class SettingsPanelController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsRootView>?
    private var languageObserver: NSObjectProtocol?

    func configure(
        values: SettingsValues,
        onApply: @escaping SettingsApplyCallback,
        onChangeFolder: FolderPickerCallback? = nil,
        onPickBearCLI: ExecutablePickerCallback? = nil
    ) {
        buildWindow(
            values: values,
            onApply: onApply,
            onChangeFolder: onChangeFolder,
            onPickBearCLI: onPickBearCLI
        )
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func close() {
        window?.close()
        hostingController = nil
        window = nil
    }

    private func buildWindow(
        values: SettingsValues,
        onApply: @escaping SettingsApplyCallback,
        onChangeFolder: FolderPickerCallback?,
        onPickBearCLI: ExecutablePickerCallback?
    ) {
        let rect = NSRect(origin: NSPoint(x: 200, y: 200), size: settingsWindowSize)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

        let window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.title = t("settings.title")
        window.minSize = settingsWindowMinSize
        window.isReleasedWhenClosed = false
        window.backgroundColor = DS.groupedBackground
        window.delegate = self
        window.center()

        let rootView = SettingsRootView(
            initialValues: values,
            onApply: { [weak self] applied in
                let didSave = onApply(applied)
                if didSave {
                    self?.close()
                }
                return didSave
            },
            onChangeFolder: onChangeFolder,
            onPickBearCLI: onPickBearCLI
        )
        let hostingController = NSHostingController(rootView: rootView)
        window.contentViewController = hostingController

        self.hostingController = hostingController
        self.window = window
        if languageObserver == nil {
            languageObserver = makeB2OULanguageObserver { [weak self] in
                self?.window?.title = t("settings.title")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if activePanel === self {
            activePanel = nil
        }
        removeB2OULanguageObserver(&languageObserver)
        hostingController = nil
        window = nil
    }
}

// MARK: - SwiftUI Root

private enum SettingsSection: String, CaseIterable, Identifiable {
    case essentials
    case backup
    case filters
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .essentials:
            return t("settings.section.essentials_title")
        case .backup:
            return t("settings.section.backup_title")
        case .filters:
            return t("settings.section.filters_title")
        case .about:
            return t("settings.section.about_title")
        }
    }

    var subtitle: String {
        switch self {
        case .essentials:
            return t("settings.section.essentials_sub")
        case .backup:
            return t("settings.section.backup_sub")
        case .filters:
            return t("settings.section.filters_sub")
        case .about:
            return t("settings.section.about_sub")
        }
    }

    var systemImage: String {
        switch self {
        case .essentials:
            return "gearshape"
        case .backup:
            return "clock"
        case .filters:
            return "line.3.horizontal.decrease.circle"
        case .about:
            return "info.circle"
        }
    }

    var pageDescription: String {
        switch self {
        case .essentials:
            return t("settings.section.essentials_page")
        case .backup:
            return t("settings.section.backup_page")
        case .filters:
            return t("settings.section.filters_page")
        case .about:
            return t("settings.section.about_page")
        }
    }
}

private struct SettingsRootView: View {
    @State private var values: SettingsValues
    @State private var selectedSection: SettingsSection = .essentials
    @State private var validationMessage = ""

    private let initialValues: SettingsValues
    private let onApply: SettingsApplyCallback
    private let onChangeFolder: FolderPickerCallback?
    private let onPickBearCLI: ExecutablePickerCallback?

    @Environment(\.colorScheme) private var colorScheme

    init(
        initialValues: SettingsValues,
        onApply: @escaping SettingsApplyCallback,
        onChangeFolder: FolderPickerCallback?,
        onPickBearCLI: ExecutablePickerCallback?
    ) {
        self.initialValues = initialValues
        self.onApply = onApply
        self.onChangeFolder = onChangeFolder
        self.onPickBearCLI = onPickBearCLI
        _values = State(initialValue: initialValues)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            SettingsSidebar(selection: $selectedSection)
                .frame(width: 252)

            SettingsDetailPane(
                values: $values,
                selectedSection: selectedSection,
                validationMessage: validationMessage,
                onPickFolder: pickFolder,
                onPickBearCLI: pickBearCLI,
                onReset: resetToDefaults,
                onSave: save
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(22)
        .frame(minWidth: 980, minHeight: 650)
        .background(settingsBackground.ignoresSafeArea())
        .font(.system(.body, design: .default))
        .b2ouRefreshesOnLanguageChange()
    }

    private var settingsBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(nsColor: DS.groupedBackground)
    }

    private func pickFolder(_ target: FolderTarget) {
        guard let newPath = onChangeFolder?() else { return }
        validationMessage = ""

        switch target {
        case .markdown:
            values.exportPath = newPath
        case .textBundle:
            values.exportPathTB = newPath
        case .backup:
            values.backupPath = newPath
        }
    }

    private func pickBearCLI() {
        guard let newPath = onPickBearCLI?() else { return }
        validationMessage = ""
        values.bearCLIPath = newPath
    }

    private func resetToDefaults() {
        validationMessage = ""
        values.exportPath = ""
        values.exportPathTB = ""
        values.exportFormat = "md"
        values.yamlFrontMatter = false
        values.tagFolders = false
        values.hideTags = false
        values.autoStart = false
        values.naming = "title"
        values.onDelete = "trash"
        values.excludeTags = ""
        values.backupInterval = 0
        values.backupPath = ""
        values.backupMaxKeep = 24
        values.bearSource = "auto"
        values.bearCLIPath = ""
        values.lastBackupSummary = ""
    }

    private func save() {
        validationMessage = ""
        var draft = values

        if draft.exportFormat != "md",
           draft.exportFormat != "tb",
           draft.exportFormat != "both" {
            draft.exportFormat = "md"
        }

        guard validate(draft) else { return }

        if draft.exportFormat == "tb" {
            if draft.exportPath.isEmpty && !draft.exportPathTB.isEmpty {
                draft.exportPath = draft.exportPathTB
            }
        }

        let saved = onApply(draft)
        if !saved {
            validationMessage = t("settings.save_failed_msg")
            NSSound.beep()
        }
    }

    private func validate(_ draft: SettingsValues) -> Bool {
        if let issue = validateSettingsInput(
            SettingsValidationInput(
                exportPath: draft.exportPath,
                exportPathTB: draft.exportPathTB,
                exportFormat: draft.exportFormat,
                backupInterval: draft.backupInterval,
                backupPath: draft.backupPath
            )
        ) {
            validationMessage = settingsValidationMessage(for: issue)
            NSSound.beep()
            return false
        }

        return true
    }
}

// MARK: - Navigation

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: selection == section
                    ) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selection = section
                        }
                    }
                }
            }
            .padding(14)

            Spacer(minLength: 20)

            SettingsStatusCard()
                .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(sidebarFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.20 : 0.85), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.045), radius: 16, x: 0, y: 8)
    }

    private var sidebarFill: Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.56)
            : Color.white.opacity(0.82)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

                    Text(section.subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowFill)
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(section.title), \(section.subtitle)")
    }

    private var rowFill: Color {
        if isSelected {
            return Color(nsColor: DS.accentPinkSoft)
        }
        if isHovering {
            return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.035)
        }
        return .clear
    }

    private var iconColor: Color {
        isSelected ? Color(nsColor: DS.accentPink) : Color(nsColor: DS.secondaryText)
    }

    private var titleColor: Color {
        isSelected ? Color(nsColor: DS.accentPink) : .primary
    }

    private var subtitleColor: Color {
        isSelected ? Color(nsColor: DS.accentPink).opacity(0.82) : .secondary
    }
}

private struct SettingsStatusCard: View {
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: DS.accentPinkSoft))

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(nsColor: DS.accentPink))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("B2OU")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(settingsCopy(zh: "已连接", en: "Connected"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(connectionForeground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(connectionBackground)
                            )
                    }

                    Text(settingsCopy(zh: "版本 \(version)", en: "Version \(version)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                b2ouOpen(b2ouReleasesURL)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text(settingsCopy(zh: "检查更新", en: "Check for Updates"))
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? hoverFill : buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.30 : 0.9), lineWidth: 0.8)
            )
            .onHover { isHovering = $0 }
            .accessibilityLabel(settingsCopy(zh: "检查更新", en: "Check for Updates"))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: DS.accentPinkSoft).opacity(colorScheme == .dark ? 0.22 : 1), lineWidth: 0.8)
        )
    }

    private var cardFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72)
    }

    private var buttonFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.72)
    }

    private var hoverFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.035)
    }

    private var connectionForeground: Color {
        colorScheme == .dark ? Color(nsColor: NSColor(hex: 0x86EFAC)) : Color(nsColor: NSColor(hex: 0x15803D))
    }

    private var connectionBackground: Color {
        colorScheme == .dark ? Color(nsColor: NSColor(hex: 0x14532D)).opacity(0.45) : Color(nsColor: NSColor(hex: 0xDCFCE7))
    }
}

// MARK: - Detail Pane

private enum FolderTarget {
    case markdown
    case textBundle
    case backup
}

private struct SettingsDetailPane: View {
    @Binding var values: SettingsValues

    let selectedSection: SettingsSection
    let validationMessage: String
    let onPickFolder: (FolderTarget) -> Void
    let onPickBearCLI: () -> Void
    let onReset: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(colorScheme == .dark ? 0.32 : 0.58)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectedContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(selectedSection)
            }

            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(detailFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.20 : 0.70), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 18, x: 0, y: 8)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(selectedSection.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(selectedSection.pageDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder private var selectedContent: some View {
        switch selectedSection {
        case .essentials:
            bearConnectionCard
            exportFormatCard
            metadataCard
            namingCard
        case .backup:
            backupCard
        case .filters:
            filtersCard
        case .about:
            aboutCard
        }
    }

    private var bearConnectionCard: some View {
        SettingsCard(title: t("settings.bear_source"), icon: "link.circle", helpTag: 11) {
            VStack(spacing: 0) {
                PickerSettingRow(
                    title: t("settings.bear_source_mode"),
                    subtitle: t("settings.bear_source_mode_detail"),
                    selection: normalizedBearSourceBinding,
                    items: [
                        ("auto", t("settings.bear_source_auto")),
                        ("bearcli", t("settings.bear_source_cli")),
                        ("sqlite", t("settings.bear_source_sqlite")),
                    ],
                    helpTag: nil
                )

                SettingsDivider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(t("settings.bearcli_path"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .opacity(values.bearSource == "sqlite" ? 0.45 : 1)

                    HStack(spacing: 10) {
                        SettingsPathField(
                            text: $values.bearCLIPath,
                            placeholder: defaultBearCLIPath.path,
                            isEnabled: values.bearSource != "sqlite",
                            accessibilityLabel: t("settings.bearcli_path")
                        )

                        SettingsButton(
                            title: t("settings.bearcli_choose"),
                            systemImage: "doc.badge.ellipsis",
                            kind: .secondary,
                            isEnabled: values.bearSource != "sqlite",
                            action: onPickBearCLI
                        )
                        .frame(width: 120)
                    }

                    Text(t("settings.bearcli_hint"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var normalizedBearSourceBinding: Binding<String> {
        Binding(
            get: {
                let s = values.bearSource.lowercased()
                if s == "bearcli" || s == "sqlite" { return s }
                return "auto"
            },
            set: { values.bearSource = $0 }
        )
    }

    private var exportFormatCard: some View {
        SettingsCard(title: t("settings.format"), icon: "doc.badge.gearshape", helpTag: 0) {
            VStack(alignment: .leading, spacing: 18) {
                ExportFormatOption(
                    title: t("settings.format_md"),
                    isOn: markdownEnabledBinding,
                    pathTitle: t("settings.export_folder_md"),
                    path: $values.exportPath,
                    placeholder: settingsCopy(zh: "选择 Markdown 导出文件夹", en: "Choose a Markdown export folder"),
                    isPathEnabled: markdownEnabled,
                    helpTag: 1
                ) {
                    onPickFolder(.markdown)
                }

                SettingsDivider()

                ExportFormatOption(
                    title: t("settings.format_tb"),
                    isOn: textBundleEnabledBinding,
                    pathTitle: t("settings.export_folder_tb"),
                    path: $values.exportPathTB,
                    placeholder: textBundlePlaceholder,
                    isPathEnabled: textBundleEnabled,
                    helpTag: 2
                ) {
                    onPickFolder(.textBundle)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: DS.accentPink))
                        .frame(width: 6, height: 6)

                    Text(t("settings.folder_not_same"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private var metadataCard: some View {
        SettingsCard(title: settingsCopy(zh: "元数据", en: "Metadata"), icon: "tag", helpTag: nil) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    title: t("settings.yaml"),
                    subtitle: settingsCopy(
                        zh: "在每篇导出笔记顶部加入标题、标签和日期。",
                        en: "Add title, tags, and dates to exported notes."
                    ),
                    isOn: $values.yamlFrontMatter,
                    helpTag: 3
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: t("settings.tag_folders"),
                    subtitle: settingsCopy(
                        zh: "根据 Bear 标签创建文件夹结构。",
                        en: "Create folders from Bear tags."
                    ),
                    isOn: $values.tagFolders,
                    helpTag: 4
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: t("settings.hide_tags"),
                    subtitle: settingsCopy(
                        zh: "从导出的正文中移除可见的 #标签。",
                        en: "Remove visible #tags from exported note bodies."
                    ),
                    isOn: $values.hideTags,
                    helpTag: 5
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: t("settings.auto_start"),
                    subtitle: settingsCopy(
                        zh: "登录 macOS 后自动启动菜单栏应用。",
                        en: "Start the menu-bar app after macOS login."
                    ),
                    isOn: $values.autoStart,
                    helpTag: 6
                )
            }
        }
    }

    private var namingCard: some View {
        SettingsCard(title: settingsCopy(zh: "文件命名", en: "File Naming"), icon: "textformat", helpTag: nil) {
            VStack(spacing: 0) {
                PickerSettingRow(
                    title: t("settings.naming"),
                    subtitle: settingsCopy(
                        zh: "决定导出文件使用标题、短标识、日期或 Bear ID。",
                        en: "Choose whether file names use title, slug, date, or Bear ID."
                    ),
                    selection: $values.naming,
                    items: [
                        ("title", t("settings.naming_title")),
                        ("slug", t("settings.naming_slug")),
                        ("date-title", t("settings.naming_date")),
                        ("id", t("settings.naming_id")),
                    ],
                    helpTag: 7
                )
                SettingsDivider()
                PickerSettingRow(
                    title: t("settings.on_delete"),
                    subtitle: settingsCopy(
                        zh: "设置原笔记删除后导出文件的处理方式。",
                        en: "Choose how exported files are handled after source notes are deleted."
                    ),
                    selection: $values.onDelete,
                    items: [
                        ("trash", t("settings.delete_trash")),
                        ("remove", t("settings.delete_remove")),
                        ("keep", t("settings.delete_keep")),
                    ],
                    helpTag: 8
                )
            }
        }
    }

    private var backupCard: some View {
        SettingsCard(title: t("settings.backup"), icon: "clock", helpTag: 10) {
            VStack(spacing: 0) {
                PickerSettingRow(
                    title: t("settings.backup_interval"),
                    subtitle: t("settings.backup_interval_detail"),
                    selection: backupSelection,
                    items: [
                        (0, t("settings.backup_off")),
                        (30, t("settings.backup_30m")),
                        (60, t("settings.backup_1h")),
                        (120, t("settings.backup_2h")),
                        (360, t("settings.backup_6h")),
                        (720, t("settings.backup_12h")),
                        (1440, t("settings.backup_24h")),
                    ],
                    helpTag: nil
                )

                SettingsDivider()

                PickerSettingRow(
                    title: t("settings.backup_keep_label"),
                    subtitle: t("settings.backup_keep_detail"),
                    selection: backupMaxKeepSelection,
                    items: [
                        (6, t("settings.backup_keep_6")),
                        (12, t("settings.backup_keep_12")),
                        (24, t("settings.backup_keep_24")),
                        (48, t("settings.backup_keep_48")),
                    ],
                    helpTag: nil
                )
                .opacity(values.backupInterval > 0 ? 1 : 0.45)
                .allowsHitTesting(values.backupInterval > 0)

                SettingsDivider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(t("settings.backup_folder"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    HStack(spacing: 10) {
                        SettingsPathField(
                            text: $values.backupPath,
                            placeholder: backupPlaceholder,
                            isEnabled: values.backupInterval > 0,
                            accessibilityLabel: t("settings.backup_folder")
                        )

                        SettingsButton(
                            title: t("settings.change"),
                            systemImage: "folder",
                            kind: .secondary,
                            isEnabled: values.backupInterval > 0,
                            action: { onPickFolder(.backup) }
                        )
                        .frame(width: 104)
                    }

                    Text(backupStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
            }
        }
    }

    private var filtersCard: some View {
        SettingsCard(title: t("settings.section.filters_card_title"), icon: "line.3.horizontal.decrease.circle", helpTag: nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("settings.exclude_tags"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)

                        Text(settingsCopy(
                            zh: "用英文逗号分隔，这些标签的笔记会被跳过。",
                            en: "Use comma-separated tags. Notes with these tags are skipped."
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    SettingsInfoButton(helpTag: 9, label: t("settings.exclude_tags"))
                }

                TextField(t("settings.exclude_placeholder"), text: $values.excludeTags)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(inputFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.32 : 0.9), lineWidth: 0.8)
                    )
                    .accessibilityLabel(t("settings.exclude_tags"))

                Text(t("settings.exclude_example"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: settingsCopy(zh: "关于 B2OU", en: "About B2OU"), icon: "info.circle", helpTag: nil) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: DS.accentPinkSoft))

                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Color(nsColor: DS.accentPink))
                    }
                    .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("B2OU")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.primary)

                        Text(settingsCopy(zh: "Bear 到 Obsidian 的菜单栏同步工具", en: "Menu-bar sync for Bear and Obsidian"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        Text(settingsCopy(zh: "版本 \(appVersion)", en: "Version \(appVersion)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }

                SettingsDivider()

                HStack(spacing: 12) {
                    SettingsButton(
                        title: settingsCopy(zh: "检查更新", en: "Check for Updates"),
                        systemImage: "arrow.clockwise",
                        kind: .secondary,
                        action: {
                            b2ouOpen(b2ouReleasesURL)
                        }
                    )
                    .frame(width: 138)

                    SettingsButton(
                        title: settingsCopy(zh: "打开项目主页", en: "Project Page"),
                        systemImage: "safari",
                        kind: .secondary,
                        action: {
                            b2ouOpen(b2ouProjectPageURL)
                        }
                    )
                    .frame(width: 148)

                    Spacer()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            SettingsButton(
                title: settingsCopy(zh: "恢复默认", en: "Restore Defaults"),
                systemImage: "arrow.counterclockwise",
                kind: .secondary,
                action: onReset
            )
            .frame(width: 132)

            if !validationMessage.isEmpty {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(validationMessage)
            }

            Spacer(minLength: 12)

            SettingsButton(
                title: settingsCopy(zh: "保存设置", en: "Save Settings"),
                systemImage: "checkmark",
                kind: .primary,
                action: onSave
            )
            .frame(width: 138)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(footerFill)
        .overlay(alignment: .top) {
            Divider()
                .opacity(colorScheme == .dark ? 0.30 : 0.58)
        }
    }

    private var markdownEnabled: Bool {
        values.exportFormat == "md" || values.exportFormat == "both"
    }

    private var textBundleEnabled: Bool {
        values.exportFormat == "tb" || values.exportFormat == "both"
    }

    private var markdownEnabledBinding: Binding<Bool> {
        Binding(
            get: { markdownEnabled },
            set: { newValue in
                setExportFormat(markdown: newValue, textBundle: textBundleEnabled)
            }
        )
    }

    private var textBundleEnabledBinding: Binding<Bool> {
        Binding(
            get: { textBundleEnabled },
            set: { newValue in
                setExportFormat(markdown: markdownEnabled, textBundle: newValue)
            }
        )
    }

    private var backupSelection: Binding<Int> {
        Binding(
            get: { values.backupInterval },
            set: { values.backupInterval = $0 }
        )
    }

    private var backupMaxKeepSelection: Binding<Int> {
        Binding(
            get: {
                let allowed = [6, 12, 24, 48]
                return allowed.contains(values.backupMaxKeep) ? values.backupMaxKeep : 24
            },
            set: { values.backupMaxKeep = $0 }
        )
    }

    private func setExportFormat(markdown: Bool, textBundle: Bool) {
        if markdown && textBundle {
            values.exportFormat = "both"
        } else if markdown {
            values.exportFormat = "md"
        } else if textBundle {
            values.exportFormat = "tb"
        } else {
            values.exportFormat = "md"
        }
    }

    private var textBundlePlaceholder: String {
        if !values.exportPathTB.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return values.exportPathTB
        }
        if values.exportPath.isEmpty {
            return settingsCopy(zh: "选择 TextBundle 导出文件夹", en: "Choose a TextBundle export folder")
        }
        return (values.exportPath as NSString).appendingPathComponent("TextBundle")
    }

    private var backupPlaceholder: String {
        if !values.backupPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return values.backupPath
        }
        if values.exportPath.isEmpty {
            return t("settings.backup_default")
        }
        return (values.exportPath as NSString).appendingPathComponent(".b2ou-backups")
    }

    private var backupStatusText: String {
        if values.backupInterval <= 0 {
            return t("settings.backup_status_off")
        }
        let summary = values.lastBackupSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty {
            return t("settings.backup_status_waiting")
        }
        return summary
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    private var detailFill: Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.45)
            : Color.white.opacity(0.64)
    }

    private var footerFill: Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.86)
            : Color(nsColor: DS.groupedBackground).opacity(0.92)
    }

    private var inputFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.82)
    }
}

// MARK: - Cards and Rows

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let helpTag: Int?
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(title: String, icon: String, helpTag: Int? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.helpTag = helpTag
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color(nsColor: DS.accentPink))
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                if let helpTag {
                    SettingsInfoButton(helpTag: helpTag, label: title)
                }
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.28 : 0.95), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.15 : 0.035), radius: 14, x: 0, y: 6)
    }

    private var cardFill: Color {
        colorScheme == .dark
            ? Color(nsColor: .controlBackgroundColor).opacity(0.72)
            : Color.white
    }
}

private struct ExportFormatOption: View {
    let title: String
    @Binding var isOn: Bool
    let pathTitle: String
    @Binding var path: String
    let placeholder: String
    let isPathEnabled: Bool
    let helpTag: Int
    let onChangeFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCheckbox(title: title, isOn: $isOn)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pathTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(isPathEnabled ? Color.secondary : Color(nsColor: DS.secondaryText).opacity(0.78))

                SettingsInfoButton(helpTag: helpTag, label: pathTitle)
                    .opacity(isPathEnabled ? 1 : 0.74)
            }
            .padding(.leading, 34)

            HStack(spacing: 10) {
                SettingsPathField(
                    text: $path,
                    placeholder: placeholder,
                    isEnabled: isPathEnabled,
                    accessibilityLabel: pathTitle
                )

                SettingsButton(
                    title: t("settings.change"),
                    systemImage: "folder",
                    kind: .secondary,
                    isEnabled: isPathEnabled,
                    action: onChangeFolder
                )
                .frame(width: 104)
            }
            .padding(.leading, 34)
        }
    }
}

private struct SettingsCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    @State private var isHovering = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isOn ? Color(nsColor: DS.accentPink) : Color(nsColor: DS.tertiaryText))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color(nsColor: DS.accentPinkSoft).opacity(0.45) : .clear)
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? settingsCopy(zh: "已开启", en: "On") : settingsCopy(zh: "已关闭", en: "Off"))
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let helpTag: Int

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Color(nsColor: DS.accentPink))
                .accessibilityLabel(title)

            SettingsInfoButton(helpTag: helpTag, label: title)
        }
        .frame(minHeight: 52)
        .padding(.vertical, 6)
    }
}

private struct PickerSettingRow<Value: Hashable>: View {
    let title: String
    let subtitle: String
    @Binding var selection: Value
    let items: [(Value, String)]
    let helpTag: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: $selection) {
                ForEach(items, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.regular)
            .frame(width: 190)
            .accessibilityLabel(title)

            if let helpTag {
                SettingsInfoButton(helpTag: helpTag, label: title)
            }
        }
        .frame(minHeight: 52)
        .padding(.vertical, 6)
    }
}

private struct SettingsPathField: View {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(promptColor))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(isEnabled ? Color.primary : Color(nsColor: DS.secondaryText))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.8)
            )
            .allowsHitTesting(isEnabled)
            .focusable(isEnabled)
            .opacity(isEnabled ? 1 : 0.84)
            .accessibilityLabel(accessibilityLabel)
    }

    private var fieldFill: Color {
        if isEnabled {
            return colorScheme == .dark ? Color.white.opacity(0.07) : Color(nsColor: DS.softCardBackground)
        }
        return colorScheme == .dark ? Color.white.opacity(0.045) : Color(nsColor: NSColor(hex: 0xF3F4F6))
    }

    private var borderColor: Color {
        if isEnabled {
            return Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.34 : 1)
        }
        return Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.20 : 0.70)
    }

    private var promptColor: Color {
        Color(nsColor: DS.tertiaryText).opacity(isEnabled ? 1 : 0.82)
    }
}

private struct SettingsInfoButton: View {
    let helpTag: Int
    let label: String

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(isHovering ? Color(nsColor: DS.accentPink) : Color(nsColor: DS.secondaryText))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(for: helpTag))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(helpText(for: helpTag))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
        .onHover { isHovering = $0 }
        .accessibilityLabel(settingsCopy(zh: "\(label) 帮助", en: "\(label) help"))
    }
}

private enum SettingsButtonKind {
    case primary
    case secondary
}

private struct SettingsButton: View {
    let title: String
    let systemImage: String
    let kind: SettingsButtonKind
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(foreground)
        .background(background)
        .overlay(border)
        .shadow(color: shadowColor, radius: kind == .primary ? 8 : 0, x: 0, y: kind == .primary ? 4 : 0)
        .opacity(isEnabled ? 1 : 0.72)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    @ViewBuilder private var background: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(backgroundFill)
    }

    @ViewBuilder private var border: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(borderColor, lineWidth: 0.8)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return isEnabled ? .white : Color(nsColor: DS.secondaryText)
        case .secondary:
            return isEnabled ? .primary : Color(nsColor: DS.secondaryText)
        }
    }

    private var backgroundFill: Color {
        guard isEnabled else {
            return colorScheme == .dark ? Color.white.opacity(0.06) : Color(nsColor: NSColor(hex: 0xEEF0F3))
        }

        switch kind {
        case .primary:
            return Color(nsColor: DS.accentPink).opacity(isHovering ? 0.92 : 1)
        case .secondary:
            if isHovering {
                return colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.035)
            }
            return colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.82)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary:
            return Color.white.opacity(isHovering ? 0.34 : 0.16)
        case .secondary:
            return Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.32 : 0.95)
        }
    }

    private var shadowColor: Color {
        kind == .primary && isEnabled
            ? Color(nsColor: DS.accentPink).opacity(isHovering ? 0.30 : 0.18)
            : .clear
    }
}

private struct SettingsDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: DS.line).opacity(colorScheme == .dark ? 0.22 : 0.68))
            .frame(height: 0.8)
    }
}

// MARK: - Active Panel

private var activePanel: SettingsPanelController?

func showSettingsPanel(
    values: SettingsValues,
    onApply: @escaping SettingsApplyCallback,
    onChangeFolder: FolderPickerCallback? = nil,
    onPickBearCLI: ExecutablePickerCallback? = nil
) {
    activePanel?.close()
    activePanel = nil

    activePanel = SettingsPanelController()
    activePanel?.configure(
        values: values,
        onApply: onApply,
        onChangeFolder: onChangeFolder,
        onPickBearCLI: onPickBearCLI
    )
    activePanel?.show()
}
