"""
Configuration dataclass for b2ou export engine.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Default Bear paths (macOS only)
# ---------------------------------------------------------------------------

_HOME = Path.home()

DEFAULT_BEAR_DB = _HOME / (
    "Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear"
    "/Application Data/database.sqlite"
)

DEFAULT_BEAR_IMAGE_PATH = _HOME / (
    "Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear"
    "/Application Data/Local Files/Note Images"
)

DEFAULT_BEAR_FILE_PATH = _HOME / (
    "Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear"
    "/Application Data/Local Files/Note Files"
)


# ---------------------------------------------------------------------------
# Export config
# ---------------------------------------------------------------------------

@dataclass
class ExportConfig:
    """All settings for the Bear → disk export engine."""

    # ── Required paths ───────────────────────────────────────────────────
    export_path: Path
    export_path_tb: Optional[Path] = None  # used when export_format == "both"

    # ── Optional / defaulted paths ───────────────────────────────────────
    bear_db: Path = field(default_factory=lambda: DEFAULT_BEAR_DB)
    bear_image_path: Path = field(default_factory=lambda: DEFAULT_BEAR_IMAGE_PATH)
    bear_file_path: Path = field(default_factory=lambda: DEFAULT_BEAR_FILE_PATH)
    assets_path: Optional[Path] = None  # defaults to export_path/BearImages

    # ── Export format ────────────────────────────────────────────────────
    # 'md'  → plain Markdown + separate BearImages folder
    # 'tb'  → TextBundle (.textbundle) with embedded assets
    export_format: str = "md"

    # ── Tag / folder options ──────────────────────────────────────────────
    make_tag_folders: bool = False
    multi_tag_folders: bool = True
    hide_tags: bool = False
    only_export_tags: list[str] = field(default_factory=list)
    exclude_tags: list[str] = field(default_factory=list)

    # ── Metadata ─────────────────────────────────────────────────────────
    yaml_front_matter: bool = False

    # ── Filename strategy ────────────────────────────────────────────────
    # 'title'      → My Note Title.md
    # 'slug'       → my-note-title.md
    # 'date-title' → 2024-01-15-my-note-title.md
    # 'id'         → 12345678.md  (first 8 chars of Bear UUID)
    naming: str = "title"

    # ── Stale-file policy ────────────────────────────────────────────────
    # 'trash'  → move to .b2ou-trash/<date>/
    # 'remove' → hard delete
    # 'keep'   → never remove stale files
    on_delete: str = "trash"

    def __post_init__(self) -> None:
        self.export_path = Path(self.export_path)
        if self.export_path_tb is not None:
            self.export_path_tb = Path(self.export_path_tb)
        self.bear_db = Path(self.bear_db)
        self.bear_image_path = Path(self.bear_image_path)
        self.bear_file_path = Path(self.bear_file_path)

        if self.assets_path is None:
            self.assets_path = self.export_path / "BearImages"
        elif self.assets_path:
            self.assets_path = Path(str(self.assets_path))

    # ── Derived flags (read-only) ─────────────────────────────────────────

    @property
    def export_as_textbundles(self) -> bool:
        return self.export_format == "tb"

    @property
    def export_as_hybrids(self) -> bool:
        """TextBundle only when note actually contains images."""
        return self.export_format == "tb"

    @property
    def export_image_repository(self) -> bool:
        """Copy Bear images to a shared BearImages folder."""
        return self.export_format == "md"

    # ── Multi-format helpers ────────────────────────────────────────────

    def split_export_configs(self) -> list["ExportConfig"]:
        """Return one or two configs when exporting both formats."""
        if self.export_format != "both":
            return [self]
        if not self.export_path_tb:
            raise ValueError(
                "TextBundle output folder is required when format is 'both'."
            )
        if self.export_path_tb.resolve() == self.export_path.resolve():
            raise ValueError(
                "Markdown and TextBundle output folders must be different."
            )
        md_cfg = replace(
            self,
            export_format="md",
            export_path=self.export_path,
            export_path_tb=None,
            assets_path=None,
        )
        tb_cfg = replace(
            self,
            export_format="tb",
            export_path=self.export_path_tb,
            export_path_tb=None,
            assets_path=None,
        )
        return [md_cfg, tb_cfg]

    # ── Helpers ──────────────────────────────────────────────────────────

    @property
    def export_ts_file(self) -> Path:
        return self.export_path / ".export-time.log"
