defmodule BDS.CliSync do
  @moduledoc false

  import Ecto.Query

  alias BDS.CliSync.Notification
  alias BDS.Persistence
  alias BDS.Repo

  @processed_ttl_ms 60 * 60 * 1000
  @unprocessed_ttl_ms 24 * 60 * 60 * 1000

  def cli_mutation_performed(entity_type, entity_id, action)
      when is_binary(entity_type) and is_binary(entity_id) do
    now = Persistence.now_ms()

    %Notification{}
    |> Notification.changeset(%{
      entity_type: entity_type,
      entity_id: entity_id,
      action: action,
      from_cli: true,
      seen_at: nil,
      created_at: now
    })
    |> Repo.insert()
  end

  def db_file_change_detected do
    now = Persistence.now_ms()

    notifications =
      Repo.all(
        from notification in Notification,
          where: notification.from_cli == true and is_nil(notification.seen_at),
          order_by: [asc: notification.created_at]
      )

    ids = Enum.map(notifications, & &1.id)

    if ids != [] do
      Repo.update_all(from(notification in Notification, where: notification.id in ^ids),
        set: [seen_at: now]
      )
    end

    {:ok,
     Enum.map(notifications, fn notification ->
       %{
         entity_type: notification.entity_type,
         entity_id: notification.entity_id,
         action: notification.action
       }
     end)}
  end

  def prune_notifications(now \\ Persistence.now_ms()) when is_integer(now) do
    {processed_count, _} =
      Repo.delete_all(
        from notification in Notification,
          where:
            not is_nil(notification.seen_at) and
              notification.created_at <= ^(now - @processed_ttl_ms)
      )

    {unprocessed_count, _} =
      Repo.delete_all(
        from notification in Notification,
          where:
            is_nil(notification.seen_at) and
              notification.created_at <= ^(now - @unprocessed_ttl_ms)
      )

    {:ok, %{processed: processed_count, unprocessed: unprocessed_count}}
  end
end
