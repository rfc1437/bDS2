defmodule BDS.Desktop.ShellLive.SidebarCreate do
  @moduledoc false

  alias BDS.Desktop.{FilePicker, ShellData}
  alias BDS.ImportDefinitions
  alias BDS.Scripts
  alias BDS.Templates

  @doc """
  Create a new sidebar item of the given kind for the active project.

  `callbacks` must contain:
    * `:reload` — `(socket, workbench -> socket)`
    * `:open_sidebar` — `(socket, params, intent -> socket)`
    * `:append_output` — `(socket, title, message, details, level -> socket)`
  """
  def create(socket, kind, callbacks) do
    case socket.assigns.projects.active_project_id do
      project_id when is_binary(project_id) -> create(socket, project_id, kind, callbacks)
      _other -> callbacks.reload.(socket, socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "post", callbacks) do
    case BDS.Posts.create_post(%{project_id: project_id, title: "", content: "", tags: [], categories: []}) do
      {:ok, _post} ->
        callbacks.reload.(socket, socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> callbacks.append_output.(translated("sidebar.newPost"), inspect(reason), nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "media", callbacks) do
    case FilePicker.choose_file(translated("sidebar.importMedia")) do
      {:ok, source_path} ->
        case BDS.Media.import_media(%{project_id: project_id, source_path: source_path}) do
          {:ok, _media} ->
            callbacks.reload.(socket, socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> callbacks.append_output.(translated("sidebar.importMedia"), inspect(reason), nil, "error")
            |> callbacks.reload.(socket.assigns.workbench)
        end

      :cancel ->
        callbacks.reload.(socket, socket.assigns.workbench)

      {:error, %{message: message}} ->
        socket
        |> callbacks.append_output.(translated("sidebar.importMedia"), message, nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "script", callbacks) do
    case Scripts.create_script(%{
           project_id: project_id,
           title: translated("sidebar.scripts.newScript"),
           kind: :utility,
           content: "print(\"new script\")",
           entrypoint: "main",
           enabled: true
         }) do
      {:ok, script} ->
        callbacks.open_sidebar.(
          socket,
          %{"route" => "scripts", "id" => script.id, "title" => script.title, "subtitle" => "Automation helpers"},
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(translated("sidebar.scripts.newScript"), inspect(reason), nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "template", callbacks) do
    case Templates.create_template(%{
           project_id: project_id,
           title: translated("sidebar.templates.newTemplate"),
           kind: :post,
           content: "",
           enabled: true
         }) do
      {:ok, template} ->
        callbacks.open_sidebar.(
          socket,
          %{"route" => "templates", "id" => template.id, "title" => template.title, "subtitle" => "Site rendering"},
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(translated("sidebar.templates.newTemplate"), inspect(reason), nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "import", callbacks) do
    case ImportDefinitions.create_definition(%{project_id: project_id, name: translated("sidebar.import.newDefinition")}) do
      {:ok, definition} ->
        callbacks.open_sidebar.(
          socket,
          %{"route" => "import", "id" => definition.id, "title" => definition.name, "subtitle" => "Import definitions"},
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(translated("sidebar.import.newDefinition"), inspect(reason), nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  def create(socket, _project_id, _kind, callbacks),
    do: callbacks.reload.(socket, socket.assigns.workbench)

  def action(:posts), do: %{kind: "post", label: "sidebar.newPost"}
  def action(:media), do: %{kind: "media", label: "sidebar.importMedia"}
  def action(:scripts), do: %{kind: "script", label: "sidebar.scripts.newScript"}
  def action(:templates), do: %{kind: "template", label: "sidebar.templates.newTemplate"}
  def action(:import), do: %{kind: "import", label: "sidebar.import.newDefinition"}
  def action(_view), do: nil

  defp translated(text), do: ShellData.translate(text, %{}, BDS.Desktop.UILocale.current())
end
