defmodule BDS.AI.ChatMessage do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string
  @roles [:system, :user, :assistant, :tool]

  schema "chat_messages" do
    belongs_to :conversation, BDS.AI.ChatConversation, references: :id, type: :string

    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :tool_call_id, :string
    field :tool_calls, :string
    field :token_usage_input, :integer
    field :token_usage_output, :integer
    field :cache_read_tokens, :integer
    field :cache_write_tokens, :integer
    field :created_at, :integer
  end

  def changeset(message, attrs) do
    message
    |> cast(
      attrs,
      [
        :conversation_id,
        :role,
        :content,
        :tool_call_id,
        :tool_calls,
        :token_usage_input,
        :token_usage_output,
        :cache_read_tokens,
        :cache_write_tokens,
        :created_at
      ], empty_values: [nil])
    |> validate_required([:conversation_id, :role, :created_at])
    |> assoc_constraint(:conversation)
  end
end
