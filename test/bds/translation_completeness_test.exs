defmodule BDS.TranslationCompletenessTest do
  use ExUnit.Case, async: true

  @translated_locales ~w(de fr it es)

  @doc """
  Counts empty msgstr entries per non-English locale .po file and ensures
  the count never increases.  When a new msgid is added to the codebase its
  translations MUST be provided for all supported locales; an empty msgstr
  in de/fr/it/es causes this test to fail.

  English files are excluded — gettext treats empty msgstr as "return msgid
  unchanged" for the source language, which is the intended fallback.

  The expected counts below represent current untranslated legacy entries
  that must decrease over time, never increase.  When the count decreases
  because translations were added, update the expected count in this test.
  """
  test "empty msgstr counts do not increase in non-English locale .po files" do
    expected = %{
      "de/default.po" => 0,
      "de/render.po" => 0,
      "de/ui.po" => 0,
      "fr/default.po" => 0,
      "fr/render.po" => 0,
      "fr/ui.po" => 0,
      "it/default.po" => 0,
      "it/render.po" => 0,
      "it/ui.po" => 0,
      "es/default.po" => 0,
      "es/render.po" => 0,
      "es/ui.po" => 0
    }

    actual =
      for locale <- @translated_locales,
          domain <- ~w(ui default render) do
        file = "priv/gettext/#{locale}/LC_MESSAGES/#{domain}.po"

        if File.exists?(file) do
          count = empty_msgstr_count(file)
          key = "#{locale}/#{domain}.po"
          {key, count}
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    for {file, expected_count} <- expected do
      actual_count = Map.get(actual, file, 0)

      assert actual_count <= expected_count,
             "#{file}: empty msgstr count increased from #{expected_count} to #{actual_count}. " <>
               "All new msgid entries MUST have translations for every supported locale (de, fr, it, es). " <>
               "When the count decreases because translations were added, update the expected count in this test."
    end
  end

  defp empty_msgstr_count(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({nil, 0}, fn line, {current_msgid, count} ->
      trimmed = String.trim(line)

      case {trimmed, current_msgid} do
        {"msgstr \"\"", nil} ->
          {nil, count}

        {"msgstr \"\"", msgid} ->
          if msgid == "" do
            {nil, count}
          else
            {nil, count + 1}
          end

        {"msgid \"" <> rest, _} ->
          {String.trim_trailing(rest, "\""), count}

        _ ->
          {current_msgid, count}
      end
    end)
    |> elem(1)
  end
end
