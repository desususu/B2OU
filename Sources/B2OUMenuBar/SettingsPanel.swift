// SettingsPanel.swift — Native macOS settings panel for B2OU.
//
// Port of the Python/PyObjC settings panel (b2ou/settings_panel.py)
// to pure AppKit. Provides a Cocoa NSWindow with toggles, popup menus,
// folder pickers, and info popovers.

import Cocoa
import B2OUCore

// MARK: - Layout Constants

private let winWidth:  CGFloat = 520
private let winHeight: CGFloat = 760
private let pad:       CGFloat = 24
private let contentW:  CGFloat = winWidth - pad * 2
private let rowH:      CGFloat = 28
private let rowGap:    CGFloat = 10
private let sectionGap: CGFloat = 18
private let labelW:    CGFloat = 220
private let infoSize:  CGFloat = 20
private let toggleW:   CGFloat = 40
private let toggleH:   CGFloat = 22

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
]

// MARK: - Settings Values

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
}

// MARK: - Callbacks

typealias SettingsApplyCallback = (SettingsValues) -> Void
typealias FolderPickerCallback = () -> String?

// MARK: - Helpers

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
        label.font = NSFont.boldSystemFont(ofSize: 13)
    } else if small {
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
    } else {
        label.font = NSFont.systemFont(ofSize: 13)
    }
    return label
}

private func makeToggle(state: Bool, x: CGFloat, y: CGFloat) -> NSSwitch {
    let toggle = NSSwitch(frame: NSRect(x: x, y: y + 2, width: toggleW, height: toggleH))
    toggle.state = state ? .on : .off
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
    let btn = NSButton(frame: NSRect(x: x, y: y, width: infoSize + 4, height: rowH))
    btn.title = "\u{24d8}"
    btn.isBordered = false
    btn.font = NSFont.systemFont(ofSize: 15)
    btn.toolTip = nil
    btn.tag = tag
    btn.target = target
    btn.action = action
    return btn
}

private func showPopover(relativeTo view: NSView, text: String) {
    let popover = NSPopover()
    let vc = NSViewController()

    let popPad: CGFloat = 12
    let maxW: CGFloat = 300

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
        let style: NSWindow.StyleMask = [.titled, .closable]
        let rect = NSRect(x: 200, y: 200, width: winWidth, height: winHeight)

        window = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window?.title = t("settings.title")
        window?.center()
        window?.isReleasedWhenClosed = false

        guard let content = window?.contentView else { return }
        let ch = content.frame.height
        var cy = ch - pad
        let x0 = pad
        let right = winWidth - pad
        let infoX = right - infoSize - 4

        // ── Export Formats ──────────────────────────────────
        cy -= rowH
        content.addSubview(makeLabel(t("settings.format"), x: x0, y: cy, bold: true))
        content.addSubview(makeInfoButton(tag: 0, x: infoX, y: cy, target: self, action: #selector(onInfo(_:))))

        let mdEnabled = v.exportFormat == "md" || v.exportFormat == "both"
        let tbEnabled = v.exportFormat == "tb" || v.exportFormat == "both"
        let indent: CGFloat = 18

        // Markdown checkbox
        cy -= rowH
        checkMD = makeCheckbox(t("settings.format_md"), state: mdEnabled, x: x0 + 6, y: cy, width: 240)
        checkMD?.target = self
        checkMD?.action = #selector(onFormatChanged(_:))
        content.addSubview(checkMD!)

        // Markdown folder label + info
        cy -= rowH
        let mdTitle = makeLabel(t("settings.export_folder_md"), x: x0 + indent, y: cy)
        content.addSubview(mdTitle)
        let mdInfo = makeInfoButton(tag: 1, x: infoX, y: cy, target: self, action: #selector(onInfo(_:)))
        content.addSubview(mdInfo)

        // Markdown folder picker
        cy -= rowH
        let folderDisplay = v.exportPath.isEmpty ? "..." : v.exportPath
        folderLabel = makeLabel(folderDisplay, x: x0 + indent, y: cy, width: contentW - 90 - indent)
        folderLabel?.lineBreakMode = .byTruncatingMiddle
        content.addSubview(folderLabel!)

        let changeBtn = NSButton(frame: NSRect(x: right - 80, y: cy, width: 80, height: rowH))
        changeBtn.title = t("settings.change")
        changeBtn.bezelStyle = .rounded
        changeBtn.target = self
        changeBtn.action = #selector(onChangeFolderMD(_:))
        content.addSubview(changeBtn)

        // TextBundle checkbox
        cy -= rowGap
        cy -= rowH
        checkTB = makeCheckbox(t("settings.format_tb"), state: tbEnabled, x: x0 + 6, y: cy, width: 260)
        checkTB?.target = self
        checkTB?.action = #selector(onFormatChanged(_:))
        content.addSubview(checkTB!)

        // TextBundle folder label + info
        cy -= rowH
        let tbTitle = makeLabel(t("settings.export_folder_tb"), x: x0 + indent, y: cy)
        content.addSubview(tbTitle)
        let tbInfo = makeInfoButton(tag: 2, x: infoX, y: cy, target: self, action: #selector(onInfo(_:)))
        content.addSubview(tbInfo)

        // TextBundle folder picker
        cy -= rowH
        let folderTBDisplay = v.exportPathTB.isEmpty ? "..." : v.exportPathTB
        folderTBLabel = makeLabel(folderTBDisplay, x: x0 + indent, y: cy, width: contentW - 90 - indent)
        folderTBLabel?.lineBreakMode = .byTruncatingMiddle
        content.addSubview(folderTBLabel!)

        changeTBBtn = NSButton(frame: NSRect(x: right - 80, y: cy, width: 80, height: rowH))
        changeTBBtn?.title = t("settings.change")
        changeTBBtn?.bezelStyle = .rounded
        changeTBBtn?.target = self
        changeTBBtn?.action = #selector(onChangeFolderTB(_:))
        content.addSubview(changeTBBtn!)

        cy -= 36
        let tbNote = makeLabel(
            t("settings.folder_not_same"), x: x0 + indent, y: cy,
            width: contentW - indent, height: 32, small: true, wrap: true
        )
        content.addSubview(tbNote)

        mdControls = [mdTitle, mdInfo, folderLabel!, changeBtn]
        tbControls = [tbTitle, tbInfo, folderTBLabel!, changeTBBtn!, tbNote]

        setControlsEnabled(mdControls, enabled: mdEnabled)
        setControlsEnabled(tbControls, enabled: tbEnabled)

        cy -= sectionGap - 6

        // ── Toggle rows ─────────────────────────────────────
        let toggleX = right - toggleW - infoSize - 16

        let toggleDefs: [(String, Int, Bool)] = [
            ("settings.yaml",        3, v.yamlFrontMatter),
            ("settings.tag_folders", 4, v.tagFolders),
            ("settings.hide_tags",   5, v.hideTags),
            ("settings.auto_start",  6, v.autoStart),
        ]

        var toggleRefs: [NSSwitch] = []
        for (labelKey, helpTag, val) in toggleDefs {
            cy -= rowH
            content.addSubview(makeLabel(t(labelKey), x: x0, y: cy, width: labelW))
            let toggle = makeToggle(state: val, x: toggleX, y: cy)
            toggleRefs.append(toggle)
            content.addSubview(toggle)
            content.addSubview(makeInfoButton(tag: helpTag, x: infoX, y: cy, target: self, action: #selector(onInfo(_:))))
            cy -= rowGap
        }

        toggleYaml       = toggleRefs[0]
        toggleTagFolders  = toggleRefs[1]
        toggleHideTags    = toggleRefs[2]
        toggleAutoStart   = toggleRefs[3]

        cy -= sectionGap - rowGap

        // ── Popup rows ──────────────────────────────────────
        let popupX = right - 160 - infoSize - 12
        let popupW: CGFloat = 150

        // Naming strategy
        cy -= rowH
        content.addSubview(makeLabel(t("settings.naming"), x: x0, y: cy))
        popupNaming = NSPopUpButton(frame: NSRect(x: popupX, y: cy, width: popupW, height: rowH), pullsDown: false)
        popupNaming?.addItems(withTitles: [
            t("settings.naming_title"),
            t("settings.naming_slug"),
            t("settings.naming_date"),
            t("settings.naming_id"),
        ])
        if let idx = namingKeys.firstIndex(of: v.naming) {
            popupNaming?.selectItem(at: idx)
        }
        content.addSubview(popupNaming!)
        content.addSubview(makeInfoButton(tag: 7, x: infoX, y: cy, target: self, action: #selector(onInfo(_:))))

        cy -= rowGap

        // On-delete policy
        cy -= rowH
        content.addSubview(makeLabel(t("settings.on_delete"), x: x0, y: cy))
        popupDelete = NSPopUpButton(frame: NSRect(x: popupX, y: cy, width: popupW, height: rowH), pullsDown: false)
        popupDelete?.addItems(withTitles: [
            t("settings.delete_trash"),
            t("settings.delete_remove"),
            t("settings.delete_keep"),
        ])
        if let idx = deleteKeys.firstIndex(of: v.onDelete) {
            popupDelete?.selectItem(at: idx)
        }
        content.addSubview(popupDelete!)
        content.addSubview(makeInfoButton(tag: 8, x: infoX, y: cy, target: self, action: #selector(onInfo(_:))))

        cy -= sectionGap

        // ── Exclude Tags ────────────────────────────────────
        cy -= rowH
        content.addSubview(makeLabel(t("settings.exclude_tags"), x: x0, y: cy, bold: true))
        content.addSubview(makeInfoButton(tag: 9, x: infoX, y: cy, target: self, action: #selector(onInfo(_:))))

        cy -= rowH
        fieldExclude = NSTextField(frame: NSRect(x: x0, y: cy, width: contentW, height: rowH))
        fieldExclude?.font = NSFont.systemFont(ofSize: 13)
        fieldExclude?.stringValue = v.excludeTags
        fieldExclude?.placeholderString = t("settings.exclude_placeholder")
        content.addSubview(fieldExclude!)

        cy -= 44
        let exampleLabel = makeLabel(
            t("settings.exclude_example"), x: x0 + 4, y: cy,
            width: contentW - 8, height: 40, small: true, wrap: true
        )
        content.addSubview(exampleLabel)

        // ── Buttons ─────────────────────────────────────────
        let btnY = pad
        let btnW: CGFloat = 90

        let applyBtn = NSButton(frame: NSRect(x: right - btnW, y: btnY, width: btnW, height: 32))
        applyBtn.title = t("settings.apply")
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        applyBtn.target = self
        applyBtn.action = #selector(onApplyClicked(_:))
        content.addSubview(applyBtn)

        let cancelBtn = NSButton(frame: NSRect(x: right - btnW * 2 - 12, y: btnY, width: btnW, height: 32))
        cancelBtn.title = t("settings.cancel")
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.target = self
        cancelBtn.action = #selector(onCancelClicked(_:))
        content.addSubview(cancelBtn)
    }

    // MARK: - Enable/Disable Controls

    private func setControlsEnabled(_ controls: [NSView], enabled: Bool) {
        for ctl in controls {
            if let c = ctl as? NSControl {
                c.isEnabled = enabled
            }
            if let tf = ctl as? NSTextField {
                tf.textColor = enabled ? .labelColor : .secondaryLabelColor
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
            // No format selected — show validation
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.format_none")
            alert.runModal()
            return
        }

        // Validate MD folder
        if mdOn == true && v.exportPath.isEmpty {
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.folder_md_missing")
            alert.runModal()
            return
        }

        // Validate TB folder for "both" mode
        if v.exportFormat == "both" && v.exportPathTB.isEmpty {
            let alert = NSAlert()
            alert.messageText = t("settings.title")
            alert.informativeText = t("settings.folder_tb_missing")
            alert.runModal()
            return
        }

        // Validate TB != MD for "both" mode
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
