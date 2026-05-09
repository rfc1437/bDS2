defmodule BDS.Desktop.ShellLive.ScriptEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  alias BDS.{Scripts, Scripting}
  alias BDS.Desktop.ShellLive.Notify
  alias BDS.Scripts.Script
  use Gettext, backend: BDS.Gettext

  embed_templates("script_editor_html/*")

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :save} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> do_save()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> build_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(%{script_editor: nil} = assigns), do: ~H""

  def render(assigns) do
    script_editor(assigns)
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_script_editor", %{"script_editor" => params}, socket) do
    socket =
      socket
      |> assign(:draft, normalize_params(params))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("save_script_editor", _params, socket) do
    {:noreply, do_save(socket)}
  end

  def handle_event("publish_script_editor", _params, socket) do
    {:noreply, do_publish(socket)}
  end

  def handle_event("run_script_editor", _params, socket) do
    {:noreply, do_run(socket)}
  end

  def handle_event("check_script_editor", _params, socket) do
    {:noreply, do_check(socket)}
  end

  def handle_event("delete_script_editor", _params, socket) do
    {:noreply, do_delete(socket)}
  end

  defp build_data(socket) do
    script_id = socket.assigns.current_tab.id

    case Scripts.get_script(script_id) do
      nil ->
        assign(socket, :script_editor, nil)

      %Script{} = script ->
        draft = current_draft(socket.assigns, script)

        data = %{
          id: script.id,
          title: draft["title"],
          slug: draft["slug"],
          kind: draft["kind"],
          entrypoint: draft["entrypoint"],
          enabled: draft["enabled"],
          content: draft["content"],
          entrypoints: discover_entrypoints(draft["content"]),
          status: script.status || :draft,
          can_publish?: script.status == :draft,
          created_at: script.created_at,
          updated_at: script.updated_at
        }

        assign(socket, :script_editor, data)
    end
  end

  defp do_save(socket) do
    script_id = socket.assigns.current_tab.id

    case Scripts.get_script(script_id) do
      nil ->
        socket

      %Script{} = script ->
        draft = current_draft(socket.assigns, script)

        case Scripting.validate(draft["content"] || "") do
          :ok ->
            case Scripts.update_script(script.id, script_attrs(draft)) do
              {:ok, _updated} ->
                socket
                |> assign(:draft, nil)
                |> build_data()
                |> notify_output(dgettext("ui", "Scripts"), dgettext("ui", "Script saved"))
                |> notify_reload()

              {:error, reason} ->
                socket
                |> notify_output(dgettext("ui", "Scripts"), inspect(reason), "error")
                |> notify_reload()
            end

          {:error, reason} ->
            socket
            |> notify_output(dgettext("ui", "Scripts"), inspect(reason), "error")
            |> notify_reload()
        end
    end
  end

  defp do_publish(socket) do
    script_id = socket.assigns.current_tab.id

    case Scripts.get_script(script_id) do
      nil ->
        socket

      %Script{} = script ->
        draft = current_draft(socket.assigns, script)

        case Scripting.validate(draft["content"] || "") do
          :ok ->
            case Scripts.update_script(script.id, script_attrs(draft)) do
              {:ok, _updated} ->
                case Scripts.publish_script(script.id) do
                  {:ok, _published} ->
                    socket
                    |> assign(:draft, nil)
                    |> build_data()
                    |> notify_output(
                      dgettext("ui", "Scripts"),
                      dgettext("ui", "Script published")
                    )
                    |> notify_reload()

                  {:error, reason} ->
                    socket
                    |> notify_output(dgettext("ui", "Scripts"), inspect(reason), "error")
                    |> notify_reload()
                end

              {:error, reason} ->
                socket
                |> notify_output(dgettext("ui", "Scripts"), inspect(reason), "error")
                |> notify_reload()
            end

          {:error, reason} ->
            socket
            |> notify_output(dgettext("ui", "Scripts"), inspect(reason), "error")
            |> notify_reload()
        end
    end
  end

  defp do_check(socket) do
    script_id = socket.assigns.current_tab.id

    case Scripts.get_script(script_id) do
      nil ->
        socket

      %Script{} = script ->
        case Scripting.validate(current_draft(socket.assigns, script)["content"] || "") do
          :ok ->
            notify_output(socket, dgettext("ui", "Scripts"), dgettext("ui", "Syntax is valid"))

          {:error, reason} ->
            notify_output(socket, dgettext("ui", "Scripts"), inspect(reason), "error")
        end
    end
  end

  defp do_run(socket) do
    script_id = socket.assigns.current_tab.id

    case Scripts.get_script(script_id) do
      nil ->
        socket

      %Script{} = script ->
        draft = current_draft(socket.assigns, script)

        case Scripting.execute_project_script(
               script.project_id,
               draft["content"] || "",
               draft["entrypoint"] || "main",
               []
             ) do
          {:ok, result} ->
            notify_output(socket, dgettext("ui", "Scripts"), inspect(result))

          {:error, reason} ->
            notify_output(socket, dgettext("ui", "Scripts"), inspect(reason), "error")
        end
    end
  end

  defp do_delete(socket) do
    script_id = socket.assigns.current_tab.id

    case Scripts.delete_script(script_id) do
      {:ok, _deleted} ->
        Notify.close_tab(:scripts, script_id)
        socket

      {:error, reason} ->
        socket
        |> notify_output(dgettext("ui", "Scripts"), inspect(reason), "error")
        |> notify_reload()
    end
  end

  defp current_draft(%{draft: draft}, _script) when is_map(draft), do: draft

  defp current_draft(_assigns, %Script{} = script) do
    %{
      "title" => script.title || "",
      "slug" => script.slug || "",
      "kind" => to_string(script.kind || :utility),
      "entrypoint" => script.entrypoint || "main",
      "enabled" => script.enabled != false,
      "content" => script.content || ""
    }
  end

  defp normalize_params(params) do
    %{
      "title" => Map.get(params, "title", ""),
      "slug" => Map.get(params, "slug", ""),
      "kind" => Map.get(params, "kind", "utility"),
      "entrypoint" => Map.get(params, "entrypoint", "main"),
      "enabled" => Map.get(params, "enabled") in [true, "true", "on", "1", 1],
      "content" => Map.get(params, "content", "")
    }
  end

  defp script_attrs(draft) do
    %{
      title: draft["title"],
      slug: draft["slug"],
      kind: BDS.BoundedAtoms.script_kind(draft["kind"], :utility),
      entrypoint: draft["entrypoint"],
      enabled: draft["enabled"],
      content: draft["content"]
    }
  end

  defp discover_entrypoints(content) do
    [
      "main"
      | Regex.scan(~r/function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/, content || "",
          capture: :all_but_first
        )
        |> List.flatten()
        |> Enum.reject(&(&1 == "main"))
    ]
  end

  defp notify_output(socket, title, message, level \\ "info") do
    Notify.output(title, message, level)
    socket
  end

  defp notify_reload(socket) do
    Notify.reload()
    socket
  end
end
