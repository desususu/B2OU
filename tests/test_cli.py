"""Tests for b2ou.cli — argument parsing and subcommand routing."""

from __future__ import annotations

import pytest

from b2ou.cli import main


def test_main_no_args(capsys):
    """No subcommand prints help and returns 0."""
    rc = main([])
    assert rc == 0
    captured = capsys.readouterr()
    assert "COMMAND" in captured.out or "usage" in captured.out.lower()


def test_export_missing_out(capsys):
    """export --profile and --out both missing should fail."""
    with pytest.raises(SystemExit):
        main(["export", "--force"])


def test_status_missing_out():
    """status requires --out."""
    with pytest.raises(SystemExit):
        main(["status"])


def test_clean_missing_out():
    """clean requires --out."""
    with pytest.raises(SystemExit):
        main(["clean"])


def test_clean_nonexistent_dir(tmp_path, capsys):
    """clean on nonexistent dir returns 1."""
    rc = main(["clean", "--out", str(tmp_path / "nope"), "--yes"])
    assert rc == 1
