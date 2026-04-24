defmodule BDS.MCP.ProposalStore do
  @moduledoc false

  use Agent

  alias BDS.Persistence

  @default_ttl_ms 30 * 60 * 1000

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case Agent.start_link(fn -> %{} end, name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  def create(kind, data, opts \\ []) when is_binary(kind) and is_map(data) do
    :ok = ensure_started()
    cleanup_expired(opts)

    proposal = %{
      id: Ecto.UUID.generate(),
      kind: kind,
      data: data,
      created_at: Persistence.now_ms(),
      expires_at: Persistence.now_ms() + Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    }

    Agent.update(__MODULE__, &Map.put(&1, proposal.id, proposal))
    proposal
  end

  def get(id) when is_binary(id) do
    :ok = ensure_started()
    cleanup_expired([])
    Agent.get(__MODULE__, &Map.get(&1, id))
  end

  def remove(id) when is_binary(id) do
    :ok = ensure_started()
    Agent.update(__MODULE__, &Map.delete(&1, id))
    :ok
  end

  def list do
    :ok = ensure_started()
    cleanup_expired([])

    Agent.get(__MODULE__, fn proposals ->
      proposals
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
    end)
  end

  def cleanup_expired(opts) do
    :ok = ensure_started()
    now = Persistence.now_ms()
    on_expire = Keyword.get(opts, :on_expire)

    Agent.get_and_update(__MODULE__, fn proposals ->
      {expired, active} = Enum.split_with(proposals, fn {_id, proposal} -> proposal.expires_at <= now end)

      Enum.each(expired, fn {_id, proposal} ->
        if is_function(on_expire, 1), do: on_expire.(proposal)
      end)

      {Enum.map(expired, &elem(&1, 1)), Map.new(active)}
    end)
  end
end
