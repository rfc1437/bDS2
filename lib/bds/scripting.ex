defmodule BDS.Scripting do
  @moduledoc """
  Facade for the configured user-script runtime.
  """

  require Logger

  alias BDS.Scripting.Capabilities
  alias BDS.Scripting.Runtime

  @type job_status :: :queued | :running | :completed | :failed | :cancelled
  @type job_snapshot :: %{
          id: String.t(),
          status: job_status(),
          progress: map(),
          result: term() | nil,
          error: term() | nil,
          inserted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }

  @spec runtime() :: module()
  def runtime do
    Application.fetch_env!(:bds, :scripting)
    |> Keyword.fetch!(:runtime)
  end

  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(source) when is_binary(source) do
    runtime().validate(source)
  end

  @spec execute(String.t(), String.t(), [term()], [Runtime.execution_option()]) ::
          {:ok, term()} | {:error, term()}
  def execute(source, entrypoint, args \\ [], opts \\ [])
      when is_binary(source) and is_binary(entrypoint) and is_list(args) and is_list(opts) do
    runtime().execute(source, entrypoint, args, opts)
  end

  @spec execute_project_script(String.t(), String.t(), String.t(), [term()], [
          Runtime.execution_option()
        ]) ::
          {:ok, term()} | {:error, term()}
  def execute_project_script(project_id, source, entrypoint, args \\ [], opts \\ [])
      when is_binary(project_id) and is_binary(source) and is_binary(entrypoint) and
             is_list(args) and is_list(opts) do
    capabilities = Capabilities.for_project(project_id, opts)
    execute(source, entrypoint, args, Keyword.put(opts, :capabilities, capabilities))
  end

  @spec execute_macro(String.t(), String.t(), [term()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute_macro(project_id, source, args, opts \\ [])
      when is_binary(project_id) and is_binary(source) and is_list(args) and is_list(opts) do
    config = Application.fetch_env!(:bds, :scripting)
    timeout = Keyword.get(opts, :timeout, Keyword.fetch!(config, :timeout))

    case execute_project_script(
           project_id,
           source,
           "render",
           args,
           Keyword.put(opts, :timeout, timeout)
         ) do
      {:ok, nil} ->
        {:ok, ""}

      {:ok, value} ->
        {:ok, to_string(value)}

      {:error, reason} ->
        Logger.warning("execute_macro failed for project #{project_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec start_job(String.t(), String.t(), [term()], [Runtime.execution_option()]) ::
          {:ok, job_snapshot()} | {:error, term()}
  def start_job(source, entrypoint, args \\ [], opts \\ [])
      when is_binary(source) and is_binary(entrypoint) and is_list(args) and is_list(opts) do
    job_id = "script-job-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

    job = %{
      id: job_id,
      status: :queued,
      progress: %{},
      result: nil,
      error: nil,
      inserted_at: DateTime.utc_now(),
      started_at: nil,
      finished_at: nil
    }

    :ok = BDS.Scripting.JobStore.put_job(job)

    child_spec =
      {BDS.Scripting.JobRunner,
       job_id: job_id,
       runtime: runtime(),
       source: source,
       entrypoint: entrypoint,
       args: args,
       opts: batch_job_defaults(opts)}

    case DynamicSupervisor.start_child(BDS.Scripting.JobSupervisor, child_spec) do
      {:ok, _pid} ->
        {:ok, BDS.Scripting.JobStore.fetch_job!(job_id)}

      {:error, reason} ->
        :ok =
          BDS.Scripting.JobStore.update_job(job_id, %{
            status: :failed,
            error: reason,
            finished_at: DateTime.utc_now()
          })

        {:error, reason}
    end
  end

  @spec get_job(String.t()) :: job_snapshot() | nil
  def get_job(job_id) when is_binary(job_id) do
    BDS.Scripting.JobStore.fetch_job(job_id)
  end

  @spec cancel_job(String.t()) :: :ok | {:error, :not_found | :not_running}
  def cancel_job(job_id) when is_binary(job_id) do
    case BDS.Scripting.JobStore.runner_for(job_id) do
      nil ->
        case BDS.Scripting.JobStore.fetch_job(job_id) do
          nil -> {:error, :not_found}
          _job -> {:error, :not_running}
        end

      pid ->
        BDS.Scripting.JobRunner.cancel(pid)
    end
  end

  defp batch_job_defaults(opts) do
    config = Application.fetch_env!(:bds, :scripting)

    defaults = [
      timeout: Keyword.get(config, :job_timeout, :infinity),
      max_reductions: Keyword.get(config, :job_max_reductions, :none)
    ]

    Keyword.merge(defaults, opts)
  end
end
