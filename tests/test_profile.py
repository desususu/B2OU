"""Tests for b2ou.profile — TOML config file loading."""

from __future__ import annotations

from pathlib import Path

import pytest

from b2ou.profile import _parse_profile, find_config, load_profiles


def test_parse_profile_minimal():
    cfg = _parse_profile("test", {"out": "/tmp/notes"})
    assert cfg.export_path == Path("/tmp/notes")
    assert cfg.export_format == "md"
    assert cfg.naming == "title"
    assert cfg.on_delete == "trash"


def test_parse_profile_full():
    cfg = _parse_profile("blog", {
        "out": "~/blog/posts",
        "format": "md",
        "tag-folders": True,
        "hide-tags": True,
        "yaml-front-matter": True,
        "naming": "date-title",
        "on-delete": "keep",
        "exclude-tags": ["private", "draft"],
        "only-tags": ["blog"],
    })
    assert cfg.export_path == Path("~/blog/posts").expanduser()
    assert cfg.make_tag_folders is True
    assert cfg.hide_tags is True
    assert cfg.yaml_front_matter is True
    assert cfg.naming == "date-title"
    assert cfg.on_delete == "keep"
    assert cfg.exclude_tags == ["private", "draft"]
    assert cfg.only_export_tags == ["blog"]


def test_parse_profile_textbundle_alias():
    cfg = _parse_profile("tb", {"out": "/tmp/tb", "format": "textbundle"})
    assert cfg.export_format == "tb"


def test_parse_profile_missing_out():
    with pytest.raises(ValueError, match="missing required 'out'"):
        _parse_profile("bad", {"format": "md"})


def test_find_config_explicit(tmp_path):
    toml_file = tmp_path / "custom.toml"
    toml_file.write_text("[profile.test]\nout = '/tmp'\n")
    assert find_config(str(toml_file)) == toml_file


def test_find_config_explicit_missing(tmp_path):
    assert find_config(str(tmp_path / "nonexistent.toml")) is None


def test_load_profiles_from_file(tmp_path):
    toml_file = tmp_path / "b2ou.toml"
    toml_file.write_text("""\
[profile.notes]
out = "/tmp/notes"
format = "md"
yaml-front-matter = true

[profile.backup]
out = "/tmp/backup"
format = "textbundle"
on-delete = "keep"
""")
    profiles = load_profiles(str(toml_file))
    assert "notes" in profiles
    assert "backup" in profiles
    assert profiles["notes"].yaml_front_matter is True
    assert profiles["backup"].export_format == "tb"
    assert profiles["backup"].on_delete == "keep"


def test_load_profiles_empty_file(tmp_path):
    toml_file = tmp_path / "b2ou.toml"
    toml_file.write_text("# empty config\n")
    profiles = load_profiles(str(toml_file))
    assert profiles == {}


def test_load_profiles_no_file():
    profiles = load_profiles("/nonexistent/path/b2ou.toml")
    assert profiles == {}
