"""
macOS menu-bar application for B2OU.

Provides a native menu-bar icon that watches Bear's database and
auto-exports notes.  Requires the ``rumps`` package.

Launch via ``python -m b2ou.menubar`` or the bundled ``.app``.
"""

from __future__ import annotations

import datetime
import logging
import os
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

try:
    import rumps
except ImportError:
    raise SystemExit(
        "The menu-bar app requires 'rumps'.\n\n"
        "If you're trying to run the app directly, build the standalone\n"
        ".app bundle instead (it bundles everything automatically):\n"
        "  ./build_app.sh\n\n"
        "For development, install dependencies first:\n"
        "  pip install rumps\n"
    )

from b2ou.autostart import is_login_item, add_login_item, remove_login_item
from b2ou.config import ExportConfig
from b2ou.i18n import get_language, init_language, set_language, t
from b2ou.profile import find_config, load_profiles

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Menu-bar icon resolution
# ---------------------------------------------------------------------------
# Prefer image-based icons (bear-shield PNGs) bundled in resources/.
# Fall back to emoji characters when images aren't available (dev mode).

_EMOJI_IDLE = "\U0001F43B"        # 🐻 Bear — notes are safe
_EMOJI_PAUSED = "\u275A\u275A"    # ❚❚ Pause bars — export paused
_EMOJI_ERROR = "\u26A0\uFE0E"    # ⚠︎ Warning — needs attention


def _find_icon_dir() -> Optional[Path]:
    """Locate the icons directory in resources/ or the PyInstaller bundle."""
    # PyInstaller frozen bundle
    if getattr(sys, "frozen", False):
        base = Path(sys._MEIPASS)
    else:
        base = Path(__file__).resolve().parent.parent
    icons = base / "resources" / "icons"
    if icons.is_dir():
        return icons
    return None


def _resolve_icon(name: str) -> Optional[str]:
    """Return the absolute path to *name*.png in the icon dir, or None."""
    icon_dir = _find_icon_dir()
    if icon_dir is None:
        return None
    path = icon_dir / f"{name}.png"
    if path.exists():
        return str(path)
    return None


POLL_INTERVAL = 2.0
DEBOUNCE = 3.0
MIN_EXPORT_INTERVAL = 10.0
NOTIFICATION_SOUND = True


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_all_profiles() -> dict[str, ExportConfig]:
    """Load all profiles from b2ou.toml."""
    try:
        return load_profiles()
    except Exception:
        return {}


def _pick_folder(prompt: str = "Choose where to save your Bear notes:") -> Optional[str]:
    """Open a native macOS folder-picker dialog. Returns path or None."""
    escaped = prompt.replace('"', '\\"')
    script = (
        f'set theFolder to POSIX path of '
        f'(choose folder with prompt "{escaped}")'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip().rstrip("/")
    except Exception:
        pass
    return None


def _toml_escape(value: str) -> str:
    """Escape a string value for safe inclusion in a TOML basic string."""
    return value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def _write_config(export_path: str, export_format: str = "md",
                  export_path_tb: Optional[str] = None,
                  yaml_front_matter: bool = False,
                  hide_tags: bool = False,
                  tag_folders: bool = False,
                  on_delete: str = "trash",
                  naming: str = "title",
                  exclude_tags: Optional[list[str]] = None) -> Path:
    """Write a b2ou.toml config file. Returns the config file path."""
    config_dir = Path.home() / ".config" / "b2ou"
    config_dir.mkdir(parents=True, exist_ok=True)
    config_file = config_dir / "b2ou.toml"

    lines = [
        "# B2OU \u2014 Bear note export configuration",
        "# Edit this file to customize your export settings.",
        "# After editing, use Profile > Reload in the menu bar.",
        "",
        "[profile.default]",
        f'out = "{_toml_escape(export_path)}"',
        f'format = "{_toml_escape(export_format)}"',
        f'on-delete = "{_toml_escape(on_delete)}"',
        f'naming = "{_toml_escape(naming)}"',
    ]
    if export_format == "both" and export_path_tb:
        lines.append(f'out-tb = "{_toml_escape(export_path_tb)}"')

    if yaml_front_matter:
        lines.append("yaml-front-matter = true")
    if hide_tags:
        lines.append("hide-tags = true")
    if tag_folders:
        lines.append("tag-folders = true")
    if exclude_tags:
        tags_str = ", ".join(f'"{_toml_escape(tag)}"' for tag in exclude_tags)
        lines.append(f"exclude-tags = [{tags_str}]")

    lines.append("")
    toml_content = "\n".join(lines)

    config_file.write_text(toml_content)

    return config_file


# ---------------------------------------------------------------------------
# Export runner (background thread)
# ---------------------------------------------------------------------------

class ExportWatcher:
    """Watches Bear's database and triggers exports in a background thread."""

    def __init__(self, cfg: ExportConfig, on_update=None):
        self.cfg = cfg
        self.on_update = on_update
        self._running = False
        self._paused = False
        self._thread: Optional[threading.Thread] = None
        self._last_signature = (0.0, -1)
        self._last_export_unix = 0.0
        self._last_export_time: Optional[datetime.datetime] = None
        self._note_count = 0
        self._consecutive_failures = 0

    def start(self):
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False

    @property
    def paused(self) -> bool:
        return self._paused

    @paused.setter
    def paused(self, value: bool):
        self._paused = value

    @property
    def last_export_time(self) -> Optional[datetime.datetime]:
        return self._last_export_time

    @property
    def note_count(self) -> int:
        return self._note_count

    def export_now(self):
        threading.Thread(target=self._do_export, daemon=True).start()

    def _loop(self):
        from b2ou.db import bear_db_signature, db_is_quiet

        idle_sleep = POLL_INTERVAL
        idle_max = 30.0

        while self._running:
            if not self._paused:
                sig = bear_db_signature(self.cfg.bear_db)
                if sig == self._last_signature or sig[1] < 0:
                    time.sleep(idle_sleep)
                    idle_sleep = min(idle_max, idle_sleep * 1.5)
                    continue
                idle_sleep = POLL_INTERVAL

                interval = MIN_EXPORT_INTERVAL * (
                    2 ** min(self._consecutive_failures, 4)
                )
                elapsed = time.time() - self._last_export_unix
                if self._last_export_unix > 0 and elapsed < interval:
                    time.sleep(min(POLL_INTERVAL, interval - elapsed))
                    continue

                if self._last_signature[1] >= 0:
                    waited = 0.0
                    while self._running and waited < DEBOUNCE * 3:
                        if db_is_quiet(self.cfg.bear_db, DEBOUNCE):
                            break
                        time.sleep(1.0)
                        waited += 1.0

                self._do_export()
                self._last_signature = bear_db_signature(self.cfg.bear_db)
                self._last_export_unix = time.time()
            else:
                time.sleep(POLL_INTERVAL)

            time.sleep(POLL_INTERVAL)

    def _do_export(self):
        from b2ou.export import (
            _write_manifest,
            cleanup_orphan_root_images,
            cleanup_stale_notes,
            export_notes,
            maintenance_due,
            purge_old_trash,
            touch_maintenance,
            write_timestamps,
        )

        error_msg = None
        try:
            configs = self.cfg.split_export_configs()
            total_count = 0
            for cfg in configs:
                cfg.export_path.mkdir(parents=True, exist_ok=True)
                count, expected, changed = export_notes(cfg)
                if changed < 0:
                    log.info("Export already running for %s — skipping.",
                             cfg.export_path)
                    continue
                write_timestamps(cfg)
                if changed > 0:
                    cleanup_stale_notes(
                        cfg.export_path, expected, cfg.on_delete
                    )
                    if maintenance_due(cfg.export_path):
                        if cfg.export_image_repository:
                            cleanup_orphan_root_images(cfg)
                        purge_old_trash(cfg.export_path)
                        touch_maintenance(cfg.export_path)
                if expected:
                    _write_manifest(cfg.export_path, expected)
                total_count = max(total_count, count)
            self._note_count = total_count
            self._last_export_time = datetime.datetime.now()
            self._consecutive_failures = 0
        except Exception as exc:
            self._consecutive_failures += 1
            error_msg = str(exc)
            log.error("Export failed (%d consecutive): %s",
                      self._consecutive_failures, exc)

        if self.on_update:
            try:
                self.on_update(self._note_count, error_msg)
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Menu-bar app
# ---------------------------------------------------------------------------

APP_NAME = "B2OU"


class B2OUApp(rumps.App):
    """macOS menu-bar app for Bear note export."""

    def __init__(self):
        # Resolve icon paths — use image if available, emoji fallback
        idle_icon = _resolve_icon("menubar")
        if idle_icon:
            super().__init__(
                APP_NAME,
                icon=idle_icon,
                template=True,   # macOS auto-adapts for dark/light mode
                quit_button=None,
            )
        else:
            super().__init__(
                APP_NAME,
                title=_EMOJI_IDLE,
                quit_button=None,
            )

        self._icon_idle = idle_icon
        self._icon_paused = _resolve_icon("menubar_paused")
        self._has_image_icons = idle_icon is not None

        # ── State ────────────────────────────────────────────────────────
        self.cfg: Optional[ExportConfig] = None
        self.watcher: Optional[ExportWatcher] = None
        self._profiles: dict[str, ExportConfig] = {}

        # ── Build the full menu (uses current language) ──────────────────
        self._build_menu()
        self._did_initial_load = False

    # ── Menu construction ─────────────────────────────────────────────────

    def _build_menu(self):
        """(Re)build all menu items using the current language strings."""
        self.status_item = rumps.MenuItem(t("menu.starting"), callback=None)
        self.status_item.set_callback(None)

        self.last_export_item = rumps.MenuItem("", callback=None)
        self.last_export_item.set_callback(None)

        self.export_now_btn = rumps.MenuItem(
            t("menu.export_now"), callback=self.on_export_now
        )
        self.pause_btn = rumps.MenuItem(
            t("menu.pause"), callback=self.on_toggle_pause
        )

        self.open_folder_btn = rumps.MenuItem(
            t("menu.open_folder"), callback=self.on_open_folder
        )

        self.profile_menu = rumps.MenuItem(t("menu.profile"))

        self.login_item = rumps.MenuItem(
            t("menu.start_at_login"), callback=self.on_toggle_login
        )
        self.login_item.state = is_login_item()

        self.change_folder_btn = rumps.MenuItem(
            t("menu.change_folder"), callback=self.on_change_folder
        )

        self.configure_btn = rumps.MenuItem(
            t("menu.configure"), callback=self.on_configure_profile
        )

        self.edit_config_btn = rumps.MenuItem(
            t("menu.edit_config"), callback=self.on_edit_config
        )

        # ── Language submenu ──────────────────────────────────────────
        self.language_menu = rumps.MenuItem(t("menu.language"))

        self._lang_en = rumps.MenuItem(
            t("lang.en"), callback=self.on_set_english
        )
        self._lang_zh = rumps.MenuItem(
            t("lang.zh"), callback=self.on_set_chinese
        )
        # Mark the active language
        cur = get_language()
        self._lang_en.state = (cur == "en")
        self._lang_zh.state = (cur == "zh")

        self.language_menu.add(self._lang_en)
        self.language_menu.add(self._lang_zh)

        self.quit_btn = rumps.MenuItem(t("menu.quit"), callback=self.on_quit)

        # ── Assemble menu ─────────────────────────────────────────────
        self.menu = [
            self.status_item,
            self.last_export_item,
            None,
            self.export_now_btn,
            self.pause_btn,
            self.open_folder_btn,
            None,
            self.profile_menu,
            self.login_item,
            self.change_folder_btn,
            self.configure_btn,
            self.edit_config_btn,
            None,
            self.language_menu,
            None,
            self.quit_btn,
        ]

    def _refresh_menu_titles(self):
        """Update all menu item titles after a language change."""
        self.status_item.title = t("menu.starting")
        self.export_now_btn.title = t("menu.export_now")
        self.open_folder_btn.title = t("menu.open_folder")
        self.profile_menu.title = t("menu.profile")
        self.login_item.title = t("menu.start_at_login")
        self.change_folder_btn.title = t("menu.change_folder")
        self.configure_btn.title = t("menu.configure")
        self.edit_config_btn.title = t("menu.edit_config")
        self.language_menu.title = t("menu.language")
        self._lang_en.title = t("lang.en")
        self._lang_zh.title = t("lang.zh")
        self.quit_btn.title = t("menu.quit")

        # Update pause button based on watcher state
        if self.watcher and self.watcher.paused:
            self.pause_btn.title = t("menu.resume")
        else:
            self.pause_btn.title = t("menu.pause")

        # Refresh status and profile labels
        self._update_status()
        self._reload_profiles()

    # ── Language switching ─────────────────────────────────────────────────

    def on_set_english(self, _):
        set_language("en")
        self._lang_en.state = True
        self._lang_zh.state = False
        self._refresh_menu_titles()

    def on_set_chinese(self, _):
        set_language("zh")
        self._lang_en.state = False
        self._lang_zh.state = True
        self._refresh_menu_titles()

    # ── Setup wizards ─────────────────────────────────────────────────────

    def _run_setup_wizard(self):
        """Entry point: ask beginner or advanced, then branch."""
        response = rumps.alert(
            title=t("wizard.welcome_title"),
            message=t("wizard.welcome_msg"),
            ok=t("wizard.quick"),
            cancel=t("wizard.advanced"),
        )

        if response == 1:
            self._wizard_beginner()
        else:
            self._wizard_advanced()

    def _wizard_beginner(self):
        """Beginner wizard: just pick a folder, everything else is automatic."""

        rumps.alert(
            title=t("wizard.quick_title"),
            message=t("wizard.quick_msg"),
            ok=t("wizard.choose_folder"),
        )

        export_path = _pick_folder(t("wizard.pick_prompt"))
        if not export_path:
            rumps.alert(t("wizard.cancelled_title"),
                        t("wizard.cancelled_msg"))
            return

        # Beginner defaults: md, no YAML, all notes, auto-start
        _write_config(export_path)
        add_login_item()
        self.login_item.state = True

        self._reload_profiles()
        if self.cfg:
            self._start_watcher()

        rumps.notification(
            APP_NAME, t("wizard.ready"),
            t("wizard.ready_msg").format(path=export_path),
            sound=NOTIFICATION_SOUND,
        )

    def _wizard_advanced(self, export_path: Optional[str] = None):
        """Advanced wizard: opens the native settings panel."""

        # Pick folder first if not provided
        if not export_path:
            export_path = _pick_folder(t("wizard.pick_advanced"))
            if not export_path:
                rumps.alert(t("wizard.cancelled_title"),
                            t("wizard.cancelled_msg"))
                return

        self._show_settings_panel(export_path)

    def _show_settings_panel(
        self,
        export_path: str,
        *,
        export_path_tb: str = "",
        export_format: str = "md",
        yaml_front_matter: bool = False,
        hide_tags: bool = False,
        tag_folders: bool = False,
        on_delete: str = "trash",
        naming: str = "title",
        exclude_tags: str = "",
        auto_start: bool = True,
    ):
        """Show the native Cocoa settings panel."""
        from b2ou.settings_panel import SettingsValues, show_settings_panel

        values = SettingsValues(
            export_path=export_path,
            export_path_tb=export_path_tb,
            export_format=export_format,
            yaml_front_matter=yaml_front_matter,
            tag_folders=tag_folders,
            hide_tags=hide_tags,
            auto_start=auto_start,
            naming=naming,
            on_delete=on_delete,
            exclude_tags=exclude_tags,
        )

        def _on_apply(v: SettingsValues) -> None:
            if v.export_format == "none":
                rumps.alert(
                    t("settings.folder_not_found"),
                    t("settings.format_none"),
                )
                return

            # Resolve target folders based on chosen formats
            export_path_out = v.export_path
            export_path_tb = v.export_path_tb

            if v.export_format == "tb":
                if not export_path_tb:
                    rumps.alert(
                        t("settings.folder_not_found"),
                        t("settings.folder_tb_missing"),
                    )
                    return
                export_path_out = export_path_tb
                export_path_tb = ""

            if v.export_format == "md" and not export_path_out:
                rumps.alert(
                    t("settings.folder_not_found"),
                    t("settings.folder_md_missing"),
                )
                return

            if v.export_format == "both":
                if not export_path_tb:
                    rumps.alert(
                        t("settings.folder_not_found"),
                        t("settings.folder_tb_missing"),
                    )
                    return
                try:
                    if Path(export_path_out).resolve() == Path(export_path_tb).resolve():
                        rumps.alert(
                            t("settings.folder_not_found"),
                            t("settings.folder_tb_conflict"),
                        )
                        return
                except Exception:
                    pass

            excl_list = [
                tag.strip() for tag in v.exclude_tags.split(",")
                if tag.strip()
            ] or None

            _write_config(
                export_path_out,
                export_path_tb=export_path_tb,
                export_format=v.export_format,
                yaml_front_matter=v.yaml_front_matter,
                hide_tags=v.hide_tags,
                tag_folders=v.tag_folders,
                on_delete=v.on_delete,
                naming=v.naming,
                exclude_tags=excl_list,
            )

            if v.auto_start:
                add_login_item()
                self.login_item.state = True
            else:
                remove_login_item()
                self.login_item.state = False

            self._reload_profiles()
            if self.cfg:
                if self.watcher:
                    self.watcher.stop()
                self._start_watcher()

            if v.export_format == "both":
                msg = t("settings.applied_msg_both").format(
                    path_md=export_path_out, path_tb=export_path_tb
                )
            else:
                msg = t("settings.applied_msg").format(path=export_path_out)
            rumps.notification(
                APP_NAME, t("settings.applied_title"),
                msg,
                sound=NOTIFICATION_SOUND,
            )

        def _on_change_folder() -> Optional[str]:
            return _pick_folder(t("wizard.pick_advanced"))

        show_settings_panel(values, _on_apply, _on_change_folder)

    # ── Profile management ───────────────────────────────────────────────

    def _reload_profiles(self):
        """Reload profiles from b2ou.toml and rebuild the profile submenu."""
        self._profiles = _load_all_profiles()

        try:
            self.profile_menu.clear()
        except AttributeError:
            pass

        if not self._profiles:
            setup_item = rumps.MenuItem(
                t("menu.setup"), callback=lambda _: self._run_setup_wizard()
            )
            self.profile_menu.add(setup_item)
            return

        for name in self._profiles:
            item = rumps.MenuItem(name, callback=self.on_select_profile)
            self.profile_menu.add(item)

        self.profile_menu.add(None)
        self.profile_menu.add(
            rumps.MenuItem(t("menu.reload"), callback=self.on_reload_profiles)
        )

        if self.cfg is None and self._profiles:
            first_name = next(iter(self._profiles))
            self._set_profile(first_name)

    def _set_profile(self, name: str):
        """Switch to the named profile."""
        if name not in self._profiles:
            return
        self.cfg = self._profiles[name]

        for item_name in self.profile_menu:
            item = self.profile_menu[item_name]
            if isinstance(item, rumps.MenuItem):
                item.state = (item_name == name)

        self._update_status()

        if self.watcher:
            self.watcher.stop()
        self._start_watcher()

    def on_select_profile(self, sender):
        self._set_profile(sender.title)

    def on_reload_profiles(self, _):
        self._reload_profiles()

    # ── Icon helpers ─────────────────────────────────────────────────────

    def _set_icon_state(self, state: str):
        """Set the menu-bar icon to 'idle', 'paused', or 'error'."""
        if self._has_image_icons:
            if state == "paused" and self._icon_paused:
                self.icon = self._icon_paused
            elif state == "idle" and self._icon_idle:
                self.icon = self._icon_idle
            else:
                # Error: keep current icon, rumps doesn't tint
                self.title = _EMOJI_ERROR if state == "error" else ""
        else:
            if state == "idle":
                self.title = _EMOJI_IDLE
            elif state == "paused":
                self.title = _EMOJI_PAUSED
            else:
                self.title = _EMOJI_ERROR

    # ── Watcher control ──────────────────────────────────────────────────

    def _start_watcher(self):
        if not self.cfg:
            return
        self.watcher = ExportWatcher(self.cfg, on_update=self._on_export_done)
        self.watcher.start()
        self._set_icon_state("idle")

    def _on_export_done(self, note_count: int, error_msg: Optional[str]):
        if error_msg:
            self._set_icon_state("error")
        else:
            self._set_icon_state("idle")
            self._update_status()

    def _update_status(self):
        if not self.cfg:
            self.status_item.title = t("menu.no_profile")
            self.last_export_item.title = ""
            return

        if self.watcher and self.watcher.note_count > 0:
            self.status_item.title = t("menu.notes_exported").format(
                count=self.watcher.note_count
            )
        else:
            folder = self.cfg.export_path.name
            self.status_item.title = t("menu.exporting_to").format(folder=folder)

        if self.watcher and self.watcher.last_export_time:
            ago = datetime.datetime.now() - self.watcher.last_export_time
            if ago.total_seconds() < 60:
                time_str = t("menu.just_now")
            elif ago.total_seconds() < 3600:
                time_str = t("menu.min_ago").format(
                    mins=int(ago.total_seconds() / 60)
                )
            else:
                time_str = self.watcher.last_export_time.strftime("%H:%M")
            self.last_export_item.title = t("menu.last_export").format(
                time=time_str
            )
        else:
            self.last_export_item.title = ""

    # ── Menu callbacks ───────────────────────────────────────────────────

    def on_export_now(self, _):
        if not self.cfg:
            self._run_setup_wizard()
            return
        if self.watcher:
            self.watcher.export_now()

    def on_toggle_pause(self, sender):
        if self.watcher:
            self.watcher.paused = not self.watcher.paused
            if self.watcher.paused:
                sender.title = t("menu.resume")
                self._set_icon_state("paused")
            else:
                sender.title = t("menu.pause")
                self._set_icon_state("idle")

    def on_open_folder(self, _):
        if self.cfg and self.cfg.export_path.is_dir():
            subprocess.run(["open", str(self.cfg.export_path)], check=False)
        elif self.cfg:
            rumps.alert(
                t("settings.folder_not_found"),
                t("settings.folder_not_found_msg").format(
                    path=self.cfg.export_path
                ),
            )
        else:
            self._run_setup_wizard()

    def on_change_folder(self, _):
        """Let the user pick a new export folder via the native picker."""
        new_path = _pick_folder(t("wizard.pick_advanced"))
        if not new_path:
            return
        if not self.cfg:
            _write_config(new_path)
            self._reload_profiles()
            if self.cfg:
                self._start_watcher()
            return

        # Rewrite config with the new path
        config_path = find_config()
        if config_path:
            try:
                content = config_path.read_text()
                old_out = str(self.cfg.export_path)
                content = content.replace(
                    f'out = "{old_out}"',
                    f'out = "{new_path}"',
                )
                config_path.write_text(content)
            except OSError:
                pass

        self._reload_profiles()
        if self.cfg:
            if self.watcher:
                self.watcher.stop()
            self._start_watcher()

        rumps.notification(
            APP_NAME, t("settings.folder_changed"),
            t("settings.folder_changed_msg").format(path=new_path),
            sound=NOTIFICATION_SOUND,
        )

    def on_configure_profile(self, _):
        """Open the native settings panel pre-filled with current config."""
        if not self.cfg:
            self._run_setup_wizard()
            return

        export_path = str(self.cfg.export_path)
        excl = ", ".join(self.cfg.exclude_tags) if self.cfg.exclude_tags else ""
        export_tb = str(getattr(self.cfg, "export_path_tb", "") or "")
        if self.cfg.export_format == "tb" and not export_tb:
            export_tb = export_path

        self._show_settings_panel(
            export_path,
            export_path_tb=export_tb,
            export_format=self.cfg.export_format,
            yaml_front_matter=self.cfg.yaml_front_matter,
            hide_tags=self.cfg.hide_tags,
            tag_folders=self.cfg.make_tag_folders,
            on_delete=self.cfg.on_delete,
            naming=self.cfg.naming,
            exclude_tags=excl,
            auto_start=is_login_item(),
        )

    def on_edit_config(self, _):
        config_path = find_config()
        if config_path:
            subprocess.run(["open", str(config_path)], check=False)
        else:
            self._run_setup_wizard()

    def on_toggle_login(self, sender):
        if sender.state:
            remove_login_item()
            sender.state = False
        else:
            add_login_item()
            sender.state = True

    def on_quit(self, _):
        if self.watcher:
            self.watcher.stop()
        rumps.quit_application()

    # ── Timers ────────────────────────────────────────────────────────────

    @rumps.timer(1)
    def _deferred_startup(self, timer):
        """One-shot: load profiles after the run-loop is live."""
        if self._did_initial_load:
            timer.stop()
            return
        self._did_initial_load = True
        timer.stop()

        self._reload_profiles()

        if self.cfg:
            self._start_watcher()
        else:
            self._run_setup_wizard()

    @rumps.timer(30)
    def refresh_status(self, _):
        self._update_status()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    init_language()
    app = B2OUApp()
    app.run()


if __name__ == "__main__":
    main()
