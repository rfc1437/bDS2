defmodule BDS.Slug do
  @moduledoc false

  @german_transliterations %{"ß" => "ss"}

  def slugify(nil), do: ""

  def slugify(value) when is_binary(value) do
    value
    |> replace_german_characters()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\p{ASCII}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
  end

  defp replace_german_characters(value) do
    Enum.reduce(@german_transliterations, value, fn {source, target}, acc ->
      String.replace(acc, source, target)
    end)
  end
end
