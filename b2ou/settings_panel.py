"""
Native macOS settings panel for B2OU.

Uses PyObjC to build a proper Cocoa NSWindow with Apple-style toggles
(NSSwitch), radio buttons, popup menus, and info buttons with tooltips.
"""

from __future__ import annotations

import logging
import math
from typing import Callable, Optional

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Lazy PyObjC imports — only loaded when settings panel is actually opened.
# This avoids loading AppKit symbols at module import time, reducing
# startup memory for the common case (menu bar only, no settings open).
# ---------------------------------------------------------------------------

_objc = None
_AppKit = None
_Foundation = None
_NSSwitch = None
_HAS_NSSWITCH = False


def _ensure_imports():
    """Load PyObjC modules on first use."""
    global _objc, _AppKit, _Foundation, _NSSwitch, _HAS_NSSWITCH
    if _objc is not None:
        return
    import objc as _objc_mod
    import AppKit as _ak
    import Foundation as _fn
    _objc = _objc_mod
    _AppKit = _ak
    _Foundation = _fn
    try:
        _NSSwitch = _ak.NSSwitch
        _HAS_NSSWITCH = True
    except AttributeError:
        _NSSwitch = None
        _HAS_NSSWITCH = False


# ---------------------------------------------------------------------------
# Layout constants
# ---------------------------------------------------------------------------

_WIN_WIDTH = 520
_WIN_HEIGHT = 760
_PAD = 24
_CONTENT_W = _WIN_WIDTH - _PAD * 2
_ROW_H = 28
_ROW_GAP = 10
_SECTION_GAP = 18
_LABEL_W = 220
_INFO_SIZE = 20
_TOGGLE_W = 40
_TOGGLE_H = 22


# ---------------------------------------------------------------------------
# Settings dataclass (pure Python — no PyObjC dependency)
# ---------------------------------------------------------------------------

class SettingsValues:
    """Mutable container for settings panel values."""

    __slots__ = (
        "export_path", "export_path_tb", "export_format", "yaml_front_matter",
        "tag_folders", "hide_tags", "auto_start",
        "naming", "on_delete", "exclude_tags",
    )

    def __init__(
        self,
        export_path: str = "",
        export_path_tb: str = "",
        export_format: str = "md",
        yaml_front_matter: bool = False,
        tag_folders: bool = False,
        hide_tags: bool = False,
        auto_start: bool = True,
        naming: str = "title",
        on_delete: str = "trash",
        exclude_tags: str = "",
    ):
        self.export_path = export_path
        self.export_path_tb = export_path_tb
        self.export_format = export_format
        self.yaml_front_matter = yaml_front_matter
        self.tag_folders = tag_folders
        self.hide_tags = hide_tags
        self.auto_start = auto_start
        self.naming = naming
        self.on_delete = on_delete
        self.exclude_tags = exclude_tags


# ---------------------------------------------------------------------------
# Helpers (require PyObjC — call _ensure_imports() first)
# ---------------------------------------------------------------------------

def _make_label(text, x, y, width=_LABEL_W, height=_ROW_H,
                bold=False, small=False, wrap=False):
    """Create a non-editable label."""
    ak = _AppKit
    if wrap:
        label = ak.NSTextField.wrappingLabelWithString_(text)
    else:
        label = ak.NSTextField.labelWithString_(text)
    label.setFrame_(ak.NSMakeRect(x, y, width, height))
    label.setBezeled_(False)
    label.setDrawsBackground_(False)
    label.setEditable_(False)
    label.setSelectable_(False)
    if bold:
        label.setFont_(ak.NSFont.boldSystemFontOfSize_(13))
    elif small:
        label.setFont_(ak.NSFont.systemFontOfSize_(11))
        label.setTextColor_(ak.NSColor.secondaryLabelColor())
    else:
        label.setFont_(ak.NSFont.systemFontOfSize_(13))
    return label


def _make_toggle(state, x, y):
    """Create an Apple-style toggle (NSSwitch) or checkbox fallback."""
    ak = _AppKit
    if _HAS_NSSWITCH and _NSSwitch is not None:
        toggle = _NSSwitch.alloc().initWithFrame_(
            ak.NSMakeRect(x, y + 2, _TOGGLE_W, _TOGGLE_H)
        )
        toggle.setState_(
            ak.NSControlStateValueOn if state else ak.NSControlStateValueOff
        )
    else:
        toggle = ak.NSButton.alloc().initWithFrame_(
            ak.NSMakeRect(x, y, _TOGGLE_W + 20, _ROW_H)
        )
        toggle.setButtonType_(1)  # NSButtonTypeSwitch
        toggle.setTitle_("")
        toggle.setState_(ak.NSOnState if state else ak.NSOffState)
    return toggle


def _make_checkbox(text, state, x, y, width=220, height=_ROW_H):
    """Create a checkbox (NSButtonTypeSwitch) with a label."""
    ak = _AppKit
    box = ak.NSButton.alloc().initWithFrame_(
        ak.NSMakeRect(x, y, width, height)
    )
    box.setButtonType_(ak.NSButtonTypeSwitch)
    box.setTitle_(text)
    box.setFont_(ak.NSFont.systemFontOfSize_(13))
    box.setState_(ak.NSOnState if state else ak.NSOffState)
    return box


def _make_info_button(tooltip, tag, x, y, target, action):
    """Create an info button (popover shown on click)."""
    ak = _AppKit
    btn = ak.NSButton.alloc().initWithFrame_(
        ak.NSMakeRect(x, y, _INFO_SIZE + 4, _ROW_H)
    )
    btn.setTitle_("\u24d8")
    btn.setBordered_(False)
    btn.setFont_(ak.NSFont.systemFontOfSize_(15))
    # Tooltips on macOS are size-limited and can truncate long text,
    # so we disable them and rely on the click popover instead.
    btn.setToolTip_(None)
    btn.setTag_(tag)
    btn.setTarget_(target)
    btn.setAction_(action)
    return btn


def _show_popover(relative_to, text):
    """Show a transient popover with explanatory text."""
    ak = _AppKit

    popover = ak.NSPopover.alloc().init()
    vc = ak.NSViewController.alloc().init()

    pad = 12
    max_w = 300

    font = ak.NSFont.systemFontOfSize_(12)
    text_view = ak.NSTextView.alloc().initWithFrame_(
        ak.NSMakeRect(0, 0, max_w, 10)
    )
    text_view.setString_(text)
    text_view.setFont_(font)
    text_view.setEditable_(False)
    text_view.setSelectable_(False)
    text_view.setDrawsBackground_(False)
    text_view.setHorizontallyResizable_(False)
    text_view.setVerticallyResizable_(True)
    text_view.setTextContainerInset_(_Foundation.NSMakeSize(0, 0))

    container = text_view.textContainer()
    container.setLineFragmentPadding_(0)
    container.setContainerSize_(_Foundation.NSMakeSize(max_w, 10_000))
    container.setWidthTracksTextView_(True)
    container.setLineBreakMode_(ak.NSLineBreakByCharWrapping)

    layout = text_view.layoutManager()
    layout.ensureLayoutForTextContainer_(container)
    used = layout.usedRectForTextContainer_(container)
    text_h = max(24, math.ceil(used.size.height) + 4)

    content_w = max_w + pad * 2
    content_h = text_h + pad * 2
    text_view.setFrame_(ak.NSMakeRect(pad, pad, max_w, text_h))

    content = ak.NSView.alloc().initWithFrame_(
        ak.NSMakeRect(0, 0, content_w, content_h)
    )
    content.addSubview_(text_view)

    vc.setView_(content)
    popover.setContentSize_(_Foundation.NSMakeSize(content_w, content_h))
    popover.setContentViewController_(vc)
    popover.setBehavior_(1)  # NSPopoverBehaviorTransient
    popover.showRelativeToRect_ofView_preferredEdge_(
        relative_to.bounds(), relative_to, ak.NSRectEdgeMaxY
    )


# ---------------------------------------------------------------------------
# Panel controller
# ---------------------------------------------------------------------------

_active_panel = None  # prevent GC

_NAMING_KEYS = ["title", "slug", "date-title", "id"]
_DELETE_KEYS = ["trash", "remove", "keep"]

_HELP_TAGS = {
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
}


def _create_controller_class():
    """Create the ObjC class on demand to avoid loading PyObjC at import."""
    _ensure_imports()
    ak = _AppKit
    objc = _objc

    from b2ou.i18n import t

    class SettingsPanelController(_Foundation.NSObject):
        """Controller for the native settings panel window."""

        @objc.python_method
        def configure(self, values, on_apply, on_change_folder=None):
            self._values = values
            self._on_apply = on_apply
            self._on_change_folder = on_change_folder
            self._check_md = None
            self._check_tb = None
            self._toggle_yaml = None
            self._toggle_tag_folders = None
            self._toggle_hide_tags = None
            self._toggle_auto_start = None
            self._popup_naming = None
            self._popup_delete = None
            self._field_exclude = None
            self._folder_label = None
            self._folder_tb_label = None
            self._change_tb_btn = None
            self._md_controls = []
            self._tb_controls = []
            self._window = None
            self._build_window()

        @objc.python_method
        def show(self):
            if self._window:
                self._window.makeKeyAndOrderFront_(None)
                ak.NSApp.activateIgnoringOtherApps_(True)

        @objc.python_method
        def close(self):
            """Safely close and clean up."""
            if self._window:
                self._window.close()
                self._window = None

        @objc.python_method
        def _build_window(self):
            v = self._values
            style = (ak.NSWindowStyleMaskTitled | ak.NSWindowStyleMaskClosable)
            rect = ak.NSMakeRect(200, 200, _WIN_WIDTH, _WIN_HEIGHT)

            self._window = (
                ak.NSWindow.alloc()
                .initWithContentRect_styleMask_backing_defer_(
                    rect, style, ak.NSBackingStoreBuffered, False
                )
            )
            self._window.setTitle_(t("settings.title"))
            self._window.center()
            self._window.setReleasedWhenClosed_(False)

            content = self._window.contentView()
            # Actual content height from the content view
            ch = content.frame().size.height
            cy = ch - _PAD
            x0 = _PAD
            right = _WIN_WIDTH - _PAD
            info_x = right - _INFO_SIZE - 4

            # ── Export Formats ────────────────────────────────────
            cy -= _ROW_H
            content.addSubview_(
                _make_label(t("settings.format"), x0, cy, bold=True)
            )
            content.addSubview_(
                _make_info_button(
                    t("help.format"), 0, info_x, cy, self, "onInfo:"
                )
            )

            md_enabled = v.export_format in ("md", "both")
            tb_enabled = v.export_format in ("tb", "both")
            indent = 18

            # Markdown checkbox
            cy -= _ROW_H
            self._check_md = _make_checkbox(
                t("settings.format_md"), md_enabled, x0 + 6, cy, width=240
            )
            self._check_md.setTarget_(self)
            self._check_md.setAction_("onFormatChanged:")
            content.addSubview_(self._check_md)

            # Markdown folder label + info
            cy -= _ROW_H
            md_title = _make_label(
                t("settings.export_folder_md"), x0 + indent, cy, bold=False
            )
            content.addSubview_(md_title)
            md_info = _make_info_button(
                t("help.export_folder_md"), 1, info_x, cy, self, "onInfo:"
            )
            content.addSubview_(md_info)

            # Markdown folder picker
            cy -= _ROW_H
            folder_display = v.export_path or "..."
            self._folder_label = _make_label(
                folder_display, x0 + indent, cy, width=_CONTENT_W - 90 - indent
            )
            self._folder_label.setLineBreakMode_(5)
            content.addSubview_(self._folder_label)

            change_btn = ak.NSButton.alloc().initWithFrame_(
                ak.NSMakeRect(right - 80, cy, 80, _ROW_H)
            )
            change_btn.setTitle_(t("settings.change"))
            change_btn.setBezelStyle_(ak.NSBezelStyleRounded)
            change_btn.setTarget_(self)
            change_btn.setAction_("onChangeFolder:")
            content.addSubview_(change_btn)

            # TextBundle checkbox
            cy -= _ROW_GAP
            cy -= _ROW_H
            self._check_tb = _make_checkbox(
                t("settings.format_tb"), tb_enabled, x0 + 6, cy, width=260
            )
            self._check_tb.setTarget_(self)
            self._check_tb.setAction_("onFormatChanged:")
            content.addSubview_(self._check_tb)

            # TextBundle folder label + info
            cy -= _ROW_H
            tb_title = _make_label(
                t("settings.export_folder_tb"), x0 + indent, cy, bold=False
            )
            content.addSubview_(tb_title)
            tb_info = _make_info_button(
                t("help.export_folder_tb"), 2, info_x, cy, self, "onInfo:"
            )
            content.addSubview_(tb_info)

            # TextBundle folder picker
            cy -= _ROW_H
            folder_tb_display = v.export_path_tb or "..."
            self._folder_tb_label = _make_label(
                folder_tb_display, x0 + indent, cy, width=_CONTENT_W - 90 - indent
            )
            self._folder_tb_label.setLineBreakMode_(5)
            content.addSubview_(self._folder_tb_label)

            self._change_tb_btn = ak.NSButton.alloc().initWithFrame_(
                ak.NSMakeRect(right - 80, cy, 80, _ROW_H)
            )
            self._change_tb_btn.setTitle_(t("settings.change"))
            self._change_tb_btn.setBezelStyle_(ak.NSBezelStyleRounded)
            self._change_tb_btn.setTarget_(self)
            self._change_tb_btn.setAction_("onChangeTBFolder:")
            content.addSubview_(self._change_tb_btn)

            cy -= 36
            tb_note = _make_label(
                t("settings.folder_not_same"), x0 + indent, cy,
                width=_CONTENT_W - indent, height=32, small=True, wrap=True,
            )
            content.addSubview_(tb_note)

            self._md_controls = [
                md_title, md_info, self._folder_label, change_btn,
            ]
            self._tb_controls = [
                tb_title, tb_info, self._folder_tb_label, self._change_tb_btn,
                tb_note,
            ]

            self._set_md_controls_enabled(md_enabled)
            self._set_tb_controls_enabled(tb_enabled)

            cy -= _SECTION_GAP - 6

            # ── Toggle rows ───────────────────────────────────────
            toggle_x = right - _TOGGLE_W - _INFO_SIZE - 16

            for label_key, help_tag, attr, val in [
                ("settings.yaml", 3, "_toggle_yaml", v.yaml_front_matter),
                ("settings.tag_folders", 4, "_toggle_tag_folders", v.tag_folders),
                ("settings.hide_tags", 5, "_toggle_hide_tags", v.hide_tags),
                ("settings.auto_start", 6, "_toggle_auto_start", v.auto_start),
            ]:
                cy -= _ROW_H
                content.addSubview_(
                    _make_label(t(label_key), x0, cy, width=_LABEL_W)
                )
                toggle = _make_toggle(val, toggle_x, cy)
                setattr(self, attr, toggle)
                content.addSubview_(toggle)
                content.addSubview_(
                    _make_info_button(
                        t(_HELP_TAGS[help_tag]), help_tag, info_x, cy,
                        self, "onInfo:"
                    )
                )
                cy -= _ROW_GAP

            cy -= _SECTION_GAP - _ROW_GAP

            # ── Popup rows ────────────────────────────────────────
            popup_x = right - 160 - _INFO_SIZE - 12
            popup_w = 150

            # Naming strategy
            cy -= _ROW_H
            content.addSubview_(
                _make_label(t("settings.naming"), x0, cy)
            )
            self._popup_naming = (
                ak.NSPopUpButton.alloc()
                .initWithFrame_pullsDown_(
                    ak.NSMakeRect(popup_x, cy, popup_w, _ROW_H), False
                )
            )
            self._popup_naming.addItemsWithTitles_([
                t("settings.naming_title"),
                t("settings.naming_slug"),
                t("settings.naming_date"),
                t("settings.naming_id"),
            ])
            if v.naming in _NAMING_KEYS:
                self._popup_naming.selectItemAtIndex_(
                    _NAMING_KEYS.index(v.naming)
                )
            content.addSubview_(self._popup_naming)
            content.addSubview_(
                _make_info_button(
                    t("help.naming"), 7, info_x, cy, self, "onInfo:"
                )
            )

            cy -= _ROW_GAP

            # On-delete policy
            cy -= _ROW_H
            content.addSubview_(
                _make_label(t("settings.on_delete"), x0, cy)
            )
            self._popup_delete = (
                ak.NSPopUpButton.alloc()
                .initWithFrame_pullsDown_(
                    ak.NSMakeRect(popup_x, cy, popup_w, _ROW_H), False
                )
            )
            self._popup_delete.addItemsWithTitles_([
                t("settings.delete_trash"),
                t("settings.delete_remove"),
                t("settings.delete_keep"),
            ])
            if v.on_delete in _DELETE_KEYS:
                self._popup_delete.selectItemAtIndex_(
                    _DELETE_KEYS.index(v.on_delete)
                )
            content.addSubview_(self._popup_delete)
            content.addSubview_(
                _make_info_button(
                    t("help.on_delete"), 8, info_x, cy, self, "onInfo:"
                )
            )

            cy -= _SECTION_GAP

            # ── Exclude Tags ──────────────────────────────────────
            cy -= _ROW_H
            content.addSubview_(
                _make_label(
                    t("settings.exclude_tags"), x0, cy, bold=True
                )
            )
            content.addSubview_(
                _make_info_button(
                    t("help.exclude_tags"), 9, info_x, cy, self, "onInfo:"
                )
            )

            cy -= _ROW_H
            self._field_exclude = ak.NSTextField.alloc().initWithFrame_(
                ak.NSMakeRect(x0, cy, _CONTENT_W, _ROW_H)
            )
            self._field_exclude.setFont_(ak.NSFont.systemFontOfSize_(13))
            self._field_exclude.setStringValue_(v.exclude_tags)
            self._field_exclude.setPlaceholderString_(
                t("settings.exclude_placeholder")
            )
            content.addSubview_(self._field_exclude)

            # Multi-line example text (wrapping label with proper height)
            example_text = t("settings.exclude_example")
            cy -= 44  # enough for 2 lines of small text
            example_label = _make_label(
                example_text, x0 + 4, cy, width=_CONTENT_W - 8,
                height=40, small=True, wrap=True,
            )
            content.addSubview_(example_label)

            # ── Buttons ───────────────────────────────────────────
            btn_y = _PAD
            btn_w = 90

            apply_btn = ak.NSButton.alloc().initWithFrame_(
                ak.NSMakeRect(right - btn_w, btn_y, btn_w, 32)
            )
            apply_btn.setTitle_(t("settings.apply"))
            apply_btn.setBezelStyle_(ak.NSBezelStyleRounded)
            apply_btn.setKeyEquivalent_("\r")
            apply_btn.setTarget_(self)
            apply_btn.setAction_("onApply:")
            content.addSubview_(apply_btn)

            cancel_btn = ak.NSButton.alloc().initWithFrame_(
                ak.NSMakeRect(right - btn_w * 2 - 12, btn_y, btn_w, 32)
            )
            cancel_btn.setTitle_(t("settings.cancel"))
            cancel_btn.setBezelStyle_(ak.NSBezelStyleRounded)
            cancel_btn.setKeyEquivalent_("\x1b")
            cancel_btn.setTarget_(self)
            cancel_btn.setAction_("onCancel:")
            content.addSubview_(cancel_btn)

        @objc.python_method
        def _set_controls_enabled(self, controls, enabled: bool) -> None:
            if not controls:
                return
            for ctl in controls:
                try:
                    ctl.setEnabled_(enabled)
                except Exception:
                    pass
                try:
                    if enabled:
                        ctl.setTextColor_(ak.NSColor.labelColor())
                    else:
                        ctl.setTextColor_(ak.NSColor.secondaryLabelColor())
                except Exception:
                    pass

        @objc.python_method
        def _set_md_controls_enabled(self, enabled: bool) -> None:
            self._set_controls_enabled(self._md_controls, enabled)

        @objc.python_method
        def _set_tb_controls_enabled(self, enabled: bool) -> None:
            self._set_controls_enabled(self._tb_controls, enabled)

        # ── Actions ───────────────────────────────────────────────

        def onFormatChanged_(self, sender):
            md_enabled = bool(
                self._check_md and self._check_md.state() == ak.NSOnState
            )
            tb_enabled = bool(
                self._check_tb and self._check_tb.state() == ak.NSOnState
            )
            self._set_md_controls_enabled(md_enabled)
            self._set_tb_controls_enabled(tb_enabled)

        def onApply_(self, sender):
            v = self._values

            md_enabled = bool(
                self._check_md and self._check_md.state() == ak.NSOnState
            )
            tb_enabled = bool(
                self._check_tb and self._check_tb.state() == ak.NSOnState
            )
            if md_enabled and tb_enabled:
                v.export_format = "both"
            elif md_enabled:
                v.export_format = "md"
            elif tb_enabled:
                v.export_format = "tb"
            else:
                v.export_format = "none"

            v.yaml_front_matter = bool(
                self._toggle_yaml
                and self._toggle_yaml.state() == ak.NSOnState
            )
            v.tag_folders = bool(
                self._toggle_tag_folders
                and self._toggle_tag_folders.state() == ak.NSOnState
            )
            v.hide_tags = bool(
                self._toggle_hide_tags
                and self._toggle_hide_tags.state() == ak.NSOnState
            )
            v.auto_start = bool(
                self._toggle_auto_start
                and self._toggle_auto_start.state() == ak.NSOnState
            )

            if self._popup_naming:
                idx = self._popup_naming.indexOfSelectedItem()
                v.naming = (
                    _NAMING_KEYS[idx]
                    if 0 <= idx < len(_NAMING_KEYS)
                    else "title"
                )
            if self._popup_delete:
                idx = self._popup_delete.indexOfSelectedItem()
                v.on_delete = (
                    _DELETE_KEYS[idx]
                    if 0 <= idx < len(_DELETE_KEYS)
                    else "trash"
                )

            if self._field_exclude:
                v.exclude_tags = str(self._field_exclude.stringValue())

            self.close()
            if self._on_apply:
                self._on_apply(v)

        def onCancel_(self, sender):
            self.close()

        def onChangeFolder_(self, sender):
            if self._on_change_folder:
                new_path = self._on_change_folder()
                if new_path and self._folder_label:
                    self._values.export_path = new_path
                    self._folder_label.setStringValue_(new_path)

        def onChangeTBFolder_(self, sender):
            if self._on_change_folder:
                new_path = self._on_change_folder()
                if new_path and self._folder_tb_label:
                    self._values.export_path_tb = new_path
                    self._folder_tb_label.setStringValue_(new_path)

        def onInfo_(self, sender):
            tag = sender.tag()
            help_key = _HELP_TAGS.get(tag, "")
            if help_key:
                _show_popover(sender, t(help_key))

    return SettingsPanelController


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def show_settings_panel(
    values: SettingsValues,
    on_apply: Callable[[SettingsValues], None],
    on_change_folder: Optional[Callable[[], Optional[str]]] = None,
) -> None:
    """
    Show the native settings panel.

    Safely closes any previous panel before opening a new one.
    """
    global _active_panel

    # Close any existing panel to prevent crashes from stale references
    if _active_panel is not None:
        try:
            _active_panel.close()
        except Exception:
            pass
        _active_panel = None

    _ensure_imports()
    ControllerClass = _create_controller_class()
    _active_panel = ControllerClass.alloc().init()
    _active_panel.configure(values, on_apply, on_change_folder)
    _active_panel.show()
