defmodule BDS.CSM012FilePickerAsyncTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})

    prev = System.get_env("BDS_DESKTOP_AUTOMATION")
    System.put_env("BDS_DESKTOP_AUTOMATION", "1")

    on_exit(fn ->
      if prev,
        do: System.put_env("BDS_DESKTOP_AUTOMATION", prev),
        else: System.delete_env("BDS_DESKTOP_AUTOMATION")
    end)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-csm012-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "CSM012", data_path: temp_dir})
    %{project: project}
  end

  describe "file picker does not block the event handler" do
    test "create media returns within 100ms — event handler is not blocked" do
      {:ok, view, _html} = live(build_conn(), "/")

      start_time = System.monotonic_time(:millisecond)
      render_click(view, "create_sidebar_item", %{"kind" => "media"})
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 100, "create_sidebar_item should return within 100ms, took #{elapsed}ms"
    end

    test "LiveView handles other events while file picker task is pending" do
      {:ok, view, _html} = live(build_conn(), "/")

      render_click(view, "create_sidebar_item", %{"kind" => "media"})

      start_time = System.monotonic_time(:millisecond)
      render_click(view, "select_view", %{"view" => "media"})
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert elapsed < 100, "select_view should respond within 100ms, took #{elapsed}ms"
    end

    test "task completion does not crash the LiveView" do
      {:ok, view, _html} = live(build_conn(), "/")

      render_click(view, "create_sidebar_item", %{"kind" => "media"})

      # Wait for the async task to complete (returns :cancel in automation mode)
      Process.sleep(50)

      assert Process.alive?(view.pid)
      assert render(view)
    end

    test "file picker cancel result is handled gracefully" do
      {:ok, view, _html} = live(build_conn(), "/")

      # In automation mode, FilePicker.choose_file returns :cancel,
      # so the task result will be :cancel
      render_click(view, "create_sidebar_item", %{"kind" => "media"})
      Process.sleep(50)

      # LiveView should still be alive and responsive after cancel
      assert Process.alive?(view.pid)
      render_click(view, "select_view", %{"view" => "media"})
      assert render(view)
    end

    test "error result from file picker does not crash LiveView" do
      {:ok, view, _html} = live(build_conn(), "/")

      # Simulate an error result being received
      send(view.pid, {make_ref(), {:error, %{message: "dialog failed"}}})
      Process.sleep(10)

      assert Process.alive?(view.pid)
      assert render(view)
    end
  end
end
