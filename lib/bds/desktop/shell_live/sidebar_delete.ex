defmodule BDS.Desktop.ShellLive.SidebarDelete do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias BDS.{AI, ImportDefinitions, Media, Posts, Scripts, Templates}
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.UILocale

  @spec request_delete(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t() | nil, map()) ::
          Phoenix.LiveView.Socket.t()
  def request_delete(socket, route, id, fallback_title, callbacks) do
    case delete_target(socket, route, id, fallback_title) do
      {:ok, entity_name} ->
        assign(socket, :shell_overlay, %{
          kind: :confirm_delete,
          title: delete_title(route),
          entity_name: entity_name,
          entity_type: route,
          reference_count: 0,
          reference_list: [],
          delete_action: %{source: :sidebar, route: route, id: id}
        })

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> callbacks.append_output.(delete_title(route), inspect(reason), nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  @spec execute_delete(Phoenix.LiveView.Socket.t(), String.t(), String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def execute_delete(socket, route, id, callbacks) do
    case route do
      "post" ->
        delete_entity(socket, :post, id, &Posts.delete_post/1, callbacks)

      "media" ->
        delete_entity(socket, :media, id, &Media.delete_media/1, callbacks)

      "scripts" ->
        delete_entity(socket, :scripts, id, &Scripts.delete_script/1, callbacks)

      "templates" ->
        delete_entity(socket, :templates, id, fn tid ->
          Templates.delete_template(tid, force: true)
        end, callbacks)

      "chat" ->
        delete_entity(socket, :chat, id, &AI.delete_chat_conversation/1, callbacks)

      "import" ->
        delete_entity(socket, :import, id, &ImportDefinitions.delete_definition/1, callbacks)

      _other ->
        socket
        |> assign(:shell_overlay, nil)
        |> callbacks.append_output.(translated("Delete"), inspect(:unsupported_route), nil, "error")
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp delete_entity(socket, type, id, delete_fn, callbacks) do
    case delete_fn.(id) do
      {:ok, :deleted} ->
        workbench = BDS.UI.Workbench.close_tab(socket.assigns.workbench, type, id)

        socket
        |> assign(:shell_overlay, nil)
        |> assign(:tab_meta, Map.delete(socket.assigns.tab_meta, {type, id}))
        |> callbacks.reload.(workbench)

      {:error, reason} ->
        socket
        |> assign(:shell_overlay, nil)
        |> callbacks.append_output.(
          delete_title(Atom.to_string(type)),
          inspect(reason),
          nil,
          "error"
        )
        |> callbacks.reload.(socket.assigns.workbench)
    end
  end

  @spec delete_target(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  defp delete_target(socket, route, id, fallback_title) do
    active_project_id = socket.assigns.projects.active_project_id

    case route do
      "post" ->
        case Posts.get_post(id) do
          %{project_id: ^active_project_id} = post ->
            {:ok, present_title(fallback_title) || present_title(post.title) || present_title(post.slug) || id}

          _other ->
            {:error, :not_found}
        end

      "media" ->
        case Media.get_media(id) do
          %{project_id: ^active_project_id} = media ->
            {:ok,
             present_title(fallback_title) || present_title(media.title) ||
               present_title(media.original_name) || id}

          _other ->
            {:error, :not_found}
        end

      "scripts" ->
        case Scripts.get_script(id) do
          %{project_id: ^active_project_id} = script ->
            {:ok, present_title(fallback_title) || present_title(script.title) || id}

          _other ->
            {:error, :not_found}
        end

      "templates" ->
        case Templates.get_template(id) do
          %{project_id: ^active_project_id} = template ->
            {:ok, present_title(fallback_title) || present_title(template.title) || id}

          _other ->
            {:error, :not_found}
        end

      "chat" ->
        case AI.get_chat_conversation(id) do
          %{title: title} -> {:ok, present_title(fallback_title) || present_title(title) || id}
          _other -> {:error, :not_found}
        end

      "import" ->
        case ImportDefinitions.get_definition(id) do
          %{project_id: ^active_project_id} = definition ->
            {:ok, present_title(fallback_title) || present_title(definition.name) || id}

          _other ->
            {:error, :not_found}
        end

      _other ->
        {:error, :unsupported_route}
    end
  end

  @spec delete_title(String.t()) :: String.t()
  defp delete_title("chat"), do: translated("sidebar.chat.deleteConversation")
  defp delete_title("post"), do: translated("Delete") <> " " <> translated("Post")
  defp delete_title("media"), do: translated("Delete") <> " " <> translated("Media")
  defp delete_title("scripts"), do: translated("Delete") <> " " <> translated("Script")
  defp delete_title("templates"), do: translated("Delete") <> " " <> translated("Template")
  defp delete_title("import"), do: translated("Delete") <> " " <> translated("Import")
  defp delete_title(_route), do: translated("Delete")

  @spec present_title(String.t() | nil) :: String.t() | nil
  defp present_title(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_title(_value), do: nil

  @spec translated(String.t(), map()) :: String.t()
  defp translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, UILocale.current())
end
