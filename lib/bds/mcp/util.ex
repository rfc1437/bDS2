defmodule BDS.MCP.Util do
  @moduledoc false

  @spec sanitize(term()) :: term()
  def sanitize(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :post, :project, :media])
    |> sanitize()
  end

  def sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), sanitize(value)} end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  def sanitize(value) when is_atom(value), do: Atom.to_string(value)
  def sanitize(value), do: value

  @spec normalize_term(term()) :: String.t()
  def normalize_term(nil), do: ""
  def normalize_term(value), do: value |> to_string() |> String.downcase()

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, key, value), do: BDS.MapUtils.maybe_put(map, key, value)

  @spec map_get(map(), atom(), term()) :: term()
  def map_get(map, key, default \\ nil) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end
end
