defmodule BDS.Strings do
  @moduledoc """
  Small string-formatting helpers shared across the codebase.
  """

  @doc "Zero-pads an integer to at least two digits, e.g. `3 -> \"03\"`."
  @spec pad2(integer()) :: String.t()
  def pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
