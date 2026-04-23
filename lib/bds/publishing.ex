defmodule BDS.Publishing do
  @moduledoc false

  use GenServer

  alias BDS.Projects
  alias BDS.Tasks

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def upload_site(project_id, credentials, opts \\ []) when is_binary(project_id) and is_map(credentials) and is_list(opts) do
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
    {:ok, %{jobs: %{}}}
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

  def handle_call({:upload_site, project_id, credentials, targets, opts}, _from, state) do
    job_id = "publish-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    uploader = Keyword.get(opts, :uploader, fn _target, _files, _credentials -> :ok end)

    job = %{
      id: job_id,
      project_id: project_id,
      status: :pending,
      task_id: nil,
      ssh_mode: credentials.ssh_mode,
      targets: Enum.map(targets, & &1.kind),
      error: nil,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    {:ok, task} =
      Tasks.submit_task("publish #{project_id}", fn report ->
        run_upload(job_id, credentials, targets, uploader, report)
      end, %{
        group_id: project_id,
        group_name: "Publishing"
      })

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

  defp build_upload_targets(base_dir, credentials) do
    remote_root = String.trim_trailing(credentials.ssh_remote_path, "/")

    [
      %{kind: :html, local_dir: Path.join(base_dir, "html"), remote_dir: remote_root},
      %{kind: :thumbnails, local_dir: Path.join(base_dir, "thumbnails"), remote_dir: Path.join(remote_root, "thumbnails")},
      %{kind: :media, local_dir: Path.join(base_dir, "media"), remote_dir: Path.join(remote_root, "media")}
    ]
  end

  defp list_target_files(target) do
    if File.dir?(target.local_dir) do
      target.local_dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, target.local_dir))
      |> Enum.reject(fn relative_path -> target.kind == :media and String.ends_with?(relative_path, ".meta") end)
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
