"""
py2app build script — DEPRECATED, use build_app.sh instead.

The recommended way to build B2OU.app is::

    ./build_app.sh

This uses PyInstaller and produces a truly standalone .app that bundles
Python + all dependencies.  No ``pip install`` needed by end users.

This py2app script is kept as a fallback for developers who prefer it::

    pip install py2app rumps
    python setup_app.py py2app
"""

from setuptools import setup

APP = ["b2ou/menubar.py"]
APP_NAME = "B2OU"

OPTIONS = {
    "argv_emulation": False,
    "iconfile": "resources/B2OU.icns",
    "plist": {
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": "B2OU — Bear Export",
        "CFBundleIdentifier": "net.b2ou.app",
        "CFBundleVersion": "5.0.0",
        "CFBundleShortVersionString": "5.0",
        "LSUIElement": True,  # menu-bar only, no Dock icon
        "NSHumanReadableCopyright": "MIT License",
        "CFBundleDocumentTypes": [],
    },
    "packages": ["b2ou"],
    "includes": [
        "rumps",
        "sqlite3",
        "plistlib",
        "tomllib",
    ],
    "excludes": [
        "tkinter",
        "unittest",
        "email",
        "http",
        "xml",
    ],
}

setup(
    name=APP_NAME,
    app=APP,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
