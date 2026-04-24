defmodule BDS.CliSync.Notification do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "db_notifications" do
    field :entity_type, :string
    field :entity_id, :string
    field :action, Ecto.Enum, values: [:created, :updated, :deleted]
    field :from_cli, :boolean, default: true
    field :seen_at, :integer
    field :created_at, :integer
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:entity_type, :entity_id, :action, :from_cli, :seen_at, :created_at], empty_values: [nil])
    |> validate_required([:entity_type, :entity_id, :action, :from_cli, :created_at])
  end
end
