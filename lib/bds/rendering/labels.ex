defmodule BDS.Rendering.Labels do
  @moduledoc """
  Pre-translated render labels passed into Liquid template context.

  All strings use constant msgids so mix gettext.extract can discover them.
  The render locale is bound explicitly via Gettext.with_locale/3.
  """

  use Gettext, backend: BDS.Gettext

  @spec for_language(String.t()) :: map()
  def for_language(language) do
    Gettext.with_locale(BDS.Gettext, language, fn ->
      %{
        taxonomy_label: dgettext("render", "Taxonomy"),
        backlinks_label: dgettext("render", "Backlinks"),
        linked_from_label: dgettext("render", "Linked from"),
        archive_label: dgettext("render", "Archive"),
        pagination_label: dgettext("render", "Pagination"),
        newer_label: dgettext("render", "newer"),
        older_label: dgettext("render", "older"),
        calendar_open_label: dgettext("render", "Open calendar"),
        calendar_loading_label: dgettext("render", "Loading calendar…"),
        calendar_error_label: dgettext("render", "Calendar data could not be loaded."),
        calendar_title_label: dgettext("render", "Archive calendar"),
        calendar_close_label: dgettext("render", "Close calendar"),
        language_switcher_label: dgettext("render", "Language"),
        site_search_label: dgettext("render", "Site search"),
        search_placeholder: dgettext("render", "Search..."),
        search_no_results: dgettext("render", "No results found"),
        not_found_message: dgettext("render", "The requested preview page could not be found."),
        not_found_back_label: dgettext("render", "Back to preview home"),
        youtube_video: dgettext("render", "YouTube video"),
        vimeo_video: dgettext("render", "Vimeo video")
      }
    end)
  end

  @spec month_name(integer() | nil, String.t()) :: String.t() | nil
  def month_name(nil, _language), do: nil

  def month_name(month, language) when month in 1..12 do
    Gettext.with_locale(BDS.Gettext, language, fn ->
      [
        dgettext("render", "January"),
        dgettext("render", "February"),
        dgettext("render", "March"),
        dgettext("render", "April"),
        dgettext("render", "May"),
        dgettext("render", "June"),
        dgettext("render", "July"),
        dgettext("render", "August"),
        dgettext("render", "September"),
        dgettext("render", "October"),
        dgettext("render", "November"),
        dgettext("render", "December")
      ]
      |> Enum.at(month - 1)
    end)
  end

  def month_name(_month, _language), do: nil
end
