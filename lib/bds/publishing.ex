defmodule BDS.Publishing do
  @moduledoc false

  use GenServer

  alias BDS.Projects
  alias BDS.Tasks

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def upload_site(project_id, credentials, opts \\ [])
      when is_binary(project_id) and is_map(credentials) and is_list(opts) do
    project = Projects.get_project!(project_id)
    normalized_credentials = normalize_credentials(credentials)
    targets = build_upload_targets(Projects.project_data_dir(project), normalized_credentials)
    GenServer.call(__MODULE__, {:upload_site, project_id, normalized_credentials, targets, opts})
  end

  def get_job(job_id) when is_binary(job_id) do
    GenServer.call(__MODULE__, {:get_job, job_id})
  end

  @impl true
  def init(_state) do
    {:ok, %{jobs: %{}, scp_uploads: %{}}}
  end

  @impl true
  def handle_call({:get_job, job_id}, _from, state) do
    {:reply, state.jobs[job_id], state}
  end

  def handle_call({:update_job, job_id, attrs}, _from, state) do
    next_state =
      update_in(state, [:jobs, job_id], fn
        nil -> nil
        job -> Map.merge(job, Map.put(attrs, :updated_at, DateTime.utc_now()))
      end)

    {:reply, :ok, next_state}
  end

  def handle_call({:should_upload_scp_file, upload_key, local_mtime}, _from, state) do
    should_upload? =
      case state.scp_uploads[upload_key] do
        nil -> true
        recorded_mtime -> local_mtime > recorded_mtime
      end

    {:reply, should_upload?, state}
  end

  def handle_call({:mark_uploaded_scp_file, upload_key, local_mtime}, _from, state) do
    {:reply, :ok, put_in(state, [:scp_uploads, upload_key], local_mtime)}
  end

  def handle_call({:upload_site, project_id, credentials, targets, opts}, _from, state) do
    job_id = "publish-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    uploader = build_uploader(Keyword.put_new(opts, :project_id, project_id))

    job = %{
      id: job_id,
      project_id: project_id,
      status: :pending,
      task_id: nil,
      ssh_host: credentials.ssh_host,
      ssh_user: credentials.ssh_user,
      ssh_remote_path: credentials.ssh_remote_path,
      ssh_mode: credentials.ssh_mode,
      targets: Enum.map(targets, & &1.kind),
      error: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    {:ok, task} =
      Tasks.submit_task(
        "publish #{project_id}",
        fn report ->
          run_upload(job_id, credentials, targets, uploader, report)
        end,
        %{
          group_id: project_id,
          group_name: "Publishing"
        }
      )

    next_job = %{job | task_id: task.id}
    {:reply, {:ok, next_job}, put_in(state, [:jobs, job_id], next_job)}
  end

  defp run_upload(job_id, credentials, targets, uploader, report) do
    update_job(job_id, %{status: :running, error: nil})

    result =
      Enum.with_index(targets, 1)
      |> Enum.reduce_while(:ok, fn {target, index}, :ok ->
        files = list_target_files(target)
        report.(index / max(length(targets), 1), "Uploading #{target.kind}")

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
    GenServer.call(__MODULE__, {:update_job, job_id, attrs})
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
    Enum.reduce_while(files, :ok, fn relative_path, :ok ->
      local_path = Path.join(target.local_dir, relative_path)

      with {:ok, local_mtime} <- file_mtime(local_path),
           true <-
             should_upload_scp_file?(
               project_id,
               credentials,
               target.kind,
               relative_path,
               local_mtime
             ) do
        remote_path = remote_file_spec(credentials, target.remote_dir, relative_path)

        case run_command(runner, "scp", ["-q", local_path, remote_path], ssh_auth_sock) do
          :ok ->
            :ok =
              mark_uploaded_scp_file(
                project_id,
                credentials,
                target.kind,
                relative_path,
                local_mtime
              )

            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        false -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp should_upload_scp_file?(project_id, credentials, target_kind, relative_path, local_mtime) do
    GenServer.call(
      __MODULE__,
      {:should_upload_scp_file,
       scp_upload_key(project_id, credentials, target_kind, relative_path), local_mtime}
    )
  end

  defp mark_uploaded_scp_file(project_id, credentials, target_kind, relative_path, local_mtime) do
    GenServer.call(
      __MODULE__,
      {:mark_uploaded_scp_file,
       scp_upload_key(project_id, credentials, target_kind, relative_path), local_mtime}
    )
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

  defp ensure_trailing_slash(path), do: String.trim_trailing(path, "/") <> "/"

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

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
