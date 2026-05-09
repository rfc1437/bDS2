defmodule BDS.CSM007ReloadShellTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm007-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM007", data_path: temp_dir})
    %{project: project}
  end

  describe "toggle_sidebar" do
    test "triggers no dashboard or git queries", %{project: _project} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      query_count = count_queries(fn ->
        render_click(view, "toggle_sidebar", %{})
      end)

      assert query_count == 0,
        "Expected 0 DB queries for sidebar toggle, got #{query_count}"
    end
  end

  describe "toggle_panel" do
    test "triggers no DB queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      query_count = count_queries(fn ->
        render_click(view, "toggle_panel", %{})
      end)

      assert query_count == 0,
        "Expected 0 DB queries for panel toggle, got #{query_count}"
    end
  end

  describe "sync_layout" do
    test "triggers no DB queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      query_count = count_queries(fn ->
        render_click(view, "sync_layout", %{
          "sidebar_width" => "300",
          "sidebar_visible" => "true",
          "panel_visible" => "false"
        })
      end)

      assert query_count == 0,
        "Expected 0 DB queries for sync_layout, got #{query_count}"
    end
  end

  describe "select_panel_tab" do
    test "triggers no DB queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      query_count = count_queries(fn ->
        render_click(view, "select_panel_tab", %{"tab" => "output"})
      end)

      assert query_count == 0,
        "Expected 0 DB queries for select_panel_tab, got #{query_count}"
    end
  end

  describe "select_view" do
    test "triggers sidebar query but not dashboard or git queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      {query_count, query_sources} = count_queries_with_sources(fn ->
        render_click(view, "select_view", %{"view" => "media"})
      end)

      assert query_count > 0, "Expected at least 1 query for view change"

      refute "dashboard" in query_sources or "projects" in query_sources,
        "View change should not query dashboard or projects, got: #{inspect(query_sources)}"
    end
  end

  describe "sidebar filter events" do
    test "do not trigger dashboard or git queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      {_count, query_sources} = count_queries_with_sources(fn ->
        render_click(view, "update_sidebar_search", %{
          "sidebar_filters" => %{"search" => "test"}
        })
      end)

      refute "dashboard" in query_sources,
        "Sidebar search should not query dashboard, got: #{inspect(query_sources)}"
    end
  end

  describe "toggle_offline_mode" do
    test "triggers only the settings write, no refresh queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      query_count = count_queries(fn ->
        render_click(view, "toggle_offline_mode", %{})
      end)

      assert query_count == 1,
        "Expected exactly 1 DB query (settings write) for offline mode toggle, got #{query_count}"
    end
  end

  defp count_queries(func) do
    test_pid = self()
    ref = make_ref()
    handler_id = "csm007-query-counter-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:bds, :repo, :query],
      fn _event, _measurements, _metadata, _ ->
        send(test_pid, {:query_executed, ref})
      end,
      nil
    )

    func.()

    :telemetry.detach(handler_id)
    count_messages(ref, 0)
  end

  defp count_queries_with_sources(func) do
    test_pid = self()
    ref = make_ref()
    handler_id = "csm007-query-sources-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:bds, :repo, :query],
      fn _event, _measurements, metadata, _ ->
        source = metadata[:source] || extract_table(metadata[:query] || "")
        send(test_pid, {:query_executed, ref, source})
      end,
      nil
    )

    func.()

    :telemetry.detach(handler_id)
    collect_query_sources(ref, 0, [])
  end

  defp collect_query_sources(ref, count, sources) do
    receive do
      {:query_executed, ^ref, source} ->
        collect_query_sources(ref, count + 1, [source | sources])
    after
      0 -> {count, Enum.uniq(sources)}
    end
  end

  defp extract_table(query) when is_binary(query) do
    cond do
      String.contains?(query, "dashboard") -> "dashboard"
      String.contains?(query, "projects") -> "projects"
      String.contains?(query, "posts") -> "posts"
      String.contains?(query, "media") -> "media"
      String.contains?(query, "tags") -> "tags"
      true -> "other"
    end
  end

  defp extract_table(_), do: "unknown"

  defp count_messages(ref, acc) do
    receive do
      {:query_executed, ^ref} -> count_messages(ref, acc + 1)
    after
      0 -> acc
    end
  end
end
