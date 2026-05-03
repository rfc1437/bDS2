defmodule BDS.Desktop.ShellLive.TemplateEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  alias BDS.{MCP, Templates}
  alias BDS.Templates.Template
  use Gettext, backend: BDS.Gettext

  embed_templates("template_editor_html/*")

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
  def render(%{template_editor: nil} = assigns), do: ~H""

  def render(assigns) do
    template_editor(assigns)
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_template_editor", %{"template_editor" => params}, socket) do
    socket =
      socket
      |> assign(:draft, normalize_params(params))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("save_template_editor", _params, socket) do
    {:noreply, do_save(socket)}
  end

  def handle_event("publish_template_editor", _params, socket) do
    {:noreply, do_publish(socket)}
  end

  def handle_event("validate_template_editor", _params, socket) do
    {:noreply, do_validate(socket)}
  end

  def handle_event("delete_template_editor", _params, socket) do
    {:noreply, do_delete(socket)}
  end

  defp build_data(socket) do
    template_id = socket.assigns.current_tab.id

    case Templates.get_template(template_id) do
      nil ->
        assign(socket, :template_editor, nil)

      %Template{} = template ->
        draft = current_draft(socket.assigns, template)

        data = %{
          id: template.id,
          title: draft["title"],
          slug: draft["slug"],
          kind: draft["kind"],
          enabled: draft["enabled"],
          content: draft["content"],
          status: template.status || :draft,
          can_publish?: template.status == :draft,
          created_at: template.created_at,
          updated_at: template.updated_at
        }

        assign(socket, :template_editor, data)
    end
  end

  defp do_save(socket) do
    template_id = socket.assigns.current_tab.id

    case Templates.get_template(template_id) do
      nil ->
        socket

      %Template{} = template ->
        draft = current_draft(socket.assigns, template)

        with {:ok, %{valid: true}} <- MCP.validate_template(draft["content"] || ""),
             {:ok, _updated} <- Templates.update_template(template.id, template_attrs(draft)) do
          socket
          |> assign(:draft, nil)
          |> build_data()
          |> notify_output(dgettext("ui", "Templates"), dgettext("ui", "Template saved"))
          |> notify_reload()
        else
          {:ok, %{valid: false, errors: errors}} ->
            socket
            |> notify_output(dgettext("ui", "Templates"), Enum.join(errors, "; "), "error")
            |> notify_reload()

          {:error, reason} ->
            socket
            |> notify_output(dgettext("ui", "Templates"), inspect(reason), "error")
            |> notify_reload()
        end
    end
  end

  defp do_publish(socket) do
    template_id = socket.assigns.current_tab.id

    case Templates.get_template(template_id) do
      nil ->
        socket

      %Template{} = template ->
        draft = current_draft(socket.assigns, template)

        with {:ok, %{valid: true}} <- MCP.validate_template(draft["content"] || ""),
             {:ok, _updated} <- Templates.update_template(template.id, template_attrs(draft)),
             {:ok, _published} <- Templates.publish_template(template.id) do
          socket
          |> assign(:draft, nil)
          |> build_data()
          |> notify_output(dgettext("ui", "Templates"), dgettext("ui", "Template published"))
          |> notify_reload()
        else
          {:ok, %{valid: false, errors: errors}} ->
            socket
            |> notify_output(dgettext("ui", "Templates"), Enum.join(errors, "; "), "error")
            |> notify_reload()

          {:error, reason} ->
            socket
            |> notify_output(dgettext("ui", "Templates"), inspect(reason), "error")
            |> notify_reload()
        end
    end
  end

  defp do_validate(socket) do
    template_id = socket.assigns.current_tab.id

    case Templates.get_template(template_id) do
      nil ->
        socket

      %Template{} = template ->
        case MCP.validate_template(current_draft(socket.assigns, template)["content"] || "") do
          {:ok, %{valid: true}} ->
            notify_output(socket, dgettext("ui", "Templates"), dgettext("ui", "Template syntax is valid"))

          {:ok, %{valid: false, errors: errors}} ->
            notify_output(socket, dgettext("ui", "Templates"), Enum.join(errors, "; "), "error")
        end
    end
  end

  defp do_delete(socket) do
    template_id = socket.assigns.current_tab.id

    case Templates.delete_template(template_id, force: true) do
      {:ok, _deleted} ->
        send(self(), {:close_tab, :templates, template_id})
        socket

      {:error, reason} ->
        socket
        |> notify_output(dgettext("ui", "Templates"), inspect(reason), "error")
        |> notify_reload()
    end
  end

  defp current_draft(%{draft: draft}, _template) when is_map(draft), do: draft

  defp current_draft(_assigns, %Template{} = template) do
    %{
      "title" => template.title || "",
      "slug" => template.slug || "",
      "kind" => to_string(template.kind || :post),
      "enabled" => template.enabled != false,
      "content" => template.content || ""
    }
  end

  defp normalize_params(params) do
    %{
      "title" => Map.get(params, "title", ""),
      "slug" => Map.get(params, "slug", ""),
      "kind" => Map.get(params, "kind", "post"),
      "enabled" => Map.get(params, "enabled") in [true, "true", "on", "1", 1],
      "content" => Map.get(params, "content", "")
    }
  end

  defp template_attrs(draft) do
    %{
      title: draft["title"],
      slug: draft["slug"],
      kind: normalize_template_kind(draft["kind"]),
      enabled: draft["enabled"],
      content: draft["content"]
    }
  end

  defp normalize_template_kind("post"), do: :post
  defp normalize_template_kind("list"), do: :list
  defp normalize_template_kind("not-found"), do: :"not-found"
  defp normalize_template_kind("partial"), do: :partial
  defp normalize_template_kind(_kind), do: :post

  defp notify_output(socket, title, message, level \\ "info") do
    send(self(), {:template_editor_output, title, message, level})
    socket
  end

  defp notify_reload(socket) do
    send(self(), :reload_shell)
    socket
  end
end