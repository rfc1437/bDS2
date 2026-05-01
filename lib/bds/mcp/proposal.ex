defmodule BDS.MCP.Proposal do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "mcp_proposals" do
    field :kind, :string

    field :status, Ecto.Enum,
      values: [:pending, :accepted, :discarded, :expired],
      default: :pending

    field :entity_id, :string
    field :data, :map
    field :created_at, :integer
    field :expires_at, :integer
  end

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:id, :kind, :status, :entity_id, :data, :created_at, :expires_at],
      empty_values: [nil]
    )
    |> validate_required([:id, :kind, :status, :entity_id, :data, :created_at, :expires_at])
    |> unique_constraint(:status, name: :mcp_proposals_entity_idx)
  end
end
