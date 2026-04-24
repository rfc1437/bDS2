defmodule BDS.AI.InFlight do
  @moduledoc false

  @table :bds_ai_in_flight

  def register(conversation_id, pid) when is_binary(conversation_id) and is_pid(pid) do
    :ets.insert(table(), {conversation_id, pid})
    :ok
  end

  def unregister(conversation_id) when is_binary(conversation_id) do
    :ets.delete(table(), conversation_id)
    :ok
  end

  def lookup(conversation_id) when is_binary(conversation_id) do
    case :ets.lookup(table(), conversation_id) do
      [{^conversation_id, pid}] -> pid
      _other -> nil
    end
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      table -> table
    end
  end
end
