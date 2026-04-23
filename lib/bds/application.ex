defmodule BDS.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BDS.Repo
    ]

    opts = [strategy: :one_for_one, name: BDS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
