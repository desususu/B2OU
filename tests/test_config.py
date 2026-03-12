from pathlib import Path

from b2ou.config import ExportConfig


def test_export_config_defaults(tmp_path):
    cfg = ExportConfig(export_path=tmp_path / "out")
    assert cfg.export_path == tmp_path / "out"
    assert cfg.assets_path == tmp_path / "out" / "BearImages"
    assert cfg.export_format == "md"
    assert cfg.export_as_textbundles is False
    assert cfg.export_image_repository is True


def test_export_config_textbundle(tmp_path):
    cfg = ExportConfig(export_path=tmp_path / "out", export_format="tb")
    assert cfg.export_as_textbundles is True
    assert cfg.export_image_repository is False


def test_export_config_custom_assets(tmp_path):
    cfg = ExportConfig(
        export_path=tmp_path / "out",
        assets_path=tmp_path / "custom_assets",
    )
    assert cfg.assets_path == tmp_path / "custom_assets"


def test_export_ts_file(tmp_path):
    cfg = ExportConfig(export_path=tmp_path / "out")
    assert cfg.export_ts_file == tmp_path / "out" / ".export-time.log"
