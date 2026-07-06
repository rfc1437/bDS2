defmodule BDS.GitTest do
  use ExUnit.Case, async: false

  alias BDS.Git

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_root = Path.join(System.tmp_dir!(), "bds-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_root)

    on_exit(fn -> File.rm_rf(temp_root) end)

    project_dir = Path.join(temp_root, "project")
    File.mkdir_p!(project_dir)

    {:ok, project} = BDS.Projects.create_project(%{name: "Git Project", data_path: project_dir})

    %{project: project, project_dir: project_dir, temp_root: temp_root}
  end

  test "initialize_repo writes ignore files, configures LFS tracking, and returns repo info", %{
    project: project,
    project_dir: project_dir
  } do
    runner =
      fake_runner(fn
        "git", ["init", "-b", "master"], _opts -> {"", 0}
        "git", ["lfs", "track" | _rest], _opts -> {"Tracking *.png\n", 0}
        "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts -> {"master\n", 0}
        "git", ["remote", "get-url", "origin"], _opts -> {"", 2}
        "git", ["lfs", "ls-files"], _opts -> {"", 0}
      end)

    assert {:ok, repo} = Git.initialize_repo(project.id, runner: runner)

    assert repo.is_initialized == true
    assert repo.current_branch == "master"
    assert repo.has_lfs == true
    assert File.read!(Path.join(project_dir, ".gitignore")) =~ "/html/"
    assert File.read!(Path.join(project_dir, ".gitattributes")) =~ "*.png filter=lfs"
  end

  test "status, diff, history, and provider detection are parsed from git output", %{
    project: project
  } do
    runner =
      fake_runner(fn
        "git", ["status", "--porcelain=v1", "--untracked-files=all"], _opts ->
          {"A  posts/new.md\n M meta/project.json\nR  old.txt -> new.txt\n?? note.txt\n", 0}

        "git", ["diff", "--cached", "--no-ext-diff"], _opts ->
          {"staged diff", 0}

        "git", ["diff", "--no-ext-diff"], _opts ->
          {"unstaged diff", 0}

        "git", ["remote", "get-url", "origin"], _opts ->
          {"git@github.com:owner/repo.git\n", 0}

        "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts ->
          {"main\n", 0}

        "git", ["log", "--date=short", "--format=%H%x09%an%x09%ad%x09%s", "main"], _opts ->
          {"a1\tAda\t2026-01-01\tLocal commit\nb2\tBabbage\t2026-01-02\tShared commit\n", 0}

        "git", ["log", "--format=%H", "origin/main"], _opts ->
          {"b2\nc3\n", 0}
      end)

    assert {:ok, status} = Git.status(project.id, runner: runner)
    assert Enum.any?(status.files, &(&1.path == "posts/new.md" and &1.status == :added))

    assert Enum.any?(
             status.files,
             &(&1.path == "new.txt" and &1.status == :renamed and &1.old_path == "old.txt")
           )

    assert Enum.any?(status.files, &(&1.path == "note.txt" and &1.status == :untracked))

    assert {:ok, diff} = Git.diff(project.id, runner: runner)
    assert diff.staged_diff == "staged diff"
    assert diff.unstaged_diff == "unstaged diff"

    assert {:ok, history} = Git.history(project.id, "main", runner: runner)
    a1 = Enum.find(history.commits, &(&1.hash == "a1"))
    assert a1.sync_status.kind == :local_only
    assert a1.author == "Ada"
    assert a1.date == "2026-01-01"
    assert a1.subject == "Local commit"
    assert Enum.find(history.commits, &(&1.hash == "b2")).sync_status.kind == :both
    assert Enum.find(history.commits, &(&1.hash == "c3")).sync_status.kind == :remote_only

    assert {:ok, repo} = Git.repository(project.id, runner: runner)
    assert repo.provider.kind == :github
    assert repo.current_branch == "main"
  end

  test "get_diff_content returns HEAD and working tree content for a changed file", %{
    project: project,
    project_dir: project_dir
  } do
    posts_dir = Path.join(project_dir, "posts")
    File.mkdir_p!(posts_dir)

    relative_path = "posts/first.md"
    full_path = Path.join(project_dir, relative_path)

    File.write!(full_path, "Old content\n")
    init_git_repo!(project_dir, "initial")
    File.write!(full_path, "New content\n")

    assert {:ok, diff} = Git.get_diff_content(project.id, relative_path)
    assert diff.file_path == relative_path
    assert diff.original == "Old content\n"
    assert diff.modified == "New content\n"
  end

  test "remote_state reports upstream ahead and behind counts", %{project: project} do
    runner =
      fake_runner(fn
        "git", ["rev-parse", "--abbrev-ref", "HEAD"], _opts ->
          {"main\n", 0}

        "git", ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], _opts ->
          {"origin/main\n", 0}

        "git", ["rev-list", "--count", "origin/main..HEAD"], _opts ->
          {"2\n", 0}

        "git", ["rev-list", "--count", "HEAD..origin/main"], _opts ->
          {"5\n", 0}
      end)

    assert {:ok, remote_state} = Git.remote_state(project.id, runner: runner)
    assert remote_state.local_branch == "main"
    assert remote_state.upstream_branch == "origin/main"
    assert remote_state.has_upstream == true
    assert remote_state.ahead == 2
    assert remote_state.behind == 5
  end

  test "fetch, pull, push, commit_all, reconcile, and prune_lfs_cache run non-interactively", %{
    project: project
  } do
    parent = self()

    runner = fn command, args, opts ->
      send(parent, {:git_command, command, args, opts})

      case {command, args} do
        {"git", ["fetch", "--all", "--prune"]} ->
          {"", 0}

        {"git", ["pull", "--ff-only"]} ->
          {"", 0}

        {"git", ["push"]} ->
          {"", 0}

        {"git", ["add", "-A"]} ->
          {"", 0}

        {"git", ["commit", "-m", "save everything"]} ->
          {"", 0}

        {"git", ["diff", "--name-status", "old", "new"]} ->
          {"A\tposts/2026/04/new-post.md\nM\tscripts/tool.lua\nD\ttemplates/old.liquid\n", 0}

        {"git", ["lfs", "prune", "--recent"]} ->
          {"", 0}

        _other ->
          {"", 0}
      end
    end

    assert {:ok, _fetch} = Git.fetch(project.id, runner: runner)
    assert {:ok, _pull} = Git.pull(project.id, runner: runner)
    assert {:ok, _push} = Git.push(project.id, runner: runner)
    assert {:ok, commit} = Git.commit_all(project.id, "save everything", runner: runner)
    assert commit.message == "save everything"

    assert {:ok, reconcile} = Git.reconcile(project.id, "old", "new", runner: runner)
    assert reconcile.changed.posts.added == ["posts/2026/04/new-post.md"]
    assert reconcile.changed.scripts.modified == ["scripts/tool.lua"]
    assert reconcile.changed.templates.deleted == ["templates/old.liquid"]

    assert {:ok, prune} = Git.prune_lfs_cache(project.id, 5, runner: runner)
    assert prune.retained_recent == 5

    assert_received {:git_command, "git", ["fetch", "--all", "--prune"], fetch_opts}
    assert fetch_opts[:env]["GIT_TERMINAL_PROMPT"] == "0"
    assert fetch_opts[:env]["GCM_INTERACTIVE"] == "never"
    assert fetch_opts[:env]["GIT_SSH_COMMAND"] =~ "BatchMode=yes"
    # git hooks (e.g. git-lfs pre-push) must find Homebrew tools even when the
    # app is launched from Finder with a minimal PATH.
    assert fetch_opts[:env]["PATH"] =~ "/opt/homebrew/bin"
  end

  test "fetch returns structured auth errors with provider guidance", %{project: project} do
    runner =
      fake_runner(fn
        "git", ["remote", "get-url", "origin"], _opts ->
          {"git@gitlab.com:owner/repo.git\n", 0}

        "git", ["fetch", "--all", "--prune"], _opts ->
          {"fatal: Authentication failed for 'origin'", 128}
      end)

    assert {:error, error} = Git.fetch(project.id, runner: runner)
    assert error.kind == :auth
    assert error.provider == :gitlab
    assert error.platform == :macos
    assert is_binary(error.guidance)
  end

  test "fetch returns a structured timeout error when a runner exceeds the deadline", %{
    project: project
  } do
    with_git_timeouts(20, 20, fn ->
      runner = fn _command, _args, _opts ->
        Process.sleep(100)
        {"", 0}
      end

      assert {:error, error} = Git.fetch(project.id, runner: runner)
      assert %{kind: :timeout, operation: :fetch, timeout_ms: 20, message: _message} = error
      assert error.message =~ "timed out"
    end)
  end

  test "default runner kills the spawned git process when fetch times out", %{
    project: project,
    temp_root: temp_root
  } do
    pid_file = Path.join(temp_root, "git-timeout.pid")
    sleep_executable = System.find_executable("sleep") || raise "missing sleep executable"
    shell_executable = System.find_executable("sh") || raise "missing sh executable"
    shell_script = "echo \"$$\" > \"#{pid_file}\"; exec \"#{sleep_executable}\" 2"

    with_git_timeouts(50, 50, fn ->
      assert {:error, error} =
               Git.fetch(project.id,
                 command: shell_executable,
                 command_args: ["-c", shell_script]
               )

      assert %{kind: :timeout, operation: :fetch} = error

      pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
      refute os_process_alive?(pid)
    end)
  end

  test "stream/4 runs a network operation for the project and streams output live", %{
    project: project,
    temp_root: temp_root
  } do
    script = Path.join(temp_root, "fake-git")
    File.write!(script, "#!/bin/sh\nprintf 'pushing %s\\n' \"$1\" 1>&2\nexit 0\n")
    File.chmod!(script, 0o755)

    assert {:ok, _pid, ref} = Git.stream(project.id, :push, self(), command: script)

    assert_receive {:git_output, ^ref, :stderr, chunk}, 2_000
    assert chunk =~ "pushing push"
    assert_receive {:git_done, ^ref, 0}, 2_000
  end

  defp fake_runner(handler) do
    fn command, args, opts -> handler.(command, args, opts) end
  end

  defp with_git_timeouts(local_timeout_ms, network_timeout_ms, fun) do
    original = Application.get_env(:bds, :git)

    Application.put_env(:bds, :git,
      local_timeout_ms: local_timeout_ms,
      network_timeout_ms: network_timeout_ms
    )

    try do
      fun.()
    after
      if original == nil do
        Application.delete_env(:bds, :git)
      else
        Application.put_env(:bds, :git, original)
      end
    end
  end

  defp os_process_alive?(pid) when is_integer(pid) do
    {_output, exit_code} =
      System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    exit_code == 0
  end

  defp init_git_repo!(project_dir, message) do
    run_git!(project_dir, ["init", "-b", "master"])
    run_git!(project_dir, ["config", "user.name", "bDS Tests"])
    run_git!(project_dir, ["config", "user.email", "tests@example.com"])
    run_git!(project_dir, ["add", "-A"])
    run_git!(project_dir, ["commit", "-m", message])
  end

  defp run_git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)

    assert status == 0, output
  end
end
