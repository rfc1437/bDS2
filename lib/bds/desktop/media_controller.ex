defmodule BDS.Desktop.MediaController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  alias BDS.Media
  alias BDS.Media.Media, as: MediaRecord
  alias BDS.Projects
  alias BDS.Repo

  @web_image_types ~w(image/jpeg image/png image/webp image/gif image/svg+xml image/avif)

  def thumbnail(conn, %{"media_id" => media_id} = params) do
    send_media(conn, active_media_thumbnail(media_id, Map.get(params, "size")))
  end

  def file(conn, %{"media_id" => media_id}) do
    send_media(conn, active_media_file(media_id))
  end

  defp send_media(conn, {:ok, content_type, path}) do
    conn
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_file(200, path)
  end

  defp send_media(conn, :error), do: send_resp(conn, 404, "not found")

  # Serves the original image at full resolution; formats browsers cannot
  # render inline fall back to the large thumbnail.
  defp active_media_file(media_id) do
    with %{} = project <- Projects.get_active_project(),
         %MediaRecord{} = media <- Repo.get(MediaRecord, media_id),
         true <- media.project_id == project.id,
         true <- media.mime_type in @web_image_types,
         absolute_path = Path.join(Projects.project_data_dir(project), media.file_path),
         true <- File.exists?(absolute_path) do
      {:ok, media.mime_type, absolute_path}
    else
      _other -> active_media_thumbnail(media_id, "large")
    end
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and
           not String.contains?(Exception.message(error), "no such table") do
        reraise error, __STACKTRACE__
      end

      :error
  end

  defp active_media_thumbnail(media_id, size) do
    with %{} = project <- Projects.get_active_project(),
         %MediaRecord{} = media <- Repo.get(MediaRecord, media_id),
         true <- media.project_id == project.id,
         relative_path when is_binary(relative_path) <-
           Media.thumbnail_paths(media)[thumbnail_size(size)],
         absolute_path = Path.join(Projects.project_data_dir(project), relative_path),
         true <- File.exists?(absolute_path) do
      {:ok, thumbnail_content_type(relative_path), absolute_path}
    else
      _other -> :error
    end
  rescue
    error in [Exqlite.Error, DBConnection.OwnershipError] ->
      if match?(%Exqlite.Error{}, error) and
           not String.contains?(Exception.message(error), "no such table") do
        reraise error, __STACKTRACE__
      end

      :error
  end

  defp thumbnail_size(size) do
    case to_string(size || "small") do
      "medium" -> :medium
      "large" -> :large
      "ai" -> :ai
      _other -> :small
    end
  end

  defp thumbnail_content_type(path) do
    case Path.extname(path) do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      _other -> "image/webp"
    end
  end
end
