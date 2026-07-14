defmodule BDS.Events do
  @moduledoc """
  Domain event bus (issue #26, phase 2).

  Contexts broadcast entity mutations on the same `"entity:changed"` topic
  (and payload shape) that `BDS.CliSync.Watcher` already uses for external
  CLI writes, so every connected client — LiveView shells and TUI sessions
  alike — stays synchronized through one subscription regardless of where
  a change originated.
  """

  @entity_topic "entity:changed"
  @settings_topic "settings:changed"

  @type action :: :created | :updated | :deleted

  @doc "Subscribe the calling process to entity and settings changes."
  @spec subscribe() :: :ok
  def subscribe do
    :ok = Phoenix.PubSub.subscribe(BDS.PubSub, @entity_topic)
    :ok = Phoenix.PubSub.subscribe(BDS.PubSub, @settings_topic)
  end

  @doc """
  Broadcast an entity mutation as `{:entity_changed, %{entity: entity,
  entity_id: id, action: action}}` — the same message the CLI sync watcher
  emits, so subscribers handle both through one code path.
  """
  @spec entity_changed(String.t(), String.t(), action()) :: :ok
  def entity_changed(entity, entity_id, action)
      when is_binary(entity) and is_binary(entity_id) and
             action in [:created, :updated, :deleted] do
    Phoenix.PubSub.broadcast(
      BDS.PubSub,
      @entity_topic,
      {:entity_changed, %{entity: entity, entity_id: entity_id, action: action}}
    )
  end

  @doc """
  Pipe-friendly broadcast: on `{:ok, %{id: id}}` broadcasts `action` for
  `entity` and returns the result unchanged; any other result passes
  through untouched.
  """
  @spec broadcast_result(term(), String.t(), action()) :: term()
  def broadcast_result({:ok, %{id: id}} = result, entity, action) when is_binary(id) do
    :ok = entity_changed(entity, id, action)
    result
  end

  def broadcast_result(result, _entity, _action), do: result

  @doc "Broadcast a global setting change as `{:settings_changed, key}`."
  @spec settings_changed(String.t()) :: :ok
  def settings_changed(key) when is_binary(key) do
    Phoenix.PubSub.broadcast(BDS.PubSub, @settings_topic, {:settings_changed, key})
  end
end
