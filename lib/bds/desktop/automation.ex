defmodule BDS.Desktop.Automation do
  @moduledoc false

  use GenServer

  @ready_timeout 60_000
  @request_timeout 30_000

  def start_session(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop_session(session) do
    GenServer.stop(session, :normal, @request_timeout)
  catch
    :exit, _reason -> :ok
  end

  def snapshot(session) do
    GenServer.call(session, :snapshot, @request_timeout)
  end

  def click(session, selector) when is_binary(selector) do
    GenServer.call(session, {:click, selector}, @request_timeout)
  end

  def capture_screenshot(session, destination) when is_binary(destination) do
    GenServer.call(session, {:capture_screenshot, destination}, @request_timeout)
  end

  def child_info(session) do
    GenServer.call(session, :child_info, @request_timeout)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    screenshot_dir = Keyword.get(opts, :screenshot_dir, System.tmp_dir!())
    port = Keyword.get_lazy(opts, :port, &free_tcp_port/0)
    project_root = project_root()
    base_url = BDS.Desktop.url(port)

    File.mkdir_p!(screenshot_dir)
    ensure_http_client_started()

    app_port = start_app_process(project_root, port)
    :ok = wait_for_server(base_url)

    driver_port = start_driver_process(project_root, base_url, screenshot_dir)

    state = %{
      app_port: app_port,
      app_os_pid: port_os_pid(app_port),
      driver_port: driver_port,
      driver_os_pid: port_os_pid(driver_port),
      driver_buffer: "",
      base_url: base_url,
      screenshot_dir: screenshot_dir
    }

    {reply, state} = await_driver_ready(state)

    case reply do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {reply, state} = driver_request(state, %{"command" => "snapshot"})
    {:reply, atomize_map(reply), state}
  end

  def handle_call({:click, selector}, _from, state) do
    {reply, state} = driver_request(state, %{"command" => "click", "selector" => selector})
    {:reply, normalize_simple_reply(reply), state}
  end

  def handle_call({:capture_screenshot, destination}, _from, state) do
    File.mkdir_p!(Path.dirname(destination))

    {reply, state} =
      driver_request(state, %{"command" => "screenshot", "path" => destination})

    {:reply, reply, state}
  end

  def handle_call(:child_info, _from, state) do
    {:reply, %{app_os_pid: state.app_os_pid, driver_os_pid: state.driver_os_pid}, state}
  end

  @impl true
  def terminate(_reason, state) do
    shutdown_driver(state)
    shutdown_app(state)
    :ok
  end

  defp start_app_process(project_root, port) do
    executable = System.find_executable("elixir") || raise "missing elixir executable"

    Port.open(
      {:spawn_executable, executable},
      [
        :binary,
        :stderr_to_stdout,
        :exit_status,
        :use_stdio,
        :hide,
        {:cd, project_root},
        {:env,
         [
           {~c"MIX_ENV", ~c"test"},
           {~c"BDS_DESKTOP_AUTOMATION", ~c"1"},
           {~c"BDS_DESKTOP_PORT", String.to_charlist(Integer.to_string(port))}
         ]},
        {:args,
         [
           "-S",
           "mix",
           "run",
           "scripts/desktop_automation_app.exs"
         ]}
      ]
    )
  end

  defp start_driver_process(project_root, base_url, screenshot_dir) do
    executable = System.find_executable("node") || raise "missing node executable"

    Port.open(
      {:spawn_executable, executable},
      [
        :binary,
        :stderr_to_stdout,
        :exit_status,
        :use_stdio,
        :hide,
        {:cd, project_root},
        {:args,
         [
           Path.join([project_root, "scripts", "desktop_automation_runner.mjs"]),
           base_url,
           screenshot_dir
         ]}
      ]
    )
  end

  defp await_driver_ready(state) do
    receive_driver_message(state, @ready_timeout, fn message ->
      case message do
        %{"status" => "ready"} -> {:ok, :ok}
        %{"status" => "error", "message" => reason} -> {:ok, {:error, reason}}
        _other -> :continue
      end
    end)
  end

  defp driver_request(state, payload) do
    ref = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    request = Map.put(payload, "ref", ref)
    Port.command(state.driver_port, Jason.encode!(request) <> "\n")

    receive_driver_message(state, @request_timeout, fn message ->
      case message do
        %{"ref" => ^ref, "status" => "ok", "result" => result} -> {:ok, result}
        %{"ref" => ^ref, "status" => "error", "message" => reason} ->
          raise "desktop automation request failed: #{reason}"

        _other ->
          :continue
      end
    end)
  end

  defp safe_driver_request(state, payload) do
    driver_request(state, payload)
  rescue
    _error -> :ok
  end

  defp shutdown_driver(state) do
    _ = safe_driver_request(state, %{"command" => "close"})
    await_port_exit(state[:driver_port], 5_000)
    safe_close_port(state[:driver_port])
  end

  defp shutdown_app(state) do
    if state[:app_port] do
      Port.command(state.app_port, "stop\n")
      await_port_exit(state.app_port, 10_000)
      safe_close_port(state.app_port)
    end
  end

  defp receive_driver_message(state, timeout, matcher) do
    deadline = System.monotonic_time(:millisecond) + timeout
    process_driver_messages(state, deadline, matcher)
  end

  defp process_driver_messages(state, deadline, matcher) do
    {messages, buffer} = split_driver_buffer(state.driver_buffer)

    case Enum.reduce_while(messages, {%{state | driver_buffer: buffer}, nil}, fn message, {acc, _} ->
           decoded = Jason.decode!(message)

           case matcher.(decoded) do
             {:ok, reply} -> {:halt, {acc, reply}}
             :continue -> {:cont, {acc, nil}}
           end
         end) do
      {state, nil} ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {port, {:data, data}} when port == state.driver_port ->
            process_driver_messages(%{state | driver_buffer: state.driver_buffer <> data}, deadline, matcher)

          {port, {:exit_status, status}} when port == state.driver_port ->
            raise "desktop automation driver exited with status #{status}"

          {port, {:exit_status, status}} when port == state.app_port ->
            raise "desktop app process exited with status #{status}"

          {_port, {:data, _data}} ->
            process_driver_messages(state, deadline, matcher)
        after
          remaining -> raise "desktop automation timed out waiting for driver response"
        end

      {state, reply} ->
        {reply, state}
    end
  end

  defp split_driver_buffer(buffer) do
    case String.split(buffer, "\n") do
      [] -> {[], ""}
      [single] -> {[], single}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp wait_for_server(base_url) do
    deadline = System.monotonic_time(:millisecond) + @ready_timeout
    do_wait_for_server(base_url, deadline)
  end

  defp do_wait_for_server(base_url, deadline) do
    case :httpc.request(:get, {String.to_charlist(base_url <> "health"), []}, [], []) do
      {:ok, {{_, 200, _}, _headers, _body}} -> :ok
      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "desktop app process did not become healthy in time"
        else
          Process.sleep(200)
          do_wait_for_server(base_url, deadline)
        end
    end
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp ensure_http_client_started do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp await_port_exit(nil, _timeout), do: :ok

  defp await_port_exit(port, timeout) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> await_port_exit(port, timeout)
    after
      timeout -> :ok
    end
  end

  defp port_os_pid(nil), do: nil

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _other -> nil
    end
  end

  defp safe_close_port(nil), do: :ok

  defp safe_close_port(port) do
    Port.close(port)
  catch
    :error, _reason -> :ok
  end

  defp normalize_simple_reply("ok"), do: :ok
  defp normalize_simple_reply(reply), do: reply

  defp atomize_map(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      normalized_key = if is_binary(key), do: String.to_atom(key), else: key
      normalized_value = if is_map(value), do: atomize_map(value), else: value
      {normalized_key, normalized_value}
    end)
  end

  defp project_root do
    Path.expand("../../..", __DIR__)
  end
end