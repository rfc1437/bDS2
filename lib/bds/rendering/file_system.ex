defmodule BDS.Rendering.FileSystem do
  @moduledoc false

  defstruct [:root_path]

  def new(root_path) do
    %__MODULE__{root_path: root_path}
  end

  def full_path(%__MODULE__{root_path: root_path}, template_path) do
    normalized_path = to_string(template_path)

    cond do
      normalized_path == "" ->
        raise Liquex.Error, message: "Illegal template path '#{template_path}'"

      Path.type(normalized_path) == :absolute ->
        raise Liquex.Error, message: "Illegal template path '#{template_path}'"

      String.contains?(normalized_path, "..") ->
        raise Liquex.Error, message: "Illegal template path '#{template_path}'"

      true ->
        Path.expand(Path.join(root_path, normalized_path <> ".liquid"))
    end
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
