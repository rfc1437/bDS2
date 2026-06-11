defmodule BDS.AI.InFlight do
  @moduledoc false

  # Registry of in-flight chat tasks keyed by conversation id. The named ETS
  # table is owned by this supervised GenServer (started from the application
  # supervision tree), so registrations survive the exit of the registering
  # process and there is no creation race between concurrent first callers.
  use GenServer

  @table :bds_ai_in_flight

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  def register(conversation_id, pid) when is_binary(conversation_id) and is_pid(pid) do
    :ets.insert(@table, {conversation_id, pid})
    :ok
  end

  def unregister(conversation_id) when is_binary(conversation_id) do
    :ets.delete(@table, conversation_id)
    :ok
  end

  def lookup(conversation_id) when is_binary(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, pid}] -> pid
      _other -> nil
    end
  end
end
