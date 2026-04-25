defmodule BDS.Preview do
  @moduledoc false

  use GenServer

  alias BDS.Posts
  alias BDS.Projects
  alias BDS.Rendering

  @host "127.0.0.1"
  @port 4123

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def start_preview(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)

    GenServer.call(
      __MODULE__,
      {:start_preview, project_id, Projects.project_data_dir(project), self()}
    )
  end

  def stop_preview(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:stop_preview, project_id})
  end

  def request(project_id, request_path) when is_binary(project_id) and is_binary(request_path) do
    {path, query_params} = split_request_path(request_path)
    GenServer.call(__MODULE__, {:request, project_id, path, query_params})
  end

  def preview_draft(project_id, request_path, post_id)
      when is_binary(project_id) and is_binary(request_path) and is_binary(post_id) do
    post = Posts.get_post!(post_id)
    {_path, query_params} = split_request_path(request_path)

    GenServer.call(__MODULE__, {
      :preview_draft,
      project_id,
      query_params,
      %{
        id: post.id,
        title: post.title,
        content: post.content || "",
        body: post.content || "",
        slug: post.slug,
        language: post.language,
        excerpt: post.excerpt,
        template_slug: post.template_slug
      }
    })
  end

  @impl true
  def init(_state) do
    {:ok, %{current: nil}}
  end

  @impl true
  def handle_call({:start_preview, project_id, data_dir, owner_pid}, _from, state) do
    state = stop_current_server(state)
    maybe_allow_repo(owner_pid)

    {:ok, listener} =
      :gen_tcp.listen(@port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    acceptor_pid = spawn_link(fn -> accept_loop(listener, project_id) end)

    server = %{
      project_id: project_id,
      data_dir: data_dir,
      host: @host,
      port: @port,
      is_running: true,
      listener: listener,
      acceptor_pid: acceptor_pid
    }

    {:reply, {:ok, public_server(server)}, %{state | current: server}}
  end

  def handle_call({:stop_preview, project_id}, _from, state) do
    next_state =
      if match?(%{project_id: ^project_id}, state.current) do
        stop_current_server(state)
      else
        state
      end

    {:reply, :ok, next_state}
  end

  def handle_call({:request, project_id, request_path, query_params}, _from, state) do
    with :ok <- ensure_running(state.current, project_id),
         {:ok, response} <- resolve_request(state.current, request_path, query_params) do
      {:reply, {:ok, response}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:preview_draft, project_id, query_params, post}, _from, state) do
    with :ok <- ensure_running(state.current, project_id) do
      body =
        case Rendering.render_post_page(project_id, Map.get(post, :template_slug), post) do
          {:ok, rendered} -> rendered
          {:error, _reason} -> render_draft(post)
        end
        |> apply_preview_overrides(query_params)

      response = %{
        content_type: "text/html",
        body: body
      }

      {:reply, {:ok, response}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:http_request, project_id, method, request_path, query_params}, _from, state) do
    response =
      with :ok <- ensure_running(state.current, project_id),
           :ok <- ensure_get(method) do
        case query_params["post_id"] do
          post_id when is_binary(post_id) ->
            if String.starts_with?(request_path, "/draft/") or query_params["draft"] == "true" do
              resolve_draft_request(project_id, post_id, query_params)
            else
              resolve_request(state.current, request_path, query_params)
            end

          _other ->
            resolve_request(state.current, request_path, query_params)
        end
      end

    {:reply, response, state}
  end

  defp ensure_running(%{project_id: project_id, is_running: true}, project_id), do: :ok
  defp ensure_running(_server, _project_id), do: {:error, :not_running}

  defp resolve_request(server, request_path, query_params) do
    with {:ok, relative_path, kind} <- route_request(request_path) do
      full_path =
        case kind do
          :media -> safe_join(server.data_dir, Path.join(["media", relative_path]))
          :generated -> safe_join(Path.join(server.data_dir, "html"), relative_path)
        end

      case full_path do
        {:error, :not_found} ->
          {:error, :not_found}

        resolved_path ->
          case read_response(resolved_path) do
            {:error, :not_found} -> render_not_found_response(server.project_id, query_params)
            {:ok, response} -> {:ok, apply_response_overrides(response, query_params)}
            other -> other
          end
      end
    end
  end

  defp resolve_draft_request(project_id, post_id, query_params) do
    try do
      post = Posts.get_post!(post_id)

      if post.project_id == project_id do
        payload = %{
          id: post.id,
          title: post.title,
          content: post.content || "",
          body: post.content || "",
          slug: post.slug,
          language: post.language,
          excerpt: post.excerpt,
          template_slug: post.template_slug
        }

        body =
          case Rendering.render_post_page(project_id, post.template_slug, payload) do
            {:ok, rendered} -> rendered
            {:error, _reason} -> render_draft(payload)
          end
          |> apply_preview_overrides(query_params)

        {:ok, %{content_type: "text/html", body: body}}
      else
        {:error, :not_found}
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
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

  defp accept_loop(listener, project_id) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve_client(socket, project_id) end)
        accept_loop(listener, project_id)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_client(socket, project_id) do
    response =
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, request} ->
          request
          |> parse_http_request()
          |> handle_http_request(project_id)

        {:error, _reason} ->
          http_error_response(400)
      end

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp parse_http_request(request) do
    case String.split(request, "\r\n", parts: 2) do
      [request_line | _rest] ->
        case String.split(request_line, " ", parts: 3) do
          [method, target, _version] -> {method, target}
          _other -> {:error, :bad_request}
        end

      _other ->
        {:error, :bad_request}
    end
  end

  defp handle_http_request({:error, :bad_request}, _project_id), do: http_error_response(400)

  defp handle_http_request({method, target}, project_id) do
    uri = URI.parse(target)
    path = uri.path || "/"
    query_params = URI.decode_query(uri.query || "")

    case GenServer.call(
           __MODULE__,
           {:http_request, project_id, method, path, query_params},
           5_000
         ) do
      {:ok, response} -> http_ok_response(response)
      {:error, :not_found} -> http_error_response(404)
      {:error, :not_running} -> http_error_response(503)
      {:error, _reason} -> http_error_response(500)
    end
  end

  defp http_ok_response(response) do
    status = Map.get(response, :status, 200)

    reason =
      case status do
        200 -> "OK"
        404 -> "Not Found"
        503 -> "Service Unavailable"
        _other -> "OK"
      end

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason,
      "\r\n",
      "content-type: ",
      response.content_type,
      "; charset=utf-8\r\n",
      "content-length: ",
      Integer.to_string(byte_size(response.body)),
      "\r\nconnection: close\r\n\r\n",
      response.body
    ]
    |> IO.iodata_to_binary()
  end

  defp http_error_response(status_code) do
    reason =
      case status_code do
        400 -> "Bad Request"
        404 -> "Not Found"
        503 -> "Service Unavailable"
        _other -> "Internal Server Error"
      end

    body = reason

    [
      "HTTP/1.1 ",
      Integer.to_string(status_code),
      " ",
      reason,
      "\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\nconnection: close\r\n\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  defp ensure_get("GET"), do: :ok
  defp ensure_get(_method), do: {:error, :not_found}

  defp maybe_allow_repo(owner_pid) do
    try do
      Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, owner_pid, self())
    rescue
      _error -> :ok
    end
  end

  defp stop_current_server(%{current: %{listener: listener, acceptor_pid: acceptor_pid}} = state) do
    _ = :gen_tcp.close(listener)
    if is_pid(acceptor_pid), do: Process.exit(acceptor_pid, :normal)
    %{state | current: nil}
  end

  defp stop_current_server(state), do: state

  defp public_server(server) do
    Map.take(server, [:project_id, :host, :port, :is_running])
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
      {:ok, body} -> {:ok, %{status: 200, body: body, content_type: content_type(path)}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_not_found_response(project_id, query_params) do
    body =
      case Rendering.render_not_found_page(project_id, not_found_assigns(query_params)) do
        {:ok, rendered} -> rendered
        {:error, _reason} -> "Not Found"
      end
      |> apply_preview_overrides(query_params)

    {:ok, %{status: 404, content_type: "text/html", body: body}}
  end

  defp split_request_path(request_path) do
    uri = URI.parse(request_path)
    {uri.path || "/", URI.decode_query(uri.query || "")}
  end

  defp apply_response_overrides(%{content_type: content_type, body: body} = response, query_params)
       when is_binary(content_type) and is_binary(body) do
    if String.starts_with?(content_type, "text/html") do
      %{response | body: apply_preview_overrides(body, query_params)}
    else
      response
    end
  end

  defp apply_preview_overrides(body, query_params) when is_binary(body) and is_map(query_params) do
    body
    |> override_html_attribute("data-theme", normalize_override(query_params["theme"]))
    |> override_html_attribute("data-mode", normalize_override(query_params["mode"]))
  end

  defp normalize_override(nil), do: nil
  defp normalize_override(""), do: nil
  defp normalize_override(value), do: String.trim(value)

  defp override_html_attribute(body, _attribute, nil), do: body

  defp override_html_attribute(body, attribute, value) do
    case Regex.run(~r/<html\b[^>]*>/, body) do
      [html_tag] ->
        replacement =
          if String.contains?(html_tag, attribute <> "=") do
            Regex.replace(~r/\s#{attribute}="[^"]*"/, html_tag, ~s( #{attribute}="#{value}"), global: false)
          else
            String.replace_suffix(html_tag, ">", ~s( #{attribute}="#{value}">))
          end

        String.replace(body, html_tag, replacement, global: false)

      _other ->
        body
    end
  end

  defp not_found_assigns(query_params) do
    %{}
    |> maybe_put_assign("html_theme_attribute", query_params["theme"], fn value -> ~s(data-theme="#{value}") end)
    |> maybe_put_assign("html_mode_attribute", query_params["mode"], fn value -> ~s(data-mode="#{value}") end)
  end

  defp maybe_put_assign(assigns, _key, nil, _mapper), do: assigns
  defp maybe_put_assign(assigns, _key, "", _mapper), do: assigns
  defp maybe_put_assign(assigns, key, value, mapper), do: Map.put(assigns, key, mapper.(value))

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
