defmodule BDS.MapUtils do
  @moduledoc false

  @typedoc "An attribute map that may use atom or string keys."
  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @spec attr(attrs(), atom()) :: term()
  def attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end

  @spec attr(attrs(), atom(), term()) :: term()
  def attr(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end

  @spec maybe_put(map(), term(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec blank_to_nil(term()) :: term()
  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value), do: value
end
