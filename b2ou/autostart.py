"""
macOS Login Item (LaunchAgent) management for B2OU.

Manages a ``~/Library/LaunchAgents/net.b2ou.app.plist`` so the menu-bar
app starts automatically at login.
"""

from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

LABEL = "net.b2ou.app"
LAUNCH_AGENTS = Path.home() / "Library" / "LaunchAgents"
PLIST_PATH = LAUNCH_AGENTS / f"{LABEL}.plist"


def _find_app_bundle() -> Path | None:
    """Walk up from the current executable to find the enclosing .app bundle."""
    if not getattr(sys, "frozen", False):
        return None
    exe = Path(sys.executable).resolve()
    for parent in exe.parents:
        if parent.suffix == ".app":
            return parent
    return None


def _build_plist() -> dict:
    """Build the LaunchAgent plist dictionary.

    When running from a .app bundle (PyInstaller / py2app), the plist
    uses ``open -a /path/to/B2OU.app`` so macOS handles the launch
    correctly.  Otherwise falls back to ``python -m b2ou.menubar``.
    """
    app_bundle = _find_app_bundle()
    if app_bundle:
        program_args = ["/usr/bin/open", "-a", str(app_bundle)]
    else:
        program_args = [sys.executable, "-m", "b2ou.menubar"]

    return {
        "Label": LABEL,
        "ProgramArguments": program_args,
        "RunAtLoad": True,
        "KeepAlive": False,
        "StandardOutPath": str(Path.home() / "Library/Logs/b2ou.log"),
        "StandardErrorPath": str(Path.home() / "Library/Logs/b2ou.log"),
    }


def add_login_item() -> bool:
    """Install the LaunchAgent plist to start at login. Returns True on success."""
    try:
        LAUNCH_AGENTS.mkdir(parents=True, exist_ok=True)
        plist_data = _build_plist()
        with open(PLIST_PATH, "wb") as f:
            plistlib.dump(plist_data, f)

        # Load immediately so it takes effect
        subprocess.run(
            ["launchctl", "load", "-w", str(PLIST_PATH)],
            capture_output=True, check=False,
        )
        return True
    except Exception:
        return False


def remove_login_item() -> bool:
    """Remove the LaunchAgent plist. Returns True on success."""
    try:
        if PLIST_PATH.exists():
            subprocess.run(
                ["launchctl", "unload", str(PLIST_PATH)],
                capture_output=True, check=False,
            )
            PLIST_PATH.unlink()
        return True
    except Exception:
        return False


def is_login_item() -> bool:
    """Check whether the LaunchAgent plist exists."""
    return PLIST_PATH.is_file()
