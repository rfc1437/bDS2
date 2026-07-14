defmodule BDS.I18n do
  @moduledoc """
  Internationalization helpers for supported languages, locale resolution, and flag emoji mapping.
  """

  @supported_languages [
    %{code: "en", flag: "GB"},
    %{code: "de", flag: "DE"},
    %{code: "fr", flag: "FR"},
    %{code: "it", flag: "IT"},
    %{code: "es", flag: "ES"}
  ]
  @supported_language_codes Enum.map(@supported_languages, & &1.code)

  @format_locales %{
    "en" => "en-US",
    "de" => "de-DE",
    "fr" => "fr-FR",
    "it" => "it-IT",
    "es" => "es-ES"
  }

  @flag_emoji %{
    "GB" => "🇬🇧",
    "DE" => "🇩🇪",
    "FR" => "🇫🇷",
    "IT" => "🇮🇹",
    "ES" => "🇪🇸"
  }

  # Native autonyms — a language's self-name, not translated into the UI locale.
  @language_names %{
    "en" => "English",
    "de" => "Deutsch",
    "fr" => "Français",
    "it" => "Italiano",
    "es" => "Español"
  }

  @default_language "en"
  @default_format_locale "en-US"

  def supported_languages, do: @supported_languages

  def default_language, do: @default_language

  @doc "Native autonym (self-name) for a supported language code, e.g. \"de\" -> \"Deutsch\"."
  def language_name(language) do
    code = resolve_render_locale(language)
    Map.get(@language_names, code, code)
  end

  def normalize_language(language) do
    language
    |> normalize_locale_prefix()
    |> case do
      value when value in @supported_language_codes -> value
      _other -> @default_language
    end
  end

  def resolve_ui_locale(locale), do: resolve_supported_locale(locale) || @default_language

  def current_ui_locale do
    (stored_ui_locale() || System.get_env("LC_ALL") || System.get_env("LC_MESSAGES") ||
       System.get_env("LANG"))
    |> resolve_ui_locale()
  end

  # The UI language is a server-side setting shared by all connected clients
  # (issue #26); the OS locale is only the fallback for a fresh install.
  defp stored_ui_locale do
    with true <- BDS.Repo.ready?(),
         value when is_binary(value) and value != "" <-
           BDS.Settings.get_global_setting("ui.language") do
      value
    else
      _other -> nil
    end
  end

  def resolve_render_locale(language), do: resolve_supported_locale(language) || @default_language

  def format_locale(language) do
    language
    |> resolve_supported_locale()
    |> case do
      nil -> @default_format_locale
      locale -> Map.get(@format_locales, locale, @default_format_locale)
    end
  end

  def locale_mapping(language) do
    ui_locale = resolve_ui_locale(language)

    %{
      ui_locale: ui_locale,
      format_locale: format_locale(ui_locale)
    }
  end

  def flag(language) do
    language
    |> resolve_supported_locale()
    |> case do
      nil -> @default_language
      locale -> locale
    end
    |> flag_code()
    |> then(&Map.get(@flag_emoji, &1, &1))
  end

  def flag_code(language) do
    language
    |> resolve_supported_locale()
    |> case do
      nil -> @default_language
      locale -> locale
    end
    |> then(fn locale ->
      @supported_languages
      |> Enum.find(hd(@supported_languages), &(&1.code == locale))
      |> Map.fetch!(:flag)
    end)
  end

  defp resolve_supported_locale(language) do
    language
    |> normalize_locale_prefix()
    |> case do
      value when value in @supported_language_codes -> value
      _other -> nil
    end
  end

  defp normalize_locale_prefix(language) do
    language
    |> to_string()
    |> String.trim()
    |> String.replace("_", "-")
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> List.first()
  end
end
