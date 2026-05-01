defmodule BDS.Desktop.ShellLive.ShellCommandRunner do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.BoundedAtoms
  alias BDS.Desktop.ShellCommands
  alias BDS.Desktop.ShellLive.{TabHelpers, TaskLocalization}
  alias BDS.UI.Workbench

  @doc """
  Execute a shell command and apply its result to the socket.

  `callbacks` requires:
    * `:reload` — `(socket, workbench -> socket)`
    * `:append_output` — `(socket, title, message, details, level -> socket)`
  """
  def execute(socket, action, params \\ %{}, callbacks) do
    case ShellCommands.execute(action, params) do
      {:ok, result} ->
        apply_result(socket, result, callbacks)

      {:error, %{message: message}} ->
        callbacks.append_output.(
          socket,
          TaskLocalization.command_title(action),
          message,
          nil,
          "error"
        )

      {:error, reason} ->
        callbacks.append_output.(
          socket,
          TaskLocalization.command_title(action),
          inspect(reason),
          nil,
          "error"
        )
    end
  end

  def apply_result(
        socket,
        %{kind: "task_queued", title: title, message: message, panel_tab: panel_tab},
        callbacks
      ) do
    workbench =
      socket.assigns.workbench
      |> Workbench.set_panel_visible(true)
      |> Workbench.set_panel_tab(BoundedAtoms.panel_tab(panel_tab, :tasks))

    socket
    |> callbacks.append_output.(
      TaskLocalization.translate_for_socket(socket, title),
      TaskLocalization.translate_for_socket(socket, message),
      nil,
      "info"
    )
    |> callbacks.reload.(workbench)
  end

  def apply_result(socket, %{kind: "output", title: title, message: message} = result, callbacks) do
    callbacks.append_output.(
      socket,
      TaskLocalization.translate_for_socket(socket, title),
      TaskLocalization.translate_for_socket(socket, message),
      Map.get(result, :details),
      Map.get(result, :level, "info")
    )
  end

  def apply_result(
        socket,
        %{kind: "open_url", title: title, message: message, url: url},
        callbacks
      ) do
    callbacks.append_output.(
      socket,
      TaskLocalization.translate_for_socket(socket, title),
      TaskLocalization.translate_for_socket(socket, message),
      url,
      "info"
    )
  end

  def apply_result(
        socket,
        %{kind: "open_editor", route: route, title: title, subtitle: subtitle} = result,
        callbacks
      ) do
    route_atom = BoundedAtoms.editor_route(route, :dashboard)
    tab_id = TabHelpers.tab_id_for_route(route_atom, route)
    workbench = Workbench.open_tab(socket.assigns.workbench, route_atom, tab_id, :pin)

    tab_meta =
      Map.put(socket.assigns.tab_meta, {route_atom, tab_id}, %{
        title: TaskLocalization.translate_for_socket(socket, title),
        subtitle: TaskLocalization.translate_for_socket(socket, subtitle),
        action: Map.get(result, :action),
        payload: Map.get(result, :payload),
        project_id: Map.get(result, :project_id),
        editor_meta:
          TaskLocalization.translate_editor_meta(
            Map.get(result, :editorMeta, []),
            socket.assigns.page_language
          )
      })

    socket
    |> assign(:tab_meta, tab_meta)
    |> callbacks.reload.(workbench)
  end

  def apply_result(socket, _result, _callbacks), do: socket

  def shell_command_atom(action), do: BoundedAtoms.shell_command(action)
end
