defmodule BDS.Desktop.ShellLive.GitHandler do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.Desktop.ShellLive.{SocketState, TabHelpers, UrlState}
  alias BDS.UI.Workbench

  use Gettext, backend: BDS.Gettext

  def run_action(socket, event) do
    project_id = current_project_id(socket)

    {label, result} =
      case event do
        "git_fetch" -> {dgettext("ui", "Fetch"), git_call(project_id, &BDS.Git.fetch/1)}
        "git_pull" -> {dgettext("ui", "Pull"), git_call(project_id, &BDS.Git.pull/1)}
        "git_push" -> {dgettext("ui", "Push"), git_call(project_id, &BDS.Git.push/1)}
        "git_prune_lfs" -> {dgettext("ui", "Prune LFS"), prune_lfs(project_id)}
      end

    socket
    |> append_git_result(label, result)
    |> SocketState.refresh_sidebar(socket.assigns.workbench)
  end

  def commit(socket, "") do
    socket
    |> SocketState.append_output_entry(
      dgettext("ui", "Commit"),
      dgettext("ui", "Commit message is required"),
      nil,
      "error"
    )
    |> SocketState.refresh_sidebar(socket.assigns.workbench)
  end

  def commit(socket, message) do
    case git_call(current_project_id(socket), &BDS.Git.commit_all(&1, message)) do
      {:ok, _result} ->
        workbench = close_git_diff_tabs(socket.assigns.workbench)
        tab_meta = TabHelpers.sync_tab_meta(workbench, socket.assigns[:tab_meta] || %{})

        socket
        |> assign(:tab_meta, tab_meta)
        |> SocketState.append_output_entry(dgettext("ui", "Commit"), message, nil, "info")
        |> SocketState.refresh_sidebar(workbench)
        |> UrlState.push()

      {:error, reason} ->
        socket
        |> SocketState.append_output_entry(dgettext("ui", "Commit"), format_git_error(reason), nil, "error")
        |> SocketState.refresh_sidebar(socket.assigns.workbench)
    end
  end

  def initialize(socket, remote_url) do
    project_id = current_project_id(socket)

    case git_call(project_id, &BDS.Git.initialize_repo/1) do
      {:ok, _repo} ->
        _ = maybe_set_git_remote(project_id, remote_url)

        socket
        |> SocketState.append_output_entry(
          dgettext("ui", "Initialize Git"),
          dgettext("ui", "Repository initialized"),
          nil,
          "info"
        )
        |> SocketState.refresh_sidebar(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> SocketState.append_output_entry(
          dgettext("ui", "Initialize Git"),
          format_git_error(reason),
          nil,
          "error"
        )
        |> SocketState.refresh_sidebar(socket.assigns.workbench)
    end
  end

  def normalize_remote_url(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      url -> url
    end
  end

  defp git_call(nil, _fun), do: {:error, :no_project}
  defp git_call("default", _fun), do: {:error, :no_project}
  defp git_call(project_id, fun) when is_binary(project_id), do: fun.(project_id)

  defp prune_lfs(nil), do: {:error, :no_project}
  defp prune_lfs("default"), do: {:error, :no_project}

  defp prune_lfs(project_id) when is_binary(project_id),
    do: BDS.Git.prune_lfs_cache(project_id, 10)

  defp maybe_set_git_remote(_project_id, nil), do: :ok
  defp maybe_set_git_remote(project_id, remote_url), do: BDS.Git.set_remote(project_id, remote_url)

  defp append_git_result(socket, label, {:ok, _result}) do
    SocketState.append_output_entry(socket, label, dgettext("ui", "Done"), nil, "info")
  end

  defp append_git_result(socket, label, {:error, reason}) do
    SocketState.append_output_entry(socket, label, format_git_error(reason), nil, "error")
  end

  defp format_git_error(:no_project), do: dgettext("ui", "No active project")
  defp format_git_error(%{message: message}) when is_binary(message), do: message
  defp format_git_error(%{guidance: guidance}) when is_binary(guidance), do: guidance
  defp format_git_error({:git_failed, message}) when is_binary(message), do: message
  defp format_git_error(reason), do: inspect(reason)

  defp close_git_diff_tabs(workbench) do
    workbench.tabs
    |> Enum.filter(&(&1.type == :git_diff))
    |> Enum.reduce(workbench, fn tab, wb -> Workbench.close_tab(wb, :git_diff, tab.id) end)
  end

  defp current_project_id(socket), do: (socket.assigns[:projects] || %{})[:active_project_id]
end
