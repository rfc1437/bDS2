defmodule BDS.Rendering.FileSystem do
  @moduledoc false

  @type t :: %__MODULE__{root_paths: [String.t()]}
  defstruct [:root_paths]

  @spec new([String.t()] | String.t()) :: t()
  def new(root_paths) when is_list(root_paths) do
    %__MODULE__{root_paths: Enum.uniq(root_paths)}
  end

  def new(root_path) when is_binary(root_path) do
    new([root_path])
  end

  @spec candidate_paths(t(), String.t()) :: [String.t()]
  def candidate_paths(%__MODULE__{root_paths: root_paths}, template_path) do
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
        Enum.map(root_paths, &Path.expand(Path.join(&1, filename)))
    end
  end

  @spec full_path(t(), String.t()) :: String.t()
  def full_path(%__MODULE__{} = fs, template_path) do
    List.first(candidate_paths(fs, template_path))
  end

  @spec try_read(t(), String.t()) :: {:ok, String.t()} | {:error, :enoent}
  def try_read(%__MODULE__{} = fs, template_path) do
    fs
    |> candidate_paths(template_path)
    |> try_read_from_paths()
  end

  defp try_read_from_paths([]), do: {:error, :enoent}

  defp try_read_from_paths([path | rest]) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> try_read_from_paths(rest)
      {:error, _reason} -> try_read_from_paths(rest)
    end
  end

  defp ensure_liquid_ext(path) do
    if Path.extname(path) == ".liquid", do: path, else: path <> ".liquid"
  end
end

defimpl Liquex.FileSystem, for: BDS.Rendering.FileSystem do
  def read_template_file(file_system, template_path) do
    case BDS.Rendering.FileSystem.try_read(file_system, template_path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> raise Liquex.Error, message: "No such template '#{template_path}'"
    end
  end
end
