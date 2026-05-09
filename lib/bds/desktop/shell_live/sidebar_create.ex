defmodule BDS.Desktop.ShellLive.SidebarCreate do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.Desktop.{FilePicker}
  alias BDS.AI
  alias BDS.ImportDefinitions
  alias BDS.Scripts
  alias BDS.Templates
  use Gettext, backend: BDS.Gettext

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
      _other -> callbacks.refresh_content.(socket, socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "post", callbacks) do
    case BDS.Posts.create_post(%{
           project_id: project_id,
           title: "",
           content: "",
           tags: [],
           categories: []
         }) do
      {:ok, _post} ->
        callbacks.refresh_content.(socket, socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> callbacks.append_output.(dgettext("ui", "New Post"), inspect(reason), nil, "error")
        |> callbacks.refresh_content.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "media", _callbacks) do
    prompt = dgettext("ui", "Import media")

    task =
      Task.async(fn ->
        case FilePicker.choose_file(prompt) do
          {:ok, source_path} ->
            BDS.Media.import_media(%{project_id: project_id, source_path: source_path})

          :cancel ->
            :cancel

          {:error, reason} ->
            {:error, reason}
        end
      end)

    assign(socket, :file_picker_task, task.ref)
  end

  def create(socket, project_id, "script", callbacks) do
    case Scripts.create_script(%{
           project_id: project_id,
           title: dgettext("ui", "New Script"),
           kind: :utility,
           content: "print(\"new script\")",
           entrypoint: "main",
           enabled: true
         }) do
      {:ok, script} ->
        callbacks.open_sidebar.(
          socket,
          %{
            "route" => "scripts",
            "id" => script.id,
            "title" => script.title,
            "subtitle" => "Automation helpers"
          },
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(
          dgettext("ui", "New Script"),
          inspect(reason),
          nil,
          "error"
        )
        |> callbacks.refresh_content.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "template", callbacks) do
    case Templates.create_template(%{
           project_id: project_id,
           title: dgettext("ui", "New Template"),
           kind: :post,
           content: "",
           enabled: true
         }) do
      {:ok, template} ->
        callbacks.open_sidebar.(
          socket,
          %{
            "route" => "templates",
            "id" => template.id,
            "title" => template.title,
            "subtitle" => "Site rendering"
          },
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(
          dgettext("ui", "New Template"),
          inspect(reason),
          nil,
          "error"
        )
        |> callbacks.refresh_content.(socket.assigns.workbench)
    end
  end

  def create(socket, _project_id, "chat", callbacks) do
    case AI.start_chat(%{}) do
      {:ok, conversation} ->
        callbacks.open_sidebar.(
          socket,
          %{
            "route" => "chat",
            "id" => conversation.id,
            "title" => conversation.title,
            "subtitle" => "AI conversations"
          },
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(dgettext("ui", "New Chat"), inspect(reason), nil, "error")
        |> callbacks.refresh_content.(socket.assigns.workbench)
    end
  end

  def create(socket, project_id, "import", callbacks) do
    case ImportDefinitions.create_definition(%{
           project_id: project_id,
           name: dgettext("ui", "New Import Definition")
         }) do
      {:ok, definition} ->
        callbacks.open_sidebar.(
          socket,
          %{
            "route" => "import",
            "id" => definition.id,
            "title" => definition.name,
            "subtitle" => "Import definitions"
          },
          :pin
        )

      {:error, reason} ->
        socket
        |> callbacks.append_output.(
          dgettext("ui", "New Import Definition"),
          inspect(reason),
          nil,
          "error"
        )
        |> callbacks.refresh_content.(socket.assigns.workbench)
    end
  end

  def create(socket, _project_id, _kind, callbacks),
    do: callbacks.refresh_content.(socket, socket.assigns.workbench)

  def action(:posts), do: %{kind: "post", label: "sidebar.newPost"}
  def action(:media), do: %{kind: "media", label: "sidebar.importMedia"}
  def action(:scripts), do: %{kind: "script", label: "sidebar.scripts.newScript"}
  def action(:templates), do: %{kind: "template", label: "sidebar.templates.newTemplate"}
  def action(:chat), do: %{kind: "chat", label: "chat.newChat"}
  def action(:import), do: %{kind: "import", label: "sidebar.import.newDefinition"}
  def action(_view), do: nil
end
