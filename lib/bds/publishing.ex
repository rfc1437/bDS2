defmodule BDS.Publishing do
  @moduledoc """
  GenServer that manages site upload jobs, coordinating file transfers to
  configured hosting destinations and tracking progress via the task system.
  """

  use GenServer

  import BDS.MapUtils, only: [attr: 2]

  alias BDS.Persistence
  alias BDS.Publishing.PublishJob
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Tasks

  @typedoc "Credentials map for an upload destination."
  @type credentials :: map()

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec upload_site(String.t(), credentials(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def upload_site(project_id, credentials, opts \\ [])
      when is_binary(project_id) and is_map(credentials) and is_list(opts) do
    project = Projects.get_project!(project_id)
    normalized_credentials = normalize_credentials(credentials)
    targets = build_upload_targets(Projects.project_data_dir(project), normalized_credentials)

    job_id = "publish-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    uploader = build_uploader(Keyword.put_new(opts, :project_id, project_id))
    now = Persistence.now_ms()

    job_attrs = %{
      id: job_id,
      project_id: project_id,
      status: :pending,
      task_id: nil,
      ssh_host: normalized_credentials.ssh_host,
      ssh_user: normalized_credentials.ssh_user,
      ssh_remote_path: normalized_credentials.ssh_remote_path,
      ssh_mode: normalized_credentials.ssh_mode,
      targets: Enum.map(targets, &to_string(&1.kind)),
      error: nil,
      inserted_at: now,
      updated_at: now
    }

    job =
      %PublishJob{}
      |> PublishJob.changeset(job_attrs)
      |> Repo.insert!()

    {:ok, task} =
      Tasks.submit_task(
        "publish #{project_id}",
        fn report ->
          run_upload(job_id, normalized_credentials, targets, uploader, report)
        end,
        %{
          group_id: project_id,
          group_name: "Publishing"
        }
      )

    next_job =
      job
      |> PublishJob.changeset(%{task_id: task.id, updated_at: Persistence.now_ms()})
      |> Repo.update!()

    {:ok, next_job}
  end

  @spec get_job(String.t()) :: PublishJob.t() | nil
  def get_job(job_id) when is_binary(job_id) do
    Repo.get(PublishJob, job_id)
  end

  @impl true
  def init(_state) do
    {:ok, %{scp_uploads: %{}}}
  end

  @impl true
  def handle_call({:filter_scp_uploads, project_id, credentials, target_kind, files}, _from, state) do
    {files_to_upload, next_uploads} =
      Enum.reduce(files, {[], state.scp_uploads}, fn {relative_path, local_mtime}, {acc, uploads} ->
        upload_key = scp_upload_key(project_id, credentials, target_kind, relative_path)

        if should_upload_mtime?(uploads[upload_key], local_mtime) do
          {[{relative_path, local_mtime} | acc], uploads}
        else
          {acc, uploads}
        end
      end)

    {:reply, Enum.reverse(files_to_upload), %{state | scp_uploads: next_uploads}}
  end

  @impl true
  def handle_call(
        {:record_uploaded_scp_files, project_id, credentials, target_kind, uploaded_files},
        _from,
        state
      ) do
    next_uploads =
      Enum.reduce(uploaded_files, state.scp_uploads, fn {relative_path, local_mtime}, uploads ->
        Map.put(
          uploads,
          scp_upload_key(project_id, credentials, target_kind, relative_path),
          local_mtime
        )
      end)

    {:reply, :ok, %{state | scp_uploads: next_uploads}}
  end

  defp run_upload(job_id, credentials, targets, uploader, report) do
    update_job(job_id, %{status: :running, error: nil})

    target_count = max(length(targets), 1)

    result =
      Enum.with_index(targets, 1)
      |> Enum.reduce_while(:ok, fn {target, index}, :ok ->
        files = list_target_files(target)
        report.(index / target_count, "Uploading #{target.kind}")

        case uploader.(target, files, credentials) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        update_job(job_id, %{status: :completed, error: nil})
        {:ok, Enum.map(targets, & &1.kind)}

      {:error, reason} ->
        update_job(job_id, %{status: :failed, error: to_string(reason)})
        {:error, to_string(reason)}
    end
  end

  defp update_job(job_id, attrs) do
    repo_opts = repo_call_opts()

    with %PublishJob{} = job <- Repo.get(PublishJob, job_id, repo_opts) do
      attrs = Map.put(attrs, :updated_at, Persistence.now_ms())
      _ = job |> PublishJob.changeset(attrs) |> Repo.update(repo_opts)
    end

    :ok
  end

  defp build_uploader(opts) do
    case Keyword.get(opts, :uploader) do
      nil ->
        runner = Keyword.get(opts, :command_runner, &System.cmd/3)
        ssh_auth_sock = Keyword.get(opts, :ssh_auth_sock, System.get_env("SSH_AUTH_SOCK"))
        project_id = Keyword.fetch!(opts, :project_id)

        fn target, files, credentials ->
          run_command_upload(project_id, target, files, credentials, runner, ssh_auth_sock)
        end

      uploader ->
        uploader
    end
  end

  defp run_command_upload(
         _project_id,
         target,
         _files,
         %{ssh_mode: :rsync} = credentials,
         runner,
         ssh_auth_sock
       ) do
    args =
      ["--update", "--compress", "--verbose"] ++
        rsync_excludes(target) ++
        [
          "-e",
          "ssh",
          ensure_trailing_slash(target.local_dir),
          remote_dir_spec(credentials, target.remote_dir)
        ]

    run_command(runner, "rsync", args, ssh_auth_sock)
  end

  defp run_command_upload(project_id, target, files, credentials, runner, ssh_auth_sock) do
    with {:ok, files_with_mtimes} <- collect_file_mtimes(target.local_dir, files) do
      files_to_upload =
        filter_scp_uploads(project_id, credentials, target.kind, files_with_mtimes)

      case upload_scp_files(
             project_id,
             target,
             credentials,
             runner,
             ssh_auth_sock,
             files_to_upload,
             []
           ) do
        {:ok, uploaded_files} ->
          persist_uploaded_scp_files(project_id, credentials, target.kind, uploaded_files)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_command(runner, command, args, ssh_auth_sock) do
    opts = command_opts(ssh_auth_sock)
    {output, exit_status} = runner.(command, args, opts)

    if exit_status == 0 do
      :ok
    else
      {:error, normalize_command_error(command, output, exit_status)}
    end
  end

  defp command_opts(nil), do: [stderr_to_stdout: true]

  defp command_opts(ssh_auth_sock),
    do: [stderr_to_stdout: true, env: [{"SSH_AUTH_SOCK", ssh_auth_sock}]]

  defp normalize_command_error(_command, output, _status) when is_binary(output) and output != "",
    do: output

  defp normalize_command_error(command, _output, status),
    do: "#{command} exited with status #{status}"

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat.mtime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter_scp_uploads(project_id, credentials, target_kind, files_with_mtimes) do
    GenServer.call(
      __MODULE__,
      {:filter_scp_uploads, project_id, credentials, target_kind, files_with_mtimes}
    )
  end

  defp record_uploaded_scp_files(project_id, credentials, target_kind, uploaded_files) do
    GenServer.call(
      __MODULE__,
      {:record_uploaded_scp_files, project_id, credentials, target_kind, uploaded_files}
    )
  end

  defp upload_scp_files(
         _project_id,
         _target,
         _credentials,
         _runner,
         _ssh_auth_sock,
         [],
         uploaded_files
       ) do
    {:ok, Enum.reverse(uploaded_files)}
  end

  defp upload_scp_files(
         project_id,
         target,
         credentials,
         runner,
         ssh_auth_sock,
         [{relative_path, local_mtime} | rest],
         uploaded_files
       ) do
    local_path = Path.join(target.local_dir, relative_path)
    remote_path = remote_file_spec(credentials, target.remote_dir, relative_path)

    case run_command(runner, "scp", ["-q", local_path, remote_path], ssh_auth_sock) do
      :ok ->
        upload_scp_files(
          project_id,
          target,
          credentials,
          runner,
          ssh_auth_sock,
          rest,
          [{relative_path, local_mtime} | uploaded_files]
        )

      {:error, reason} ->
        persist_uploaded_scp_files(project_id, credentials, target.kind, uploaded_files)
        {:error, reason}
    end
  end

  defp collect_file_mtimes(local_dir, files) do
    Enum.reduce_while(files, {:ok, []}, fn relative_path, {:ok, acc} ->
      local_path = Path.join(local_dir, relative_path)

      case file_mtime(local_path) do
        {:ok, local_mtime} -> {:cont, {:ok, [{relative_path, local_mtime} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files_with_mtimes} -> {:ok, Enum.reverse(files_with_mtimes)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_uploaded_scp_files(_project_id, _credentials, _target_kind, []), do: :ok

  defp persist_uploaded_scp_files(project_id, credentials, target_kind, uploaded_files) do
    record_uploaded_scp_files(
      project_id,
      credentials,
      target_kind,
      Enum.reverse(uploaded_files)
    )
  end

  defp should_upload_mtime?(nil, _local_mtime), do: true
  defp should_upload_mtime?(recorded_mtime, local_mtime), do: local_mtime > recorded_mtime

  defp repo_call_opts do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> [caller: pid]
      _other -> []
    end
  end

  defp scp_upload_key(project_id, credentials, target_kind, relative_path) do
    {
      project_id,
      credentials.ssh_host,
      credentials.ssh_user,
      credentials.ssh_remote_path,
      target_kind,
      relative_path
    }
  end

  defp rsync_excludes(%{kind: :media}), do: ["--exclude=*.meta"]
  defp rsync_excludes(_target), do: []

  @spec ensure_trailing_slash(String.t()) :: String.t()
  def ensure_trailing_slash(path), do: String.trim_trailing(path, "/") <> "/"

  defp remote_dir_spec(credentials, remote_dir) do
    remote_base(credentials) <> ":" <> ensure_trailing_slash(remote_dir)
  end

  defp remote_file_spec(credentials, remote_dir, relative_path) do
    remote_base(credentials) <> ":" <> Path.join(remote_dir, relative_path)
  end

  defp remote_base(credentials), do: "#{credentials.ssh_user}@#{credentials.ssh_host}"

  defp build_upload_targets(base_dir, credentials) do
    remote_root = String.trim_trailing(credentials.ssh_remote_path, "/")

    [
      %{kind: :html, local_dir: Path.join(base_dir, "html"), remote_dir: remote_root},
      %{
        kind: :thumbnails,
        local_dir: Path.join(base_dir, "thumbnails"),
        remote_dir: Path.join(remote_root, "thumbnails")
      },
      %{
        kind: :media,
        local_dir: Path.join(base_dir, "media"),
        remote_dir: Path.join(remote_root, "media")
      }
    ]
  end

  defp list_target_files(target) do
    if File.dir?(target.local_dir) do
      target.local_dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, target.local_dir))
      |> Enum.reject(fn relative_path ->
        target.kind == :media and String.ends_with?(relative_path, ".meta")
      end)
      |> Enum.sort()
    else
      []
    end
  end

  defp normalize_credentials(credentials) do
    %{
      ssh_host: attr(credentials, :ssh_host),
      ssh_user: attr(credentials, :ssh_user),
      ssh_remote_path: attr(credentials, :ssh_remote_path) || "/",
      ssh_mode: normalize_ssh_mode(attr(credentials, :ssh_mode))
    }
  end

  defp normalize_ssh_mode(mode) when mode in [:scp, :rsync], do: mode
  defp normalize_ssh_mode("rsync"), do: :rsync
  defp normalize_ssh_mode(_mode), do: :scp
end
