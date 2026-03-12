"""Tests for b2ou.i18n — internationalization module."""

from __future__ import annotations

import pytest


class TestTranslation:
    def test_default_language_is_english(self):
        from b2ou.i18n import get_language, t
        # After import, default should be 'en'
        assert get_language() == "en"
        assert t("menu.export_now") == "Export Now"

    def test_set_language_to_chinese(self):
        from b2ou.i18n import set_language, get_language, t
        set_language("zh")
        assert get_language() == "zh"
        assert t("menu.quit") == "\u9000\u51fa"
        # Reset to English for other tests
        set_language("en")

    def test_set_language_invalid_falls_back_to_english(self):
        from b2ou.i18n import set_language, get_language
        set_language("fr")
        assert get_language() == "en"

    def test_missing_key_returns_key_itself(self):
        from b2ou.i18n import set_language, t
        set_language("en")
        assert t("nonexistent.key") == "nonexistent.key"

    def test_chinese_missing_key_falls_back_to_english(self):
        from b2ou.i18n import set_language, t
        set_language("zh")
        # If a key exists in EN but not ZH, it should fall back to EN
        # All keys should be in both, but let's verify the fallback mechanism
        result = t("nonexistent.key")
        assert result == "nonexistent.key"
        set_language("en")

    def test_all_en_keys_exist_in_zh(self):
        from b2ou.i18n import _STRINGS
        en_keys = set(_STRINGS["en"].keys())
        zh_keys = set(_STRINGS["zh"].keys())
        missing = en_keys - zh_keys
        assert not missing, f"Keys missing in Chinese: {missing}"

    def test_all_zh_keys_exist_in_en(self):
        from b2ou.i18n import _STRINGS
        en_keys = set(_STRINGS["en"].keys())
        zh_keys = set(_STRINGS["zh"].keys())
        extra = zh_keys - en_keys
        assert not extra, f"Extra keys in Chinese not in English: {extra}"

    def test_t_returns_string(self):
        from b2ou.i18n import set_language, t
        for lang in ("en", "zh"):
            set_language(lang)
            for key in ("menu.export_now", "settings.title", "help.format"):
                result = t(key)
                assert isinstance(result, str)
                assert len(result) > 0
        set_language("en")

    def test_format_strings_have_placeholders(self):
        from b2ou.i18n import _STRINGS
        # Verify format-style strings work in both languages
        for lang in ("en", "zh"):
            table = _STRINGS[lang]
            # These should contain {count}
            assert "{count" in table["menu.notes_exported"]
            # These should contain {path}
            assert "{path}" in table["wizard.ready_msg"]
            assert "{path}" in table["settings.applied_msg"]

    def test_detect_system_language_returns_valid(self):
        from b2ou.i18n import detect_system_language
        lang = detect_system_language()
        assert lang in ("en", "zh")


try:
    import objc  # noqa: F401
    _has_objc = True
except ImportError:
    _has_objc = False


@pytest.mark.skipif(not _has_objc, reason="PyObjC not available (macOS only)")
class TestSettingsValues:
    def test_defaults(self):
        from b2ou.settings_panel import SettingsValues
        v = SettingsValues()
        assert v.export_path == ""
        assert v.export_format == "md"
        assert v.yaml_front_matter is False
        assert v.tag_folders is False
        assert v.hide_tags is False
        assert v.auto_start is True
        assert v.naming == "title"
        assert v.on_delete == "trash"
        assert v.exclude_tags == ""

    def test_custom_values(self):
        from b2ou.settings_panel import SettingsValues
        v = SettingsValues(
            export_path="/tmp/test",
            export_format="tb",
            yaml_front_matter=True,
            tag_folders=True,
            hide_tags=True,
            auto_start=False,
            naming="slug",
            on_delete="remove",
            exclude_tags="private, draft",
        )
        assert v.export_path == "/tmp/test"
        assert v.export_format == "tb"
        assert v.yaml_front_matter is True
        assert v.naming == "slug"
        assert v.exclude_tags == "private, draft"
