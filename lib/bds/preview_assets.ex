defmodule BDS.PreviewAssets do
  @moduledoc false

  @preview_root Application.app_dir(:bds, "priv/preview_assets")

  def response(pathname) when is_binary(pathname) do
    pathname
    |> request_path()
    |> case do
      {:ok, relative_path} ->
        case File.read(Path.join(@preview_root, relative_path)) do
          {:ok, body} -> {:ok, %{content_type: content_type(relative_path), body: body}}
          {:error, _reason} -> :error
        end

      :error ->
        :error
    end
  end

  def generated_outputs do
    ["assets", "images"]
    |> Enum.flat_map(fn directory ->
      @preview_root
      |> Path.join(directory)
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: false)
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      {Path.relative_to(path, @preview_root), File.read!(path)}
    end)
  end

  def stylesheet_href(nil), do: "/assets/pico.min.css"
  def stylesheet_href(""), do: "/assets/pico.min.css"
  def stylesheet_href("default"), do: "/assets/pico.min.css"
  def stylesheet_href(theme), do: "/assets/pico.#{theme}.min.css"

  defp request_path(pathname) do
    normalized = pathname |> URI.parse() |> Map.get(:path, pathname)

    case String.split(normalized, "/", trim: true) do
      [directory, filename] when directory in ["assets", "images"] ->
        relative_path = Path.join(directory, filename)

        if File.regular?(Path.join(@preview_root, relative_path)) do
          {:ok, relative_path}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      _other -> "application/octet-stream"
    end
  end
end
