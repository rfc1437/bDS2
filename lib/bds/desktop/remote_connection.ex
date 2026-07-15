defmodule BDS.Desktop.RemoteConnection do
  @moduledoc """
  GUI remote mode (issue #26, phase 5).

  Connects the desktop app to a headless bDS2 server over the same SSH
  channel (and the same public keys) the TUI uses: `:ssh.connect` with
  public-key auth, then an OTP TCP/IP tunnel to the server's loopback HTTP
  endpoint. The webview then loads the local tunnel end — the server never
  exposes HTTP.

  Client key material lives in the same private `ssh/` directory next to
  the database (`BDS.Server.ssh_dir/0`): an `id_ed25519`/`id_rsa` identity
  and a `known_hosts` written on first connect.
  """

  use GenServer
  use Gettext, backend: BDS.Gettext

  require Logger

  @default_ssh_port 2222
  @tunnel_timeout_ms 10_000

  def start_link(opts \\ []) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {nil, init_opts} -> GenServer.start_link(__MODULE__, init_opts)
      {name, init_opts} -> GenServer.start_link(__MODULE__, init_opts, name: name)
    end
  end

  @doc """
  Parses `user@host[:port]` into connection parameters. The port is the
  server's SSH port (default #{@default_ssh_port}).
  """
  @spec parse_target(String.t()) ::
          {:ok, %{user: String.t(), host: String.t(), port: pos_integer()}}
          | {:error, :invalid_target}
  def parse_target(target) when is_binary(target) do
    with [user, rest] when user != "" <- String.split(String.trim(target), "@", parts: 2),
         {:ok, host, port} <- parse_host_port(rest) do
      {:ok, %{user: user, host: host, port: port}}
    else
      _other -> {:error, :invalid_target}
    end
  end

  defp parse_host_port(rest) do
    case String.split(rest, ":", parts: 2) do
      [host] when host != "" ->
        {:ok, host, @default_ssh_port}

      [host, port] when host != "" ->
        case Integer.parse(port) do
          {number, ""} when number > 0 -> {:ok, host, number}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  @doc "Connects and tunnels; returns the local URL the webview should load."
  @spec connect(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def connect(server \\ __MODULE__, target) do
    GenServer.call(server, {:connect, target}, @tunnel_timeout_ms + 5_000)
  end

  @spec disconnect(GenServer.server()) :: :ok
  def disconnect(server \\ __MODULE__) do
    GenServer.call(server, :disconnect)
  end

  @spec status(GenServer.server()) :: :disconnected | {:connected, String.t(), String.t()}
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Human-readable connection error for menu/shell error reporting."
  @spec format_reason(term()) :: String.t()
  def format_reason(:invalid_target) do
    dgettext("ui", "Use the form user@host or user@host:port.")
  end

  def format_reason(%{message: message}) when is_binary(message), do: message
  def format_reason(reason), do: inspect(reason)

  ## GenServer callbacks

  @impl true
  def init(opts) do
    overrides = Keyword.get(opts, :test_overrides, [])

    {:ok,
     %{
       conn: nil,
       monitor: nil,
       target: nil,
       url: nil,
       connect_fun: Keyword.get(overrides, :connect_fun, &:ssh.connect/3),
       tunnel_fun: Keyword.get(overrides, :tunnel_fun, &:ssh.tcpip_tunnel_to_server/6),
       close_fun: Keyword.get(overrides, :close_fun, &:ssh.close/1),
       ssh_dir_fun: Keyword.get(overrides, :ssh_dir_fun, &BDS.Server.ssh_dir/0)
     }}
  end

  @impl true
  def handle_call({:connect, target}, _from, state) do
    state = close_current(state)

    with {:ok, parsed} <- parse_target(target),
         {:ok, conn} <- do_connect(state, parsed),
         {:ok, local_port} <- do_tunnel(state, conn) do
      url = "http://127.0.0.1:#{local_port}/"

      {:reply, {:ok, url},
       %{
         state
         | conn: conn,
           monitor: Process.monitor(conn),
           target: String.trim(target),
           url: url
       }}
    else
      {:error, reason} = error ->
        Logger.warning("Remote connection to #{inspect(target)} failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    {:reply, :ok, close_current(state)}
  end

  def handle_call(:status, _from, %{conn: nil} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, {:connected, state.target, state.url}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state) do
    Logger.warning("Remote SSH connection lost: #{inspect(reason)}")
    {:noreply, %{state | conn: nil, monitor: nil, target: nil, url: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Internal helpers

  defp do_connect(state, %{user: user, host: host, port: port}) do
    ssh_dir = BDS.Server.ensure_ssh_dir!(state.ssh_dir_fun.())

    state.connect_fun.(String.to_charlist(host), port,
      user: String.to_charlist(user),
      user_dir: String.to_charlist(ssh_dir),
      auth_methods: ~c"publickey",
      # First connect records the host key in <ssh_dir>/known_hosts;
      # later connects verify against it (trust-on-first-use).
      silently_accept_hosts: true,
      connect_timeout: @tunnel_timeout_ms
    )
  end

  defp do_tunnel(state, conn) do
    remote_port = Application.get_env(:bds, :desktop)[:port] || 4010

    state.tunnel_fun.(conn, ~c"127.0.0.1", 0, ~c"127.0.0.1", remote_port, @tunnel_timeout_ms)
  end

  defp close_current(%{conn: nil} = state), do: state

  defp close_current(state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    _ = state.close_fun.(state.conn)
    %{state | conn: nil, monitor: nil, target: nil, url: nil}
  end
end
