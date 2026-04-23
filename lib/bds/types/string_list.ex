defmodule BDS.Types.StringList do
  @moduledoc false

  use Ecto.Type

  def type, do: :string

  def cast(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      :error
    end
  end

  def cast(nil), do: {:ok, []}
  def cast(_value), do: :error

  def load(nil), do: {:ok, []}

  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        if is_list(decoded) and Enum.all?(decoded, &is_binary/1) do
          {:ok, decoded}
        else
          :error
        end

      _ -> :error
    end
  end

  def dump(nil), do: {:ok, "[]"}

  def dump(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, Jason.encode!(value)}
    else
      :error
    end
  end

  def dump(_value), do: :error
end
