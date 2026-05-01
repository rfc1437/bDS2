defmodule BDS.Persistence do
  @moduledoc false

  def now_ms, do: System.system_time(:millisecond)

  def normalize_unix_timestamp(nil), do: nil

  def normalize_unix_timestamp(value) when is_integer(value) do
    if abs(value) < 100_000_000_000 do
      value * 1000
    else
      value
    end
  end

  def normalize_unix_timestamp(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {integer, ""} -> normalize_unix_timestamp(integer)
          _ -> nil
        end
    end
  end

  def normalize_unix_timestamp(_value), do: nil

  def from_unix_ms!(value) when is_integer(value) do
    value
    |> normalize_unix_timestamp()
    |> DateTime.from_unix!(:millisecond)
  end

  def timestamp_to_iso8601(nil), do: nil

  def timestamp_to_iso8601(value) when is_integer(value) do
    value
    |> from_unix_ms!()
    |> DateTime.to_iso8601()
  end

  def parse_timestamp(nil), do: nil
  def parse_timestamp(value) when is_integer(value), do: normalize_unix_timestamp(value)

  def parse_timestamp(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      Regex.match?(~r/^-?\d+$/, trimmed) ->
        normalize_unix_timestamp(trimmed)

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
          _ -> nil
        end
    end
  end

  def parse_timestamp(_value), do: nil

  def atomic_write(path, contents) when is_binary(path) and is_binary(contents) do
    temp_path = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, contents),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(temp_path)
        error
    end
  end
end
