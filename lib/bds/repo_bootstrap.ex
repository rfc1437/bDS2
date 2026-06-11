defmodule BDS.RepoBootstrap do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    :ok = ensure_ready(opts)
    {:ok, %{}}
  end

  def ensure_ready(opts \\ []) do
    repo = Keyword.get(opts, :repo, BDS.Repo)

    if Keyword.get(opts, :migrate?, true) do
      :ok = ensure_schema(Keyword.put(opts, :repo, repo))
    end

    if repo == BDS.Repo do
      case BDS.Projects.ensure_default_project() do
        {:ok, _project} -> :ok
        {:error, reason} -> raise "failed to ensure default project: #{inspect(reason)}"
      end

      {:ok, _summary} = BDS.AI.SecretMigration.migrate_legacy_secrets()
      :ok
    else
      :ok
    end
  end

  def ensure_schema(opts \\ []) do
    repo = Keyword.get(opts, :repo, BDS.Repo)
    migrations_path = Keyword.get(opts, :migrations_path, migrations_path())

    _versions = Ecto.Migrator.run(repo, migrations_path, :up, all: true)
    :ok
  end

  def migrations_path do
    Path.expand("../../priv/repo/migrations", __DIR__)
  end
end
