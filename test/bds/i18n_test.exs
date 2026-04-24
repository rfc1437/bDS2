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

  test "render translations are loaded from locale json files with unsupported-locale fallback" do
    locale_dir = Application.app_dir(:bds, "priv/i18n/locales")

    assert File.exists?(Path.join(locale_dir, "en.json"))
    assert File.exists?(Path.join(locale_dir, "de.json"))
    assert File.exists?(Path.join(locale_dir, "fr.json"))
    assert File.exists?(Path.join(locale_dir, "it.json"))
    assert File.exists?(Path.join(locale_dir, "es.json"))

    assert BDS.I18n.get_render_translations("de") ==
             Jason.decode!(File.read!(Path.join(locale_dir, "de.json")))

    assert BDS.I18n.translate("de", "render.notFound.back") ==
             "Zurück zur Vorschau-Startseite"

    assert BDS.I18n.translate("pt-BR", "render.notFound.back") == "Back to preview home"
  end

  test "supported locales do not silently fall back to english per key" do
    assert BDS.I18n.translate("de", "missing.key") == "missing.key"
  end
end
