defmodule BDS.Desktop.ShellLive.GitRunTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BDS.Desktop.ShellLive.GitRun
  alias Phoenix.Component

  defp socket(git_run) do
    %Phoenix.LiveView.Socket{}
    |> Component.assign(:git_run, git_run)
  end

  test "network_event? recognises fetch/pull/push but not prune" do
    assert GitRun.network_event?("git_push")
    assert GitRun.network_event?("git_pull")
    assert GitRun.network_event?("git_fetch")
    refute GitRun.network_event?("git_prune_lfs")
  end

  test "start with no project shows an error and a failed status" do
    result = GitRun.start(socket(nil), "git_push", nil)
    run = result.assigns.git_run

    assert run.operation == :push
    assert run.status == {:done, 1}
    assert [{:stderr, text}] = run.lines
    assert text =~ "No active project"
  end

  test "append accumulates chunks for the active ref only" do
    ref = make_ref()
    run = %{operation: :push, pid: nil, ref: ref, lines: [], status: :running}

    socket =
      socket(run)
      |> GitRun.append(ref, :stdout, "a")
      |> GitRun.append(ref, :stderr, "b")
      |> GitRun.append(make_ref(), :stdout, "ignored")

    assert socket.assigns.git_run.lines == [{:stderr, "b"}, {:stdout, "a"}]
  end

  test "done records the exit status and clears the pid" do
    ref = make_ref()
    run = %{operation: :push, pid: self(), ref: ref, lines: [], status: :running}

    socket = GitRun.done(socket(run), ref, 128)

    assert socket.assigns.git_run.status == {:done, 128}
    assert socket.assigns.git_run.pid == nil
  end

  test "renders nothing when there is no active run" do
    assert render_component(&GitRun.git_run_modal/1, git_run: nil) |> String.trim() == ""
  end

  test "renders the failed run with stderr coloured and a fail status" do
    run = %{
      operation: :push,
      pid: nil,
      ref: make_ref(),
      lines: [{:stderr, "rejected"}, {:stdout, "counting"}],
      status: {:done, 1}
    }

    html = render_component(&GitRun.git_run_modal/1, git_run: run)

    assert html =~ "git push"
    assert html =~ "git-run-stderr"
    assert html =~ "rejected"
    assert html =~ "git-run-status fail"
  end

  test "close cancels a running command and clears the modal" do
    target = self()

    pid =
      spawn(fn ->
        receive do
          :cancel -> send(target, :cancelled)
        end
      end)

    run = %{operation: :push, pid: pid, ref: make_ref(), lines: [], status: :running}

    socket = GitRun.close(socket(run))

    assert socket.assigns.git_run == nil
    assert_receive :cancelled, 1_000
  end
end
