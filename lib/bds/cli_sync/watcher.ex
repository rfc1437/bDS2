defmodule BDS.CliSync.Watcher do
  @moduledoc false

  use GenServer

  alias BDS.CliSync

  @topic "entity:changed"
  @default_poll_interval_ms 100

  def start_link(opts \\ []) do
    case Keyword.pop(opts, :name, __MODULE__) do
      {nil, init_opts} -> GenServer.start_link(__MODULE__, init_opts)
      {name, init_opts} -> GenServer.start_link(__MODULE__, init_opts, name: name)
    end
  end

  def topic, do: @topic

  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :poll_now)
  end

  @impl true
  def init(opts) do
    state = %{
      poll_interval_ms:
        normalize_positive_integer(
          Keyword.get(opts, :poll_interval_ms),
          @default_poll_interval_ms
        ),
      pubsub: Keyword.get(opts, :pubsub, BDS.PubSub),
      data_version_reader: Keyword.get(opts, :data_version_reader, &CliSync.data_version/0),
      notification_fetcher:
        Keyword.get(opts, :notification_fetcher, &CliSync.db_file_change_detected/0),
      pruner: Keyword.get(opts, :pruner, &CliSync.prune_notifications/0),
      last_data_version: nil
    }

    {:ok, schedule_poll(state)}
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    {:reply, :ok, process_notifications(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply,
     state
     |> process_notifications()
     |> schedule_poll()}
  end

  defp process_notifications(state) do
    current_data_version = state.data_version_reader.()

    if state.last_data_version == current_data_version do
      %{state | last_data_version: current_data_version}
    else
      {:ok, notifications} = state.notification_fetcher.()
      {:ok, _pruned} = state.pruner.()

      Enum.each(notifications, fn notification ->
        Phoenix.PubSub.broadcast(
          state.pubsub,
          topic(),
          {:entity_changed, notification_payload(notification)}
        )
      end)

      %{state | last_data_version: current_data_version}
    end
  end

  defp notification_payload(notification) do
    %{
      entity: notification.entity_type,
      entity_id: notification.entity_id,
      action: notification.action
    }
  end

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, state.poll_interval_ms)
    state
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default
end
