# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec file for the B2OU CLI — a lightweight command-line tool.

This builds ONLY the Python export engine (no GUI, no rumps, no PyObjC).
The Swift menu-bar app launches this CLI as a subprocess.

Build:  python -m PyInstaller B2OU-CLI.spec
Output: dist/b2ou-cli/b2ou-cli
"""

import os

block_cipher = None

a = Analysis(
    ["b2ou/cli.py"],
    pathex=["."],
    binaries=[],
    datas=[],
    hiddenimports=[
        "b2ou",
        "b2ou.config",
        "b2ou.constants",
        "b2ou.db",
        "b2ou.export",
        "b2ou.images",
        "b2ou.markdown",
        "b2ou.profile",
        "sqlite3",
        "fcntl",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # GUI/PyObjC — not needed for CLI (saves ~90 MB RAM + disk)
        "rumps",
        "AppKit",
        "Foundation",
        "objc",
        "PyObjCTools",
        "pyobjc",
        "Cocoa",
        "PIL",
        "Pillow",
        "tkinter",
        # GUI-only b2ou modules
        "b2ou.menubar",
        "b2ou.settings_panel",
        "b2ou.autostart",
        "b2ou.i18n",
        # Unused stdlib modules
        "unittest",
        "test",
        "xmlrpc",
        "doctest",
        "pydoc",
        "webbrowser",
        "multiprocessing",
        "asyncio",
        "email",
        "html.parser",
        "http.server",
        "xml",
        "ftplib",
        "imaplib",
        "smtplib",
        "poplib",
        "nntplib",
        "telnetlib",
        "turtle",
        "turtledemo",
        "idlelib",
        "lib2to3",
        "ensurepip",
        "venv",
        "distutils",
        "setuptools",
        "pkg_resources",
        "pip",
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
    name="b2ou-cli",
    debug=False,
    bootloader_ignore_signals=False,
    strip=True,
    upx=True,
    console=True,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=True,
    upx=True,
    name="b2ou-cli",
)
