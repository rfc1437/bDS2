defmodule BDS.Desktop.AutomationTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.Automation

  @tag timeout: 120_000

  test "automation boots the app in a separate process, inspects shell content, drives UI, and captures screenshots" do
    screenshot_dir = Path.join(System.tmp_dir!(), "bds-desktop-automation-test")
    File.rm_rf!(screenshot_dir)
    File.mkdir_p!(screenshot_dir)

    {:ok, session} = Automation.start_session(screenshot_dir: screenshot_dir)

    on_exit(fn ->
      Automation.stop_session(session)
      File.rm_rf!(screenshot_dir)
    end)

    snapshot = Automation.snapshot(session)

    assert snapshot.window_title == "Blogging Desktop Server"
    assert snapshot.active_view == "posts"
    assert snapshot.sidebar_visible == true
    assert snapshot.assistant_visible == false
    assert snapshot.panel_visible == false
    assert snapshot.editor_title == "Dashboard"
    assert snapshot.activity_labels == [
             "Posts",
             "Pages",
             "Media",
             "Scripts",
             "Templates",
             "Tags",
             "Chat",
             "Import",
             "Git",
             "Settings"
           ]
    assert "Drafts" in snapshot.sidebar_sections
    assert "Status" in snapshot.editor_meta_labels

    assert :ok = Automation.click(session, "[data-testid='toggle-sidebar']")

    snapshot = Automation.snapshot(session)
    assert snapshot.sidebar_visible == false

    assert :ok = Automation.click(session, "[data-testid='toggle-assistant']")

    snapshot = Automation.snapshot(session)
    assert snapshot.assistant_visible == true
    assert snapshot.panel_visible == false

    screenshot_path = Path.join(screenshot_dir, "main-window.png")
    assert Automation.capture_screenshot(session, screenshot_path) == screenshot_path
    assert File.exists?(screenshot_path)
  end

  @tag timeout: 120_000
  test "automation stop_session shuts down the app and browser child processes it started" do
    baseline = automation_process_counts()

    {:ok, session} = Automation.start_session()
    children = Automation.child_info(session)

    assert is_integer(children.app_os_pid)
    assert is_integer(children.driver_os_pid)
    assert os_pid_alive?(children.app_os_pid)
    assert os_pid_alive?(children.driver_os_pid)
    assert automation_process_counts().app == baseline.app + 1
    assert automation_process_counts().driver == baseline.driver + 1

    assert :ok = Automation.stop_session(session)

    assert wait_until(fn -> not os_pid_alive?(children.app_os_pid) end)
    assert wait_until(fn -> not os_pid_alive?(children.driver_os_pid) end)
    assert automation_process_counts() == baseline
  end

  defp os_pid_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _other -> false
    end
  end

  defp automation_process_counts do
    %{app: count_processes("scripts/desktop_automation_app\\.exs"), driver: count_processes("desktop_automation_runner\\.mjs")}
  end

  defp count_processes(pattern) do
    {output, 0} =
      System.cmd("sh", ["-c", "ps -Ao args | rg -c '#{pattern}' || true"], stderr_to_stdout: true)

    output
    |> String.trim()
    |> case do
      "" -> 0
      value -> String.to_integer(value)
    end
  end

  defp wait_until(fun, timeout \\ 5_000)

  defp wait_until(fun, timeout) when timeout <= 0, do: fun.()

  defp wait_until(fun, timeout) do
    if fun.() do
      true
    else
      Process.sleep(100)
      wait_until(fun, timeout - 100)
    end
  end
end
