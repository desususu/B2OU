"""Tests for b2ou.export — front matter, filenames, cleanup, timestamps."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from b2ou.constants import CORE_DATA_EPOCH
from b2ou.db import BearNote


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _note(
    title: str = "Test Note",
    text: str = "Hello #world",
    uuid: str = "AABBCCDD-1234-5678-9012-ABCDEF123456",
    pk: int = 1,
    creation_ts: float = 700_000_000.0,   # Core Data timestamp
    modified_ts: float = 700_000_100.0,
) -> BearNote:
    return BearNote(
        title=title, text=text, uuid=uuid, pk=pk,
        creation_date=creation_ts, modified_date=modified_ts,
    )


# ---------------------------------------------------------------------------
# generate_front_matter
# ---------------------------------------------------------------------------

def test_generate_front_matter_basic():
    from b2ou.export import generate_front_matter

    note = _note(title="My Note", text="Hello #tag1 #tag2")
    fm = generate_front_matter(note, "Hello #tag1 #tag2")
    assert fm.startswith("---\n")
    assert fm.endswith("---\n\n")
    assert "title: My Note" in fm
    assert "bear_id: AABBCCDD" in fm
    assert "  - tag1" in fm
    assert "  - tag2" in fm
    assert "created:" in fm
    assert "modified:" in fm


def test_generate_front_matter_special_chars():
    from b2ou.export import generate_front_matter

    note = _note(title='Title: "with quotes"')
    fm = generate_front_matter(note, "no tags")
    assert 'title: "Title: \\"with quotes\\""' in fm
    assert "tags:" not in fm


def test_generate_front_matter_empty_title():
    from b2ou.export import generate_front_matter

    note = _note(title="")
    fm = generate_front_matter(note, "text")
    assert 'title: ""' in fm


# ---------------------------------------------------------------------------
# generate_filename
# ---------------------------------------------------------------------------

def test_generate_filename_title():
    from b2ou.export import generate_filename

    note = _note(title="My Great Note!")
    assert generate_filename(note, "title") == "My Great Note!"


def test_generate_filename_slug():
    from b2ou.export import generate_filename

    note = _note(title="My Great Note!")
    result = generate_filename(note, "slug")
    assert result == "my-great-note"


def test_generate_filename_date_title():
    from b2ou.export import generate_filename

    note = _note(title="Hello World")
    result = generate_filename(note, "date-title")
    # Should start with a date prefix
    assert result.startswith("20")
    assert "hello-world" in result


def test_generate_filename_id():
    from b2ou.export import generate_filename

    note = _note(uuid="AABBCCDD-1234-5678-9012-ABCDEF123456")
    assert generate_filename(note, "id") == "AABBCCDD"


def test_generate_filename_empty_title_slug():
    from b2ou.export import generate_filename

    note = _note(title="")
    assert generate_filename(note, "slug") == "untitled"

def test_is_untitled_placeholder():
    from b2ou.export import _is_untitled_placeholder

    assert _is_untitled_placeholder(_note(title="", text=""))
    assert _is_untitled_placeholder(_note(title="", text="#"))
    assert _is_untitled_placeholder(_note(title="", text="  #  "))
    assert _is_untitled_placeholder(_note(title="", text="##\n#\n"))
    assert not _is_untitled_placeholder(_note(title="Untitled", text="#"))
    assert not _is_untitled_placeholder(_note(title="", text="#tag"))


# ---------------------------------------------------------------------------
# write_note_file
# ---------------------------------------------------------------------------

def test_write_note_file(tmp_path):
    from b2ou.export import write_note_file

    filepath = tmp_path / "test.md"
    write_note_file(filepath, "# Hello\nWorld", 1700000000.0, 0)
    assert filepath.read_text() == "# Hello\nWorld"
    assert filepath.stat().st_mtime == pytest.approx(1700000000.0, abs=1)


def test_write_note_file_creates_parents(tmp_path):
    from b2ou.export import write_note_file

    filepath = tmp_path / "sub" / "dir" / "note.md"
    write_note_file(filepath, "content", 1700000000.0, 0)
    assert filepath.exists()


# ---------------------------------------------------------------------------
# cleanup_stale_notes
# ---------------------------------------------------------------------------

def test_cleanup_stale_notes_trash(tmp_path):
    from b2ou.export import _write_manifest, cleanup_stale_notes

    # Create exported files and register in manifest
    (tmp_path / "keep.md").write_text("keep")
    (tmp_path / "stale.md").write_text("stale")
    _write_manifest(tmp_path, {tmp_path / "keep.md", tmp_path / "stale.md"})

    expected = {tmp_path / "keep.md"}
    removed = cleanup_stale_notes(tmp_path, expected, "trash")
    assert removed == 1
    assert (tmp_path / "keep.md").exists()
    assert not (tmp_path / "stale.md").exists()
    # Should be in trash
    trash = tmp_path / ".b2ou-trash"
    assert trash.exists()


def test_cleanup_stale_notes_remove(tmp_path):
    from b2ou.export import _write_manifest, cleanup_stale_notes

    (tmp_path / "stale.md").write_text("gone")
    _write_manifest(tmp_path, {tmp_path / "stale.md"})
    removed = cleanup_stale_notes(tmp_path, set(), "remove")
    assert removed == 1
    assert not (tmp_path / "stale.md").exists()
    assert not (tmp_path / ".b2ou-trash").exists()


def test_cleanup_stale_notes_preserves_user_files(tmp_path):
    """Files NOT in the manifest should never be deleted."""
    from b2ou.export import cleanup_stale_notes

    (tmp_path / "user-note.md").write_text("my personal notes")
    # No manifest entry for this file
    removed = cleanup_stale_notes(tmp_path, set(), "remove")
    assert removed == 0
    assert (tmp_path / "user-note.md").exists()


def test_cleanup_stale_notes_keep(tmp_path):
    from b2ou.export import cleanup_stale_notes

    (tmp_path / "stale.md").write_text("stay")
    removed = cleanup_stale_notes(tmp_path, set(), "keep")
    assert removed == 0
    assert (tmp_path / "stale.md").exists()


def test_cleanup_stale_notes_skips_sentinel(tmp_path):
    from b2ou.export import cleanup_stale_notes

    (tmp_path / ".export-time.log").write_text("sentinel")
    removed = cleanup_stale_notes(tmp_path, set(), "remove")
    assert removed == 0
    assert (tmp_path / ".export-time.log").exists()


# ---------------------------------------------------------------------------
# write_timestamps / check_db_modified
# ---------------------------------------------------------------------------

def test_write_and_check_timestamps(tmp_path):
    from b2ou.config import ExportConfig
    from b2ou.export import check_db_modified, write_timestamps

    cfg = ExportConfig(export_path=tmp_path / "out")
    cfg.export_path.mkdir()

    # Before any export, should return True
    assert check_db_modified(cfg) is True

    # Simulate a DB file
    db_file = cfg.bear_db
    db_file.parent.mkdir(parents=True, exist_ok=True)
    db_file.write_text("fake db")

    write_timestamps(cfg)
    assert cfg.export_ts_file.exists()

    # DB is now "older" than the timestamp (same or older mtime)
    # Touch the ts file to be newer
    import time
    time.sleep(0.05)
    cfg.export_ts_file.write_text("updated")
    assert check_db_modified(cfg) is False

    # Touch the DB to be newer
    time.sleep(0.05)
    db_file.write_text("modified db")
    assert check_db_modified(cfg) is True


# ---------------------------------------------------------------------------
# _yaml_escape
# ---------------------------------------------------------------------------

def test_yaml_escape():
    from b2ou.export import _yaml_escape

    assert _yaml_escape("simple") == "simple"
    assert _yaml_escape("has: colon") == '"has: colon"'
    assert _yaml_escape('has "quotes"') == '"has \\"quotes\\""'
    assert _yaml_escape("") == '""'
