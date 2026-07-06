defmodule BDS.Desktop.ShellLive.GitRun do
  @moduledoc """
  Live modal for streaming network git commands (fetch/pull/push).

  Starts a `BDS.Git.Stream`, appends its stdout/stderr chunks as they arrive
  (stderr rendered in red), shows a spinner while running and a pass/fail banner
  from the exit status. Closing the modal cancels a still-running command, which
  kills the OS process.
  """

  use Phoenix.Component

  use Gettext, backend: BDS.Gettext

  alias BDS.Git

  @operations %{"git_fetch" => :fetch, "git_pull" => :pull, "git_push" => :push}

  @doc "True when the shell event is a streaming network git action."
  def network_event?(event), do: Map.has_key?(@operations, event)

  @doc "Open the modal and start streaming the operation."
  def start(socket, event, project_id) do
    operation = Map.fetch!(@operations, event)

    run =
      case start_stream(project_id, operation) do
        {:ok, pid, ref} ->
          %{operation: operation, pid: pid, ref: ref, lines: [], status: :running}

        {:error, reason} ->
          %{
            operation: operation,
            pid: nil,
            ref: nil,
            lines: [{:stderr, error_text(reason)}],
            status: {:done, 1}
          }
      end

    assign(socket, :git_run, run)
  end

  @doc "Append a streamed chunk to the modal (newest first internally)."
  def append(socket, ref, stream, chunk) do
    case socket.assigns[:git_run] do
      %{ref: ^ref, lines: lines} = run ->
        assign(socket, :git_run, %{run | lines: [{stream, chunk} | lines]})

      _other ->
        socket
    end
  end

  @doc "Mark the run finished with its exit status."
  def done(socket, ref, status) do
    case socket.assigns[:git_run] do
      %{ref: ^ref} = run ->
        assign(socket, :git_run, %{run | status: {:done, status}, pid: nil})

      _other ->
        socket
    end
  end

  @doc "Close the modal, cancelling (killing) a still-running command."
  def close(socket) do
    case socket.assigns[:git_run] do
      %{status: :running, pid: pid} when is_pid(pid) -> Git.Stream.cancel(pid)
      _other -> :ok
    end

    assign(socket, :git_run, nil)
  end

  defp start_stream(nil, _operation), do: {:error, :no_project}
  defp start_stream("default", _operation), do: {:error, :no_project}

  defp start_stream(project_id, operation) when is_binary(project_id),
    do: Git.stream(project_id, operation, self())

  defp error_text(reason) when reason in [:no_project, :not_found],
    do: dgettext("ui", "No active project") <> "\n"

  defp error_text(reason), do: inspect(reason) <> "\n"

  def git_run_modal(assigns) do
    ~H"""
    <%= if @git_run do %>
      <div class="shell-overlay-backdrop git-run-backdrop" data-testid="git-run-backdrop" phx-window-keydown="git_run_keydown">
        <button class="shell-overlay-dismiss" type="button" phx-click="git_run_close" aria-label={dgettext("ui", "Close")}></button>
        <div class="git-run-modal" role="dialog" aria-modal="true">
          <div class="git-run-header">
            <h2 class="git-run-title">{title(@git_run.operation)}</h2>
            <span class={["git-run-status", status_class(@git_run.status)]} data-testid="git-run-status">
              {status_label(@git_run.status)}
            </span>
          </div>
          <pre class="git-run-output" data-testid="git-run-output"><%= for {stream, text} <- Enum.reverse(@git_run.lines) do %><span class={line_class(stream)}>{text}</span><% end %></pre>
          <div class="git-run-footer">
            <button class="git-action-button" type="button" phx-click="git_run_close" data-testid="git-run-close">
              {close_label(@git_run.status)}
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  defp title(:fetch), do: dgettext("ui", "git fetch")
  defp title(:pull), do: dgettext("ui", "git pull")
  defp title(:push), do: dgettext("ui", "git push")

  defp line_class(:stderr), do: "git-run-line git-run-stderr"
  defp line_class(:stdout), do: "git-run-line git-run-stdout"

  defp status_class(:running), do: "running"
  defp status_class({:done, 0}), do: "ok"
  defp status_class({:done, _status}), do: "fail"

  defp status_label(:running), do: dgettext("ui", "Running…")
  defp status_label({:done, 0}), do: dgettext("ui", "Done")

  defp status_label({:done, status}),
    do: dgettext("ui", "Failed (exit %{status})", status: status)

  defp close_label(:running), do: dgettext("ui", "Cancel")
  defp close_label({:done, _status}), do: dgettext("ui", "Close")
end
