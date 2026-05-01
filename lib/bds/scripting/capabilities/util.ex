defmodule BDS.Scripting.Capabilities.Util do
  @moduledoc false

  alias BDS.Projects

  def project_path(project_id) do
    project_id
    |> Projects.get_project()
    |> Projects.project_data_dir()
  end

  def sanitize(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def sanitize(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :post, :project, :media, :translations])
    |> sanitize()
  end

  def sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), sanitize(value)} end)
  end

  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  def sanitize(value) when is_boolean(value), do: value
  def sanitize(value) when is_atom(value), do: Atom.to_string(value)
  def sanitize(value), do: value

  def sanitize_nilable(nil), do: nil
  def sanitize_nilable(value), do: sanitize(value)

  def normalize_input(%_struct{} = struct), do: struct |> Map.from_struct() |> normalize_input()

  def normalize_input(map) when is_map(map) do
    normalized =
      Map.new(map, fn {key, value} -> {normalize_input_key(key), normalize_input(value)} end)

    if numeric_sequence_map?(normalized) do
      normalized
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {_key, value} -> value end)
    else
      normalized
    end
  end

  def normalize_input(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _value} when is_integer(key) or is_float(key) or is_binary(key) or is_atom(key), &1)) do
      normalized =
        Map.new(list, fn {key, value} -> {normalize_input_key(key), normalize_input(value)} end)

      if numeric_sequence_map?(normalized) do
        normalized
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map(fn {_key, value} -> value end)
      else
        normalized
      end
    else
      Enum.map(list, &normalize_input/1)
    end
  end

  def normalize_input(value) when is_atom(value), do: Atom.to_string(value)
  def normalize_input(value), do: value

  def normalize_input_key(key) when is_integer(key), do: key
  def normalize_input_key(key) when is_float(key) and trunc(key) == key, do: trunc(key)

  def normalize_input_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {integer, ""} -> integer
      _other -> key
    end
  end

  def normalize_input_key(key) when is_atom(key), do: Atom.to_string(key)
  def normalize_input_key(key), do: key

  def numeric_sequence_map?(map) when map == %{}, do: false

  def numeric_sequence_map?(map) do
    keys = Map.keys(map)
    Enum.all?(keys, &is_integer/1) and Enum.sort(keys) == Enum.to_list(1..length(keys))
  end

  def normalize_map(value) when is_map(value) do
    case normalize_input(value) do
      normalized when is_map(normalized) -> normalized
      _other -> %{}
    end
  end

  def normalize_map(value) when is_list(value) do
    if Enum.all?(value, &match?({key, _value} when is_binary(key) or is_atom(key), &1)) do
      Map.new(value, fn {key, entry_value} -> {to_string(key), normalize_input(entry_value)} end)
    else
      %{}
    end
  end

  def normalize_map(_value), do: %{}

  def normalize_string_list(value) when is_list(value), do: Enum.map(value, &to_string/1)

  def normalize_string_list(value) when is_map(value) do
    value
    |> normalize_input()
    |> case do
      normalized when is_list(normalized) -> Enum.map(normalized, &to_string/1)
      _other -> []
    end
  end

  def normalize_string_list(_value), do: []

  def normalize_search_filters(filters) do
    filters
    |> normalize_map()
    |> Enum.into(%{}, fn {key, value} ->
      normalized_key =
        case key do
          "start_date" -> "from"
          "end_date" -> "to"
          other -> other
        end

      {normalized_key, value}
    end)
  end

  def integer_or_default(value, _default) when is_integer(value), do: value
  def integer_or_default(value, _default) when is_float(value), do: trunc(value)
  def integer_or_default(_value, default), do: default

  def string_or_nil(value) when is_binary(value), do: value
  def string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  def string_or_nil(value) when is_number(value), do: to_string(value)
  def string_or_nil(_value), do: nil

  def truthy?(value), do: value in [true, "true", 1, 1.0, "1"]

  def pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  def blank_to_nil(value), do: value

  def maybe_put_query(query, _key, false), do: query
  def maybe_put_query(query, _key, nil), do: query
  def maybe_put_query(query, key, value), do: Map.put(query, key, value)

  def maybe_put_opt(opts, _key, nil), do: opts
  def maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  def maybe_put_normalized_list(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, normalize_string_list(value))
      :error -> attrs
    end
  end

  def compare_optional(nil, _fun), do: true
  def compare_optional(value, fun) when is_function(fun, 1), do: fun.(value)

  def parse_datetime(nil), do: nil
  def parse_datetime(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)

  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  def parse_datetime(_value), do: nil

  def unwrap_result(result, transform \\ &sanitize/1)
  def unwrap_result({:ok, value}, transform), do: transform.(value)
  def unwrap_result({:error, _reason}, _transform), do: nil

  def boolean_result({:ok, _value}), do: true
  def boolean_result({:error, _reason}), do: false

  def atom_result({:ok, value}, expected_value), do: value == expected_value
  def atom_result(_result, _expected_value), do: false

  def thumbnail_size(size) do
    case blank_to_nil(size) do
      "medium" -> :medium
      "large" -> :large
      "ai" -> :ai
      _other -> :small
    end
  end

  def thumbnail_mime(path) do
    case Path.extname(path) do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      _other -> "image/webp"
    end
  end

  def shell_open_system_path(path) do
    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [path]}
        {:unix, _other} -> {"xdg-open", [path]}
        {:win32, _other} -> {"cmd", ["/c", "start", "", path]}
      end

    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  def shell_reveal_system_path(path) do
    {command, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", ["-R", path]}
        {:unix, _other} -> {"xdg-open", [Path.dirname(path)]}
        {:win32, _other} -> {"explorer", ["/select,", path]}
      end

    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error -> {:error, error}
  end

  def zero_or_one_arg(callback) when is_function(callback, 1) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)
      value = callback.(normalize_input(decoded_args))
      :luerl.encode_list([sanitize(value)], state)
    end
  end

  def one_arg(callback) when is_function(callback, 1) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first | _rest] -> callback.(normalize_input(first))
          [] -> callback.(nil)
        end

      :luerl.encode_list([sanitize(value)], state)
    end
  end

  def two_arg(callback) when is_function(callback, 2) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first, second | _rest] -> callback.(normalize_input(first), normalize_input(second))
          [first] -> callback.(normalize_input(first), nil)
          [] -> callback.(nil, nil)
        end

      :luerl.encode_list([sanitize(value)], state)
    end
  end

  def three_arg(callback) when is_function(callback, 3) do
    fn args, state ->
      decoded_args = :luerl.decode_list(args, state)

      value =
        case decoded_args do
          [first, second, third | _rest] ->
            callback.(normalize_input(first), normalize_input(second), normalize_input(third))

          [first, second] ->
            callback.(normalize_input(first), normalize_input(second), nil)

          [first] ->
            callback.(normalize_input(first), nil, nil)

          [] ->
            callback.(nil, nil, nil)
        end

      :luerl.encode_list([sanitize(value)], state)
    end
  end
end
