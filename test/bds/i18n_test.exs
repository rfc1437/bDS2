defmodule BDS.I18nTest do
  use ExUnit.Case, async: true

  test "supported languages, normalization, and UI locale resolution follow the spec" do
    assert Enum.map(BDS.I18n.supported_languages(), & &1.code) == ["en", "de", "fr", "it", "es"]

    assert BDS.I18n.normalize_language("de-DE") == "de"
    assert BDS.I18n.normalize_language("FR_ca") == "fr"
    assert BDS.I18n.normalize_language("pt-BR") == "en"

    assert BDS.I18n.resolve_ui_locale("it-IT") == "it"
    assert BDS.I18n.resolve_ui_locale("es_ES.UTF-8") == "es"
    assert BDS.I18n.resolve_ui_locale(nil) == "en"

    assert BDS.I18n.resolve_render_locale("fr-FR") == "fr"
    assert BDS.I18n.resolve_render_locale("unknown") == "en"
  end

  test "format locale mapping uses the spec locale table" do
    assert BDS.I18n.format_locale("en") == "en-US"
    assert BDS.I18n.format_locale("de-DE") == "de-DE"
    assert BDS.I18n.format_locale("fr") == "fr-FR"
    assert BDS.I18n.format_locale("it-CH") == "it-IT"
    assert BDS.I18n.format_locale("es_MX") == "es-ES"
    assert BDS.I18n.format_locale("pt-BR") == "en-US"
  end

  test "gettext render translations resolve for supported locales" do
    assert BDS.Gettext.lgettext("de", "render", "Back to preview home") ==
             "Zurück zur Vorschau-Startseite"

    assert BDS.Gettext.lgettext("pt-BR", "render", "Back to preview home") ==
             "Back to preview home"
  end

  test "gettext ui translations resolve for supported locales" do
    BDS.Gettext.put_locale("de")
    assert Gettext.dgettext(BDS.Gettext, "ui", "Posts") == "Beiträge"
    BDS.Gettext.put_locale("en")
  end

  test "gettext falls back to the msgid for missing translations" do
    assert BDS.Gettext.lgettext("de", "ui", "totally.missing.key.12345") ==
             "totally.missing.key.12345"
  end

  test "supported non-english locales translate representative keys differently from english" do
    representative = [
      {"ui", "Posts"},
      {"render", "Back to preview home"},
      {"render", "Archive"}
    ]

    for locale <- ["de", "fr", "it", "es"], {domain, msgid} <- representative do
      assert BDS.Gettext.lgettext(locale, domain, msgid) != msgid
    end
  end
end
