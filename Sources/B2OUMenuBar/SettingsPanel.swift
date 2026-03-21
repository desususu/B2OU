// SettingsPanel.swift — Native macOS settings panel for B2OU.
//
// Apple-design-inspired: full-size content view with titlebar vibrancy,
// grouped card sections, SF Pro typography, and generous spacing.

import Cocoa
import B2OUCore

// MARK: - Layout Constants

private let winWidth:  CGFloat = 560
private let winHeight: CGFloat = 900
private let pad:       CGFloat = 28
private let contentW:  CGFloat = winWidth - pad * 2
private let rowH:      CGFloat = 30
private let rowGap:    CGFloat = 6
private let sectionGap: CGFloat = 20
private let labelW:    CGFloat = 220
private let infoSize:  CGFloat = 20
private let toggleW:   CGFloat = 40
private let toggleH:   CGFloat = 22
private let cardPad:   CGFloat = 16
private let cardRadius: CGFloat = 10

// MARK: - Naming / Delete Keys

private let namingKeys = ["title", "slug", "date-title", "id"]
private let deleteKeys = ["trash", "remove", "keep"]

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
]

// MARK: - Settings Values

private let backupIntervalKeys = [0, 30, 60, 120, 360, 720, 1440]

struct SettingsValues {
    var exportPath: String
    var exportPathTB: String
    var exportFormat: String   // "md", "tb", "both"
    var yamlFrontMatter: Bool
    var tagFolders: Bool
    var hideTags: Bool
    var autoStart: Bool
    var naming: String         // "title", "slug", "date-title", "id"
    var onDelete: String       // "trash", "remove", "keep"
    var excludeTags: String
    var backupInterval: Int    // minutes, 0 = disabled
    var backupPath: String
}

// MARK: - Callbacks

typealias SettingsApplyCallback = (SettingsValues) -> Void
typealias FolderPickerCallback = () -> String?

// MARK: - Helpers

private func makeCard(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> NSView {
    let card = NSView(frame: NSRect(x: x, y: y, width: width, height: height))
    card.wantsLayer = true
    card.layer?.cornerRadius = cardRadius
    card.layer?.masksToBounds = true
    if #available(macOS 14.0, *) {
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.06).cgColor
    } else {
        card.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.06).cgColor
    }
    parent.addSubview(card)
    return card
}

private func makeLabel(
    _ text: String, x: CGFloat, y: CGFloat,
    width: CGFloat = labelW, height: CGFloat = rowH,
    bold: Bool = false, small: Bool = false, wrap: Bool = false
) -> NSTextField {
    let label: NSTextField
    if wrap {
        label = NSTextField(wrappingLabelWithString: text)
    } else {
        label = NSTextField(labelWithString: text)
    }
    label.frame = NSRect(x: x, y: y, width: width, height: height)
    label.isBezeled = false
    label.drawsBackground = false
    label.isEditable = false
    label.isSelectable = false
    if bold {
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
    } else if small {
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
    } else {
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
    }
    return label
}

private func makeToggle(state: Bool, x: CGFloat, y: CGFloat) -> NSSwitch {
    let toggle = NSSwitch(frame: NSRect(x: x, y: y + 3, width: toggleW, height: toggleH))
    toggle.state = state ? .on : .off
    toggle.controlSize = .small
    return toggle
}

private func makeCheckbox(_ text: String, state: Bool, x: CGFloat, y: CGFloat, width: CGFloat = 220) -> NSButton {
    let box = NSButton(checkboxWithTitle: text, target: nil, action: nil)
    box.frame = NSRect(x: x, y: y, width: width, height: rowH)
    box.font = NSFont.systemFont(ofSize: 13)
    box.state = state ? .on : .off
    return box
}

private func makeInfoButton(tag: Int, x: CGFloat, y: CGFloat, target: AnyObject, action: Selector) -> NSButton {
    let btn = NSButton(frame: NSRect(x: x, y: y + 4, width: 20, height: 20))
    btn.title = ""
    btn.image = NSImage(named: NSImage.infoName)
    btn.isBordered = false
    btn.imageScaling = .scaleProportionallyDown
    btn.tag = tag
    btn.target = target
    btn.action = action
    btn.toolTip = nil
    return btn
}

private func showPopover(relativeTo view: NSView, text: String) {
    let popover = NSPopover()
    let vc = NSViewController()

    let popPad: CGFloat = 14
    let maxW: CGFloat = 280

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: maxW, height: 10))
    textView.string = text
    textView.font = NSFont.systemFont(ofSize: 12)
    textView.isEditable = false
    textView.isSelectable = false
    textView.drawsBackground = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.textContainerInset = NSSize(width: 0, height: 0)

    if let container = textView.textContainer {
        container.lineFragmentPadding = 0
        container.size = NSSize(width: maxW, height: 10_000)
        container.widthTracksTextView = true
        container.lineBreakMode = .byCharWrapping
    }

    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
    let textH = max(24, ceil(used.height) + 4)

    let contentW = maxW + popPad * 2
    let contentH = textH + popPad * 2
    textView.frame = NSRect(x: popPad, y: popPad, width: maxW, height: textH)

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
    contentView.addSubview(textView)

    vc.view = contentView
    popover.contentSize = NSSize(width: contentW, height: contentH)
    popover.contentViewController = vc
    popover.behavior = .transient
    popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
}

// MARK: - Settings Panel Controller

class SettingsPanelController: NSObject {
    private var values: SettingsValues!
    private var onApply: SettingsApplyCallback?
    private var onChangeFolder: FolderPickerCallback?

    private var window: NSWindow?

    // Controls
    private var checkMD: NSButton?
    private var checkTB: NSButton?
    private var toggleYaml: NSSwitch?
    private var toggleTagFolders: NSSwitch?
    private var toggleHideTags: NSSwitch?
    private var toggleAutoStart: NSSwitch?
    private var popupNaming: NSPopUpButton?
    private var popupDelete: NSPopUpButton?
    private var popupBackup: NSPopUpButton?
    private var backupFolderLabel: NSTextField?
    private var changeBackupBtn: NSButton?
    private var backupControls: [NSView] = []
    private var fieldExclude: NSTextField?
    private var folderLabel: NSTextField?
    private var folderTBLabel: NSTextField?
    private var changeTBBtn: NSButton?

    private var mdControls: [NSView] = []
    private var tbControls: [NSView] = []

    func configure(values: SettingsValues, onApply: @escaping SettingsApplyCallback, onChangeFolder: FolderPickerCallback? = nil) {
        self.values = values
        self.onApply = onApply
        self.onChangeFolder = onChangeFolder
        buildWindow()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    // MARK: - Build Window

    private func buildWindow() {
        let v = values!
        let style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        let rect = NSRect(x: 200, y: 200, width: winWidth, height: winHeight)

        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window?.title = t("settings.title")
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

        // Scroll view for content
        let scrollView = NSScrollView(frame: content.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        content.addSubview(scrollView)

        let docView = FlippedView(frame: NSRect(x: 0, y: 0, width: winWidth, height: 0))
        scrollView.documentView = docView

        let w = contentW
        var cy: CGFloat = pad + 28  // titlebar space

        let x0: CGFloat = pad
        let infoX = x0 + w - infoSize - 4
        let indent: CGFloat = 18

        // ── Export Formats Card ──────────────────────────────

        let mdEnabled = v.exportFormat == "md" || v.exportFormat == "both"
        let tbEnabled = v.exportFormat == "tb" || v.exportFormat == "both"

        let formatCardH: CGFloat = 280
        let formatCard = makeCard(in: docView, x: x0, y: cy, width: w, height: formatCardH)

        var fy: CGFloat = 12

        let formatTitle = makeLabel(t("settings.format"), x: cardPad, y: fy, width: w - cardPad * 2, bold: true)
        formatCard.addSubview(formatTitle)
        formatCard.addSubview(makeInfoButton(tag: 0, x: w - cardPad - infoSize, y: fy, target: self, action: #selector(onInfo(_:))))
        fy += rowH

        // Markdown checkbox
        checkMD = makeCheckbox(t("settings.format_md"), state: mdEnabled, x: cardPad + 4, y: fy, width: 240)
        checkMD?.target = self
        checkMD?.action = #selector(onFormatChanged(_:))
        formatCard.addSubview(checkMD!)
        fy += rowH

        // Markdown folder label
        let mdTitle = makeLabel(t("settings.export_folder_md"), x: cardPad + indent, y: fy, width: w - cardPad * 2 - indent)
        formatCard.addSubview(mdTitle)
        let mdInfo = makeInfoButton(tag: 1, x: w - cardPad - infoSize, y: fy, target: self, action: #selector(onInfo(_:)))
        formatCard.addSubview(mdInfo)
        fy += rowH

        // Markdown folder picker
        let folderDisplay = v.exportPath.isEmpty ? "..." : v.exportPath
        folderLabel = makeLabel(folderDisplay, x: cardPad + indent, y: fy, width: w - cardPad * 2 - 90 - indent)
        folderLabel?.lineBreakMode = .byTruncatingMiddle
        folderLabel?.textColor = .secondaryLabelColor
        formatCard.addSubview(folderLabel!)

        let changeBtn = NSButton(frame: NSRect(x: w - cardPad - 80, y: fy, width: 80, height: rowH))
        changeBtn.title = t("settings.change")
        changeBtn.bezelStyle = .rounded
        changeBtn.controlSize = .small
        changeBtn.target = self
        changeBtn.action = #selector(onChangeFolderMD(_:))
        formatCard.addSubview(changeBtn)
        fy += rowH + rowGap

        // TextBundle checkbox
        checkTB = makeCheckbox(t("settings.format_tb"), state: tbEnabled, x: cardPad + 4, y: fy, width: 260)
        checkTB?.target = self
        checkTB?.action = #selector(onFormatChanged(_:))
        formatCard.addSubview(checkTB!)
        fy += rowH

        // TextBundle folder label
        let tbTitle = makeLabel(t("settings.export_folder_tb"), x: cardPad + indent, y: fy, width: w - cardPad * 2 - indent)
        formatCard.addSubview(tbTitle)
        let tbInfo = makeInfoButton(tag: 2, x: w - cardPad - infoSize, y: fy, target: self, action: #selector(onInfo(_:)))
        formatCard.addSubview(tbInfo)
        fy += rowH

        // TextBundle folder picker
        let folderTBDisplay = v.exportPathTB.isEmpty ? "..." : v.exportPathTB
        folderTBLabel = makeLabel(folderTBDisplay, x: cardPad + indent, y: fy, width: w - cardPad * 2 - 90 - indent)
        folderTBLabel?.lineBreakMode = .byTruncatingMiddle
        folderTBLabel?.textColor = .secondaryLabelColor
        formatCard.addSubview(folderTBLabel!)

        changeTBBtn = NSButton(frame: NSRect(x: w - cardPad - 80, y: fy, width: 80, height: rowH))
        changeTBBtn?.title = t("settings.change")
        changeTBBtn?.bezelStyle = .rounded
        changeTBBtn?.controlSize = .small
        changeTBBtn?.target = self
        changeTBBtn?.action = #selector(onChangeFolderTB(_:))
        formatCard.addSubview(changeTBBtn!)
        fy += rowH + 4

        let tbNote = makeLabel(
            t("settings.folder_not_same"), x: cardPad + indent, y: fy,
            width: w - cardPad * 2 - indent, height: 32, small: true, wrap: true
        )
        formatCard.addSubview(tbNote)

        mdControls = [mdTitle, mdInfo, folderLabel!, changeBtn]
        tbControls = [tbTitle, tbInfo, folderTBLabel!, changeTBBtn!, tbNote]

        setControlsEnabled(mdControls, enabled: mdEnabled)
        setControlsEnabled(tbControls, enabled: tbEnabled)

        cy += formatCardH + sectionGap

        // ── Options Card (toggles) ──────────────────────────

        let optionsCardH: CGFloat = 4 * (rowH + rowGap) + 24
        let optionsCard = makeCard(in: docView, x: x0, y: cy, width: w, height: optionsCardH)

        let toggleX = w - cardPad - toggleW - infoSize - 12
        var oy: CGFloat = 12

        let toggleDefs: [(String, Int, Bool)] = [
            ("settings.yaml",        3, v.yamlFrontMatter),
            ("settings.tag_folders", 4, v.tagFolders),
            ("settings.hide_tags",   5, v.hideTags),
            ("settings.auto_start",  6, v.autoStart),
        ]

        var toggleRefs: [NSSwitch] = []
        for (labelKey, helpTag, val) in toggleDefs {
            optionsCard.addSubview(makeLabel(t(labelKey), x: cardPad, y: oy, width: w - cardPad * 2 - toggleW - infoSize - 20))
            let toggle = makeToggle(state: val, x: toggleX, y: oy)
            toggleRefs.append(toggle)
            optionsCard.addSubview(toggle)
            optionsCard.addSubview(makeInfoButton(tag: helpTag, x: w - cardPad - infoSize, y: oy, target: self, action: #selector(onInfo(_:))))
            oy += rowH + rowGap
        }

        toggleYaml       = toggleRefs[0]
        toggleTagFolders  = toggleRefs[1]
        toggleHideTags    = toggleRefs[2]
        toggleAutoStart   = toggleRefs[3]

        cy += optionsCardH + sectionGap

        // ── Naming & Delete Card ────────────────────────────

        let popupX = w - cardPad - 150 - infoSize - 8
        let popupW: CGFloat = 150

        let namingCardH: CGFloat = 2 * (rowH + rowGap) + 24
        let namingCard = makeCard(in: docView, x: x0, y: cy, width: w, height: namingCardH)

        var ny: CGFloat = 12

        // Naming strategy
        namingCard.addSubview(makeLabel(t("settings.naming"), x: cardPad, y: ny))
        popupNaming = NSPopUpButton(frame: NSRect(x: popupX, y: ny, width: popupW, height: rowH), pullsDown: false)
        popupNaming?.controlSize = .small
        popupNaming?.font = NSFont.systemFont(ofSize: 12)
        popupNaming?.addItems(withTitles: [
            t("settings.naming_title"),
            t("settings.naming_slug"),
            t("settings.naming_date"),
            t("settings.naming_id"),
        ])
        if let idx = namingKeys.firstIndex(of: v.naming) {
            popupNaming?.selectItem(at: idx)
        }
        namingCard.addSubview(popupNaming!)
        namingCard.addSubview(makeInfoButton(tag: 7, x: w - cardPad - infoSize, y: ny, target: self, action: #selector(onInfo(_:))))
        ny += rowH + rowGap

        // On-delete policy
        namingCard.addSubview(makeLabel(t("settings.on_delete"), x: cardPad, y: ny))
        popupDelete = NSPopUpButton(frame: NSRect(x: popupX, y: ny, width: popupW, height: rowH), pullsDown: false)
        popupDelete?.controlSize = .small
        popupDelete?.font = NSFont.systemFont(ofSize: 12)
        popupDelete?.addItems(withTitles: [
            t("settings.delete_trash"),
            t("settings.delete_remove"),
            t("settings.delete_keep"),
        ])
        if let idx = deleteKeys.firstIndex(of: v.onDelete) {
            popupDelete?.selectItem(at: idx)
        }
        namingCard.addSubview(popupDelete!)
        namingCard.addSubview(makeInfoButton(tag: 8, x: w - cardPad - infoSize, y: ny, target: self, action: #selector(onInfo(_:))))

        cy += namingCardH + sectionGap

        // ── Scheduled Backup Card ───────────────────────────

        let backupCardH: CGFloat = 130
        let backupCard = makeCard(in: docView, x: x0, y: cy, width: w, height: backupCardH)

        var by: CGFloat = 12

        let backupTitle = makeLabel(t("settings.backup"), x: cardPad, y: by, width: w - cardPad * 2, bold: true)
        backupCard.addSubview(backupTitle)
        backupCard.addSubview(makeInfoButton(tag: 10, x: w - cardPad - infoSize, y: by, target: self, action: #selector(onInfo(_:))))
        by += rowH

        backupCard.addSubview(makeLabel(t("settings.backup_interval"), x: cardPad, y: by))
        popupBackup = NSPopUpButton(frame: NSRect(x: popupX, y: by, width: popupW, height: rowH), pullsDown: false)
        popupBackup?.controlSize = .small
        popupBackup?.font = NSFont.systemFont(ofSize: 12)
        popupBackup?.addItems(withTitles: [
            t("settings.backup_off"),
            t("settings.backup_30m"),
            t("settings.backup_1h"),
            t("settings.backup_2h"),
            t("settings.backup_6h"),
            t("settings.backup_12h"),
            t("settings.backup_24h"),
        ])
        if let idx = backupIntervalKeys.firstIndex(of: v.backupInterval) {
            popupBackup?.selectItem(at: idx)
        }
        popupBackup?.target = self
        popupBackup?.action = #selector(onBackupIntervalChanged(_:))
        backupCard.addSubview(popupBackup!)
        by += rowH

        // Backup folder
        let backupFolderTitle = makeLabel(t("settings.backup_folder"), x: cardPad + indent, y: by)
        backupCard.addSubview(backupFolderTitle)
        by += rowH

        let backupDisplay = v.backupPath.isEmpty ? t("settings.backup_default") : v.backupPath
        backupFolderLabel = makeLabel(backupDisplay, x: cardPad + indent, y: by, width: w - cardPad * 2 - 90 - indent)
        backupFolderLabel?.lineBreakMode = .byTruncatingMiddle
        backupFolderLabel?.textColor = .secondaryLabelColor
        backupCard.addSubview(backupFolderLabel!)

        changeBackupBtn = NSButton(frame: NSRect(x: w - cardPad - 80, y: by, width: 80, height: rowH))
        changeBackupBtn?.title = t("settings.change")
        changeBackupBtn?.bezelStyle = .rounded
        changeBackupBtn?.controlSize = .small
        changeBackupBtn?.target = self
        changeBackupBtn?.action = #selector(onChangeFolderBackup(_:))
        backupCard.addSubview(changeBackupBtn!)

        backupControls = [backupFolderTitle, backupFolderLabel!, changeBackupBtn!]
        setControlsEnabled(backupControls, enabled: v.backupInterval > 0)

        cy += backupCardH + sectionGap

        // ── Exclude Tags Card ───────────────────────────────

        let excludeCardH: CGFloat = 120
        let excludeCard = makeCard(in: docView, x: x0, y: cy, width: w, height: excludeCardH)

        var ey: CGFloat = 12

        excludeCard.addSubview(makeLabel(t("settings.exclude_tags"), x: cardPad, y: ey, width: w - cardPad * 2, bold: true))
        excludeCard.addSubview(makeInfoButton(tag: 9, x: w - cardPad - infoSize, y: ey, target: self, action: #selector(onInfo(_:))))
        ey += rowH

        fieldExclude = NSTextField(frame: NSRect(x: cardPad, y: ey, width: w - cardPad * 2, height: 26))
        fieldExclude?.font = NSFont.systemFont(ofSize: 13)
        fieldExclude?.stringValue = v.excludeTags
        fieldExclude?.placeholderString = t("settings.exclude_placeholder")
        fieldExclude?.bezelStyle = .roundedBezel
        excludeCard.addSubview(fieldExclude!)
        ey += 32

        let exampleLabel = makeLabel(
            t("settings.exclude_example"), x: cardPad, y: ey,
            width: w - cardPad * 2, height: 36, small: true, wrap: true
        )
        excludeCard.addSubview(exampleLabel)

        cy += excludeCardH + sectionGap + 8

        // ── Action Buttons ──────────────────────────────────

        let btnW: CGFloat = 96

        let applyBtn = NSButton(frame: NSRect(x: x0 + w - btnW, y: cy, width: btnW, height: 30))
        applyBtn.title = t("settings.apply")
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        applyBtn.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        applyBtn.target = self
        applyBtn.action = #selector(onApplyClicked(_:))
        docView.addSubview(applyBtn)

        let cancelBtn = NSButton(frame: NSRect(x: x0 + w - btnW * 2 - 12, y: cy, width: btnW, height: 30))
        cancelBtn.title = t("settings.cancel")
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.font = NSFont.systemFont(ofSize: 13)
        cancelBtn.target = self
        cancelBtn.action = #selector(onCancelClicked(_:))
        docView.addSubview(cancelBtn)

        cy += 40 + pad

        docView.frame = NSRect(x: 0, y: 0, width: winWidth, height: cy)
    }

    // MARK: - Enable/Disable Controls

    private func setControlsEnabled(_ controls: [NSView], enabled: Bool) {
        for ctl in controls {
            if let c = ctl as? NSControl {
                c.isEnabled = enabled
            }
            if let tf = ctl as? NSTextField {
                tf.textColor = enabled ? .labelColor : .quaternaryLabelColor
            }
        }
    }

    // MARK: - Actions

    @objc private func onFormatChanged(_ sender: Any) {
        let mdOn = checkMD?.state == .on
        let tbOn = checkTB?.state == .on
        setControlsEnabled(mdControls, enabled: mdOn)
        setControlsEnabled(tbControls, enabled: tbOn)
    }

    @objc private func onBackupIntervalChanged(_ sender: Any) {
        let idx = popupBackup?.indexOfSelectedItem ?? 0
        let enabled = idx > 0
        setControlsEnabled(backupControls, enabled: enabled)
    }

    @objc private func onChangeFolderBackup(_ sender: Any) {
        if let newPath = onChangeFolder?() {
            values.backupPath = newPath
            backupFolderLabel?.stringValue = newPath
        }
    }

    @objc private func onApplyClicked(_ sender: Any) {
        guard var v = values else { return }

        let mdOn = checkMD?.state == .on
        let tbOn = checkTB?.state == .on

        if mdOn == true && tbOn == true {
            v.exportFormat = "both"
        } else if mdOn == true {
            v.exportFormat = "md"
        } else if tbOn == true {
            v.exportFormat = "tb"
        } else {
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.format_none")
            alert.runModal()
            return
        }

        if mdOn == true && v.exportPath.isEmpty {
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.folder_md_missing")
            alert.runModal()
            return
        }

        if tbOn == true && v.exportPathTB.isEmpty {
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.folder_tb_missing")
            alert.runModal()
            return
        }

        if v.exportFormat == "tb" {
            v.exportPath = v.exportPathTB
            v.exportPathTB = ""
        }

        if v.exportFormat == "both" && v.exportPath == v.exportPathTB {
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.folder_tb_conflict")
            alert.runModal()
            return
        }

        v.yamlFrontMatter = toggleYaml?.state == .on
        v.tagFolders      = toggleTagFolders?.state == .on
        v.hideTags        = toggleHideTags?.state == .on
        v.autoStart       = toggleAutoStart?.state == .on

        if let idx = popupNaming?.indexOfSelectedItem, idx >= 0, idx < namingKeys.count {
            v.naming = namingKeys[idx]
        }
        if let idx = popupDelete?.indexOfSelectedItem, idx >= 0, idx < deleteKeys.count {
            v.onDelete = deleteKeys[idx]
        }

        v.excludeTags = fieldExclude?.stringValue ?? ""

        if let idx = popupBackup?.indexOfSelectedItem, idx >= 0, idx < backupIntervalKeys.count {
            v.backupInterval = backupIntervalKeys[idx]
        }
        v.backupPath = backupFolderLabel?.stringValue ?? ""
        if v.backupPath == t("settings.backup_default") { v.backupPath = "" }

        close()
        onApply?(v)
    }

    @objc private func onCancelClicked(_ sender: Any) {
        close()
    }

    @objc private func onChangeFolderMD(_ sender: Any) {
        if let newPath = onChangeFolder?() {
            values.exportPath = newPath
            folderLabel?.stringValue = newPath
        }
    }

    @objc private func onChangeFolderTB(_ sender: Any) {
        if let newPath = onChangeFolder?() {
            values.exportPathTB = newPath
            folderTBLabel?.stringValue = newPath
        }
    }

    @objc private func onInfo(_ sender: NSButton) {
        guard let helpKey = helpTags[sender.tag] else { return }
        showPopover(relativeTo: sender, text: t(helpKey))
    }
}

// MARK: - Flipped View

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Active Panel (prevent GC)

private var activePanel: SettingsPanelController?

func showSettingsPanel(
    values: SettingsValues,
    onApply: @escaping SettingsApplyCallback,
    onChangeFolder: FolderPickerCallback? = nil
) {
    activePanel?.close()
    activePanel = nil

    activePanel = SettingsPanelController()
    activePanel?.configure(values: values, onApply: onApply, onChangeFolder: onChangeFolder)
    activePanel?.show()
}
