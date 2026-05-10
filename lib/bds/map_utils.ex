defmodule BDS.MapUtils do
  @moduledoc """
  Utility functions for working with maps that may have atom or string keys,
  including safe atom conversion for untrusted input.
  """

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

  @spec safe_atomize_key(atom() | String.t()) :: atom() | String.t()
  def safe_atomize_key(key) when is_atom(key), do: key

  def safe_atomize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  @spec safe_atomize_keys(term()) :: term()
  def safe_atomize_keys(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} ->
      {safe_atomize_key(key), safe_atomize_keys(nested_value)}
    end)
    |> Map.new()
  end

  def safe_atomize_keys(value) when is_list(value), do: Enum.map(value, &safe_atomize_keys/1)
  def safe_atomize_keys(value), do: value
end
