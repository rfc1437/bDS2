defmodule BDS.Git do
  @moduledoc false

  alias BDS.Projects

  @lfs_patterns [
    "*.jpg",
    "*.jpeg",
    "*.png",
    "*.gif",
    "*.webp",
    "*.svg",
    "*.tif",
    "*.tiff",
    "*.bmp",
    "*.heic",
    "*.heif"
  ]

  @gitignore_lines [
    "/html/",
    "/thumbnails/",
    "/pagefind/",
    "/.DS_Store",
    "/node_modules/",
    "/deps/",
    "/_build/"
  ]

  def initialize_repo(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         :ok <- write_gitignore(project_dir),
         {:ok, _init} <- run_git(project_dir, ["init", "-b", "master"], opts),
         {:ok, _track} <- configure_lfs(project_dir, opts),
         {:ok, branch} <- current_branch(project_dir, opts),
         {:ok, remote_url} <- remote_url(project_dir, opts),
         {:ok, has_lfs} <- has_lfs?(project_dir, opts) do
      {:ok,
       %{
         is_initialized: true,
         remote_url: remote_url,
         provider: provider_info(remote_url),
         current_branch: branch,
         has_lfs: has_lfs
       }}
    end
  end

  def repository(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, branch} <- current_branch(project_dir, opts),
         {:ok, remote_url} <- remote_url(project_dir, opts) do
      {:ok,
       %{
         is_initialized: true,
         remote_url: remote_url,
         provider: provider_info(remote_url),
         current_branch: branch,
         has_lfs: has_lfs_configured?(project_dir)
       }}
    else
      {:error, :not_found} = error ->
        error

      {:error, _reason} ->
        {:ok,
         %{
           is_initialized: false,
           remote_url: nil,
           provider: nil,
           current_branch: nil,
           has_lfs: false
         }}
    end
  end

  def status(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, output} <-
           run_git(project_dir, ["status", "--porcelain=v1", "--untracked-files=all"], opts) do
      {:ok, %{files: parse_status(output)}}
    end
  end

  def diff(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, staged_diff} <- run_git(project_dir, ["diff", "--cached", "--no-ext-diff"], opts),
         {:ok, unstaged_diff} <- run_git(project_dir, ["diff", "--no-ext-diff"], opts) do
      {:ok, %{staged_diff: staged_diff, unstaged_diff: unstaged_diff}}
    end
  end

  def get_diff_content(project_id, file_path, opts \\ [])
      when is_binary(project_id) and is_binary(file_path) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id) do
      runner = Keyword.get(opts, :runner, &system_runner/3)

      original =
        case runner.("git", ["show", "HEAD:#{file_path}"], command_opts(project_dir)) do
          {output, 0} -> output
          {_output, _status} -> ""
        end

      modified =
        case File.read(Path.join(project_dir, file_path)) do
          {:ok, contents} -> contents
          {:error, _reason} -> ""
        end

      {:ok, %{file_path: file_path, original: original, modified: modified}}
    end
  end

  def history(project_id, branch, opts \\ [])
      when is_binary(project_id) and is_binary(branch) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, local_log} <-
           run_git(
             project_dir,
             ["log", "--date=short", "--format=%H%x09%an%x09%ad%x09%s", branch],
             opts
           ) do
      remote_log =
        case run_git(project_dir, ["log", "--format=%H", "origin/#{branch}"], opts) do
          {:ok, output} -> output
          {:error, {:git_failed, _message}} -> ""
        end

      local_commits = parse_history_log(local_log)
      remote_hashes = MapSet.new(parse_remote_history(remote_log))
      local_hashes = MapSet.new(Enum.map(local_commits, & &1.hash))

      remote_only =
        remote_hashes
        |> MapSet.difference(local_hashes)
        |> MapSet.to_list()
        |> Enum.map(fn hash ->
          %{hash: hash, subject: nil, author: nil, date: nil, sync_status: %{kind: :remote_only}}
        end)

      commits =
        Enum.map(local_commits, fn commit ->
          kind = if MapSet.member?(remote_hashes, commit.hash), do: :both, else: :local_only
          Map.put(commit, :sync_status, %{kind: kind})
        end) ++ remote_only

      {:ok, %{commits: commits}}
    end
  end

  def file_history(project_id, file_path, opts \\ [])
      when is_binary(project_id) and is_binary(file_path) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, output} <-
           run_git(project_dir, ["log", "--follow", "--format=%H%x09%s", "--", file_path], opts) do
      {:ok, %{commits: parse_local_history(output) |> Enum.take(50)}}
    else
      {:error, {:git_failed, _message}} -> {:ok, %{commits: []}}
      error -> error
    end
  end

  def fetch(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id) do
      case run_git(project_dir, ["fetch", "--all", "--prune"], opts) do
        {:ok, output} ->
          {:ok, %{updated: true, output: output}}

        {:error, {:git_failed, message}} ->
          structured_git_error(project_dir, :fetch, message, opts)
      end
    end
  end

  def pull(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, output} <- run_git(project_dir, ["pull", "--ff-only"], opts) do
      {:ok, %{updated: true, output: output}}
    end
  end

  def push(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, output} <- run_git(project_dir, ["push"], opts) do
      {:ok, %{updated: true, output: output}}
    end
  end

  def commit_all(project_id, message, opts \\ [])
      when is_binary(project_id) and is_binary(message) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, _stage} <- run_git(project_dir, ["add", "-A"], opts),
         {:ok, output} <- run_git(project_dir, ["commit", "-m", message], opts) do
      {:ok, %{message: message, output: output}}
    end
  end

  def reconcile(project_id, old_commit, new_commit, opts \\ [])
      when is_binary(project_id) and is_binary(old_commit) and is_binary(new_commit) and
             is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, output} <-
           run_git(project_dir, ["diff", "--name-status", old_commit, new_commit], opts) do
      {:ok, %{changed: parse_changed_files(output)}}
    end
  end

  def prune_lfs_cache(project_id, retain_recent, opts \\ [])
      when is_binary(project_id) and is_integer(retain_recent) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, output} <- run_git(project_dir, ["lfs", "prune", "--recent"], opts) do
      {:ok, %{retained_recent: retain_recent, output: output}}
    end
  end

  def set_remote(project_id, remote_url, opts \\ [])
      when is_binary(project_id) and is_binary(remote_url) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id) do
      case run_git(project_dir, ["remote", "add", "origin", remote_url], opts) do
        {:ok, _output} ->
          {:ok, %{remote_url: remote_url}}

        {:error, {:git_failed, _message}} ->
          with {:ok, _output} <-
                 run_git(project_dir, ["remote", "set-url", "origin", remote_url], opts) do
            {:ok, %{remote_url: remote_url}}
          end
      end
    end
  end

  def remote_state(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, project_dir} <- project_dir(project_id),
         {:ok, local_branch} <- current_branch(project_dir, opts) do
      case upstream_branch(project_dir, opts) do
        {:ok, nil} ->
          {:ok,
           %{
             local_branch: local_branch,
             upstream_branch: nil,
             has_upstream: false,
             ahead: 0,
             behind: 0
           }}

        {:ok, upstream_branch} ->
          {:ok,
           %{
             local_branch: local_branch,
             upstream_branch: upstream_branch,
             has_upstream: true,
             ahead: revision_count(project_dir, "#{upstream_branch}..HEAD", opts),
             behind: revision_count(project_dir, "HEAD..#{upstream_branch}", opts)
           }}
      end
    end
  end

  defp project_dir(project_id) do
    case Projects.get_project(project_id) do
      nil -> {:error, :not_found}
      project -> {:ok, Projects.project_data_dir(project)}
    end
  end

  defp configure_lfs(project_dir, opts) do
    Enum.reduce_while(@lfs_patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case run_git(project_dir, ["lfs", "track", pattern], opts) do
        {:ok, output} -> {:cont, {:ok, [output | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _outputs} ->
        write_gitattributes(project_dir)
        {:ok, :configured}

      error ->
        error
    end
  end

  defp write_gitignore(project_dir) do
    File.write!(Path.join(project_dir, ".gitignore"), Enum.join(@gitignore_lines, "\n") <> "\n")
    :ok
  end

  defp write_gitattributes(project_dir) do
    contents =
      @lfs_patterns
      |> Enum.map(&"#{&1} filter=lfs diff=lfs merge=lfs -text")
      |> Enum.join("\n")

    File.write!(Path.join(project_dir, ".gitattributes"), contents <> "\n")
    :ok
  end

  defp current_branch(project_dir, opts) do
    run_git(project_dir, ["rev-parse", "--abbrev-ref", "HEAD"], opts)
    |> normalize_optional_string()
  end

  defp remote_url(project_dir, opts) do
    case run_git(project_dir, ["remote", "get-url", "origin"], opts) do
      {:ok, output} -> {:ok, blank_to_nil(output)}
      {:error, {:git_failed, _message}} -> {:ok, nil}
    end
  end

  defp has_lfs?(project_dir, opts) do
    case run_git(project_dir, ["lfs", "ls-files"], opts) do
      {:ok, _output} -> {:ok, true}
      {:error, {:git_failed, _message}} -> {:ok, false}
    end
  end

  defp has_lfs_configured?(project_dir) do
    File.exists?(Path.join(project_dir, ".gitattributes"))
  end

  defp provider_info(nil), do: nil

  defp provider_info(remote_url) do
    kind =
      cond do
        String.contains?(remote_url, "github.com") -> :github
        String.contains?(remote_url, "gitlab") -> :gitlab
        true -> :gitea_forgejo
      end

    %{kind: kind}
  end

  defp run_git(project_dir, args, opts) do
    runner = Keyword.get(opts, :runner, &system_runner/3)

    case runner.("git", args, command_opts(project_dir)) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _status} -> {:error, {:git_failed, String.trim(output)}}
    end
  end

  defp system_runner(command, args, opts) do
    env = opts |> Keyword.get(:env, %{}) |> Enum.to_list()
    cwd = Keyword.fetch!(opts, :cd)
    System.cmd(command, args, cd: cwd, env: env, stderr_to_stdout: true)
  end

  defp command_opts(project_dir) do
    ssh_command = "ssh -oBatchMode=yes"

    [
      cd: project_dir,
      env: %{
        "GIT_TERMINAL_PROMPT" => "0",
        "GCM_INTERACTIVE" => "never",
        "GIT_SSH_COMMAND" => ssh_command
      }
    ]
  end

  defp upstream_branch(project_dir, opts) do
    case run_git(
           project_dir,
           ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
           opts
         ) do
      {:ok, output} -> {:ok, blank_to_nil(output)}
      {:error, {:git_failed, _message}} -> {:ok, nil}
    end
  end

  defp parse_status(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_status_line/1)
  end

  defp parse_status_line("?? " <> path), do: %{path: path, status: :untracked}

  defp parse_status_line("R  " <> rename) do
    [old_path, new_path] = String.split(rename, " -> ", parts: 2)
    %{path: new_path, old_path: old_path, status: :renamed}
  end

  defp parse_status_line(<<index::binary-size(1), worktree::binary-size(1), " ", path::binary>>) do
    %{path: path, status: status_from_porcelain(index, worktree)}
  end

  defp status_from_porcelain("A", _worktree), do: :added
  defp status_from_porcelain("D", _worktree), do: :deleted
  defp status_from_porcelain("M", _worktree), do: :modified
  defp status_from_porcelain(_, "D"), do: :deleted
  defp status_from_porcelain(_, "M"), do: :modified
  defp status_from_porcelain(_, _), do: :modified

  defp parse_local_history(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [hash, subject] -> %{hash: hash, subject: subject}
        [hash] -> %{hash: hash, subject: nil}
      end
    end)
  end

  defp parse_history_log(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 4) do
        [hash, author, date, subject] ->
          %{hash: hash, author: author, date: date, subject: subject}

        [hash, author, date] ->
          %{hash: hash, author: author, date: date, subject: nil}

        [hash | _rest] ->
          %{hash: hash, author: nil, date: nil, subject: nil}
      end
    end)
  end

  defp parse_remote_history(output) do
    String.split(output, "\n", trim: true)
  end

  defp parse_changed_files(output) do
    base = fn -> %{added: [], modified: [], deleted: [], renamed: []} end

    Enum.reduce(
      String.split(output, "\n", trim: true),
      %{posts: base.(), scripts: base.(), templates: base.()},
      fn line, acc ->
        case String.split(line, "\t", trim: true) do
          ["A", path] ->
            update_changed(acc, path, :added, path)

          ["M", path] ->
            update_changed(acc, path, :modified, path)

          ["D", path] ->
            update_changed(acc, path, :deleted, path)

          ["R" <> _score, old_path, new_path] ->
            update_changed(acc, new_path, :renamed, %{old: old_path, new: new_path})

          _other ->
            acc
        end
      end
    )
  end

  defp update_changed(acc, path, key, value) do
    case category_for_path(path) do
      nil ->
        acc

      category ->
        Map.update!(acc, category, &Map.update!(&1, key, fn items -> items ++ [value] end))
    end
  end

  defp revision_count(project_dir, revision_range, opts) do
    case run_git(project_dir, ["rev-list", "--count", revision_range], opts) do
      {:ok, output} -> parse_count(output)
      {:error, {:git_failed, _message}} -> 0
    end
  end

  defp parse_count(value) do
    case Integer.parse(to_string(value)) do
      {count, _rest} -> count
      :error -> 0
    end
  end

  defp category_for_path("posts/" <> _rest), do: :posts
  defp category_for_path("scripts/" <> _rest), do: :scripts
  defp category_for_path("templates/" <> _rest), do: :templates
  defp category_for_path(_path), do: nil

  defp structured_git_error(project_dir, _operation, message, opts) do
    provider =
      case remote_url(project_dir, opts) do
        {:ok, remote} -> provider_info(remote)
      end

    if auth_error?(message) do
      {:error,
       %{
         kind: :auth,
         provider: provider && provider.kind,
         platform: current_platform(),
         guidance: auth_guidance(provider && provider.kind, current_platform())
       }}
    else
      {:error, %{kind: :git_failed, message: message}}
    end
  end

  defp auth_error?(message) do
    downcased = String.downcase(message)
    String.contains?(downcased, "auth") or String.contains?(downcased, "permission denied")
  end

  defp auth_guidance(provider, platform) do
    provider_label = provider || :git

    "Authentication failed for #{provider_label} on #{platform}. Configure SSH keys or a credential helper that works non-interactively."
  end

  defp current_platform do
    case :os.type() do
      {:win32, _type} -> :windows
      {:unix, :darwin} -> :macos
      {:unix, _type} -> :linux
    end
  end

  defp normalize_optional_string({:ok, value}), do: {:ok, blank_to_nil(value)}
  defp normalize_optional_string({:error, _reason} = error), do: error

  defp blank_to_nil(value) when value in ["", "\n"], do: nil
  defp blank_to_nil(value), do: String.trim(value)
end
