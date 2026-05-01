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
      pubsub: Keyword.get(opts, :pubsub, BDS.PubSub)
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
    {:ok, notifications} = CliSync.db_file_change_detected()
    {:ok, _pruned} = CliSync.prune_notifications()

    Enum.each(notifications, fn notification ->
      Phoenix.PubSub.broadcast(
        state.pubsub,
        topic(),
        {:entity_changed, notification_payload(notification)}
      )
    end)

    state
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
