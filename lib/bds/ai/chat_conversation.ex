defmodule BDS.AI.ChatConversation do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          model: String.t() | nil,
          copilot_session_id: String.t() | nil,
          surface_state: map() | nil,
          created_at: integer() | nil,
          updated_at: integer() | nil
        }

  schema "chat_conversations" do
    field :title, :string
    field :model, :string
    field :copilot_session_id, :string
    field :surface_state, :map
    field :created_at, :integer
    field :updated_at, :integer
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(
      attrs,
      [:id, :title, :model, :copilot_session_id, :surface_state, :created_at, :updated_at],
      empty_values: [nil]
    )
    |> validate_required([:id, :title, :created_at, :updated_at])
  end
end
