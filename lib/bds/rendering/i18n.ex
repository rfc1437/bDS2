defmodule BDS.Rendering.I18n do
  @moduledoc false

  defdelegate supported_languages(), to: BDS.I18n
  defdelegate normalize_language(language), to: BDS.I18n
  defdelegate translate(language, key), to: BDS.I18n
  defdelegate flag(language), to: BDS.I18n
end
