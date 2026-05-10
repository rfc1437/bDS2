defmodule BDS.DocumentFields do
  @moduledoc """
  Accessor functions for document frontmatter fields, supporting key aliases
  (e.g. "date" and "published_at" resolve to the same value).
  """

  def get(fields, key, default \\ nil) when is_map(fields) and is_binary(key) do
    case fetch(fields, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def fetch!(fields, key) when is_map(fields) and is_binary(key) do
    case fetch(fields, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  def has_key?(fields, key) when is_map(fields) and is_binary(key) do
    match?({:ok, _value}, fetch(fields, key))
  end

  def fetch(fields, key) when is_map(fields) and is_binary(key) do
    key
    |> aliases_for()
    |> Enum.find_value(:error, fn alias_key ->
      if Map.has_key?(fields, alias_key) do
        {:ok, Map.get(fields, alias_key)}
      end
    end)
  end

  defp aliases_for(key) do
    [key, Macro.underscore(key), lower_camelize(key)]
    |> Enum.uniq()
  end

  defp lower_camelize(value) do
    case Macro.camelize(value) do
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
      "" -> ""
    end
  end
end
