# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec file for B2OU.app — a standalone macOS menu-bar app.

This bundles Python, rumps, pyobjc, and all b2ou code into a single
.app that requires no external dependencies.

Build:  python -m PyInstaller B2OU.spec
Output: dist/B2OU.app
"""

import os
import sys

block_cipher = None

# Collect menu-bar icon PNGs from resources/icons/
_icon_datas = []
_icons_dir = os.path.join("resources", "icons")
if os.path.isdir(_icons_dir):
    for fname in os.listdir(_icons_dir):
        if fname.endswith(".png"):
            _icon_datas.append(
                (os.path.join(_icons_dir, fname), os.path.join("resources", "icons"))
            )

# Collect all b2ou package files
a = Analysis(
    ["b2ou/menubar.py"],
    pathex=["."],
    binaries=[],
    datas=_icon_datas,
    hiddenimports=[
        # rumps + pyobjc internals that PyInstaller may miss
        "rumps",
        "AppKit",
        "Foundation",
        "objc",
        "PyObjCTools",
        "PyObjCTools.AppHelper",
        # b2ou modules
        "b2ou",
        "b2ou.autostart",
        "b2ou.cli",
        "b2ou.config",
        "b2ou.constants",
        "b2ou.db",
        "b2ou.export",
        "b2ou.i18n",
        "b2ou.images",
        "b2ou.markdown",
        "b2ou.profile",
        "b2ou.settings_panel",
        # stdlib modules used at runtime
        "sqlite3",
        "plistlib",
        "fcntl",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "tkinter",
        "unittest",
        "test",
        "xmlrpc",
        "doctest",
        "pydoc",
        "webbrowser",
    ],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="B2OU",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,           # No terminal window
    target_arch=None,        # Build for current arch (or universal2)
)

# Icon path — use .icns if built, otherwise skip
icon_file = "resources/B2OU.icns"
if not os.path.exists(icon_file):
    icon_file = None

app = BUNDLE(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    name="B2OU.app",
    icon=icon_file,
    bundle_identifier="net.b2ou.app",
    info_plist={
        "CFBundleName": "B2OU",
        "CFBundleDisplayName": "B2OU — Bear Export",
        "CFBundleIdentifier": "net.b2ou.app",
        "CFBundleVersion": "5.0.0",
        "CFBundleShortVersionString": "5.0",
        "LSUIElement": True,         # Menu-bar only — no Dock icon
        "NSHumanReadableCopyright": "MIT License",
        "LSMinimumSystemVersion": "10.15",
        "NSHighResolutionCapable": True,
        "CFBundleDocumentTypes": [],
    },
)
