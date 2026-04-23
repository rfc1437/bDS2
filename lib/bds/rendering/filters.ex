defmodule BDS.Rendering.Filters do
  @moduledoc false

  use Liquex.Filter

  alias BDS.Rendering.I18n

  def i18n(value, language, _context) do
    key = value |> to_string() |> String.trim()

    if key == "" do
      ""
    else
      I18n.translate(language, key)
    end
  end

  def markdown(value, _post_id, _post_data_json_by_id, _canonical_post_paths, _canonical_media_paths, _language, _language_prefix, _context) do
    value
    |> to_string()
    |> Earmark.as_html!()
  end
end
