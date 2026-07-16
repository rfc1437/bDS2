defmodule BDS.Server do
  @moduledoc """
  Headless server mode (issue #26).

  Boots the app without any wx window and serves clients over a single SSH
  daemon: TUI sessions run server-side via `ExRatatui.SSH` (only terminal
  cells cross the wire), and GUI clients tunnel to the loopback HTTP
  endpoint through the same daemon (`tcpip_tunnel_out`). Authentication is
  public-key only; host key and `authorized_keys` live in the private app
  data dir next to the database — never in the repo or a priv dir.
  """

  @doc """
  Resolves the boot mode from the `BDS_MODE` environment variable:
  `"server"` (headless + SSH daemon), `"tui"` (headless + SSH daemon +
  a TUI attached to the launching terminal), anything else is desktop.
  """
  @spec mode(String.t() | nil) :: :desktop | :server | :tui
  def mode(value \\ System.get_env("BDS_MODE"))

  def mode(value) when is_binary(value) do
    case String.downcase(value) do
      "server" -> :server
      "tui" -> :tui
      _other -> :desktop
    end
  end

  def mode(nil), do: :desktop

  @doc """
  The mode the app actually boots in: the resolved `BDS_MODE`, except that
  desktop mode falls back to the TUI when no graphical display is available
  (issue #33). Starting the app on a display-less Linux server then still
  opens a UI — the terminal one — instead of crashing wx.

  Only non-Darwin unix systems fall back: they need `DISPLAY` or
  `WAYLAND_DISPLAY` to run wx, while macOS and Windows always have a
  graphical session for a launched app.
  """
  @spec effective_mode(:desktop | :server | :tui, {atom(), atom()}, %{
          optional(String.t()) => String.t()
        }) :: :desktop | :server | :tui
  def effective_mode(mode \\ mode(), os_type \\ :os.type(), env \\ System.get_env())

  def effective_mode(:desktop, {:unix, os}, env) when os != :darwin do
    if Enum.any?(["DISPLAY", "WAYLAND_DISPLAY"], &(env[&1] not in [nil, ""])),
      do: :desktop,
      else: :tui
  end

  def effective_mode(mode, _os_type, _env), do: mode

  @doc """
  Whether the HTTP endpoint requires the desktop webview auth token. Only
  desktop mode does: in server/tui mode the endpoint stays loopback-only
  and clients arrive through the key-authenticated SSH tunnel, which the
  per-boot webview token would otherwise lock out.
  """
  @spec desktop_auth_required?(:desktop | :server | :tui) :: boolean()
  def desktop_auth_required?(mode \\ effective_mode())
  def desktop_auth_required?(:desktop), do: true
  def desktop_auth_required?(_mode), do: false

  @doc "SSH key-material directory: `<data dir>/ssh` next to the database."
  @spec ssh_dir() :: Path.t()
  def ssh_dir do
    Application.get_env(:bds, BDS.Repo)[:database]
    |> Path.dirname()
    |> Path.join("ssh")
  end

  @doc """
  Ensures the SSH directory exists with an `authorized_keys` file (created
  empty and chmod 600 on first boot; existing keys are never touched).
  """
  @spec ensure_ssh_dir!(Path.t()) :: Path.t()
  def ensure_ssh_dir!(dir) do
    File.mkdir_p!(dir)
    keys_path = Path.join(dir, "authorized_keys")

    unless File.exists?(keys_path) do
      File.write!(keys_path, "")
      File.chmod!(keys_path, 0o600)
    end

    dir
  end

  @doc """
  Options for `ExRatatui.SSH.Daemon`: serves `BDS.TUI`, public-key auth
  only, and allows TCP/IP tunneling out so GUI clients can reach the
  loopback HTTP endpoint through the SSH connection.
  """
  @spec daemon_opts(Path.t()) :: keyword()
  def daemon_opts(dir \\ ssh_dir()) do
    dir = ensure_ssh_dir!(dir)
    system_dir = ExRatatui.SSH.Daemon.ensure_host_key!(dir)

    [
      mod: BDS.TUI,
      port: ssh_port(),
      system_dir: system_dir,
      user_dir: String.to_charlist(dir),
      auth_methods: ~c"publickey",
      tcpip_tunnel_out: true
    ]
  end

  @doc "SSH listen port: `BDS_SSH_PORT` env or `:bds, :server` config."
  @spec ssh_port() :: pos_integer()
  def ssh_port do
    case System.get_env("BDS_SSH_PORT") do
      value when is_binary(value) and value != "" -> String.to_integer(value)
      _other -> Application.get_env(:bds, :server)[:ssh_port] || 2222
    end
  end

  @doc false
  # Child spec that defers all filesystem work (key generation) to process
  # start, so building a children list never touches the data dir.
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  @doc false
  def start_link do
    ExRatatui.SSH.Daemon.start_link(daemon_opts())
  end
end
