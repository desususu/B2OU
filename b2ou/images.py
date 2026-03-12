"""
Image copy and path-resolution helpers for the export pipeline.

``process_export_images`` rewrites Bear image references in the exported
Markdown and copies the actual image files to the assets directory
(incremental — only newer sources are copied).
"""

from __future__ import annotations

import logging
import os
import shutil
import sqlite3
import urllib.parse
from pathlib import Path

from b2ou.constants import (
    IMAGE_EXTENSIONS,
    RE_BEAR_FILE,
    RE_BEAR_FILE_SUB,
    RE_BEAR_IMAGE,
    RE_BEAR_IMG_SUB,
    RE_MD_LINK,
    RE_MD_IMAGE,
    RE_WIKI_IMAGE,
)
from b2ou.markdown import html_img_to_markdown, normalize_local_image_ref

log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Low-level file helpers
# ---------------------------------------------------------------------------

def _find_attachment(
    file_uuid: str,
    filename: str,
    bear_image_path: Path,
    bear_file_path: Path | None = None,
) -> Path | None:
    """Locate an attachment file in Bear's storage directories.

    Bear stores images in ``Note Images/`` and non-image files (PDFs, videos,
    audio, etc.) in ``Note Files/``.  This helper checks both locations and
    returns the first existing path, or ``None``.
    """
    candidate = bear_image_path / file_uuid / filename
    if candidate.exists():
        return candidate
    if bear_file_path:
        candidate = bear_file_path / file_uuid / filename
        if candidate.exists():
            return candidate
    return None


def _is_image_file(filename: str) -> bool:
    """Return True if *filename* has a recognized image extension."""
    return Path(filename).suffix.lower() in IMAGE_EXTENSIONS


def _make_link(filename: str, rel_path: str) -> str:
    """Return Markdown image syntax for images, link syntax for other files."""
    encoded = urllib.parse.quote(rel_path)
    if _is_image_file(filename):
        return f"![{filename}]({encoded})"
    return f"[{filename}]({encoded})"


def copy_incremental(source: Path, dest: Path) -> None:
    """Copy *source* → *dest* only when *source* is newer; create dirs as needed."""
    if not source.exists():
        return
    if dest.exists() and dest.stat().st_mtime >= source.stat().st_mtime:
        return
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
    except OSError as exc:
        log.warning("Failed to copy image %s → %s: %s", source, dest, exc)


def collect_referenced_local_images(root_path: Path, skip_dirs: frozenset) -> set[Path]:
    """
    Walk *root_path* and return the set of absolute local image paths
    referenced by all note files found there.
    """
    refs: set[Path] = set()
    if not root_path.is_dir():
        return refs

    for dirpath, dirnames, filenames in os.walk(root_path, topdown=True):
        dirnames[:] = [
            d for d in dirnames
            if d not in skip_dirs
            and d != ".git"
            and d != "__pycache__"
        ]
        for fname in filenames:
            if not any(fname.endswith(ext) for ext in (".md", ".txt", ".markdown")):
                continue
            note_path = Path(dirpath) / fname
            try:
                text = note_path.read_text(encoding="utf-8")
            except Exception:
                continue

            text = html_img_to_markdown(text)

            for m in RE_MD_IMAGE.finditer(text):
                raw = normalize_local_image_ref(m.group(2))
                if not raw or raw.startswith(("http://", "https://")):
                    continue
                abs_img = Path(raw) if os.path.isabs(raw) else (
                    note_path.parent / raw
                ).resolve()
                refs.add(abs_img)

            for raw in RE_WIKI_IMAGE.findall(text):
                img = normalize_local_image_ref(raw)
                if not img or img.startswith(("http://", "https://")):
                    continue
                abs_img = Path(img) if os.path.isabs(img) else (
                    note_path.parent / img
                ).resolve()
                refs.add(abs_img)

    return refs


# ---------------------------------------------------------------------------
# Export-side image processing
# ---------------------------------------------------------------------------

def process_export_images(
    text: str,
    filepath: Path,
    conn: sqlite3.Connection,
    note_pk: int,
    bear_image_path: Path,
    assets_path: Path,
    export_path: Path,
    bear_file_path: Path | None = None,
) -> str:
    """
    Rewrite Bear image/file references in *text* to point at *assets_path*
    and copy the actual files there (incrementally).

    Handles:
    • Bear 1.x: ``[image:UUID/filename]`` → images
    • Bear 1.x: ``[file:UUID/filename]``  → non-image attachments
    • Bear 2.x: ``![alt](filename)``      → linked via ZSFNOTEFILE UUID lookup
    """
    # Build filename → UUID map for all files attached to this note
    file_map: dict[str, str] = {}
    for row in conn.execute(
        "SELECT ZFILENAME, ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE WHERE ZNOTE = ?",
        (note_pk,),
    ):
        file_map[row["ZFILENAME"]] = row["ZUNIQUEIDENTIFIER"]

    rel_assets = os.path.relpath(assets_path, export_path)
    exported_filenames: set[str] = set()
    rel_assets_prefix = rel_assets + "/"

    # ── Bear 1.x: [image:UUID/filename] ──────────────────────────────────

    def _rewrite_bear1_image(m: "re.Match") -> str:
        ref = m.group(1)
        parts = ref.split("/", 1)
        if len(parts) != 2:
            return m.group(0)
        img_uuid, img_filename = parts
        exported_filenames.add(img_filename)
        source = _find_attachment(
            img_uuid, img_filename, bear_image_path, bear_file_path
        )
        if source is None:
            return m.group(0)
        dest = assets_path / img_uuid / img_filename
        copy_incremental(source, dest)
        rel = f"{rel_assets}/{img_uuid}/{img_filename}"
        return f"![]({urllib.parse.quote(rel)})"

    text = RE_BEAR_IMAGE.sub(_rewrite_bear1_image, text)

    # ── Bear 1.x: [file:UUID/filename] ───────────────────────────────────

    def _rewrite_bear1_file(m: "re.Match") -> str:
        ref = m.group(1)
        parts = ref.split("/", 1)
        if len(parts) != 2:
            return m.group(0)
        file_uuid, file_name = parts
        exported_filenames.add(file_name)
        source = _find_attachment(
            file_uuid, file_name, bear_image_path, bear_file_path
        )
        if source is None:
            return m.group(0)
        dest = assets_path / file_uuid / file_name
        copy_incremental(source, dest)
        rel = f"{rel_assets}/{file_uuid}/{file_name}"
        return _make_link(file_name, rel)

    text = RE_BEAR_FILE.sub(_rewrite_bear1_file, text)

    # ── Bear 2.x: ![alt](filename) ───────────────────────────────────────

    def _rewrite_md(m: "re.Match") -> str:
        img_url = m.group(2)
        if img_url.startswith("http"):
            return m.group(0)

        img_filename = urllib.parse.unquote(img_url)
        if img_filename.startswith(rel_assets + "/"):
            return m.group(0)  # already exported

        basename = os.path.basename(img_filename)
        file_uuid = file_map.get(basename)
        if file_uuid is None:
            return m.group(0)

        exported_filenames.add(basename)
        source = _find_attachment(
            file_uuid, basename, bear_image_path, bear_file_path
        )
        if source is None:
            return m.group(0)
        dest = assets_path / file_uuid / basename
        copy_incremental(source, dest)
        rel = f"{rel_assets}/{file_uuid}/{basename}"
        return f"![{m.group(1)}]({urllib.parse.quote(rel)})"

    text = RE_MD_IMAGE.sub(_rewrite_md, text)

    # ── Bear 2.x: [label](filename) for non-image attachments ───────────
    def _rewrite_md_link(m: "re.Match") -> str:
        label = m.group(1)
        raw = m.group(2).strip()
        if raw.startswith(("http://", "https://", "mailto:")):
            return m.group(0)
        parts = raw.split(None, 1)
        url_part = parts[0]
        tail = raw[len(url_part):]
        url_clean = url_part.strip("<>")
        if url_clean.startswith(rel_assets_prefix):
            exported_filenames.add(
                os.path.basename(urllib.parse.unquote(url_clean))
            )
            return m.group(0)
        basename = os.path.basename(urllib.parse.unquote(url_clean))
        file_uuid = file_map.get(basename)
        if file_uuid is None:
            return m.group(0)
        exported_filenames.add(basename)
        source = _find_attachment(
            file_uuid, basename, bear_image_path, bear_file_path
        )
        if source is None:
            return m.group(0)
        dest = assets_path / file_uuid / basename
        copy_incremental(source, dest)
        rel = f"{rel_assets}/{file_uuid}/{basename}"
        return f"[{label}]({urllib.parse.quote(rel)}{tail})"

    text = RE_MD_LINK.sub(_rewrite_md_link, text)

    # ── Unreferenced attachments (PDFs, videos, audio, etc.) ─────────────
    # Copy any ZSFNOTEFILE entries not already handled above and append links.
    unreferenced_links: list[str] = []
    for filename, file_uuid in file_map.items():
        if filename in exported_filenames:
            continue
        source = _find_attachment(
            file_uuid, filename, bear_image_path, bear_file_path
        )
        if source is None:
            continue
        dest = assets_path / file_uuid / filename
        copy_incremental(source, dest)
        rel = f"{rel_assets}/{file_uuid}/{filename}"
        unreferenced_links.append(_make_link(filename, rel))

    if unreferenced_links:
        text = text.rstrip() + "\n\n" + "\n".join(unreferenced_links) + "\n"

    return text


def process_export_images_textbundle(
    text: str,
    bundle_assets: Path,
    conn: sqlite3.Connection,
    note_pk: int,
    bear_image_path: Path,
    bear_file_path: Path | None = None,
    existing_assets: Path | None = None,
) -> str:
    """
    Like ``process_export_images`` but for TextBundle format.

    Images and file attachments are copied into *bundle_assets* (inside the
    ``.textbundle``).
    """
    # Build UUID→filename map for all attachments
    file_map: dict[str, str] = {}
    for row in conn.execute(
        "SELECT ZFILENAME, ZUNIQUEIDENTIFIER FROM ZSFNOTEFILE WHERE ZNOTE = ?",
        (note_pk,),
    ):
        file_map[row["ZFILENAME"]] = row["ZUNIQUEIDENTIFIER"]

    exported_filenames: set[str] = set()

    def _link_or_copy(src: Path, dest: Path) -> None:
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, dest)
            return
        except OSError:
            pass
        try:
            shutil.copy2(src, dest)
        except OSError as exc:
            log.warning("Failed to copy asset %s → %s: %s", src, dest, exc)

    def _copy_tb_asset(source: Path | None, dest: Path) -> None:
        if source is None or not source.exists():
            return
        if existing_assets:
            existing = existing_assets / dest.name
            try:
                if existing.exists():
                    s_stat = source.stat()
                    e_stat = existing.stat()
                    if (e_stat.st_size == s_stat.st_size
                            and e_stat.st_mtime >= s_stat.st_mtime):
                        _link_or_copy(existing, dest)
                        return
            except OSError:
                pass
        copy_incremental(source, dest)

    # ── Bear 1.x: [image:UUID/filename] ──────────────────────────────────
    for match in RE_BEAR_IMAGE.findall(text):
        image_name = match
        parts = image_name.split("/", 1)
        new_name = image_name.replace("/", "_")
        if len(parts) == 2:
            source = _find_attachment(
                parts[0], parts[1], bear_image_path, bear_file_path
            )
            exported_filenames.add(parts[1])
        else:
            source = bear_image_path / image_name
        target = bundle_assets / new_name
        _copy_tb_asset(source, target)
    text = RE_BEAR_IMG_SUB.sub(r"![](assets/\1_\2)", text)

    # ── Bear 1.x: [file:UUID/filename] ───────────────────────────────────
    def _rewrite_bear1_file_tb(m: "re.Match") -> str:
        ref = m.group(1)
        parts = ref.split("/", 1)
        if len(parts) != 2:
            return m.group(0)
        file_uuid, file_name = parts
        exported_filenames.add(file_name)
        source = _find_attachment(
            file_uuid, file_name, bear_image_path, bear_file_path
        )
        if source is None:
            return m.group(0)
        new_name = f"{file_uuid}_{file_name}"
        target = bundle_assets / new_name
        _copy_tb_asset(source, target)
        asset_rel = f"assets/{new_name}"
        return _make_link(file_name, asset_rel)

    text = RE_BEAR_FILE.sub(_rewrite_bear1_file_tb, text)

    # ── Bear 2.x: ![alt](filename) ───────────────────────────────────────
    def _replace_md(m: "re.Match") -> str:
        alt_text = m.group(1)
        image_url = m.group(2)
        if image_url.startswith("http") or image_url.startswith("assets/"):
            return m.group(0)
        image_filename = urllib.parse.unquote(image_url)
        basename = os.path.basename(image_filename)
        file_uuid = file_map.get(basename)
        if not file_uuid:
            return m.group(0)
        exported_filenames.add(basename)
        source = _find_attachment(
            file_uuid, basename, bear_image_path, bear_file_path
        )
        new_name = f"{file_uuid}_{basename}"
        target = bundle_assets / new_name
        _copy_tb_asset(source, target)
        return f"![{alt_text}]({urllib.parse.quote(f'assets/{new_name}')})"

    text = RE_MD_IMAGE.sub(_replace_md, text)

    # ── Bear 2.x: [label](filename) for non-image attachments ───────────
    def _replace_md_link(m: "re.Match") -> str:
        label = m.group(1)
        raw = m.group(2).strip()
        if raw.startswith(("http://", "https://", "mailto:")):
            return m.group(0)
        parts = raw.split(None, 1)
        url_part = parts[0]
        tail = raw[len(url_part):]
        url_clean = url_part.strip("<>")
        if url_clean.startswith("assets/"):
            exported_filenames.add(
                os.path.basename(urllib.parse.unquote(url_clean))
            )
            return m.group(0)
        basename = os.path.basename(urllib.parse.unquote(url_clean))
        file_uuid = file_map.get(basename)
        if not file_uuid:
            return m.group(0)
        exported_filenames.add(basename)
        source = _find_attachment(
            file_uuid, basename, bear_image_path, bear_file_path
        )
        new_name = f"{file_uuid}_{basename}"
        target = bundle_assets / new_name
        _copy_tb_asset(source, target)
        asset_rel = f"assets/{new_name}"
        return f"[{label}]({urllib.parse.quote(asset_rel)}{tail})"

    text = RE_MD_LINK.sub(_replace_md_link, text)

    # ── Unreferenced attachments ─────────────────────────────────────────
    unreferenced_links: list[str] = []
    for filename, file_uuid in file_map.items():
        if filename in exported_filenames:
            continue
        source = _find_attachment(
            file_uuid, filename, bear_image_path, bear_file_path
        )
        if source is None:
            continue
        new_name = f"{file_uuid}_{filename}"
        target = bundle_assets / new_name
        if not target.exists():
            _copy_tb_asset(source, target)
        asset_rel = f"assets/{new_name}"
        unreferenced_links.append(_make_link(filename, asset_rel))

    if unreferenced_links:
        text = text.rstrip() + "\n\n" + "\n".join(unreferenced_links) + "\n"

    return text
