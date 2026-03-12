"""
Internationalization support for B2OU.

Provides translated strings for English and Chinese, with automatic
system-language detection and runtime switching via the menu bar.
"""

from __future__ import annotations

import locale
import logging
from typing import Optional

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Language preference persistence (macOS NSUserDefaults)
# ---------------------------------------------------------------------------

_PREF_KEY = "B2OULanguage"


def _read_preference() -> Optional[str]:
    """Read saved language preference from macOS defaults."""
    try:
        from Foundation import NSUserDefaults
        val = NSUserDefaults.standardUserDefaults().stringForKey_(_PREF_KEY)
        return str(val) if val else None
    except Exception:
        return None


def _write_preference(lang: str) -> None:
    """Persist language preference to macOS defaults."""
    try:
        from Foundation import NSUserDefaults
        NSUserDefaults.standardUserDefaults().setObject_forKey_(lang, _PREF_KEY)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# System language detection
# ---------------------------------------------------------------------------

def detect_system_language() -> str:
    """Return ``'zh'`` if the system locale is Chinese, else ``'en'``."""
    # Try macOS-native detection first
    try:
        from Foundation import NSLocale
        langs = NSLocale.preferredLanguages()
        if langs and len(langs) > 0:
            primary = str(langs[0]).lower()
            if primary.startswith("zh"):
                return "zh"
            return "en"
    except Exception:
        pass
    # Fallback to Python locale
    try:
        lang_code = locale.getlocale()[0] or ""
        if lang_code.lower().startswith("zh"):
            return "zh"
    except Exception:
        pass
    return "en"


# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

_current_lang: str = "en"


def init_language() -> str:
    """Initialize language from saved preference or system detection."""
    global _current_lang
    saved = _read_preference()
    if saved and saved in ("en", "zh"):
        _current_lang = saved
    else:
        _current_lang = detect_system_language()
    return _current_lang


def set_language(lang: str) -> None:
    """Set the active language and persist the choice."""
    global _current_lang
    if lang not in ("en", "zh"):
        lang = "en"
    _current_lang = lang
    _write_preference(lang)


def get_language() -> str:
    """Return the current active language code."""
    return _current_lang


def t(key: str) -> str:
    """Return the translated string for *key* in the current language."""
    table = _STRINGS.get(_current_lang, _STRINGS["en"])
    return table.get(key, _STRINGS["en"].get(key, key))


# ---------------------------------------------------------------------------
# String tables
# ---------------------------------------------------------------------------

_STRINGS: dict[str, dict[str, str]] = {
    "en": {
        # ── Menu items ────────────────────────────────────────────────
        "menu.starting": "Starting...",
        "menu.export_now": "Export Now",
        "menu.pause": "Pause",
        "menu.resume": "Resume",
        "menu.open_folder": "Open Export Folder",
        "menu.profile": "Profile",
        "menu.start_at_login": "Start at Login",
        "menu.change_folder": "Change Export Folder...",
        "menu.configure": "Configure Profile...",
        "menu.edit_config": "Edit Config File...",
        "menu.quit": "Quit",
        "menu.language": "Language",
        "menu.setup": "Set Up...",
        "menu.reload": "Reload",
        "menu.no_profile": "No profile loaded",
        "menu.notes_exported": "{count:,} notes exported",
        "menu.exporting_to": "Exporting to {folder}",
        "menu.last_export": "Last export: {time}",
        "menu.just_now": "just now",
        "menu.min_ago": "{mins} min ago",

        # ── Language names (always shown in native form) ──────────────
        "lang.en": "English",
        "lang.zh": "\u4e2d\u6587",
        "lang.auto": "Auto (System)",

        # ── Wizard ────────────────────────────────────────────────────
        "wizard.welcome_title": "Welcome to B2OU",
        "wizard.welcome_msg": (
            "B2OU keeps your Bear notes automatically backed up "
            "as Markdown files.\n\n"
            "How would you like to set it up?"
        ),
        "wizard.quick": "Quick Setup (Recommended)",
        "wizard.advanced": "Advanced Setup",
        "wizard.quick_title": "Quick Setup",
        "wizard.quick_msg": (
            "Just pick a folder and you're done.\n\n"
            "B2OU will export all your Bear notes as clean Markdown "
            "files, automatically keep them up to date, and start "
            "at login."
        ),
        "wizard.choose_folder": "Choose Folder",
        "wizard.cancelled_title": "Setup Cancelled",
        "wizard.cancelled_msg": "You can set up later from the menu bar.",
        "wizard.ready": "Ready",
        "wizard.ready_msg": "Your notes are being exported to:\n{path}",
        "wizard.pick_prompt": "Choose where to save your Bear notes:",
        "wizard.pick_advanced": "Choose the export destination folder:",

        # ── Settings panel ────────────────────────────────────────────
        "settings.title": "B2OU Settings",
        "settings.export_folder": "Export Folder",
        "settings.export_folder_md": "Markdown Folder",
        "settings.change": "Change...",
        "settings.format": "Export Format",
        "settings.format_md": "Markdown (.md)",
        "settings.format_tb": "TextBundle (.textbundle)",
        "settings.format_both": "Both (MD + TB)",
        "settings.export_folder_tb": "TextBundle Folder",
        "settings.folder_not_same": (
            "When exporting both formats, the TextBundle folder must be "
            "different from the Markdown folder."
        ),
        "settings.yaml": "YAML Front Matter",
        "settings.tag_folders": "Organize by Tag Folders",
        "settings.hide_tags": "Hide Tags in Notes",
        "settings.auto_start": "Start at Login",
        "settings.naming": "File Naming",
        "settings.naming_title": "title",
        "settings.naming_slug": "slug",
        "settings.naming_date": "date-title",
        "settings.naming_id": "id",
        "settings.on_delete": "When Note Deleted",
        "settings.delete_trash": "trash",
        "settings.delete_remove": "remove",
        "settings.delete_keep": "keep",
        "settings.exclude_tags": "Exclude Tags",
        "settings.exclude_placeholder": "e.g. private, draft, work/internal",
        "settings.exclude_example": (
            "Example: private, draft, work/internal\n"
            "Notes with these tags will not be exported."
        ),
        "settings.cancel": "Cancel",
        "settings.apply": "Apply",
        "settings.applied_title": "Settings applied",
        "settings.applied_msg": "Exporting to: {path}",
        "settings.applied_msg_both": (
            "Exporting to:\nMarkdown: {path_md}\nTextBundle: {path_tb}"
        ),
        "settings.folder_changed": "Export folder changed",
        "settings.folder_changed_msg": "Now exporting to: {path}",
        "settings.folder_not_found": "Folder not found",
        "settings.folder_not_found_msg": (
            "Export folder does not exist yet:\n{path}\n\n"
            "It will be created on the first export."
        ),
        "settings.folder_tb_missing": (
            "Please choose a TextBundle export folder when exporting both "
            "formats."
        ),
        "settings.folder_md_missing": (
            "Please choose a Markdown export folder."
        ),
        "settings.folder_tb_conflict": (
            "Markdown and TextBundle folders must be different."
        ),
        "settings.format_none": "Please select at least one export format.",

        # ── Help / tooltip text ───────────────────────────────────────
        "help.format": (
            "Markdown (.md): Plain Markdown files with a shared "
            "images folder. Best for Obsidian.\n\n"
            "TextBundle (.textbundle): Each note is a bundle with "
            "embedded images. Best for Ulysses.\n\n"
            "Both: Export to separate Markdown and TextBundle folders."
        ),
        "help.yaml": (
            "Add YAML front matter (title, tags, dates) at the top "
            "of each exported note.\n\n"
            "Useful for static site generators (Hugo, Jekyll) and "
            "Obsidian metadata queries."
        ),
        "help.tag_folders": (
            "Create subfolders based on Bear tags.\n\n"
            "For example, a note tagged #work/meetings will be "
            "placed in work/meetings/ folder.\n"
            "Notes with multiple tags are copied to each tag folder."
        ),
        "help.hide_tags": (
            "Remove #tag lines from the exported Markdown content.\n\n"
            "Tags are still preserved in YAML front matter if enabled."
        ),
        "help.naming": (
            "How exported files are named:\n\n"
            "\u2022 title \u2014 My Note Title.md\n"
            "\u2022 slug \u2014 my-note-title.md\n"
            "\u2022 date-title \u2014 2024-01-15-my-note-title.md\n"
            "\u2022 id \u2014 12345678.md (Bear UUID prefix)"
        ),
        "help.on_delete": (
            "What happens to exported files when the original Bear "
            "note is trashed:\n\n"
            "\u2022 trash \u2014 Move to .b2ou-trash/ (recoverable)\n"
            "\u2022 remove \u2014 Delete permanently\n"
            "\u2022 keep \u2014 Never remove stale files"
        ),
        "help.exclude_tags": (
            "Comma-separated list of Bear tags to exclude from export.\n\n"
            "Example: private, draft, work/internal\n\n"
            "Notes with any of these tags will be skipped entirely.\n"
            "Nested tags use / as separator (e.g. work/internal)."
        ),
        "help.auto_start": (
            "Automatically launch B2OU when you log in to your Mac.\n\n"
            "Creates a LaunchAgent that starts the menu-bar app "
            "at login."
        ),
        "help.export_folder_md": (
            "The folder where Markdown files will be exported.\n\n"
            "Choose any folder \u2014 a common choice is a folder "
            "inside your Obsidian vault or iCloud Drive."
        ),
        "help.export_folder_tb": (
            "TextBundle output folder used when exporting both formats.\n\n"
            "It must be different from the Markdown folder."
        ),
    },

    "zh": {
        # ── Menu items ────────────────────────────────────────────────
        "menu.starting": "\u542f\u52a8\u4e2d...",
        "menu.export_now": "\u7acb\u5373\u5bfc\u51fa",
        "menu.pause": "\u6682\u505c",
        "menu.resume": "\u7ee7\u7eed",
        "menu.open_folder": "\u6253\u5f00\u5bfc\u51fa\u6587\u4ef6\u5939",
        "menu.profile": "\u914d\u7f6e\u6587\u4ef6",
        "menu.start_at_login": "\u5f00\u673a\u542f\u52a8",
        "menu.change_folder": "\u66f4\u6539\u5bfc\u51fa\u6587\u4ef6\u5939...",
        "menu.configure": "\u914d\u7f6e\u5f53\u524d\u65b9\u6848...",
        "menu.edit_config": "\u7f16\u8f91\u914d\u7f6e\u6587\u4ef6...",
        "menu.quit": "\u9000\u51fa",
        "menu.language": "\u8bed\u8a00",
        "menu.setup": "\u8bbe\u7f6e...",
        "menu.reload": "\u91cd\u65b0\u52a0\u8f7d",
        "menu.no_profile": "\u672a\u52a0\u8f7d\u914d\u7f6e",
        "menu.notes_exported": "\u5df2\u5bfc\u51fa {count:,} \u7bc7\u7b14\u8bb0",
        "menu.exporting_to": "\u5bfc\u51fa\u5230 {folder}",
        "menu.last_export": "\u4e0a\u6b21\u5bfc\u51fa: {time}",
        "menu.just_now": "\u521a\u521a",
        "menu.min_ago": "{mins} \u5206\u949f\u524d",

        # ── Language names ────────────────────────────────────────────
        "lang.en": "English",
        "lang.zh": "\u4e2d\u6587",
        "lang.auto": "\u81ea\u52a8 (\u7cfb\u7edf\u8bed\u8a00)",

        # ── Wizard ────────────────────────────────────────────────────
        "wizard.welcome_title": "\u6b22\u8fce\u4f7f\u7528 B2OU",
        "wizard.welcome_msg": (
            "B2OU \u53ef\u4ee5\u81ea\u52a8\u5c06 Bear \u7b14\u8bb0\u5907\u4efd"
            "\u4e3a Markdown \u6587\u4ef6\u3002\n\n"
            "\u8bf7\u9009\u62e9\u8bbe\u7f6e\u65b9\u5f0f:"
        ),
        "wizard.quick": "\u5feb\u901f\u8bbe\u7f6e (\u63a8\u8350)",
        "wizard.advanced": "\u9ad8\u7ea7\u8bbe\u7f6e",
        "wizard.quick_title": "\u5feb\u901f\u8bbe\u7f6e",
        "wizard.quick_msg": (
            "\u53ea\u9700\u9009\u62e9\u4e00\u4e2a\u6587\u4ef6\u5939\u5373\u53ef\u5b8c\u6210\u3002\n\n"
            "B2OU \u4f1a\u5c06\u6240\u6709 Bear \u7b14\u8bb0\u5bfc\u51fa\u4e3a "
            "Markdown \u6587\u4ef6\uff0c\u5e76\u81ea\u52a8\u4fdd\u6301\u540c\u6b65\u3002"
        ),
        "wizard.choose_folder": "\u9009\u62e9\u6587\u4ef6\u5939",
        "wizard.cancelled_title": "\u8bbe\u7f6e\u5df2\u53d6\u6d88",
        "wizard.cancelled_msg": "\u60a8\u53ef\u4ee5\u7a0d\u540e\u901a\u8fc7\u83dc\u5355\u680f\u8fdb\u884c\u8bbe\u7f6e\u3002",
        "wizard.ready": "\u5c31\u7eea",
        "wizard.ready_msg": "\u7b14\u8bb0\u6b63\u5728\u5bfc\u51fa\u5230:\n{path}",
        "wizard.pick_prompt": "\u9009\u62e9\u4fdd\u5b58 Bear \u7b14\u8bb0\u7684\u4f4d\u7f6e:",
        "wizard.pick_advanced": "\u9009\u62e9\u5bfc\u51fa\u76ee\u6807\u6587\u4ef6\u5939:",

        # ── Settings panel ────────────────────────────────────────────
        "settings.title": "B2OU \u8bbe\u7f6e",
        "settings.export_folder": "\u5bfc\u51fa\u6587\u4ef6\u5939",
        "settings.export_folder_md": "Markdown \u5bfc\u51fa\u6587\u4ef6\u5939",
        "settings.change": "\u66f4\u6539...",
        "settings.format": "\u5bfc\u51fa\u683c\u5f0f",
        "settings.format_md": "Markdown (.md)",
        "settings.format_tb": "TextBundle (.textbundle)",
        "settings.format_both": "\u540c\u65f6\u5bfc\u51fa\uff08Markdown + TextBundle\uff09",
        "settings.export_folder_tb": "TextBundle \u5bfc\u51fa\u6587\u4ef6\u5939",
        "settings.folder_not_same": (
            "\u540c\u65f6\u5bfc\u51fa\u65f6\uff0cTextBundle \u6587\u4ef6\u5939"
            "\u5fc5\u987b\u4e0e Markdown \u6587\u4ef6\u5939\u4e0d\u540c\u3002"
        ),
        "settings.yaml": "YAML \u5143\u6570\u636e",
        "settings.tag_folders": "\u6309\u6807\u7b7e\u5206\u6587\u4ef6\u5939",
        "settings.hide_tags": "\u9690\u85cf\u7b14\u8bb0\u4e2d\u7684\u6807\u7b7e",
        "settings.auto_start": "\u5f00\u673a\u542f\u52a8",
        "settings.naming": "\u6587\u4ef6\u547d\u540d",
        "settings.naming_title": "\u6807\u9898",
        "settings.naming_slug": "\u77ed\u6807\u8bc6",
        "settings.naming_date": "\u65e5\u671f-\u6807\u9898",
        "settings.naming_id": "ID",
        "settings.on_delete": "\u7b14\u8bb0\u5220\u9664\u65f6",
        "settings.delete_trash": "\u79fb\u5230\u56de\u6536\u7ad9",
        "settings.delete_remove": "\u6c38\u4e45\u5220\u9664",
        "settings.delete_keep": "\u4fdd\u7559\u6587\u4ef6",
        "settings.exclude_tags": "\u6392\u9664\u6807\u7b7e",
        "settings.exclude_placeholder": "\u4f8b\u5982: private, draft, work/internal",
        "settings.exclude_example": (
            "\u793a\u4f8b: private, draft, work/internal\n"
            "\u5305\u542b\u8fd9\u4e9b\u6807\u7b7e\u7684\u7b14\u8bb0\u5c06\u4e0d\u4f1a\u88ab\u5bfc\u51fa\u3002"
        ),
        "settings.cancel": "\u53d6\u6d88",
        "settings.apply": "\u5e94\u7528",
        "settings.applied_title": "\u8bbe\u7f6e\u5df2\u5e94\u7528",
        "settings.applied_msg": "\u5bfc\u51fa\u5230: {path}",
        "settings.applied_msg_both": (
            "\u5bfc\u51fa\u5230:\nMarkdown: {path_md}\nTextBundle: {path_tb}"
        ),
        "settings.folder_changed": "\u5bfc\u51fa\u6587\u4ef6\u5939\u5df2\u66f4\u6539",
        "settings.folder_changed_msg": "\u73b0\u5728\u5bfc\u51fa\u5230: {path}",
        "settings.folder_not_found": "\u6587\u4ef6\u5939\u672a\u627e\u5230",
        "settings.folder_not_found_msg": (
            "\u5bfc\u51fa\u6587\u4ef6\u5939\u5c1a\u4e0d\u5b58\u5728:\n{path}\n\n"
            "\u5c06\u5728\u9996\u6b21\u5bfc\u51fa\u65f6\u81ea\u52a8\u521b\u5efa\u3002"
        ),
        "settings.folder_tb_missing": (
            "\u8bf7\u4e3a\u201c\u540c\u65f6\u5bfc\u51fa\u201d\u9009\u62e9\u4e00\u4e2a TextBundle \u5bfc\u51fa\u6587\u4ef6\u5939\u3002"
        ),
        "settings.folder_md_missing": (
            "\u8bf7\u9009\u62e9 Markdown \u5bfc\u51fa\u6587\u4ef6\u5939\u3002"
        ),
        "settings.folder_tb_conflict": (
            "Markdown \u548c TextBundle \u7684\u5bfc\u51fa\u6587\u4ef6\u5939\u5fc5\u987b\u4e0d\u540c\u3002"
        ),
        "settings.format_none": "\u8bf7\u81f3\u5c11\u9009\u62e9\u4e00\u79cd\u5bfc\u51fa\u683c\u5f0f\u3002",

        # ── Help / tooltip text ───────────────────────────────────────
        "help.format": (
            "Markdown (.md): \u7eaf Markdown \u6587\u4ef6\uff0c\u56fe\u7247\u5b58\u653e\u5728"
            "\u5171\u4eab\u6587\u4ef6\u5939\u4e2d\u3002\u9002\u5408 Obsidian\u3002\n\n"
            "TextBundle (.textbundle): \u6bcf\u7bc7\u7b14\u8bb0\u5305\u542b\u5185\u5d4c"
            "\u56fe\u7247\u3002\u9002\u5408 Ulysses\u3002\n\n"
            "\u540c\u65f6\u5bfc\u51fa: \u9700\u5206\u522b\u4f7f\u7528 Markdown \u548c TextBundle \u7684\u4e24\u4e2a\u6587\u4ef6\u5939\u3002"
        ),
        "help.yaml": (
            "\u5728\u6bcf\u7bc7\u5bfc\u51fa\u7b14\u8bb0\u9876\u90e8\u6dfb\u52a0 YAML \u5143\u6570\u636e"
            "\uff08\u6807\u9898\u3001\u6807\u7b7e\u3001\u65e5\u671f\uff09\u3002\n\n"
            "\u9002\u7528\u4e8e\u9759\u6001\u7f51\u7ad9\u751f\u6210\u5668 (Hugo, Jekyll) "
            "\u548c Obsidian \u5143\u6570\u636e\u67e5\u8be2\u3002"
        ),
        "help.tag_folders": (
            "\u6839\u636e Bear \u6807\u7b7e\u521b\u5efa\u5b50\u6587\u4ef6\u5939\u3002\n\n"
            "\u4f8b\u5982\uff0c\u6807\u8bb0\u4e3a #work/meetings \u7684\u7b14\u8bb0\u4f1a"
            "\u653e\u5728 work/meetings/ \u6587\u4ef6\u5939\u4e2d\u3002\n"
            "\u6709\u591a\u4e2a\u6807\u7b7e\u7684\u7b14\u8bb0\u4f1a\u590d\u5236\u5230"
            "\u6bcf\u4e2a\u6807\u7b7e\u6587\u4ef6\u5939\u3002"
        ),
        "help.hide_tags": (
            "\u4ece\u5bfc\u51fa\u7684 Markdown \u5185\u5bb9\u4e2d\u79fb\u9664 #\u6807\u7b7e\u3002\n\n"
            "\u5982\u679c\u542f\u7528\u4e86 YAML \u5143\u6570\u636e\uff0c\u6807\u7b7e\u4ecd\u4f1a"
            "\u4fdd\u7559\u5728\u5143\u6570\u636e\u4e2d\u3002"
        ),
        "help.naming": (
            "\u5bfc\u51fa\u6587\u4ef6\u7684\u547d\u540d\u65b9\u5f0f:\n\n"
            "\u2022 \u6807\u9898 \u2014 \u6211\u7684\u7b14\u8bb0.md\n"
            "\u2022 \u77ed\u6807\u8bc6 \u2014 my-note-title.md\n"
            "\u2022 \u65e5\u671f-\u6807\u9898 \u2014 2024-01-15-my-note-title.md\n"
            "\u2022 ID \u2014 12345678.md (Bear UUID \u524d\u7f00)"
        ),
        "help.on_delete": (
            "\u5f53 Bear \u4e2d\u7684\u7b14\u8bb0\u88ab\u5220\u9664\u65f6\uff0c"
            "\u5bfc\u51fa\u6587\u4ef6\u7684\u5904\u7406\u65b9\u5f0f:\n\n"
            "\u2022 \u56de\u6536\u7ad9 \u2014 \u79fb\u5230 .b2ou-trash/\uff08\u53ef\u6062\u590d\uff09\n"
            "\u2022 \u6c38\u4e45\u5220\u9664 \u2014 \u5f7b\u5e95\u5220\u9664\n"
            "\u2022 \u4fdd\u7559 \u2014 \u4e0d\u5220\u9664\u65e7\u6587\u4ef6"
        ),
        "help.exclude_tags": (
            "\u7528\u9017\u53f7\u5206\u9694\u7684 Bear \u6807\u7b7e\u5217\u8868"
            "\uff0c\u8fd9\u4e9b\u6807\u7b7e\u7684\u7b14\u8bb0\u4e0d\u4f1a\u88ab\u5bfc\u51fa\u3002\n\n"
            "\u793a\u4f8b: private, draft, work/internal\n\n"
            "\u5305\u542b\u4efb\u4f55\u8fd9\u4e9b\u6807\u7b7e\u7684\u7b14\u8bb0\u5c06\u88ab\u8df3\u8fc7\u3002\n"
            "\u5d4c\u5957\u6807\u7b7e\u4f7f\u7528 / \u5206\u9694\uff08\u4f8b\u5982 work/internal\uff09\u3002"
        ),
        "help.auto_start": (
            "\u767b\u5f55 Mac \u65f6\u81ea\u52a8\u542f\u52a8 B2OU\u3002\n\n"
            "\u4f1a\u521b\u5efa\u4e00\u4e2a LaunchAgent\uff0c"
            "\u5728\u767b\u5f55\u65f6\u542f\u52a8\u83dc\u5355\u680f\u5e94\u7528\u3002"
        ),
        "help.export_folder_md": (
            "\u5bfc\u51fa Markdown \u7b14\u8bb0\u7684\u76ee\u6807\u6587\u4ef6\u5939\u3002\n\n"
            "\u53ef\u4ee5\u9009\u62e9\u4efb\u610f\u6587\u4ef6\u5939\uff0c"
            "\u5e38\u89c1\u9009\u62e9\u662f Obsidian \u4fdd\u5e93\u6216 iCloud Drive "
            "\u4e2d\u7684\u6587\u4ef6\u5939\u3002"
        ),
        "help.export_folder_tb": (
            "\u5f53\u9009\u62e9\u201c\u540c\u65f6\u5bfc\u51fa\u201d\u65f6\uff0c"
            "TextBundle \u7684\u5bfc\u51fa\u76ee\u5f55\u3002\n\n"
            "\u5fc5\u987b\u4e0e Markdown \u5bfc\u51fa\u6587\u4ef6\u5939\u4e0d\u540c\u3002"
        ),
    },
}
