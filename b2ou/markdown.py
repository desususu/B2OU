"""
Pure Markdown transformation functions — no I/O, no config dependencies.

All functions take a string and return a string (or ancillary data).
They rely only on the pre-compiled patterns in ``b2ou.constants``.
"""

from __future__ import annotations

import urllib.parse
from typing import Optional

from b2ou.constants import (
    RE_BEAR_EMBED,
    RE_CLEAN_TITLE,
    RE_HIDE_TAGS,
    RE_HTML_IMG_ALT,
    RE_HTML_IMG_SRC,
    RE_HTML_IMG_TAG,
    RE_MD_HEADING,
    RE_MD_IMAGE,
    RE_REF_CLEAN,
    RE_REF_DEF,
    RE_REF_IMP,
    RE_REF_IMG,
    RE_REF_LINK,
    RE_REF_LINK_IMP,
    RE_TAG_PATTERN1,
    RE_TAG_PATTERN2,
    RE_TRAILING_DASH,
)


# ---------------------------------------------------------------------------
# Title sanitisation
# ---------------------------------------------------------------------------

def clean_title(title: str) -> str:
    """Return a filesystem-safe version of *title*.

    The result is capped so that the UTF-8 byte length stays under 240,
    leaving room for a file extension (e.g. ``.md``, ``.textbundle``).
    """
    # Cap characters first (fast path for ASCII-only titles)
    title = title[:225].strip() or "Untitled"
    title = RE_CLEAN_TITLE.sub("-", title)
    title = RE_TRAILING_DASH.sub("", title)
    title = title.strip()

    # Ensure the UTF-8 byte length fits in 240 bytes (255 limit minus extension)
    max_bytes = 240
    encoded = title.encode("utf-8")
    if len(encoded) > max_bytes:
        # Truncate by decoding back with error handling to avoid splitting mid-char
        title = encoded[:max_bytes].decode("utf-8", errors="ignore").rstrip()

    return title


# ---------------------------------------------------------------------------
# Bear → standard Markdown normalisation
# ---------------------------------------------------------------------------

import re as _re

_RE_BEAR_HIGHLIGHT = _re.compile(r'(?<!\:)\:\:(?!\:)(.+?)(?<!\:)\:\:(?!\:)')


def bear_highlight_to_md(text: str) -> str:
    """Convert Bear's ``::highlight::`` syntax to Obsidian's ``==highlight==``."""
    return _RE_BEAR_HIGHLIGHT.sub(r'==\1==', text)


def normalise_bear_markdown(text: str) -> str:
    """Apply all Bear → standard Markdown conversions.

    Currently handles:
    - ``::highlight::`` → ``==highlight==``
    - ``<img>`` HTML tags → ``![alt](src)``
    """
    text = bear_highlight_to_md(text)
    text = html_img_to_markdown(text)
    text = RE_BEAR_EMBED.sub("", text)
    return text


# ---------------------------------------------------------------------------
# Tag handling
# ---------------------------------------------------------------------------

def hide_tags(text: str) -> str:
    """Strip Bear tag lines (lines beginning with #tag) from *text*."""
    return RE_HIDE_TAGS.sub(r"\1", text)


def extract_tags(text: str) -> list[str]:
    """Return all Bear tag strings found in *text* (without the leading #)."""
    tags: list[str] = []
    tags.extend(m[0] for m in RE_TAG_PATTERN1.findall(text))
    tags.extend(m[0] for m in RE_TAG_PATTERN2.findall(text))
    return tags


def sub_path_from_tag(
    base_path: str,
    filename: str,
    text: str,
    make_tag_folders: bool,
    multi_tag_folders: bool,
    only_export_tags: list[str],
    exclude_tags: list[str],
) -> list[str]:
    """
    Return the list of output file paths for a note, based on its tags.

    With *make_tag_folders=False* (default) returns a single path under
    *base_path*.  With *make_tag_folders=True* the note may be written to
    multiple tag-based subdirectories (when *multi_tag_folders=True*).
    """
    import os

    if not make_tag_folders:
        is_excluded = any(("#" + tag) in text for tag in exclude_tags)
        return [] if is_excluded else [os.path.join(base_path, filename)]

    if multi_tag_folders:
        tags = extract_tags(text)
        if not tags:
            return [os.path.join(base_path, filename)]
    else:
        t1 = RE_TAG_PATTERN1.search(text)
        t2 = RE_TAG_PATTERN2.search(text)
        if t1 and t2:
            tag = t1.group(1) if t1.start(1) < t2.start(1) else t2.group(1)
        elif t1:
            tag = t1.group(1)
        elif t2:
            tag = t2.group(1)
        else:
            return [os.path.join(base_path, filename)]
        tags = [tag]

    paths = [os.path.join(base_path, filename)]
    for tag in tags:
        if tag == "/":
            continue
        if only_export_tags:
            if not any(tag.lower().startswith(et.lower())
                       for et in only_export_tags):
                continue
        if any(tag.lower().startswith(nt.lower()) for nt in exclude_tags):
            return []
        sub = ("_" + tag[1:]) if tag.startswith(".") else tag
        # Sanitize characters that are invalid in directory names
        sub = _sanitize_dir_name(sub)
        if not sub:
            continue
        tag_path = os.path.join(base_path, sub)
        os.makedirs(tag_path, exist_ok=True)
        paths.append(os.path.join(tag_path, filename))
    return paths


_RE_INVALID_DIR_CHARS = _re.compile(r'[<>:"|?*\x00-\x1f]')


def _sanitize_dir_name(name: str) -> str:
    """Remove or replace characters that are invalid in directory names."""
    name = _RE_INVALID_DIR_CHARS.sub("_", name)
    # Collapse multiple underscores/spaces
    name = _re.sub(r'_+', '_', name).strip().strip("_")
    return name


# ---------------------------------------------------------------------------
# HTML → Markdown image conversion
# ---------------------------------------------------------------------------

def html_img_to_markdown(text: str) -> str:
    """Replace ``<img src=... alt=...>`` tags with ``![alt](src)`` syntax."""

    def _replace(m: "re.Match") -> str:
        tag = m.group(0)
        src_m = RE_HTML_IMG_SRC.search(tag)
        if not src_m:
            return tag
        src = (src_m.group(2) or "").strip()
        if not src:
            return tag
        alt_m = RE_HTML_IMG_ALT.search(tag)
        alt = (alt_m.group(2) if alt_m else "image").strip() or "image"
        alt = alt.replace("]", r"\]")
        return f"![{alt}]({src})"

    return RE_HTML_IMG_TAG.sub(_replace, text)


# ---------------------------------------------------------------------------
# Reference-style link resolution
# ---------------------------------------------------------------------------

def ref_links_to_inline(text: str) -> str:
    """
    Expand reference-style links and images to inline syntax.

    ``[text][ref]`` → ``[text](url)``
    ``![alt][ref]`` → ``![alt](url)``
    """
    refs = dict(RE_REF_DEF.findall(text))
    if not refs:
        return text

    # Reference images
    text = RE_REF_IMG.sub(
        lambda m: f"![{m.group(1)}]({refs.get(m.group(2), m.group(2))})",
        text,
    )
    text = RE_REF_IMP.sub(
        lambda m: f"![{m.group(1)}]({refs.get(m.group(1), m.group(1))})",
        text,
    )
    # Reference links
    text = RE_REF_LINK.sub(
        lambda m: f"[{m.group(1)}]({refs.get(m.group(2), m.group(2))})",
        text,
    )
    text = RE_REF_LINK_IMP.sub(
        lambda m: (
            f"[{m.group(1)}]({refs[m.group(1)]})"
            if m.group(1) in refs
            else m.group(0)
        ),
        text,
    )
    # Remove reference definitions
    text = RE_REF_CLEAN.sub("", text)
    return text


# ---------------------------------------------------------------------------
# Image link normalisation
# ---------------------------------------------------------------------------

def normalize_local_image_ref(raw_url: Optional[str]) -> str:
    """
    Convert an image URL / path from Markdown or HTML src to a local path token.

    Strips URL encoding, optional ``file://`` prefix, and inline title strings.
    Returns an empty string for ``None`` or empty input.
    """
    if not raw_url:
        return ""
    url = urllib.parse.unquote(str(raw_url)).strip()
    if not url:
        return ""

    # Strip optional inline title: path "title" / path 'title'
    for q in ('"', "'"):
        if q in url:
            head = url[: url.find(q)].rstrip()
            if head:
                url = head
                break

    if url.startswith("<") and url.endswith(">"):
        url = url[1:-1].strip()

    if url.lower().startswith("file://"):
        parsed = urllib.parse.urlparse(url)
        fp = urllib.parse.unquote(parsed.path or "")
        if fp:
            return fp

    return url


# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

def first_heading(text: str) -> str:
    """Return the first non-empty line stripped of any Markdown heading prefix."""
    for line in text.splitlines():
        line = line.strip()
        if line:
            return RE_MD_HEADING.sub("", line).strip()
    return ""
