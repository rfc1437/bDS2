defmodule BDS.Preview do
  @moduledoc false

  use GenServer

  alias BDS.Posts
  alias BDS.Projects

  @host "127.0.0.1"
  @port 4123

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start_preview(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)
    GenServer.call(__MODULE__, {:start_preview, project_id, Projects.project_data_dir(project)})
  end

  def stop_preview(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:stop_preview, project_id})
  end

  def request(project_id, request_path) when is_binary(project_id) and is_binary(request_path) do
    GenServer.call(__MODULE__, {:request, project_id, request_path})
  end

  def preview_draft(project_id, request_path, post_id)
      when is_binary(project_id) and is_binary(request_path) and is_binary(post_id) do
    post = Posts.get_post!(post_id)
    GenServer.call(__MODULE__, {:preview_draft, project_id, request_path, %{title: post.title, body: post.content || ""}})
  end

  @impl true
  def init(_state) do
    {:ok, %{current: nil}}
  end

  @impl true
  def handle_call({:start_preview, project_id, data_dir}, _from, state) do
    server = %{project_id: project_id, data_dir: data_dir, host: @host, port: @port, is_running: true}
    {:reply, {:ok, server}, %{state | current: server}}
  end

  def handle_call({:stop_preview, project_id}, _from, state) do
    next_state =
      if match?(%{project_id: ^project_id}, state.current) do
        %{state | current: nil}
      else
        state
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:request, project_id, request_path}, _from, state) do
    with :ok <- ensure_running(state.current, project_id),
         {:ok, response} <- resolve_request(state.current, request_path) do
      {:reply, {:ok, response}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:preview_draft, project_id, _request_path, post}, _from, state) do
    with :ok <- ensure_running(state.current, project_id) do
      response = %{
        content_type: "text/html",
        body: render_draft(post)
      }

      {:reply, {:ok, response}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_running(%{project_id: project_id, is_running: true}, project_id), do: :ok
  defp ensure_running(_server, _project_id), do: {:error, :not_running}

  defp resolve_request(server, request_path) do
    with {:ok, relative_path, kind} <- route_request(request_path) do
      full_path =
        case kind do
          :media -> safe_join(server.data_dir, Path.join(["media", relative_path]))
          :generated -> safe_join(Path.join(server.data_dir, "html"), relative_path)
        end

      case full_path do
        {:error, :not_found} -> {:error, :not_found}
        resolved_path -> read_response(resolved_path)
      end
    end
  end

  defp route_request(request_path) do
    normalized = request_path |> URI.parse() |> Map.get(:path, "/")
    segments = String.split(normalized, "/", trim: true)

    cond do
      Enum.any?(segments, &(&1 == "..")) ->
        {:error, :not_found}

      match?(["media" | _], segments) ->
        {:ok, Path.join(tl(segments)), :media}

      normalized == "/" ->
        {:ok, "index.html", :generated}

      Path.extname(List.last(segments) || "") != "" ->
        {:ok, Path.join(segments), :generated}

      true ->
        {:ok, Path.join(segments ++ ["index.html"]), :generated}
    end
  end

  defp safe_join(root, relative_path) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(relative_path, root)

    if String.starts_with?(expanded_path, expanded_root <> "/") or expanded_path == expanded_root do
      expanded_path
    else
      {:error, :not_found}
    end
  end

  defp read_response(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, %{body: body, content_type: content_type(path)}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".html" -> "text/html"
      ".js" -> "application/javascript"
      ".css" -> "text/css"
      ".json" -> "application/json"
      ".xml" -> "application/xml"
      ".txt" -> "text/plain"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      _other -> "application/octet-stream"
    end
  end

  defp render_draft(post) do
    [
      "<html>",
      "<head><title>",
      to_string(post.title),
      "</title></head>",
      "<body><article data-pagefind-body>",
      post.body,
      "</article></body>",
      "</html>"
    ]
    |> IO.iodata_to_binary()
  end
end
