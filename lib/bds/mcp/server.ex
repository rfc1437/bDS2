defmodule BDS.MCP.Server do
  @moduledoc false

  use GenServer

  @host "127.0.0.1"
  @server_name "Blogging Desktop Server"

  def start(port \\ 0) when is_integer(port) and port >= 0 do
    pid = ensure_started()
    GenServer.call(pid, {:start_server, port, self()}, 5_000)
  end

  def stop do
    pid = ensure_started()
    GenServer.call(pid, :stop_server, 5_000)
  end

  def current do
    pid = ensure_started()
    GenServer.call(pid, :current, 5_000)
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{current: nil}, name: __MODULE__)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:start_server, port, owner_pid}, _from, state) do
    state = stop_current_server(state)
    maybe_allow_repo(owner_pid)

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, actual_port} = :inet.port(listener)
    acceptor_pid = spawn_link(fn -> accept_loop(listener) end)

    current = %{
      host: @host,
      port: actual_port,
      listener: listener,
      acceptor_pid: acceptor_pid,
      is_running: true
    }

    {:reply, {:ok, public_server(current)}, %{state | current: current}}
  end

  def handle_call(:stop_server, _from, state) do
    {:reply, :ok, stop_current_server(state)}
  end

  def handle_call(:current, _from, state) do
    {:reply, state.current && public_server(state.current), state}
  end

  def handle_call({:http_request, request}, _from, state) do
    response = handle_mcp_request(request)
    {:reply, response, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, pid} = start_link([])
        pid

      pid ->
        pid
    end
  end

  defp accept_loop(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
          serve_client(socket)
        end)

        accept_loop(listener)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve_client(socket) do
    response =
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, request} ->
          request
          |> parse_http_request()
          |> dispatch_http_request()

        {:error, _reason} ->
          http_error_response(400)
      end

    :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  defp parse_http_request(request) do
    with [header_blob, body] <- String.split(request, "\r\n\r\n", parts: 2),
         [request_line | header_lines] <- String.split(header_blob, "\r\n", trim: true),
         [method, target, _version] <- String.split(request_line, " ", parts: 3) do
      headers =
        Enum.reduce(header_lines, %{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
            _other -> acc
          end
        end)

      {:ok, %{method: method, target: target, headers: headers, body: body}}
    else
      _other -> {:error, :bad_request}
    end
  end

  defp dispatch_http_request({:error, :bad_request}), do: http_error_response(400)

  defp dispatch_http_request({:ok, %{method: "OPTIONS"}}) do
    http_response(204, "", "text/plain", %{})
  end

  defp dispatch_http_request({:ok, %{method: "POST", target: target} = request}) do
    case URI.parse(target) do
      %URI{path: "/mcp"} ->
        GenServer.call(__MODULE__, {:http_request, request}, 5_000)
        |> encode_http_response(request.headers)

      _other ->
        http_error_response(404, request.headers)
    end
  end

  defp dispatch_http_request({:ok, request}), do: http_error_response(404, request.headers)

  defp handle_mcp_request(%{headers: headers} = request) do
    with :ok <- ensure_local_origin(headers),
         {:ok, payload} <- Jason.decode(request.body),
         {:ok, response} <- route_rpc(payload) do
      {:ok, 200, response}
    else
      {:error, :forbidden_origin} -> {:error, 403, "Forbidden"}
      {:error, :invalid_json} -> {:error, 400, "Bad Request"}
      {:error, response} when is_map(response) -> {:ok, 200, response}
    end
  end

  defp route_rpc(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload) do
    params = Map.get(payload, "params", %{})

    case method do
      "initialize" ->
        {:ok,
         success_response(id, %{
           "protocolVersion" => Map.get(params, "protocolVersion", "2025-03-26"),
           "capabilities" => %{"tools" => %{}, "resources" => %{}},
           "serverInfo" => %{
             "name" => @server_name,
             "version" => Application.spec(:bds, :vsn) |> to_string()
           }
         })}

      "tools/list" ->
        {:ok, success_response(id, %{"tools" => BDS.MCP.list_tools()})}

      "tools/call" ->
        call_tool(id, params)

      "resources/list" ->
        {:ok, success_response(id, %{"resources" => BDS.MCP.list_resources()})}

      "resources/templates/list" ->
        {:ok, success_response(id, %{"resourceTemplates" => BDS.MCP.list_resource_templates()})}

      "resources/read" ->
        read_resource(id, params)

      _other ->
        {:error, error_response(id, -32601, "Method not found")}
    end
  end

  defp route_rpc(_payload), do: {:error, :invalid_json}

  defp call_tool(id, %{"name" => name} = params) do
    arguments = Map.get(params, "arguments", %{})

    case BDS.MCP.call_tool(name, arguments) do
      {:ok, result} ->
        {:ok, success_response(id, %{"content" => [%{"type" => "json", "json" => result}]})}

      {:error, :unknown_tool} ->
        {:error, error_response(id, -32601, "Unknown tool")}

      {:error, :not_found} ->
        {:error, error_response(id, -32004, "Not found")}

      {:error, reason} ->
        {:error, error_response(id, -32000, inspect(reason))}
    end
  end

  defp call_tool(id, _params), do: {:error, error_response(id, -32602, "Invalid params")}

  defp read_resource(id, %{"uri" => uri}) do
    case BDS.MCP.read_resource(uri) do
      {:ok, result} ->
        {:ok,
         success_response(id, %{
           "contents" => [resource_content(uri, result)]
         })}

      {:error, :not_found} ->
        {:error, error_response(id, -32004, "Not found")}

      {:error, :invalid_cursor} ->
        {:error, error_response(id, -32602, "Invalid cursor")}
    end
  end

  defp read_resource(id, _params), do: {:error, error_response(id, -32602, "Invalid params")}

  defp resource_content(uri, %{"blob" => blob, "mimeType" => mime_type})
       when is_binary(blob) and is_binary(mime_type) do
    %{"uri" => uri, "mimeType" => mime_type, "blob" => blob}
  end

  defp resource_content(uri, result) do
    %{"uri" => uri, "mimeType" => "application/json", "text" => Jason.encode!(result)}
  end

  defp success_response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp ensure_local_origin(headers) do
    case Map.get(headers, "origin") do
      nil -> :ok
      origin -> if local_origin?(origin), do: :ok, else: {:error, :forbidden_origin}
    end
  end

  defp local_origin?(origin) do
    case URI.parse(origin) do
      %URI{host: host} when host in ["localhost", "127.0.0.1"] -> true
      _other -> false
    end
  end

  defp cors_headers(headers) do
    allow_origin = Map.get(headers, "origin", "*")

    [
      {"access-control-allow-origin", allow_origin},
      {"access-control-allow-methods", "POST, OPTIONS"},
      {"access-control-allow-headers", "content-type, accept, origin"},
      {"access-control-max-age", "86400"}
    ]
  end

  defp encode_http_response({:ok, status, body}, headers),
    do: json_http_response(status, body, headers)

  defp encode_http_response({:error, status, body}, headers),
    do: text_http_response(status, body, headers)

  defp json_http_response(status, body, headers) do
    http_response(status, Jason.encode!(body), "application/json", headers)
  end

  defp text_http_response(status, body, headers) do
    http_response(status, body, "text/plain", headers)
  end

  defp http_response(status, body, content_type, headers) do
    header_lines =
      [
        {"content-type", content_type <> "; charset=utf-8"},
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
        | cors_headers(headers)
      ]
      |> Enum.map(fn {name, value} -> [name, ": ", value, "\r\n"] end)

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      http_reason_phrase(status),
      "\r\n",
      header_lines,
      "\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  defp http_reason_phrase(200), do: "OK"
  defp http_reason_phrase(204), do: "No Content"
  defp http_reason_phrase(400), do: "Bad Request"
  defp http_reason_phrase(403), do: "Forbidden"
  defp http_reason_phrase(404), do: "Not Found"
  defp http_reason_phrase(_status), do: "Internal Server Error"

  defp http_error_response(status, headers \\ %{}),
    do: http_response(status, reason_body(status), "text/plain", headers)

  defp reason_body(400), do: "Bad Request"
  defp reason_body(404), do: "Not Found"

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

  defp public_server(server), do: Map.take(server, [:host, :port, :is_running])
end
