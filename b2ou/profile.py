"""
TOML profile loader for b2ou.

Discovers and parses ``b2ou.toml`` config files with ``[profile.*]``
sections, converting each into an :class:`~b2ou.config.ExportConfig`.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Optional

from b2ou.config import ExportConfig

log = logging.getLogger(__name__)

# Python 3.11+ has tomllib in stdlib; fall back to tomli for older versions.
try:
    import tomllib  # type: ignore[import]
except ModuleNotFoundError:
    try:
        import tomli as tomllib  # type: ignore[import,no-redef]
    except ModuleNotFoundError:
        tomllib = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# Config discovery
# ---------------------------------------------------------------------------

_SEARCH_PATHS = [
    Path.cwd() / "b2ou.toml",
    Path.home() / ".config" / "b2ou" / "b2ou.toml",
    Path.home() / "b2ou.toml",
]


def find_config(explicit: Optional[str] = None) -> Optional[Path]:
    """Return the first ``b2ou.toml`` that exists, or *explicit* if given."""
    if explicit:
        p = Path(explicit).expanduser()
        return p if p.is_file() else None
    for candidate in _SEARCH_PATHS:
        if candidate.is_file():
            return candidate
    return None


# ---------------------------------------------------------------------------
# Profile parsing
# ---------------------------------------------------------------------------

def _parse_profile(name: str, data: dict[str, Any]) -> ExportConfig:
    """Convert a ``[profile.<name>]`` dict into an ExportConfig."""
    out = data.get("out")
    if not out:
        raise ValueError(f"Profile '{name}' is missing required 'out' key")

    fmt = data.get("format", "md")
    if fmt == "textbundle":
        fmt = "tb"
    out_tb = data.get("out-tb")
    if fmt == "both" and not out_tb:
        raise ValueError(f"Profile '{name}' requires 'out-tb' when format=both")

    return ExportConfig(
        export_path=Path(out).expanduser(),
        export_path_tb=Path(out_tb).expanduser() if out_tb else None,
        export_format=fmt,
        make_tag_folders=data.get("tag-folders", False),
        multi_tag_folders=data.get("multi-tag-folders", True),
        hide_tags=data.get("hide-tags", False),
        only_export_tags=data.get("only-tags", []),
        exclude_tags=data.get("exclude-tags", []),
        yaml_front_matter=data.get("yaml-front-matter", False),
        naming=data.get("naming", "title"),
        on_delete=data.get("on-delete", "trash"),
    )


def load_profiles(
    config_path: Optional[str] = None,
) -> dict[str, ExportConfig]:
    """
    Load all ``[profile.*]`` sections from ``b2ou.toml``.

    Returns a dict mapping profile name → ExportConfig.
    Raises RuntimeError if tomllib/tomli is not available.
    """
    if tomllib is None:
        raise RuntimeError(
            "TOML support requires Python 3.11+ (tomllib) or the 'tomli' package"
        )

    path = find_config(config_path)
    if path is None:
        return {}

    with open(path, "rb") as f:
        data = tomllib.load(f)

    profiles: dict[str, ExportConfig] = {}
    for name, section in data.get("profile", {}).items():
        if not isinstance(section, dict):
            log.warning("Ignoring non-table profile entry: %s", name)
            continue
        try:
            profiles[name] = _parse_profile(name, section)
        except (ValueError, TypeError) as exc:
            log.warning("Skipping profile '%s': %s", name, exc)

    return profiles


def load_profile(
    name: str, config_path: Optional[str] = None
) -> ExportConfig:
    """Load a single named profile. Raises KeyError if not found."""
    profiles = load_profiles(config_path)
    if name not in profiles:
        available = ", ".join(sorted(profiles)) or "(none)"
        raise KeyError(
            f"Profile '{name}' not found. Available profiles: {available}"
        )
    return profiles[name]
