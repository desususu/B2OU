"""
Compiled regex patterns, file-extension sets, and other module-level constants.

All patterns are compiled once at import time for performance.
"""

import re

# ---------------------------------------------------------------------------
# Core Data / epoch
# ---------------------------------------------------------------------------

# Bear stores timestamps as Core Data "seconds since 2001-01-01 UTC".
# Adding this offset converts them to Unix timestamps.
CORE_DATA_EPOCH: float = 978_307_200.0  # 2001-01-01 00:00:00 UTC

# ---------------------------------------------------------------------------
# Image references
# ---------------------------------------------------------------------------

RE_MD_IMAGE     = re.compile(r'!\[(.*?)\]\(([^)]+)\)')
RE_MD_LINK      = re.compile(r'(?<!!)\[([^\]]+)\]\(([^)]+)\)')
RE_WIKI_IMAGE   = re.compile(r'!\[\[(.*?)\]\]')
RE_HTML_IMG_TAG = re.compile(r'<img\b[^>]*>', re.IGNORECASE)
RE_HTML_IMG_SRC = re.compile(r'\bsrc=(["\'])(.*?)\1', re.IGNORECASE)
RE_HTML_IMG_ALT = re.compile(r'\balt=(["\'])(.*?)\1', re.IGNORECASE)

# Bear 1.x inline image syntax: [image:UUID/filename]
RE_BEAR_IMAGE     = re.compile(r'\[image:(.+?)\]')
RE_BEAR_IMG_SUB   = re.compile(r'\[image:(.+?)/(.+?)\]')

# Bear file attachment syntax: [file:UUID/filename]
RE_BEAR_FILE      = re.compile(r'\[file:(.+?)\]')
RE_BEAR_FILE_SUB  = re.compile(r'\[file:(.+?)/(.+?)\]')

# Bear embed metadata (for attachments like audio/video)
RE_BEAR_EMBED = re.compile(
    r'<!--\s*\{\s*"embed"\s*:\s*"?true"?\s*\}\s*-->'
)

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

# Pattern 1: #tag or #nested/tag followed by space/newline, not part of a URL
RE_TAG_PATTERN1 = re.compile(
    r'(?<!\S)\#([.\w\/\-]+)[ \n]?(?!([\/ \w]+\w[#]))')
# Pattern 2: multi-word tags enclosed in double hashes: #multi word tag#
RE_TAG_PATTERN2 = re.compile(
    r'(?<![\S])\#([^ \d][.\w\/ ]+?)\#([ \n]|$)')

# Hide tags: strip tag lines from exported markdown
RE_HIDE_TAGS = re.compile(r'(\n)[ \t]*(\#[^\s#].*)')

# ---------------------------------------------------------------------------
# Markdown structure
# ---------------------------------------------------------------------------

RE_MD_HEADING = re.compile(r'^#+\s*')
RE_CLEAN_TITLE    = re.compile(r'[\/\\:]')
RE_TRAILING_DASH  = re.compile(r'-$')

# Reference-style links
RE_REF_DEF      = re.compile(r'^\[(?!\/\/)([^\]]+)\]:\s*(\S+).*$', re.MULTILINE)
RE_REF_IMG      = re.compile(r'!\[([^\]]*)\]\[([^\]]+)\]')
RE_REF_IMP      = re.compile(r'!\[([^\[\]]+)\](?!\()')
RE_REF_LINK     = re.compile(r'(?<!!)\[([^\]]+)\]\[([^\]]+)\]')
RE_REF_LINK_IMP = re.compile(r'(?<!!)\[([^\[\]]+)\](?!\(|\[|:)')
RE_REF_CLEAN    = re.compile(r'^\[(?!\/\/)[^\]]+\]:\s*\S+.*$\n?', re.MULTILINE)

# ---------------------------------------------------------------------------
# File-system constants
# ---------------------------------------------------------------------------

IMAGE_EXTENSIONS: frozenset[str] = frozenset({
    '.png', '.jpg', '.jpeg', '.gif', '.webp',
    '.heic', '.bmp', '.tif', '.tiff',
})

NOTE_EXTENSIONS: frozenset[str] = frozenset({'.md', '.txt', '.markdown'})

SENTINEL_FILES: frozenset[str] = frozenset({
    '.sync-time.log', '.export-time.log', '.b2ou-manifest',
})

# Directories always skipped during export-folder walks
EXPORT_SKIP_DIRS: frozenset[str] = frozenset({'BearImages', '.obsidian'})
EXPORT_SKIP_DIR_PREFIXES: tuple[str, ...] = ('.Ulysses',)
