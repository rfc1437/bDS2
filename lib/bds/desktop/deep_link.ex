defmodule BDS.Desktop.DeepLink do
  @moduledoc """
  Receives OS URL-scheme events for the `bds2://` scheme and routes them to the
  live shell (spec: script.allium `BlogmarkReceived`).

  On macOS the `BDS2.app` bundle registers `bds2://` as a custom URL scheme via
  the `CFBundleURLTypes` entry in its `Info.plist` (built by `BDS.MacBundle` /
  `mix bds.bundle.macos`). When the browser bookmarklet navigates to
  `bds2://new-post?title=&url=`, the OS launches/raises the app and `Desktop.Env`
  relays erlang `:wx`'s `{:open_url, Url}` app event (where `Url` is the URL as a
  charlist). This GenServer subscribes to those events and forwards recognised
  `bds2://` links to the live shell.

  Cold start matters here: when the bookmarklet *launches* the app, the deep
  link arrives during startup, before the LiveView shell's websocket has
  connected. Such links are queued and replayed the moment a shell registers via
  `attach/2`; while a shell is connected, links are delivered to it directly.

  The `bds2://` scheme is distinct from the legacy app's `bds://` so the two
  installs do not contend for the same registration.
  """

  use GenServer

  require Logger

  @scheme "bds2://"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers the live shell `pid` as the deep-link sink and immediately replays
  any links that arrived before a shell was connected. Future links are sent to
  this pid until it dies, after which links queue again.
  """
  @spec attach(pid(), GenServer.server()) :: :ok
  def attach(shell_pid, server \\ __MODULE__) when is_pid(shell_pid) do
    GenServer.call(server, {:attach, shell_pid})
  end

  @impl true
  def init(_opts) do
    subscribe_to_env()
    {:ok, %{shell: nil, pending: []}}
  end

  @impl true
  def handle_call({:attach, pid}, _from, state) do
    Process.monitor(pid)

    state.pending
    |> Enum.reverse()
    |> Enum.each(&send(pid, {:blogmark_deep_link, &1}))

    {:reply, :ok, %{state | shell: pid, pending: []}}
  end

  # erlang's :wx delivers macOS app events as `{:open_url, Url}` where `Url` is
  # the URL *string itself* — a charlist on current OTP, not a list of URLs
  # (see `wx:subscribe_events/0`). Desktop.Env forwards it unchanged, so the
  # payload must be normalised to a binary before routing.
  @impl true
  def handle_info({:open_url, payload}, state) do
    {:noreply, route(to_url(payload), state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{shell: pid} = state) do
    {:noreply, %{state | shell: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Accept the charlist wx actually sends, a bare binary, or a [binary | _] list
  # (the shape Desktop.Env's docs imply), normalising all to a binary URL.
  defp to_url(value) when is_binary(value), do: value
  defp to_url([first | _]) when is_binary(first), do: first
  defp to_url(value) when is_list(value), do: List.to_string(value)
  defp to_url(_other), do: ""

  defp route(url, state) do
    cond do
      not String.starts_with?(url, @scheme) ->
        Logger.debug("ignoring non-bds2 deep link: #{inspect(url)}")
        state

      is_pid(state.shell) and Process.alive?(state.shell) ->
        send(state.shell, {:blogmark_deep_link, url})
        state

      true ->
        # No shell connected yet (cold start) — hold the link until one attaches.
        %{state | pending: [url | state.pending]}
    end
  end

  # Desktop.Env is only present when the wx desktop adapter is running. Guard the
  # subscribe so the GenServer can still start in headless/test configurations.
  defp subscribe_to_env do
    if Process.whereis(Desktop.Env) do
      try do
        Desktop.Env.subscribe()
      catch
        :exit, reason ->
          Logger.debug("swallowed deep_link Desktop.Env.subscribe exit: #{inspect(reason)}")
          :ok
      end
    end

    :ok
  end
end
