"""Tests for b2ou.images — attachment export (images + files)."""

from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_db(tmp_path: Path) -> sqlite3.Connection:
    """Create an in-memory SQLite DB mimicking Bear's schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute(
        "CREATE TABLE ZSFNOTE ("
        "  Z_PK INTEGER PRIMARY KEY,"
        "  ZTITLE TEXT,"
        "  ZTEXT TEXT,"
        "  ZCREATIONDATE REAL,"
        "  ZMODIFICATIONDATE REAL,"
        "  ZUNIQUEIDENTIFIER TEXT,"
        "  ZTRASHED INTEGER DEFAULT 0,"
        "  ZARCHIVED INTEGER DEFAULT 0"
        ")"
    )
    conn.execute(
        "CREATE TABLE ZSFNOTEFILE ("
        "  Z_PK INTEGER PRIMARY KEY,"
        "  ZFILENAME TEXT,"
        "  ZUNIQUEIDENTIFIER TEXT,"
        "  ZNOTE INTEGER"
        ")"
    )
    return conn


def _add_note(conn: sqlite3.Connection, pk: int = 1, title: str = "Test") -> int:
    conn.execute(
        "INSERT INTO ZSFNOTE (Z_PK, ZTITLE, ZTEXT, ZCREATIONDATE, "
        "ZMODIFICATIONDATE, ZUNIQUEIDENTIFIER) VALUES (?, ?, '', 0, 0, 'note-uuid')",
        (pk, title),
    )
    return pk


def _add_file(conn: sqlite3.Connection, filename: str, uuid: str, note_pk: int = 1):
    conn.execute(
        "INSERT INTO ZSFNOTEFILE (ZFILENAME, ZUNIQUEIDENTIFIER, ZNOTE) "
        "VALUES (?, ?, ?)",
        (filename, uuid, note_pk),
    )


def _create_source_file(base_dir: Path, uuid: str, filename: str, content: bytes = b"data"):
    """Create a file at base_dir/uuid/filename."""
    d = base_dir / uuid
    d.mkdir(parents=True, exist_ok=True)
    (d / filename).write_bytes(content)


# ---------------------------------------------------------------------------
# _find_attachment
# ---------------------------------------------------------------------------

class TestFindAttachment:
    def test_finds_in_image_path(self, tmp_path):
        from b2ou.images import _find_attachment

        img_dir = tmp_path / "Note Images"
        _create_source_file(img_dir, "uuid1", "photo.jpg")

        result = _find_attachment("uuid1", "photo.jpg", img_dir)
        assert result is not None
        assert result.exists()

    def test_finds_in_file_path(self, tmp_path):
        from b2ou.images import _find_attachment

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        _create_source_file(file_dir, "uuid2", "video.mp4")

        # Not in Note Images
        result = _find_attachment("uuid2", "video.mp4", img_dir)
        assert result is None

        # Found in Note Files
        result = _find_attachment("uuid2", "video.mp4", img_dir, file_dir)
        assert result is not None
        assert result.exists()

    def test_prefers_image_path(self, tmp_path):
        from b2ou.images import _find_attachment

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        _create_source_file(img_dir, "uuid3", "file.pdf", b"img-ver")
        _create_source_file(file_dir, "uuid3", "file.pdf", b"file-ver")

        result = _find_attachment("uuid3", "file.pdf", img_dir, file_dir)
        assert result == img_dir / "uuid3" / "file.pdf"


# ---------------------------------------------------------------------------
# _is_image_file / _make_link
# ---------------------------------------------------------------------------

class TestLinkHelpers:
    def test_is_image_file(self):
        from b2ou.images import _is_image_file

        assert _is_image_file("photo.jpg") is True
        assert _is_image_file("photo.PNG") is True
        assert _is_image_file("video.mp4") is False
        assert _is_image_file("doc.pdf") is False

    def test_make_link_image(self):
        from b2ou.images import _make_link

        result = _make_link("photo.jpg", "BearImages/uuid/photo.jpg")
        assert result.startswith("![")

    def test_make_link_file(self):
        from b2ou.images import _make_link

        result = _make_link("video.mp4", "BearImages/uuid/video.mp4")
        assert result.startswith("[video.mp4]")
        assert "!" not in result.split("]")[0]


# ---------------------------------------------------------------------------
# process_export_images — file attachments
# ---------------------------------------------------------------------------

class TestProcessExportImages:
    def test_mp4_in_note_files_dir(self, tmp_path):
        """MP4 in Note Files/ should be exported and linked."""
        from b2ou.images import process_export_images

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        assets = tmp_path / "export" / "BearImages"
        export = tmp_path / "export"
        export.mkdir()

        conn = _make_db(tmp_path)
        _add_note(conn)
        _add_file(conn, "clip.mp4", "vid-uuid-1")
        _create_source_file(file_dir, "vid-uuid-1", "clip.mp4", b"fake-mp4")

        text = "# My Note\n\nSome text"
        result = process_export_images(
            text, export / "note", conn, 1,
            img_dir, assets, export,
            bear_file_path=file_dir,
        )

        # The MP4 should be linked at the end (unreferenced attachment)
        assert "clip.mp4" in result
        # Should use link syntax, not image syntax
        assert "[clip.mp4](" in result
        # File should be copied
        assert (assets / "vid-uuid-1" / "clip.mp4").exists()

    def test_pdf_in_note_files_dir(self, tmp_path):
        """PDF in Note Files/ should be exported with link syntax."""
        from b2ou.images import process_export_images

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        assets = tmp_path / "export" / "BearImages"
        export = tmp_path / "export"
        export.mkdir()

        conn = _make_db(tmp_path)
        _add_note(conn)
        _add_file(conn, "doc.pdf", "pdf-uuid-1")
        _create_source_file(file_dir, "pdf-uuid-1", "doc.pdf", b"fake-pdf")

        text = "# My Note"
        result = process_export_images(
            text, export / "note", conn, 1,
            img_dir, assets, export,
            bear_file_path=file_dir,
        )

        assert "[doc.pdf](" in result
        assert (assets / "pdf-uuid-1" / "doc.pdf").exists()

    def test_image_still_uses_image_syntax(self, tmp_path):
        """Images should still use ![](path) syntax."""
        from b2ou.images import process_export_images

        img_dir = tmp_path / "Note Images"
        assets = tmp_path / "export" / "BearImages"
        export = tmp_path / "export"
        export.mkdir()

        conn = _make_db(tmp_path)
        _add_note(conn)
        _add_file(conn, "photo.jpg", "img-uuid-1")
        _create_source_file(img_dir, "img-uuid-1", "photo.jpg", b"fake-jpg")

        text = "# My Note\n\n![](photo.jpg)"
        result = process_export_images(
            text, export / "note", conn, 1,
            img_dir, assets, export,
        )

        assert "![](BearImages/" in result
        assert (assets / "img-uuid-1" / "photo.jpg").exists()

    def test_bear1_file_syntax(self, tmp_path):
        """[file:UUID/filename] should be rewritten to proper link."""
        from b2ou.images import process_export_images

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        assets = tmp_path / "export" / "BearImages"
        export = tmp_path / "export"
        export.mkdir()

        conn = _make_db(tmp_path)
        _add_note(conn)
        _create_source_file(file_dir, "abc123", "presentation.pptx", b"fake-pptx")

        text = "# My Note\n\n[file:abc123/presentation.pptx]"
        result = process_export_images(
            text, export / "note", conn, 1,
            img_dir, assets, export,
            bear_file_path=file_dir,
        )

        assert "[file:" not in result
        assert "[presentation.pptx](" in result
        assert (assets / "abc123" / "presentation.pptx").exists()

    def test_bear1_image_syntax(self, tmp_path):
        """[image:UUID/filename] should still work."""
        from b2ou.images import process_export_images

        img_dir = tmp_path / "Note Images"
        assets = tmp_path / "export" / "BearImages"
        export = tmp_path / "export"
        export.mkdir()

        conn = _make_db(tmp_path)
        _add_note(conn)
        _create_source_file(img_dir, "img-uuid", "pic.png", b"fake-png")

        text = "# My Note\n\n[image:img-uuid/pic.png]"
        result = process_export_images(
            text, export / "note", conn, 1,
            img_dir, assets, export,
        )

        assert "[image:" not in result
        assert "![](BearImages/" in result
        assert (assets / "img-uuid" / "pic.png").exists()

    def test_mixed_images_and_files(self, tmp_path):
        """Notes with both images and file attachments."""
        from b2ou.images import process_export_images

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        assets = tmp_path / "export" / "BearImages"
        export = tmp_path / "export"
        export.mkdir()

        conn = _make_db(tmp_path)
        _add_note(conn)
        _add_file(conn, "photo.jpg", "img-uuid")
        _add_file(conn, "video.mp4", "vid-uuid")
        _add_file(conn, "doc.pdf", "pdf-uuid")
        _create_source_file(img_dir, "img-uuid", "photo.jpg")
        _create_source_file(file_dir, "vid-uuid", "video.mp4")
        _create_source_file(file_dir, "pdf-uuid", "doc.pdf")

        text = "# My Note\n\n![](photo.jpg)"
        result = process_export_images(
            text, export / "note", conn, 1,
            img_dir, assets, export,
            bear_file_path=file_dir,
        )

        # Image was inline-referenced
        assert "![](BearImages/" in result
        # Non-image files appended as links
        assert "[video.mp4](" in result
        assert "[doc.pdf](" in result
        # All files copied
        assert (assets / "img-uuid" / "photo.jpg").exists()
        assert (assets / "vid-uuid" / "video.mp4").exists()
        assert (assets / "pdf-uuid" / "doc.pdf").exists()


# ---------------------------------------------------------------------------
# process_export_images_textbundle — file attachments
# ---------------------------------------------------------------------------

class TestProcessExportImagesTextbundle:
    def test_file_attachment_in_textbundle(self, tmp_path):
        """Non-image files should be included in TextBundle assets."""
        from b2ou.images import process_export_images_textbundle

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        bundle_assets = tmp_path / "bundle" / "assets"
        bundle_assets.mkdir(parents=True)

        conn = _make_db(tmp_path)
        _add_note(conn)
        _add_file(conn, "video.mp4", "vid-uuid")
        _create_source_file(file_dir, "vid-uuid", "video.mp4", b"fake-mp4")

        text = "# My Note"
        result = process_export_images_textbundle(
            text, bundle_assets, conn, 1,
            img_dir, bear_file_path=file_dir,
        )

        assert "video.mp4" in result
        assert (bundle_assets / "vid-uuid_video.mp4").exists()

    def test_bear1_file_in_textbundle(self, tmp_path):
        """[file:UUID/filename] in TextBundle mode."""
        from b2ou.images import process_export_images_textbundle

        img_dir = tmp_path / "Note Images"
        file_dir = tmp_path / "Note Files"
        bundle_assets = tmp_path / "bundle" / "assets"
        bundle_assets.mkdir(parents=True)

        conn = _make_db(tmp_path)
        _add_note(conn)
        _create_source_file(file_dir, "abc", "slides.pptx", b"fake")

        text = "# My Note\n\n[file:abc/slides.pptx]"
        result = process_export_images_textbundle(
            text, bundle_assets, conn, 1,
            img_dir, bear_file_path=file_dir,
        )

        assert "[file:" not in result
        assert "[slides.pptx](" in result
        assert (bundle_assets / "abc_slides.pptx").exists()
