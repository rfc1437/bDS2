defmodule BDS.CSM010RescueControlFlowTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.ShellData
  alias BDS.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok
  end

  describe "Repo.ready?/0" do
    test "returns true when the database is available" do
      assert Repo.ready?()
    end
  end

  describe "project_snapshot/0" do
    test "returns {:ok, snapshot} when DB is ready" do
      assert {:ok, snapshot} = ShellData.project_snapshot()
      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :active_project_id)
      assert Map.has_key?(snapshot, :projects)
    end

    test "returns {:error, :not_ready} when DB is unavailable" do
      Ecto.Adapters.SQL.Sandbox.checkin(BDS.Repo)

      assert {:error, :not_ready} = with_stopped_repo(&ShellData.project_snapshot/0)
    end
  end

  describe "dashboard/1" do
    test "returns {:ok, snapshot} when DB is ready" do
      assert {:ok, dashboard} = ShellData.dashboard("default")
      assert is_map(dashboard)
      assert Map.has_key?(dashboard, :post_stats)
    end

    test "returns {:error, :not_ready} when DB is unavailable" do
      Ecto.Adapters.SQL.Sandbox.checkin(BDS.Repo)

      assert {:error, :not_ready} = with_stopped_repo(fn -> ShellData.dashboard("default") end)
    end
  end

  describe "sidebar_view/3" do
    test "returns {:ok, view} when DB is ready" do
      assert {:ok, view} = ShellData.sidebar_view("default", "posts")
      assert is_map(view)
    end

    test "returns {:error, :not_ready} when DB is unavailable" do
      Ecto.Adapters.SQL.Sandbox.checkin(BDS.Repo)

      assert {:error, :not_ready} =
               with_stopped_repo(fn -> ShellData.sidebar_view("default", "posts") end)
    end
  end

  describe "git_badge_count/2" do
    test "returns {:ok, count} when DB is ready" do
      assert {:ok, count} = ShellData.git_badge_count("default")
      assert is_integer(count)
    end

    test "returns {:ok, 0} for nil project_id" do
      assert {:ok, 0} = ShellData.git_badge_count(nil)
    end

    test "returns {:error, :not_ready} when DB is unavailable" do
      Ecto.Adapters.SQL.Sandbox.checkin(BDS.Repo)

      assert {:error, :not_ready} =
               with_stopped_repo(fn -> ShellData.git_badge_count("some-project") end)
    end
  end

  defp with_stopped_repo(fun) do
    Supervisor.terminate_child(BDS.Supervisor, BDS.Repo)

    try do
      fun.()
    after
      Supervisor.restart_child(BDS.Supervisor, BDS.Repo)
    end
  end
end
