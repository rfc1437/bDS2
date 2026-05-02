defmodule BDS.Desktop.ShellLive.CodeEntityEditor do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.ShellData
  alias BDS.{MCP, Scripts, Scripting, Templates}
  alias BDS.Scripts.Script
  alias BDS.Templates.Template

  embed_templates("code_entity_editor_html/*")

  @spec assign_socket(term()) :: term()
  def assign_socket(socket) do
    socket
    |> assign(:script_editor, build_script(socket.assigns))
    |> assign(:template_editor, build_template(socket.assigns))
  end

  @spec update_script(term(), term(), term()) :: term()
  def update_script(socket, params, reload) do
    %{id: script_id} = socket.assigns.current_tab

    socket
    |> assign(
      :script_editor_drafts,
      Map.put(socket.assigns.script_editor_drafts, script_id, normalize_script_params(params))
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec save_script(term(), term(), term()) :: term()
  def save_script(socket, reload, append_output) do
    persist_script(socket, :save, reload, append_output)
  end

  @spec publish_script(term(), term(), term()) :: term()
  def publish_script(socket, reload, append_output) do
    persist_script(socket, :publish, reload, append_output)
  end

  @spec check_script(term(), term(), term()) :: term()
  def check_script(socket, reload, append_output) do
    %{id: script_id} = socket.assigns.current_tab

    case Scripts.get_script(script_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      %Script{} = script ->
        case Scripting.validate(current_script_draft(socket.assigns, script)["content"] || "") do
          :ok ->
            append_output.(socket, translated("Scripts"), translated("Syntax is valid"))
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            append_output.(socket, translated("Scripts"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  @spec run_script(term(), term(), term()) :: term()
  def run_script(socket, reload, append_output) do
    %{id: script_id} = socket.assigns.current_tab

    case Scripts.get_script(script_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      %Script{} = script ->
        draft = current_script_draft(socket.assigns, script)

        case Scripting.execute_project_script(
               script.project_id,
               draft["content"] || "",
               draft["entrypoint"] || "main",
               []
             ) do
          {:ok, result} ->
            socket
            |> append_output.(translated("Scripts"), inspect(result))
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Scripts"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  @spec delete_script(term(), term(), term()) :: term()
  def delete_script(socket, reload, append_output) do
    %{id: script_id} = socket.assigns.current_tab

    case Scripts.delete_script(script_id) do
      {:ok, _deleted} ->
        reload.(socket, BDS.UI.Workbench.close_tab(socket.assigns.workbench, :scripts, script_id))

      {:error, reason} ->
        append_output.(socket, translated("Scripts"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec update_template(term(), term(), term()) :: term()
  def update_template(socket, params, reload) do
    %{id: template_id} = socket.assigns.current_tab

    socket
    |> assign(
      :template_editor_drafts,
      Map.put(
        socket.assigns.template_editor_drafts,
        template_id,
        normalize_template_params(params)
      )
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec save_template(term(), term(), term()) :: term()
  def save_template(socket, reload, append_output) do
    persist_template(socket, :save, reload, append_output)
  end

  @spec publish_template(term(), term(), term()) :: term()
  def publish_template(socket, reload, append_output) do
    persist_template(socket, :publish, reload, append_output)
  end

  @spec validate_template(term(), term(), term()) :: term()
  def validate_template(socket, reload, append_output) do
    %{id: template_id} = socket.assigns.current_tab

    case Templates.get_template(template_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      %Template{} = template ->
        case MCP.validate_template(
               current_template_draft(socket.assigns, template)["content"] || ""
             ) do
          {:ok, %{valid: true}} ->
            append_output.(
              socket,
              translated("Templates"),
              translated("Template syntax is valid")
            )
            |> reload.(socket.assigns.workbench)

          {:ok, %{valid: false, errors: errors}} ->
            append_output.(socket, translated("Templates"), Enum.join(errors, "; "), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  @spec delete_template(term(), term(), term()) :: term()
  def delete_template(socket, reload, append_output) do
    %{id: template_id} = socket.assigns.current_tab

    case Templates.delete_template(template_id, force: true) do
      {:ok, _deleted} ->
        reload.(
          socket,
          BDS.UI.Workbench.close_tab(socket.assigns.workbench, :templates, template_id)
        )

      {:error, reason} ->
        append_output.(socket, translated("Templates"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec build_script(term()) :: term()
  def build_script(%{current_tab: %{type: :scripts, id: script_id}} = assigns) do
    case Scripts.get_script(script_id) do
      nil ->
        nil

      %Script{} = script ->
        draft = current_script_draft(assigns, script)

        %{
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
    end
  end

  def build_script(_assigns), do: nil

  @spec build_template(term()) :: term()
  def build_template(%{current_tab: %{type: :templates, id: template_id}} = assigns) do
    case Templates.get_template(template_id) do
      nil ->
        nil

      %Template{} = template ->
        draft = current_template_draft(assigns, template)

        %{
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
    end
  end

  def build_template(_assigns), do: nil

  @spec status_label(term()) :: term()
  def status_label(status), do: ShellData.dashboard_status_label(status)

  @spec translated(term(), term()) :: term()
  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())

  @spec format_timestamp(term()) :: term()
  def format_timestamp(nil), do: ""
  def format_timestamp(timestamp), do: BDS.Persistence.timestamp_to_iso8601(timestamp)

  defp normalize_script_params(params) do
    %{
      "title" => Map.get(params, "title", ""),
      "slug" => Map.get(params, "slug", ""),
      "kind" => Map.get(params, "kind", "utility"),
      "entrypoint" => Map.get(params, "entrypoint", "main"),
      "enabled" => Map.get(params, "enabled") in [true, "true", "on", "1", 1],
      "content" => Map.get(params, "content", "")
    }
  end

  defp normalize_template_params(params) do
    %{
      "title" => Map.get(params, "title", ""),
      "slug" => Map.get(params, "slug", ""),
      "kind" => Map.get(params, "kind", "post"),
      "enabled" => Map.get(params, "enabled") in [true, "true", "on", "1", 1],
      "content" => Map.get(params, "content", "")
    }
  end

  defp current_script_draft(assigns, %Script{} = script) do
    Map.get(assigns.script_editor_drafts, script.id, %{
      "title" => script.title || "",
      "slug" => script.slug || "",
      "kind" => to_string(script.kind || :utility),
      "entrypoint" => script.entrypoint || "main",
      "enabled" => script.enabled != false,
      "content" => script.content || ""
    })
  end

  defp current_template_draft(assigns, %Template{} = template) do
    Map.get(assigns.template_editor_drafts, template.id, %{
      "title" => template.title || "",
      "slug" => template.slug || "",
      "kind" => to_string(template.kind || :post),
      "enabled" => template.enabled != false,
      "content" => template.content || ""
    })
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

  defp template_attrs(draft) do
    %{
      title: draft["title"],
      slug: draft["slug"],
      kind: normalize_template_kind(draft["kind"]),
      enabled: draft["enabled"],
      content: draft["content"]
    }
  end

  defp persist_script(socket, action, reload, append_output) do
    %{id: script_id} = socket.assigns.current_tab

    case Scripts.get_script(script_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      %Script{} = script ->
        draft = current_script_draft(socket.assigns, script)

        case Scripting.validate(draft["content"] || "") do
          :ok ->
            case Scripts.update_script(script.id, script_attrs(draft))
                 |> maybe_publish_script(script.id, action) do
              {:ok, _updated} ->
                socket
                |> assign(
                  :script_editor_drafts,
                  Map.delete(socket.assigns.script_editor_drafts, script.id)
                )
                |> reload.(socket.assigns.workbench)

              {:error, reason} ->
                socket
                |> append_output.(translated("Scripts"), inspect(reason), nil, "error")
                |> reload.(socket.assigns.workbench)
            end

          {:error, reason} ->
            socket
            |> append_output.(translated("Scripts"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  defp persist_template(socket, action, reload, append_output) do
    %{id: template_id} = socket.assigns.current_tab

    case Templates.get_template(template_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      %Template{} = template ->
        draft = current_template_draft(socket.assigns, template)

        with {:ok, %{valid: true}} <- MCP.validate_template(draft["content"] || ""),
             {:ok, _updated} <-
               Templates.update_template(template.id, template_attrs(draft))
               |> maybe_publish_template(template.id, action) do
          socket
          |> assign(
            :template_editor_drafts,
            Map.delete(socket.assigns.template_editor_drafts, template.id)
          )
          |> reload.(socket.assigns.workbench)
        else
          {:ok, %{valid: false, errors: errors}} ->
            append_output.(socket, translated("Templates"), Enum.join(errors, "; "), nil, "error")
            |> reload.(socket.assigns.workbench)

          {:error, reason} ->
            append_output.(socket, translated("Templates"), inspect(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  defp maybe_publish_script({:ok, _script}, script_id, :publish), do: Scripts.publish_script(script_id)
  defp maybe_publish_script(result, _script_id, _action), do: result

  defp maybe_publish_template({:ok, _template}, template_id, :publish),
    do: Templates.publish_template(template_id)

  defp maybe_publish_template(result, _template_id, _action), do: result

  defp normalize_template_kind("post"), do: :post
  defp normalize_template_kind("list"), do: :list
  defp normalize_template_kind("not-found"), do: :"not-found"
  defp normalize_template_kind("partial"), do: :partial
  defp normalize_template_kind(_kind), do: :post

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
end
