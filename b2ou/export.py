"""
Export phase: Bear SQLite database → Markdown / TextBundle files on disk.

Entry point: ``export_notes(config)``

The export is incremental: notes whose on-disk file is already at or newer
than the Bear modification timestamp are skipped (zero I/O).  At the end,
stale files (no longer present in Bear) are removed.
"""

from __future__ import annotations

import datetime
import fcntl
import json
import logging
import os
import shutil
import time
import urllib.parse
from pathlib import Path
from typing import Optional

from b2ou.config import ExportConfig
from b2ou.constants import (
    EXPORT_SKIP_DIR_PREFIXES,
    EXPORT_SKIP_DIRS,
    IMAGE_EXTENSIONS,
    SENTINEL_FILES,
)
from b2ou.db import BearNote, copy_and_open, core_data_to_unix, iter_notes
from b2ou.images import (
    collect_referenced_local_images,
    copy_incremental,
    process_export_images,
    process_export_images_textbundle,
)
from b2ou.markdown import (
    clean_title,
    extract_tags,
    hide_tags,
    normalise_bear_markdown,
    sub_path_from_tag,
)
def set_creation_date(filepath: Path, unix_timestamp: float) -> None:
    """Set the file's creation date (birthtime) via setattrlist(2).

    Uses ctypes to call the macOS setattrlist syscall directly, avoiding the
    ~90 MB memory overhead of importing the Foundation framework.
    """
    import ctypes
    import ctypes.util
    import struct
    import sys

    if sys.platform != "darwin":
        return

    try:
        _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        ATTR_BIT_MAP_COUNT = 5
        ATTR_CMN_CRTIME = 0x00000200
        secs = int(unix_timestamp)
        nsecs = int((unix_timestamp - secs) * 1_000_000_000)
        # struct timespec {time_t tv_sec; long tv_nsec;}
        timespec = struct.pack("ll", secs, nsecs)
        # struct attrlist {bitmapcount, reserved, commonattr, volattr, dirattr,
        #                  fileattr, forkattr}
        attrlist = struct.pack("IIIII", ATTR_BIT_MAP_COUNT, 0,
                               ATTR_CMN_CRTIME, 0, 0)
        path_bytes = str(filepath).encode("utf-8") + b"\x00"
        ret = _libc.setattrlist(path_bytes, attrlist, timespec,
                                len(timespec), 0)
        if ret != 0:
            errno = ctypes.get_errno()
            log.debug("setattrlist failed for %s: errno %d", filepath, errno)
    except Exception as exc:
        log.warning("Creation-date set failed for %s: %s", filepath, exc)

log = logging.getLogger(__name__)

_RE_NON_ALNUM = __import__("re").compile(r'[^a-z0-9]+')

# Manifest file that tracks which files b2ou created, so cleanup never
# deletes user-created files.  Stored as one relative path per line.
MANIFEST_NAME = ".b2ou-manifest"


def _read_manifest(export_path: Path) -> set[str]:
    """Read the manifest file and return the set of relative paths."""
    manifest = export_path / MANIFEST_NAME
    if not manifest.is_file():
        return set()
    try:
        return {line.strip() for line in manifest.read_text().splitlines()
                if line.strip()}
    except OSError:
        return set()


def _write_manifest(export_path: Path, paths: set[Path]) -> None:
    """Write the manifest file with relative paths of all exported files."""
    manifest = export_path / MANIFEST_NAME
    lines = sorted(
        str(p.relative_to(export_path))
        for p in paths
        if p != manifest
    )
    try:
        manifest.write_text("\n".join(lines) + "\n" if lines else "",
                            encoding="utf-8")
    except OSError as exc:
        log.warning("Could not write manifest: %s", exc)


# ---------------------------------------------------------------------------
# YAML front matter
# ---------------------------------------------------------------------------

def generate_front_matter(note: BearNote, text: str) -> str:
    """Return a YAML front matter block for *note*."""
    created = datetime.datetime.fromtimestamp(
        core_data_to_unix(note.creation_date), tz=datetime.timezone.utc,
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    modified = datetime.datetime.fromtimestamp(
        core_data_to_unix(note.modified_date), tz=datetime.timezone.utc,
    ).strftime("%Y-%m-%dT%H:%M:%SZ")

    tags = extract_tags(text)

    lines = [
        "---",
        f"title: {_yaml_escape(note.title)}",
        f"created: {created}",
        f"modified: {modified}",
        f"bear_id: {note.uuid}",
    ]
    if tags:
        lines.append("tags:")
        for tag in tags:
            lines.append(f"  - {_yaml_escape(tag)}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"


def _yaml_escape(value: str) -> str:
    """Escape a YAML value if it contains special characters."""
    if not value:
        return '""'
    # Quote if it contains characters that might break YAML parsing
    if any(c in value for c in ':{}[]&*?|>!%@`,"\'#'):
        escaped = value.replace('"', '\\"')
        return f'"{escaped}"'
    return value


# ---------------------------------------------------------------------------
# Filename strategies
# ---------------------------------------------------------------------------

def generate_filename(note: BearNote, naming: str) -> str:
    """Generate a filename (without extension) per the chosen *naming* strategy."""
    if naming == "slug":
        slug = _RE_NON_ALNUM.sub("-", note.title.lower().strip()).strip("-")
        return clean_title(slug) if slug else "untitled"

    if naming == "date-title":
        date_prefix = datetime.datetime.fromtimestamp(
            core_data_to_unix(note.creation_date)
        ).strftime("%Y-%m-%d")
        slug = _RE_NON_ALNUM.sub("-", note.title.lower().strip()).strip("-")
        title_part = clean_title(slug) if slug else "untitled"
        return f"{date_prefix}-{title_part}"

    if naming == "id":
        return note.uuid[:8]

    # Default: "title"
    return clean_title(note.title)


# ---------------------------------------------------------------------------
# File I/O helpers
# ---------------------------------------------------------------------------

def write_note_file(
    filepath: Path,
    content: str,
    modified_unix: float,
    created_core_data: float,
) -> None:
    """Write *content* to *filepath*, preserving Bear timestamps."""
    is_new = not filepath.exists()
    filepath.parent.mkdir(parents=True, exist_ok=True)
    tmp = filepath.with_name(f".{filepath.name}.tmp")
    try:
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, filepath)
    finally:
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
    if modified_unix > 0:
        os.utime(filepath, (-1, modified_unix))
    if created_core_data > 0 and is_new:
        set_creation_date(filepath, core_data_to_unix(created_core_data))


# ---------------------------------------------------------------------------
# Stale-file cleanup
# ---------------------------------------------------------------------------

def cleanup_stale_notes(
    export_path: Path, expected_paths: set[Path],
    on_delete: str = "trash",
) -> int:
    """
    Handle exported note files / bundles no longer present in Bear.

    *on_delete*:
        ``"trash"``  — move to ``.b2ou-trash/<date>/``
        ``"remove"`` — hard delete
        ``"keep"``   — do nothing

    Skips ``BearImages``, ``.obsidian``, ``.Ulysses*`` directories and
    sentinel files.  Returns the count of removed/trashed items.
    """
    if on_delete == "keep" or not export_path.is_dir():
        return 0

    managed_files = _read_manifest(export_path)

    trash_dir: Optional[Path] = None
    if on_delete == "trash":
        date_str = datetime.datetime.now().strftime("%Y-%m-%d")
        trash_dir = export_path / ".b2ou-trash" / date_str

    def _dispose(path: Path, is_dir: bool = False) -> bool:
        try:
            if trash_dir:
                trash_dir.mkdir(parents=True, exist_ok=True)
                dest = trash_dir / path.name
                # Avoid collision in trash
                count = 2
                while dest.exists():
                    stem = path.stem if not is_dir else path.name
                    suffix = path.suffix if not is_dir else ""
                    dest = trash_dir / f"{stem} - {count:02d}{suffix}"
                    count += 1
                shutil.move(str(path), str(dest))
            else:
                if is_dir:
                    shutil.rmtree(path)
                else:
                    path.unlink()
            return True
        except OSError:
            return False

    removed = 0
    empty_dirs: list[Path] = []

    for root, dirs, files in os.walk(export_path, topdown=True):
        root_path = Path(root)
        keep_dirs: list[str] = []
        for d in dirs:
            if d in EXPORT_SKIP_DIRS or d == ".b2ou-trash":
                continue
            if any(d.startswith(pfx) for pfx in EXPORT_SKIP_DIR_PREFIXES):
                continue
            if d.endswith(".Ulysses_Public_Filter"):
                continue
            if d.endswith(".textbundle"):
                bundle = root_path / d
                if bundle not in expected_paths:
                    try:
                        rel = str(bundle.relative_to(export_path))
                    except ValueError:
                        rel = ""
                    # Only remove bundles that b2ou previously created
                    if rel and rel in managed_files:
                        if _dispose(bundle, is_dir=True):
                            removed += 1
                continue
            keep_dirs.append(d)
        dirs[:] = keep_dirs

        for fname in files:
            if fname in SENTINEL_FILES or fname == MANIFEST_NAME:
                continue
            fpath = root_path / fname
            if fpath in expected_paths:
                continue
            if any(fname.endswith(ext) for ext in (".md", ".txt", ".markdown")):
                # Only remove files that b2ou created (listed in manifest)
                try:
                    rel = str(fpath.relative_to(export_path))
                except ValueError:
                    continue
                if rel not in managed_files:
                    continue
                if _dispose(fpath):
                    removed += 1

        if root_path != export_path:
            empty_dirs.append(root_path)

    # Remove empty tag subdirectories (deepest first)
    for d in sorted(empty_dirs, reverse=True):
        try:
            if d.is_dir() and not list(d.iterdir()):
                d.rmdir()
        except OSError:
            pass

    return removed


def purge_old_trash(export_path: Path, max_age_days: int = 30) -> int:
    """Remove trash date-folders older than *max_age_days*.

    Returns the number of folders purged.
    """
    trash_root = export_path / ".b2ou-trash"
    if not trash_root.is_dir():
        return 0

    cutoff = datetime.datetime.now() - datetime.timedelta(days=max_age_days)
    removed = 0
    try:
        for entry in trash_root.iterdir():
            if not entry.is_dir():
                continue
            # Folder names are YYYY-MM-DD
            try:
                folder_date = datetime.datetime.strptime(entry.name, "%Y-%m-%d")
            except ValueError:
                continue
            if folder_date < cutoff:
                shutil.rmtree(entry, ignore_errors=True)
                removed += 1
                log.debug("Purged old trash folder: %s", entry.name)
    except OSError:
        pass

    # Remove trash root if empty
    try:
        if trash_root.is_dir() and not list(trash_root.iterdir()):
            trash_root.rmdir()
    except OSError:
        pass

    return removed


# ---------------------------------------------------------------------------
# Maintenance throttling
# ---------------------------------------------------------------------------

_MAINTENANCE_MARKER = ".b2ou-maintenance"


def maintenance_due(export_path: Path, min_interval_hours: float = 6.0) -> bool:
    """Return True when heavy maintenance should run for *export_path*."""
    marker = export_path / _MAINTENANCE_MARKER
    try:
        last = float(marker.read_text().strip())
    except Exception:
        return True
    return (time.time() - last) >= (min_interval_hours * 3600)


def touch_maintenance(export_path: Path) -> None:
    """Update maintenance marker for *export_path*."""
    try:
        (export_path / _MAINTENANCE_MARKER).write_text(
            str(time.time()), encoding="utf-8"
        )
    except OSError:
        pass


def cleanup_orphan_root_images(config: ExportConfig) -> int:
    """
    Remove root-level images that are no longer referenced by any note
    and already have a canonical copy in the BearImages assets folder.
    """
    if not config.export_path.is_dir():
        return 0

    referenced = collect_referenced_local_images(
        config.export_path, EXPORT_SKIP_DIRS
    )
    asset_basenames: set[str] = set()
    if config.assets_path and config.assets_path.is_dir():
        for _, _, files in os.walk(config.assets_path):
            asset_basenames.update(files)

    removed = 0
    try:
        root_files = list(config.export_path.iterdir())
    except OSError:
        return 0

    for fpath in root_files:
        if not fpath.is_file():
            continue
        if fpath.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        if fpath in referenced:
            continue
        if fpath.name not in asset_basenames:
            continue
        try:
            fpath.unlink()
            removed += 1
            log.debug("Removed orphan root image: %s", fpath.name)
        except OSError:
            pass

    return removed


# ---------------------------------------------------------------------------
# TextBundle export
# ---------------------------------------------------------------------------

def make_text_bundle(
    text: str,
    filepath: Path,
    mod_unix: float,
    created_core_data: float,
    conn,
    note_pk: int,
    bear_image_path: Path,
    note_uuid: str = "",
    bear_file_path: Path | None = None,
) -> None:
    """Write a ``.textbundle`` for *text* at *filepath* (without extension).

    Uses atomic creation: build in a temporary directory, then rename into
    place so readers never see a half-written bundle.
    """
    import tempfile

    bundle_path = Path(str(filepath) + ".textbundle")
    existing_assets = bundle_path / "assets" if bundle_path.exists() else None
    # Build in a temp dir next to the final location, then rename
    tmp_dir = tempfile.mkdtemp(
        prefix=".b2ou-tb-", dir=bundle_path.parent,
    )
    tmp_bundle = Path(tmp_dir)
    tmp_assets = tmp_bundle / "assets"
    tmp_assets.mkdir(parents=True, exist_ok=True)

    info = json.dumps(
        {
            "transient": True,
            "type": "net.daringfireball.markdown",
            "version": 2,
            "creatorIdentifier": "net.shinyfrog.bear",
            "bear_uuid": note_uuid,
        }
    )

    try:
        text = process_export_images_textbundle(
            text, tmp_assets, conn, note_pk, bear_image_path,
            bear_file_path=bear_file_path,
            existing_assets=existing_assets,
        )

        write_note_file(tmp_bundle / "text.md", text, mod_unix, 0)
        write_note_file(tmp_bundle / "info.json", info, mod_unix, 0)

        # Atomic swap: remove old bundle if it exists, rename temp into place
        if bundle_path.exists():
            shutil.rmtree(bundle_path)
        os.rename(tmp_bundle, bundle_path)
        os.utime(bundle_path, (-1, mod_unix))
    except Exception:
        # Clean up temp on failure
        shutil.rmtree(tmp_bundle, ignore_errors=True)
        raise


# ---------------------------------------------------------------------------
# Timestamp files
# ---------------------------------------------------------------------------

def write_timestamps(config: ExportConfig) -> None:
    """Write the ``export-time.log`` sentinel file."""
    msg = "Export from Bear written at: " + datetime.datetime.now().strftime(
        "%Y-%m-%d at %H:%M:%S"
    )
    path = config.export_ts_file
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(msg, encoding="utf-8")


def check_db_modified(config: ExportConfig) -> bool:
    """Return True if Bear's database is newer than the last export timestamp."""
    try:
        configs = config.split_export_configs()
    except Exception:
        return True

    for cfg in configs:
        if not cfg.export_ts_file.exists():
            return True
        try:
            db_mtime = cfg.bear_db.stat().st_mtime
            ts_mtime = cfg.export_ts_file.stat().st_mtime
            if db_mtime > ts_mtime:
                return True
        except OSError:
            return True
    return False


# ---------------------------------------------------------------------------
# Main export entry point
# ---------------------------------------------------------------------------

def _acquire_lock(export_path: Path):
    """Acquire an exclusive lock on ``.b2ou.lock`` in the export folder.

    Returns the open file handle (caller must keep it alive until done)
    or ``None`` if the lock cannot be acquired.
    """
    lock_path = export_path / ".b2ou.lock"
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fh = open(lock_path, "w")  # noqa: SIM115
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fh
    except OSError:
        return None


def export_notes(config: ExportConfig) -> tuple[int, set[Path], int]:
    """
    Export all non-trashed, non-archived Bear notes to *config.export_path*.

    Returns ``(note_count, expected_paths, changed_count)`` where:
    - *note_count* is the total number of visible notes
    - *expected_paths* is the set of paths that should exist on disk
    - *changed_count* is the number of notes actually written (not skipped)
    - If the export lock is already held, *changed_count* will be ``-1``.

    The *changed_count* lets callers skip expensive cleanup when nothing
    changed.
    """
    lock_fh = _acquire_lock(config.export_path)
    if lock_fh is None:
        log.warning("Another b2ou instance is already exporting to %s — skipping.",
                     config.export_path)
        return 0, set(), -1

    conn, tmp_path = copy_and_open(config.bear_db)
    note_count = 0
    changed_count = 0
    expected_paths: set[Path] = set()
    reserved_targets: set[Path] = set()

    def _target_for(base_path: Path, as_textbundle: bool) -> Path:
        suffix = ".textbundle" if as_textbundle else ".md"
        return Path(str(base_path) + suffix)

    def _unique_base_path(
        base_path: Path,
        as_textbundle: bool,
        note_uuid: str,
    ) -> Path:
        target = _target_for(base_path, as_textbundle)
        if target not in reserved_targets:
            reserved_targets.add(target)
            return base_path

        tagged = base_path.parent / f"{base_path.name} - {note_uuid[:8]}"
        tagged_target = _target_for(tagged, as_textbundle)
        if tagged_target not in reserved_targets:
            reserved_targets.add(tagged_target)
            return tagged

        count = 2
        while True:
            candidate = base_path.parent / f"{tagged.name} - {count:02d}"
            candidate_target = _target_for(candidate, as_textbundle)
            if candidate_target not in reserved_targets:
                reserved_targets.add(candidate_target)
                return candidate
            count += 1

    try:
        config.export_path.mkdir(parents=True, exist_ok=True)

        for note in iter_notes(conn):
            filename = generate_filename(note, config.naming)
            mod_unix = core_data_to_unix(note.modified_date)

            # Tag filtering uses raw text to check tags before expensive
            # markdown processing.  normalise_bear_markdown is deferred
            # until after the incremental-skip check below.
            raw_text = note.text

            if config.make_tag_folders:
                file_list = sub_path_from_tag(
                    str(config.export_path),
                    filename,
                    raw_text,
                    make_tag_folders=True,
                    multi_tag_folders=config.multi_tag_folders,
                    only_export_tags=config.only_export_tags,
                    exclude_tags=config.exclude_tags,
                )
            else:
                is_excluded = any(
                    ("#" + tag) in raw_text for tag in config.exclude_tags
                )
                file_list = (
                    []
                    if is_excluded
                    else [str(config.export_path / filename)]
                )

            if not file_list:
                continue

            seen_paths: set[str] = set()
            for filepath_str in file_list:
                if filepath_str in seen_paths:
                    continue
                seen_paths.add(filepath_str)

                filepath = Path(filepath_str)
                note_count += 1
                as_textbundle = (
                    config.export_as_textbundles
                    and _should_use_textbundle(raw_text, filepath, config)
                )
                filepath = _unique_base_path(filepath, as_textbundle, note.uuid)
                target = _target_for(filepath, as_textbundle)

                # ── Incremental skip ──────────────────────────────────────
                if target.exists() and target.stat().st_mtime >= mod_unix:
                    expected_paths.add(target)
                    continue

                # ── Markdown processing (deferred until needed) ───────────
                text = normalise_bear_markdown(raw_text)

                front_matter = ""
                if config.yaml_front_matter:
                    front_matter = generate_front_matter(note, text)

                if config.hide_tags:
                    text = hide_tags(text)

                # ── Full export ───────────────────────────────────────────
                changed_count += 1
                if as_textbundle:
                    make_text_bundle(
                        front_matter + text, filepath, mod_unix,
                        note.creation_date, conn, note.pk,
                        config.bear_image_path, note_uuid=note.uuid,
                        bear_file_path=config.bear_file_path,
                    )
                    expected_paths.add(target)
                elif config.export_image_repository:
                    processed = process_export_images(
                        text, filepath, conn, note.pk,
                        config.bear_image_path,
                        config.assets_path,
                        config.export_path,
                        bear_file_path=config.bear_file_path,
                    )
                    write_note_file(
                        target, front_matter + processed,
                        mod_unix, note.creation_date,
                    )
                    expected_paths.add(target)
                else:
                    write_note_file(
                        target, front_matter + text,
                        mod_unix, note.creation_date,
                    )
                    expected_paths.add(target)

    finally:
        conn.close()
        if tmp_path and tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        # Write manifest so cleanup knows which files b2ou created
        if expected_paths:
            _write_manifest(config.export_path, expected_paths)
        if lock_fh:
            try:
                fcntl.flock(lock_fh, fcntl.LOCK_UN)
                lock_fh.close()
            except OSError:
                pass

    return note_count, expected_paths, changed_count


def _should_use_textbundle(
    text: str, filepath: Path, config: ExportConfig
) -> bool:
    """True if this note should be exported as a .textbundle."""
    if not config.export_as_hybrids:
        return True
    tb = Path(str(filepath) + ".textbundle")
    if tb.exists():
        return True
    from b2ou.constants import RE_BEAR_IMAGE
    return bool(RE_BEAR_IMAGE.search(text) or __import__("re").search(r"!\[", text))
