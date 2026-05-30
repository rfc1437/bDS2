defmodule BDS.Desktop.DeepLink do
  @moduledoc """
  Receives OS URL-scheme events for the `bds2://` scheme and routes them to the
  shell (spec: script.allium `BlogmarkReceived`).

  On macOS the app bundle registers `bds2://` as a custom URL scheme (see the
  `CFBundleURLTypes` entry in the packaged `Info.plist`). When the browser
  bookmarklet navigates to `bds2://new-post?title=&url=`, the OS launches/raises
  the app and `Desktop.Env` delivers an `{:open_url, [url]}` event. This
  GenServer subscribes to those events and forwards recognised `bds2://` links to
  the live shell over PubSub, where `BDS.Blogmark` turns them into draft posts.

  The `bds2://` scheme is distinct from the legacy app's `bds://` so the two
  installs do not contend for the same registration.
  """

  use GenServer

  require Logger

  alias BDS.CliSync.Watcher

  @scheme "bds2://"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    pubsub = Keyword.get(opts, :pubsub, BDS.PubSub)
    topic = Keyword.get(opts, :topic, Watcher.topic())

    subscribe_to_env()

    {:ok, %{pubsub: pubsub, topic: topic}}
  end

  # Desktop.Env delivers OS events as {event_name, args} tuples.
  @impl true
  def handle_info({:open_url, [url | _rest]}, state) when is_binary(url) do
    {:noreply, route(url, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp route(url, state) do
    if String.starts_with?(url, @scheme) do
      Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:blogmark_deep_link, url})
    else
      Logger.debug("ignoring non-bds2 deep link: #{inspect(url)}")
    end

    state
  end

  # Desktop.Env is only present when the wx desktop adapter is running. Guard the
  # subscribe so the GenServer can still start in headless/test configurations.
  defp subscribe_to_env do
    if Process.whereis(Desktop.Env) do
      try do
        Desktop.Env.subscribe()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
