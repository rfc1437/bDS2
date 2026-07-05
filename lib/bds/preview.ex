defmodule BDS.Preview do
  @moduledoc """
  GenServer that runs the local, self-contained preview server for a project.

  Starts/stops per-project preview rendering and serves rendered pages and draft
  previews via `request/2` and `preview_draft/3`. Generated HTML references only
  local, package-bundled assets — never remote CDN JS/CSS.
  """

  use GenServer
  require Logger

  alias BDS.Posts
  alias BDS.Posts.Translation
  alias BDS.PreviewAssets
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Rendering
  alias BDS.Rendering.TemplateSelection

  @host "127.0.0.1"
  @preferred_port 4123
  @server_table __MODULE__.ServerTable

  # Max time to wait for inflight requests to finish during graceful shutdown
  # before remaining request tasks are forcibly terminated.
  @drain_timeout 5_000
  @listen_retry_attempts 10
  @listen_retry_delay_ms 50

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec start_preview(String.t()) :: {:ok, map()} | {:error, term()}
  def start_preview(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)

    GenServer.call(
      __MODULE__,
      {:start_preview, project_id, Projects.project_data_dir(project), self()}
    )
  end

  @spec ensure_preview(String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_preview(project_id) when is_binary(project_id) do
    project = Projects.get_project!(project_id)

    GenServer.call(
      __MODULE__,
      {:ensure_preview, project_id, Projects.project_data_dir(project), self()}
    )
  end

  @spec base_url() :: String.t()
  def base_url do
    case :ets.whereis(@server_table) do
      :undefined -> "http://#{@host}:#{@preferred_port}"

      _table ->
        case :ets.lookup(@server_table, :current) do
          [{:current, %{host: host, port: port}}] -> "http://#{host}:#{port}"
          _other -> "http://#{@host}:#{@preferred_port}"
        end
    end
  end

  @spec stop_preview(String.t()) :: :ok | {:error, term()}
  def stop_preview(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:stop_preview, project_id})
  end

  @spec request(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def request(project_id, request_path) when is_binary(project_id) and is_binary(request_path) do
    {path, query_params} = split_request_path(request_path)

    run_tracked_request(fn ->
      resolve_preview_request(project_id, path, query_params)
    end)
  end

  @spec preview_draft(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def preview_draft(project_id, request_path, post_id)
      when is_binary(project_id) and is_binary(request_path) and is_binary(post_id) do
    {_path, query_params} = split_request_path(request_path)

    run_tracked_request(fn ->
      resolve_draft_preview_request(project_id, query_params, post_id)
    end)
  end

  @impl true
  def init(_state) do
    ensure_server_table!()
    {:ok, %{current: nil, stopping: nil}}
  end

  @impl true
  def handle_call({:start_preview, project_id, data_dir, owner_pid}, _from, state) do
    {reply, next_state} = start_server(state, project_id, data_dir, owner_pid)
    {:reply, reply, next_state}
  end

  def handle_call(
        {:ensure_preview, project_id, _data_dir, _owner_pid},
        _from,
        %{current: %{project_id: project_id, is_running: true}} = state
      ) do
    {:reply, {:ok, public_server(state.current)}, state}
  end

  def handle_call({:ensure_preview, project_id, data_dir, owner_pid}, _from, state) do
    {reply, next_state} = start_server(state, project_id, data_dir, owner_pid)
    {:reply, reply, next_state}
  end

  def handle_call({:stop_preview, project_id}, from, state) do
    if match?(%{project_id: ^project_id}, state.current) do
      begin_graceful_stop(state, from)
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:track_request, pid}, %{current: %{} = current} = state) when is_pid(pid) do
    ref = Process.monitor(pid)
    inflight = Map.put(current.inflight, ref, pid)
    {:noreply, %{state | current: %{current | inflight: inflight}}}
  end

  def handle_cast({:track_request, _pid}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{current: %{} = current} = state) do
    inflight = Map.delete(current.inflight, ref)
    state = %{state | current: %{current | inflight: inflight}}
    {:noreply, maybe_finalize_stop(state)}
  end

  def handle_info(:drain_timeout, state) do
    {:noreply, force_finalize_stop(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp ensure_running(%{project_id: project_id, is_running: true}, project_id), do: :ok
  defp ensure_running(_server, _project_id), do: {:error, :not_running}

  defp resolve_preview_request(project_id, request_path, query_params) do
    with {:ok, server} <- current_server(project_id),
         {:ok, response} <- run_request(fn -> resolve_request(server, request_path, query_params) end) do
      {:ok, response}
    end
  end

  defp resolve_draft_preview_request(project_id, query_params, post_id) do
    with {:ok, _server} <- current_server(project_id),
         {:ok, response} <-
           run_request(fn -> resolve_draft_request(project_id, post_id, query_params) end) do
      {:ok, response}
    else
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_http_request(project_id, method, request_path, query_params) do
    with {:ok, server} <- current_server(project_id),
         :ok <- ensure_get(method) do
      run_request(fn ->
        case query_params["post_id"] do
          post_id when is_binary(post_id) ->
            if String.starts_with?(request_path, "/draft/") or query_params["draft"] == "true" do
              resolve_draft_request(project_id, post_id, query_params)
            else
              resolve_request(server, request_path, query_params)
            end

          _other ->
            resolve_request(server, request_path, query_params)
        end
      end)
    end
  end

  defp resolve_request(server, request_path, query_params) do
    case PreviewAssets.response(request_path) do
      {:ok, response} ->
        {:ok, response}

      :error ->
        with {:ok, relative_path, kind} <- route_request(request_path) do
          case kind do
            :media ->
              serve_file(safe_join(server.data_dir, Path.join(["media", relative_path])),
                server: server,
                query_params: query_params
              )

            :static ->
              serve_file(safe_join(Path.join(server.data_dir, "html"), relative_path),
                server: server,
                query_params: query_params
              )

            :generated ->
              # Content is always rendered dynamically; generated files on
              # disk go stale and must never be served by the preview.
              case BDS.Preview.Router.render_route(server.project_id, request_path) do
                {:ok, response} ->
                  {:ok, apply_response_overrides(response, query_params)}

                :not_matched ->
                  render_not_found_response(server.project_id, query_params)
              end
          end
        end
    end
  end

  defp serve_file({:error, :not_found}, opts) do
    render_not_found_response(opts[:server].project_id, opts[:query_params])
  end

  defp serve_file(resolved_path, opts) do
    case read_response(resolved_path) do
      {:error, :not_found} ->
        render_not_found_response(opts[:server].project_id, opts[:query_params])

      {:ok, response} ->
        {:ok, apply_response_overrides(response, opts[:query_params])}

      other ->
        other
    end
  end

  defp resolve_draft_request(project_id, post_id, query_params) do
    with {:ok, payload} <- load_draft_preview_payload(project_id, post_id, query_params) do
      body =
        case Rendering.render_post_page(project_id, payload.template_slug, payload) do
          {:ok, rendered} -> rendered
          {:error, _reason} -> render_draft(payload)
        end
        |> apply_preview_overrides(query_params)

      {:ok, %{content_type: "text/html", body: body}}
    end
  end

  defp load_draft_preview_payload(project_id, post_id, query_params) do
    try do
      post = Posts.get_post!(post_id)

      if post.project_id == project_id do
        {:ok, draft_preview_payload(post, query_params)}
      else
        {:error, :not_found}
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  defp draft_preview_payload(post, query_params) do
    requested_language = query_params |> Map.get("lang") |> normalize_requested_language()

    effective_slug =
      post.template_slug ||
        TemplateSelection.resolve_post_template_slug(post.project_id, post.tags, post.categories)

    case draft_preview_translation(post.id, requested_language, post.language) do
      %Translation{} = translation ->
        %{
          id: translation.id,
          title: translation.title,
          content: Posts.editor_body(translation),
          body: Posts.editor_body(translation),
          slug: post.slug,
          language: translation.language,
          excerpt: translation.excerpt,
          template_slug: effective_slug
        }

      nil ->
        %{
          id: post.id,
          title: post.title,
          content: Posts.editor_body(post),
          body: Posts.editor_body(post),
          slug: post.slug,
          language: post.language,
          excerpt: post.excerpt,
          template_slug: effective_slug
        }
    end
  end

  defp draft_preview_translation(_post_id, nil, _post_language), do: nil

  defp draft_preview_translation(_post_id, requested_language, post_language)
       when requested_language == post_language, do: nil

  defp draft_preview_translation(post_id, requested_language, _post_language) do
    Repo.get_by(Translation, translation_for: post_id, language: requested_language)
  end

  defp normalize_requested_language(nil), do: nil
  defp normalize_requested_language(""), do: nil
  defp normalize_requested_language(language), do: language |> String.trim() |> String.downcase()

  defp route_request(request_path) do
    normalized = request_path |> URI.parse() |> Map.get(:path, "/")
    segments = String.split(normalized, "/", trim: true)

    cond do
      Enum.any?(segments, &(&1 == "..")) ->
        {:error, :not_found}

      match?(["media" | _], segments) ->
        {:ok, Path.join(tl(segments)), :media}

      match?(["pagefind" | _], segments) ->
        {:ok, Path.join(segments), :static}

      normalized == "/" ->
        {:ok, "index.html", :generated}

      Path.extname(List.last(segments) || "") != "" ->
        {:ok, Path.join(segments), :generated}

      true ->
        {:ok, Path.join(segments ++ ["index.html"]), :generated}
    end
  end

  defp accept_loop(listener, project_id, owner_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
               maybe_allow_repo(owner_pid)
               serve_client(socket, project_id)
             end) do
          {:ok, pid} ->
            # Hand the socket to the request task so an inflight request survives
            # the acceptor being shut down (it would otherwise close the socket).
            _ = :gen_tcp.controlling_process(socket, pid)
            GenServer.cast(__MODULE__, {:track_request, pid})

          _other ->
            :ok
        end

        accept_loop(listener, project_id, owner_pid)

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

    case resolve_http_request(project_id, method, path, query_params) do
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
      error ->
        Logger.debug("swallowed preview maybe_allow_repo error: #{inspect(error)}")
        :ok
    end
  end

  # Graceful shutdown: stop accepting new connections, then wait for inflight
  # request tasks to finish before reporting the server stopped. The stop call
  # is parked (no immediate reply) and finalized from the :DOWN handlers, so the
  # GenServer stays available to serve the requests it is draining.
  defp begin_graceful_stop(%{current: current} = state, from) do
    current = %{current | is_running: false}
    put_current_server(current)

    _ = :gen_tcp.close(current.listener)
    if is_pid(current.acceptor_pid), do: Process.exit(current.acceptor_pid, :normal)

    if map_size(current.inflight) == 0 do
      clear_current_server()
      {:reply, :ok, %{state | current: nil, stopping: nil}}
    else
      timer = Process.send_after(self(), :drain_timeout, @drain_timeout)
      {:noreply, %{state | current: current, stopping: %{from: from, timer: timer}}}
    end
  end

  defp maybe_finalize_stop(
         %{stopping: %{from: from, timer: timer}, current: %{inflight: inflight}} = state
       )
       when map_size(inflight) == 0 do
    if is_reference(timer), do: Process.cancel_timer(timer)
    clear_current_server()
    GenServer.reply(from, :ok)
    %{state | current: nil, stopping: nil}
  end

  defp maybe_finalize_stop(state), do: state

  defp force_finalize_stop(%{stopping: %{from: from}, current: %{inflight: inflight}} = state) do
    kill_inflight(inflight)
    clear_current_server()
    GenServer.reply(from, :ok)
    %{state | current: nil, stopping: nil}
  end

  defp force_finalize_stop(state), do: state

  # Hard stop used when restarting the server in place (no graceful drain).
  defp stop_current_server(%{current: %{} = current} = state) do
    _ = :gen_tcp.close(current.listener)
    if is_pid(current.acceptor_pid), do: Process.exit(current.acceptor_pid, :normal)
    kill_inflight(current.inflight)
    clear_current_server()
    %{state | current: nil}
  end

  defp stop_current_server(state), do: state

  defp kill_inflight(inflight) do
    Enum.each(inflight, fn {ref, pid} ->
      Process.demonitor(ref, [:flush])
      if is_pid(pid), do: Process.exit(pid, :kill)
    end)
  end

  defp start_server(state, project_id, data_dir, owner_pid) do
    state = stop_current_server(state)
    maybe_allow_repo(owner_pid)

    {:ok, listener, port} = listen_with_retry(@listen_retry_attempts)

    acceptor_pid = spawn_link(fn -> accept_loop(listener, project_id, owner_pid) end)

    server = %{
      project_id: project_id,
      data_dir: data_dir,
      host: @host,
      port: port,
      is_running: true,
      owner_pid: owner_pid,
      listener: listener,
      acceptor_pid: acceptor_pid,
      inflight: %{}
    }

    put_current_server(server)
    {{:ok, public_server(server)}, %{state | current: server}}
  end

  defp listen_with_retry(attempts_left) when attempts_left > 0 do
    case listen_on_port(@preferred_port) do
      {:ok, listener, port} ->
        {:ok, listener, port}

      {:error, :eaddrinuse} when attempts_left > 1 ->
        Process.sleep(@listen_retry_delay_ms)
        listen_with_retry(attempts_left - 1)

      {:error, :eaddrinuse} ->
        listen_on_port(0)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp listen_on_port(port) do
    case :gen_tcp.listen(port, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           ip: {127, 0, 0, 1}
         ]) do
      {:ok, listener} ->
        {:ok, {_host, actual_port}} = :inet.sockname(listener)
        {:ok, listener, actual_port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_tracked_request(fun) when is_function(fun, 0) do
    owner_pid = self()

    task =
      Task.Supervisor.async_nolink(BDS.TCP.TaskSupervisor, fn ->
        maybe_allow_repo(owner_pid)
        fun.()
      end)

    GenServer.cast(__MODULE__, {:track_request, task.pid})
    Task.await(task, :infinity)
  end

  defp run_request(fun) when is_function(fun, 0) do
    case Application.get_env(:bds, __MODULE__, []) |> Keyword.get(:request_runner) do
      {module, opts} -> module.run(fun, opts)
      nil -> fun.()
    end
  end

  defp ensure_server_table! do
    case :ets.whereis(@server_table) do
      :undefined ->
        :ets.new(@server_table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _table ->
        :ok
    end
  end

  defp current_server(project_id) do
    case :ets.lookup(@server_table, :current) do
      [{:current, %{project_id: ^project_id} = server}] ->
        case ensure_running(server, project_id) do
          :ok -> {:ok, server}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :not_running}
    end
  end

  defp put_current_server(server) do
    true = :ets.insert(@server_table, {:current, server})
    :ok
  end

  defp clear_current_server do
    true = :ets.delete(@server_table, :current)
    :ok
  end

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

  defp apply_response_overrides(
         %{content_type: content_type, body: body} = response,
         query_params
       )
       when is_binary(content_type) and is_binary(body) do
    if String.starts_with?(content_type, "text/html") do
      %{response | body: apply_preview_overrides(body, query_params)}
    else
      response
    end
  end

  defp apply_preview_overrides(body, query_params)
       when is_binary(body) and is_map(query_params) do
    theme_override = normalize_pico_theme_override(query_params["theme"])
    mode_override = normalize_mode_override(query_params["mode"])

    body
    |> override_pico_stylesheet_href(theme_override)
    |> override_html_attribute("data-theme", mode_override)
    |> override_html_attribute("data-mode", mode_override)
  end

  defp override_pico_stylesheet_href(body, nil), do: body

  defp override_pico_stylesheet_href(body, theme) do
    Regex.replace(
      ~r{/assets/pico(?:\.[a-z]+)?\.min\.css},
      body,
      PreviewAssets.stylesheet_href(theme),
      global: false
    )
  end

  defp normalize_override(nil), do: nil
  defp normalize_override(""), do: nil
  defp normalize_override(value), do: String.trim(value)

  defp normalize_pico_theme_override(value), do: normalize_override(value)

  defp normalize_mode_override(value) do
    case normalize_override(value) do
      mode when mode in ["dark", "light"] -> mode
      _other -> nil
    end
  end

  defp override_html_attribute(body, _attribute, nil), do: body

  defp override_html_attribute(body, attribute, value) do
    case Regex.run(~r/<html\b[^>]*>/, body) do
      [html_tag] ->
        replacement =
          if String.contains?(html_tag, attribute <> "=") do
            Regex.replace(~r/\s#{attribute}="[^"]*"/, html_tag, ~s( #{attribute}="#{value}"),
              global: false
            )
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
    |> maybe_put_assign(
      "pico_stylesheet_href",
      normalize_pico_theme_override(query_params["theme"]),
      &PreviewAssets.stylesheet_href/1
    )
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
