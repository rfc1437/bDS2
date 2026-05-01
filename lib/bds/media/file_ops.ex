defmodule BDS.Media.FileOps do
  @moduledoc false

  alias BDS.Persistence
  alias BDS.ProgressReporter
  alias BDS.Projects

  defdelegate attr(attrs, key), to: BDS.MapUtils
  defdelegate maybe_put(map, key, value), to: BDS.MapUtils
  defdelegate blank_to_nil(value), to: BDS.MapUtils

  @spec atomic_write(Path.t(), iodata()) :: :ok | {:error, term()}
  def atomic_write(path, contents), do: Persistence.atomic_write(path, contents)

  @spec delete_file_if_present(String.t(), Path.t()) :: :ok | {:error, term()}
  def delete_file_if_present(project_id, relative_path) do
    project = Projects.get_project!(project_id)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)

    case File.rm(full_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_matching_files(Path.t(), String.t()) :: [Path.t()]
  def list_matching_files(dir, pattern) do
    if File.dir?(dir) do
      Path.join([dir, "**", pattern])
      |> Path.wildcard()
      |> Enum.sort()
    else
      []
    end
  end

  @spec media_file_path(String.t(), integer()) :: Path.t()
  def media_file_path(file_name, timestamp) do
    datetime = Persistence.from_unix_ms!(timestamp)
    year = Integer.to_string(datetime.year)
    month = datetime.month |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join(["media", year, month, file_name])
  end

  @spec detect_mime(String.t()) :: String.t()
  def detect_mime(file_name) do
    case String.downcase(Path.extname(file_name)) do
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      ".bmp" -> "image/bmp"
      ".heic" -> "image/heic"
      ".heif" -> "image/heif"
      _ -> "application/octet-stream"
    end
  end

  @spec image_dimensions(Path.t(), String.t() | nil) ::
          {non_neg_integer() | nil, non_neg_integer() | nil}
  def image_dimensions(source_path, mime_type) do
    if image_mime?(mime_type) do
      case Image.open(source_path) do
        {:ok, image} -> {Image.width(image), Image.height(image)}
        {:error, _reason} -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  @spec image_mime?(String.t() | nil) :: boolean()
  def image_mime?(mime_type), do: String.starts_with?(mime_type || "", "image/")

  @spec progress_callback(keyword()) :: (float(), String.t() -> any()) | nil
  def progress_callback(opts), do: ProgressReporter.callback(opts)

  @spec scaled_progress_reporter((float(), String.t() -> any()) | nil, float(), float()) ::
          (float(), String.t() -> any()) | nil
  def scaled_progress_reporter(report, start_value, end_value),
    do: ProgressReporter.scaled(report, start_value, end_value)

  @spec report_rebuild_started(
          (float(), String.t() -> any()) | nil,
          non_neg_integer(),
          String.t()
        ) :: :ok
  def report_rebuild_started(callback, total, label),
    do: ProgressReporter.report_rebuild_started(callback, total, label)

  @spec report_rebuild_progress(
          (float(), String.t() -> any()) | nil,
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: :ok
  def report_rebuild_progress(callback, current, total, label),
    do: ProgressReporter.report_rebuild_progress(callback, current, total, label)

  @spec report_rebuild_phase((float(), String.t() -> any()) | nil, float(), String.t()) :: :ok
  def report_rebuild_phase(callback, progress, message),
    do: ProgressReporter.report_phase(callback, progress, message)
end
