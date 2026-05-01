defmodule BDS.MCP.ProposalStore do
  @moduledoc false

  import Ecto.Query

  alias BDS.MCP.Proposal
  alias BDS.Persistence
  alias BDS.Repo

  @default_ttl_ms 30 * 60 * 1000

  def ensure_started, do: :ok

  def create(kind, data, opts \\ []) when is_binary(kind) and is_map(data) do
    :ok = ensure_started()
    cleanup_expired(opts)
    now = Persistence.now_ms()

    entity_id = Keyword.get(opts, :entity_id) || derive_entity_id(data)

    %Proposal{}
    |> Proposal.changeset(%{
      id: Ecto.UUID.generate(),
      kind: kind,
      status: :pending,
      entity_id: entity_id,
      data: data,
      created_at: now,
      expires_at: now + Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    })
    |> Repo.insert!()
  end

  def get(id) when is_binary(id) do
    :ok = ensure_started()
    cleanup_expired([])
    Repo.get(Proposal, id)
  end

  def remove(id) when is_binary(id) do
    :ok = ensure_started()
    Repo.delete_all(from proposal in Proposal, where: proposal.id == ^id)
    :ok
  end

  def list do
    :ok = ensure_started()
    cleanup_expired([])

    Repo.all(from proposal in Proposal, order_by: [asc: proposal.created_at])
  end

  def cleanup_expired(opts \\ []) do
    :ok = ensure_started()
    now = Persistence.now_ms()
    on_expire = Keyword.get(opts, :on_expire)

    expired =
      Repo.all(
        from proposal in Proposal,
          where: proposal.status == :pending and proposal.expires_at <= ^now
      )

    Enum.each(expired, fn proposal ->
      if is_function(on_expire, 1), do: on_expire.(proposal)
      mark_status(proposal.id, :expired)
    end)

    Enum.map(expired, &Repo.get(Proposal, &1.id))
  end

  def mark_accepted(id) when is_binary(id), do: mark_status(id, :accepted)
  def mark_discarded(id) when is_binary(id), do: mark_status(id, :discarded)

  defp mark_status(id, status) do
    case Repo.get(Proposal, id) do
      nil ->
        nil

      proposal ->
        Repo.delete_all(
          from other in Proposal,
            where:
              other.id != ^id and other.kind == ^proposal.kind and
                other.entity_id == ^proposal.entity_id and
                other.status == ^status
        )

        proposal
        |> Proposal.changeset(%{status: status})
        |> Repo.update!()
    end
  end

  defp derive_entity_id(data) do
    data["post_id"] || data["script_id"] || data["template_id"] || data["media_id"] ||
      Ecto.UUID.generate()
  end
end
