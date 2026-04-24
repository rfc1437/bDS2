defmodule BDS.AI.ChatConversation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "chat_conversations" do
    field :title, :string
    field :model, :string
    field :copilot_session_id, :string
    field :created_at, :integer
    field :updated_at, :integer
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:id, :title, :model, :copilot_session_id, :created_at, :updated_at], empty_values: [nil])
    |> validate_required([:id, :title, :created_at, :updated_at])
  end
end
