defmodule BDS.Repo.BootstrapTest do
  use ExUnit.Case, async: false

  alias BDS.Projects.Project

  defmodule TempRepo do
    use Ecto.Repo,
      otp_app: :bds,
      adapter: Ecto.Adapters.SQLite3
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    __MODULE__.RepoConfigBackup.put_env()

    on_exit(fn ->
      __MODULE__.RepoConfigBackup.restore_env()
    end)

    :ok
  end

  test "ensure_schema creates persistence tables in a blank sqlite database" do
    temp_db = Path.join(System.tmp_dir!(), "bds-bootstrap-#{System.unique_integer([:positive])}.db")

    Application.put_env(:bds, TempRepo,
      database: temp_db,
      pool_size: 1,
      stacktrace: true,
      show_sensitive_data_on_connection_error: true
    )

    start_supervised!(TempRepo)

    on_exit(fn ->
      File.rm_rf(temp_db)
    end)

    assert :ok = BDS.RepoBootstrap.ensure_schema(repo: TempRepo)

    tables =
      Ecto.Adapters.SQL.query!(TempRepo, "SELECT name FROM sqlite_master WHERE type = 'table'", []).rows
      |> Enum.map(&hd/1)

    assert "projects" in tables
    assert "posts" in tables
    assert "templates" in tables
  end

  test "ensure_ready seeds the default project in the app repo" do
    BDS.Repo.delete_all(Project)

    assert :ok = BDS.RepoBootstrap.ensure_ready(migrate?: false)

    assert %Project{id: "default", name: "My Blog", is_active: true} = BDS.Projects.get_active_project()
  end

  test "dev repo config disables query logging by default" do
    config_path = Path.expand("../../../config/config.exs", __DIR__)
    config = Config.Reader.read!(config_path, env: :dev)

    repo_config =
      config
      |> Keyword.fetch!(:bds)
      |> Keyword.fetch!(BDS.Repo)

    assert repo_config[:log] == false
  end

  test "dev repo config sets a rebuild-safe sqlite busy timeout" do
    config_path = Path.expand("../../../config/config.exs", __DIR__)
    config = Config.Reader.read!(config_path, env: :dev)

    repo_config =
      config
      |> Keyword.fetch!(:bds)
      |> Keyword.fetch!(BDS.Repo)

    assert repo_config[:busy_timeout] == 15_000
  end

  defmodule RepoConfigBackup do
    def put_env do
      Process.put({__MODULE__, :temp_repo_config}, Application.get_env(:bds, TempRepo))
    end

    def restore_env do
      case Process.get({__MODULE__, :temp_repo_config}) do
        nil -> Application.delete_env(:bds, TempRepo)
        config -> Application.put_env(:bds, TempRepo, config)
      end
    end
  end
end
