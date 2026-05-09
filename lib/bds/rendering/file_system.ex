defmodule BDS.Rendering.FileSystem do
  @moduledoc false

  defstruct [:root_paths]

  def new(root_paths) when is_list(root_paths) do
    %__MODULE__{root_paths: Enum.uniq(root_paths)}
  end

  def new(root_path) when is_binary(root_path) do
    new([root_path])
  end

  def full_path(%__MODULE__{root_paths: root_paths}, template_path) do
    normalized_path = to_string(template_path)

    cond do
      normalized_path == "" ->
        raise Liquex.Error, message: "Illegal template path '#{template_path}'"

      Path.type(normalized_path) == :absolute ->
        raise Liquex.Error, message: "Illegal template path '#{template_path}'"

      String.contains?(normalized_path, "..") ->
        raise Liquex.Error, message: "Illegal template path '#{template_path}'"

      true ->
        filename = ensure_liquid_ext(normalized_path)

        root_paths
        |> Enum.map(&Path.expand(Path.join(&1, filename)))
        |> Enum.find(&File.regular?/1)
        |> case do
          nil ->
            Path.expand(Path.join(List.first(root_paths) || ".", filename))

          path ->
            path
        end
    end
  end

  defp ensure_liquid_ext(path) do
    if Path.extname(path) == ".liquid", do: path, else: path <> ".liquid"
  end
end

defimpl Liquex.FileSystem, for: BDS.Rendering.FileSystem do
  def read_template_file(file_system, template_path) do
    file_system
    |> BDS.Rendering.FileSystem.full_path(template_path)
    |> File.read()
    |> case do
      {:ok, contents} -> contents
      _error -> raise Liquex.Error, message: "No such template '#{template_path}'"
    end
  end
end
