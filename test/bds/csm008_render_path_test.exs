defmodule BDS.CSM008RenderPathTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm008-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM008", data_path: temp_dir})

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "CSM008 Test Post",
        slug: "csm008-test",
        status: :draft,
        language: "en"
      })

    %{project: project, post: post}
  end

  describe "panel re-renders fire no DB queries" do
    test "post_links panel re-render uses cached assigns", %{post: post} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "select_tab", %{"type" => "post", "id" => post.id})
      render_click(view, "select_panel_tab", %{"tab" => "post_links"})

      query_count = count_queries(fn ->
        1..10 |> Enum.each(fn _ -> render(view) end)
      end)

      assert query_count == 0,
        "Expected 0 DB queries on panel re-renders, got #{query_count}"
    end

    test "git_log panel re-render uses cached assigns", %{post: post} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "select_tab", %{"type" => "post", "id" => post.id})
      render_click(view, "select_panel_tab", %{"tab" => "git_log"})

      query_count = count_queries(fn ->
        1..10 |> Enum.each(fn _ -> render(view) end)
      end)

      assert query_count == 0,
        "Expected 0 DB queries on git_log re-renders, got #{query_count}"
    end
  end

  describe "select_panel_tab triggers panel data fetch only for active panel" do
    test "switching to output panel triggers no post/media queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      {query_count, query_sources} = count_queries_with_sources(fn ->
        render_click(view, "select_panel_tab", %{"tab" => "output"})
      end)

      refute "post_links" in query_sources,
        "Switching to output should not query post_links, got: #{inspect(query_sources)}"

      assert query_count == 0,
        "Expected 0 queries for output panel tab, got #{query_count}"
    end

    test "switching to tasks panel triggers no post/media queries" do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      {query_count, _query_sources} = count_queries_with_sources(fn ->
        render_click(view, "select_panel_tab", %{"tab" => "tasks"})
      end)

      assert query_count == 0,
        "Expected 0 queries for tasks panel tab, got #{query_count}"
    end
  end

  describe "sync_tab_meta skips DB queries for complete meta" do
    test "tabs with existing title and subtitle skip DB queries", %{post: post} do
      {:ok, view, _html} = live_isolated(build_conn(), BDS.Desktop.ShellLive)

      render_click(view, "open_sidebar_item", %{
        "route" => "post",
        "id" => post.id,
        "title" => "Preset Title",
        "subtitle" => "preset subtitle"
      })

      query_count = count_queries(fn ->
        render_click(view, "select_tab", %{"type" => "post", "id" => post.id})
      end)

      assert query_count == 0,
        "Expected 0 DB queries when tab meta is already complete, got #{query_count}"
    end
  end

  defp count_queries(func) do
    test_pid = self()
    ref = make_ref()
    handler_id = "csm008-query-counter-#{inspect(ref)}"

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
    handler_id = "csm008-query-sources-#{inspect(ref)}"

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
      String.contains?(query, "post_links") -> "post_links"
      String.contains?(query, "posts") -> "posts"
      String.contains?(query, "media") -> "media"
      String.contains?(query, "scripts") -> "scripts"
      String.contains?(query, "templates") -> "templates"
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
