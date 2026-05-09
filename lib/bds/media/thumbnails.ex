defmodule BDS.Media.Thumbnails do
  @moduledoc false

  import BDS.Media.FileOps,
    only: [
      delete_file_if_present: 2,
      image_mime?: 1,
      progress_callback: 1,
      report_rebuild_progress: 4,
      report_rebuild_started: 3
    ]

  import Ecto.Query

  alias BDS.Media.Media
  alias BDS.Projects
  alias BDS.Repo

  @type rebuild_opts :: keyword()

  @spec thumbnail_paths(Media.t()) :: %{required(atom()) => String.t()}
  def thumbnail_paths(%Media{id: id}) do
    prefix = String.slice(id, 0, 2)

    %{
      small: Path.join(["thumbnails", prefix, "#{id}-small.webp"]),
      medium: Path.join(["thumbnails", prefix, "#{id}-medium.webp"]),
      large: Path.join(["thumbnails", prefix, "#{id}-large.webp"]),
      ai: Path.join(["thumbnails", prefix, "#{id}-ai.jpg"])
    }
  end

  @spec regenerate_thumbnails(String.t()) :: {:ok, Media.t()} | {:error, :not_found | term()}
  def regenerate_thumbnails(media_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      media ->
        project = Projects.get_project!(media.project_id)

        case ensure_thumbnails(project, media) do
          :ok -> {:ok, media}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec regenerate_missing_thumbnails(String.t(), rebuild_opts()) ::
          %{processed: non_neg_integer(), generated: non_neg_integer(), failed: non_neg_integer()}
  def regenerate_missing_thumbnails(project_id, opts \\ []) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    media_items =
      Repo.all(
        from(media in Media,
          where: media.project_id == ^project_id,
          order_by: [asc: media.created_at]
        )
      )
      |> Enum.filter(fn media ->
        String.starts_with?(media.mime_type || "", "image/") and
          not String.contains?(media.mime_type || "", "svg")
      end)

    total_media = length(media_items)
    :ok = report_rebuild_started(on_progress, total_media, "image assets")

    media_items
    |> Enum.with_index(1)
    |> Enum.reduce(%{processed: 0, generated: 0, failed: 0}, fn {media, index}, acc ->
      missing_paths =
        media
        |> thumbnail_paths()
        |> Enum.map(fn {_size, relative_path} ->
          Path.join(Projects.project_data_dir(project), relative_path)
        end)
        |> Enum.reject(&File.exists?/1)

      next_acc =
        if missing_paths == [] do
          %{acc | processed: acc.processed + 1}
        else
          case ensure_thumbnails(project, media) do
            :ok ->
              %{
                processed: acc.processed + 1,
                generated: acc.generated + length(missing_paths),
                failed: acc.failed
              }

            {:error, _reason} ->
              %{acc | processed: acc.processed + 1, failed: acc.failed + 1}
          end
        end

      :ok = report_rebuild_progress(on_progress, index, total_media, "image assets")
      next_acc
    end)
  end

  @spec ensure_thumbnails(BDS.Projects.Project.t(), Media.t()) :: :ok | {:error, term()}
  def ensure_thumbnails(project, media) do
    if image_mime?(media.mime_type) do
      source_path = Path.join(Projects.project_data_dir(project), media.file_path)

      with {:ok, image} <- Image.open(source_path),
           {:ok, {rotated, _rotation_info}} <- Image.autorotate(image),
           :ok <- write_all_thumbnails(rotated, project, media) do
        :ok
      end
    else
      :ok
    end
  end

  @spec delete_thumbnail_files(String.t(), Media.t()) :: :ok
  def delete_thumbnail_files(project_id, media) do
    Enum.each(Map.values(thumbnail_paths(media)), fn path ->
      delete_file_if_present(project_id, path)
    end)

    :ok
  end

  defp write_all_thumbnails(image, project, media) do
    thumbnail_paths(media)
    |> Enum.reduce_while(:ok, fn {size, relative_path}, :ok ->
      destination = Path.join(Projects.project_data_dir(project), relative_path)

      with :ok <- File.mkdir_p(Path.dirname(destination)),
           {:ok, rendered} <- render_thumbnail(image, size),
           :ok <- write_thumbnail(rendered, destination, size) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp render_thumbnail(image, :small), do: bounded_thumbnail(image, 150, 150)
  defp render_thumbnail(image, :medium), do: bounded_thumbnail(image, 400, 400)
  defp render_thumbnail(image, :large), do: bounded_thumbnail(image, 800, 800)

  defp render_thumbnail(image, :ai) do
    with {:ok, thumbnail} <-
           Image.thumbnail(image, "448x448",
             fit: :contain,
             resize: :both,
             autorotate: false
           ),
         {:ok, embedded} <-
           Image.embed(thumbnail, 448, 448,
             x: :center,
             y: :center,
             background_color: :black
           ) do
      {:ok, embedded}
    end
  end

  defp bounded_thumbnail(image, width, height) do
    Image.thumbnail(image, "#{width}x#{height}",
      fit: :contain,
      resize: :down,
      autorotate: false
    )
  end

  defp write_thumbnail(image, destination, :ai) do
    with {:ok, flattened} <- Image.flatten(image, background_color: :black),
         {:ok, _} <- Image.write(flattened, destination, quality: 85, strip_metadata: true) do
      :ok
    end
  end

  defp write_thumbnail(image, destination, _size) do
    case Image.write(image, destination, quality: 80, strip_metadata: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
