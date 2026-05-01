defmodule BDS.Desktop.ShellLive.ChatEditor do
  @moduledoc false

  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]

  alias BDS.AI
  alias BDS.Desktop.ShellData
  alias BDS.Desktop.ShellLive.ChatEditor.{MessageBuild, ModelSelection, ToolTracking}

  embed_templates("chat_editor_html/*")

  # ── Public API: state assignment ───────────────────────────────────────────

  @spec assign_socket(term()) :: term()
  def assign_socket(socket) do
    assign(socket, :chat_editor, MessageBuild.build(socket.assigns))
  end

  defdelegate build(assigns), to: MessageBuild

  # ── Public API: model selection ────────────────────────────────────────────

  defdelegate toggle_model_selector(socket, reload), to: ModelSelection
  defdelegate set_model(socket, model_id, reload, append_output), to: ModelSelection

  # ── Public API: input + surface state ──────────────────────────────────────

  @spec update_input(term(), term(), term()) :: term()
  def update_input(socket, value, reload) do
    %{id: conversation_id} = socket.assigns.current_tab

    socket
    |> assign(
      :chat_editor_inputs,
      Map.put(socket.assigns.chat_editor_inputs, conversation_id, to_string(value || ""))
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec update_surface_form(term(), term(), term(), term()) :: term()
  def update_surface_form(socket, surface_id, fields, reload)
      when is_binary(surface_id) and is_map(fields) do
    next_data = Map.put(socket.assigns.chat_editor_surface_data, surface_id, fields)

    socket
    |> assign(:chat_editor_surface_data, next_data)
    |> reload.(socket.assigns.workbench)
  end

  @spec select_surface_tab(term(), term(), term(), term()) :: term()
  def select_surface_tab(socket, surface_id, index, reload)
      when is_binary(surface_id) and is_integer(index) and index >= 0 do
    socket
    |> assign(
      :chat_editor_surface_tabs,
      Map.put(socket.assigns.chat_editor_surface_tabs, surface_id, index)
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec dismiss_surface(term(), term(), term()) :: term()
  def dismiss_surface(socket, surface_id, reload) when is_binary(surface_id) do
    socket
    |> assign(
      :chat_editor_dismissed_surfaces,
      MapSet.put(socket.assigns.chat_editor_dismissed_surfaces, surface_id)
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec current_surface_data(term(), term()) :: term()
  def current_surface_data(socket, surface_id) when is_binary(surface_id) do
    Map.get(socket.assigns.chat_editor_surface_data, surface_id, %{})
  end

  @spec set_action_error(term(), term(), term(), term()) :: term()
  def set_action_error(socket, conversation_id, message, reload)
      when is_binary(conversation_id) and is_binary(message) do
    socket
    |> assign(
      :chat_editor_action_errors,
      Map.put(socket.assigns.chat_editor_action_errors, conversation_id, message)
    )
    |> reload.(socket.assigns.workbench)
  end

  @spec clear_action_error(term(), term(), term()) :: term()
  def clear_action_error(socket, conversation_id, reload) when is_binary(conversation_id) do
    socket
    |> assign(
      :chat_editor_action_errors,
      Map.delete(socket.assigns.chat_editor_action_errors, conversation_id)
    )
    |> reload.(socket.assigns.workbench)
  end

  # ── Public API: messaging ──────────────────────────────────────────────────

  @spec send_message(term(), term(), term()) :: term()
  def send_message(socket, reload, append_output) do
    %{id: conversation_id} = socket.assigns.current_tab
    message = socket.assigns.chat_editor_inputs |> Map.get(conversation_id, "") |> String.trim()

    cond do
      message == "" ->
        reload.(socket, socket.assigns.workbench)

      Map.has_key?(socket.assigns.chat_editor_requests, conversation_id) ->
        reload.(socket, socket.assigns.workbench)

      socket.assigns.offline_mode ->
        socket
        |> append_output.(
          translated("Chat"),
          translated("Automatic AI actions stay gated by airplane mode."),
          nil,
          "info"
        )
        |> reload.(socket.assigns.workbench)

      ModelSelection.needs_api_key?(false) ->
        reload.(socket, socket.assigns.workbench)

      true ->
        live_view_pid = self()

        task =
          Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
            AI.send_chat_message(conversation_id, message,
              project_id: socket.assigns.projects.active_project_id,
              event_target: live_view_pid
            )
          end)

        :ok = allow_repo_sandbox(task.pid)

        socket
        |> assign(
          :chat_editor_inputs,
          Map.put(socket.assigns.chat_editor_inputs, conversation_id, "")
        )
        |> assign(
          :chat_editor_requests,
          Map.put(socket.assigns.chat_editor_requests, conversation_id, %{
            ref: task.ref,
            pid: task.pid,
            message: message,
            content: "",
            tool_events: []
          })
        )
        |> assign(
          :chat_editor_request_refs,
          Map.put(socket.assigns.chat_editor_request_refs, task.ref, conversation_id)
        )
        |> assign(
          :chat_editor_action_errors,
          Map.delete(socket.assigns.chat_editor_action_errors, conversation_id)
        )
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec abort_message(term(), term()) :: term()
  def abort_message(socket, reload) do
    %{id: conversation_id} = socket.assigns.current_tab

    case Map.get(socket.assigns.chat_editor_requests, conversation_id) do
      nil ->
        reload.(socket, socket.assigns.workbench)

      %{ref: ref} = _request ->
        :ok = AI.cancel_chat(conversation_id)

        socket
        |> assign(
          :chat_editor_requests,
          Map.delete(socket.assigns.chat_editor_requests, conversation_id)
        )
        |> assign(
          :chat_editor_request_refs,
          Map.delete(socket.assigns.chat_editor_request_refs, ref)
        )
        |> reload.(socket.assigns.workbench)
    end
  end

  @spec note_tool_call(term(), term(), term(), term()) :: term()
  def note_tool_call(socket, conversation_id, tool_call, reload)
      when is_binary(conversation_id) and is_map(tool_call) do
    update_request(
      socket,
      conversation_id,
      fn request ->
        update_in(
          request.tool_events,
          &(&1 ++
              [
                %{
                  type: :call,
                  name: ToolTracking.tool_call_name(tool_call),
                  arguments: ToolTracking.tool_call_arguments(tool_call)
                }
              ])
        )
      end,
      reload
    )
  end

  @spec note_tool_result(term(), term(), term(), term()) :: term()
  def note_tool_result(socket, conversation_id, name, reload)
      when is_binary(conversation_id) and is_binary(name) do
    update_request(
      socket,
      conversation_id,
      fn request ->
        update_in(request.tool_events, &(&1 ++ [%{type: :result, name: name}]))
      end,
      reload
    )
  end

  @spec note_streaming_content(term(), term(), term(), term()) :: term()
  def note_streaming_content(socket, conversation_id, content, reload)
      when is_binary(conversation_id) and is_binary(content) do
    update_request(
      socket,
      conversation_id,
      fn request -> %{request | content: content} end,
      reload
    )
  end

  @spec finish_request(term(), term(), term(), term(), term()) :: term()
  def finish_request(socket, ref, result, reload, append_output) when is_reference(ref) do
    case Map.pop(socket.assigns.chat_editor_request_refs, ref) do
      {nil, _remaining_refs} ->
        socket

      {conversation_id, remaining_refs} ->
        socket =
          socket
          |> assign(:chat_editor_request_refs, remaining_refs)
          |> assign(
            :chat_editor_requests,
            Map.delete(socket.assigns.chat_editor_requests, conversation_id)
          )

        case result do
          {:ok, _reply} ->
            reload.(socket, socket.assigns.workbench)

          {:error, :cancelled} ->
            reload.(socket, socket.assigns.workbench)

          {:error, %{kind: :endpoint_not_configured}} ->
            reload.(socket, socket.assigns.workbench)

          {:error, reason} ->
            socket
            |> append_output.(translated("Chat"), format_error(reason), nil, "error")
            |> reload.(socket.assigns.workbench)
        end
    end
  end

  # ── HEEx-callable helpers ─────────────────────────────────────────────────

  @spec message_role_label(term()) :: term()
  def message_role_label(:user), do: translated("chat.role.you")
  def message_role_label(_role), do: translated("chat.role.assistant")

  defdelegate tool_call_name(tool_call), to: ToolTracking
  defdelegate tool_call_arguments(tool_call), to: ToolTracking

  @spec tool_surface_type(term()) :: term()
  def tool_surface_type(surface), do: Map.get(surface, :type, "json")

  def markdown_html(content) when is_binary(content) do
    html =
      case Earmark.as_html(content, escape: true) do
        {:ok, rendered, _messages} -> rendered
        {:error, rendered, _messages} -> rendered
      end
      |> rewrite_external_images()

    raw(html)
  end

  @spec markdown_html(term()) :: term()
  def markdown_html(_content), do: ""

  @spec payload_json(term()) :: term()
  def payload_json(nil), do: "{}"
  def payload_json(payload) when is_map(payload), do: Jason.encode!(payload)

  def chart_width(_max_value, value) when not is_number(value), do: 0

  def chart_width(max_value, value) when is_number(max_value) and max_value > 0 do
    value
    |> Kernel./(max_value)
    |> Kernel.*(100)
    |> min(100)
    |> max(0)
    |> Float.round(2)
  end

  @spec chart_width(term(), term()) :: term()
  def chart_width(_max_value, _value), do: 0

  def truthy?(value) when value in [true, "true", 1, "1", "on"], do: true
  @spec truthy?(term()) :: term()
  def truthy?(_value), do: false

  # ── HEEx components ───────────────────────────────────────────────────────

  attr(:markers, :list, required: true)

  @spec chat_tool_markers(term()) :: term()
  def chat_tool_markers(assigns) do
    ~H"""
    <%= if @markers != [] do %>
      <div class="chat-tool-markers">
        <%= for marker <- @markers do %>
          <details class={["chat-tool-marker", if(marker.complete?, do: "completed", else: "pending")]} data-testid="chat-tool-marker">
            <summary>
              <span class="chat-tool-marker-icon"><%= if marker.complete?, do: "✓", else: "●" %></span>
              <span class="chat-tool-marker-name"><%= marker.name %></span>
              <%= if marker.args_preview not in [nil, ""] do %>
                <span class="chat-tool-marker-args">(<%= marker.args_preview %>)</span>
              <% end %>
            </summary>
            <div class="chat-tool-marker-details" data-testid="chat-tool-marker-details">
              <div class="chat-tool-marker-detail-label"><%= translated("chat.toolArguments") %></div>
              <pre><%= Jason.encode!(marker.arguments || %{}, pretty: true) %></pre>
              <%= if marker.result not in [nil, ""] do %>
                <div class="chat-tool-marker-detail-label"><%= translated("chat.toolResult") %></div>
                <pre><%= marker.result %></pre>
              <% end %>
            </div>
          </details>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr(:surface, :map, required: true)

  @spec chat_surface(term()) :: term()
  def chat_surface(assigns) do
    ~H"""
    <details id={@surface.id} class={["chat-inline-surface", "chat-inline-surface-#{@surface.type}"]} data-testid="chat-inline-surface" open={Map.get(@surface, :expanded?, false)}>
      <summary class="chat-inline-surface-header">
        <span class="chat-inline-surface-icon"><%= surface_icon(@surface.type) %></span>
        <span class="chat-inline-surface-title"><%= surface_title(@surface) %></span>
        <button class="chat-inline-surface-dismiss" type="button" phx-click="dismiss_chat_surface" phx-value-surface-id={@surface.id} aria-label={translated("chat.dismissSurface")} data-testid="chat-inline-surface-dismiss">×</button>
      </summary>
      <div class="chat-inline-surface-body">
      <%= case @surface.type do %>
        <% "card" -> %>
          <div class="chat-surface-card">
            <%= if present?(@surface.title) do %>
              <h3><%= @surface.title %></h3>
            <% end %>
            <%= if present?(@surface.subtitle) do %>
              <p class="chat-surface-subtitle"><%= @surface.subtitle %></p>
            <% end %>
            <p class="chat-surface-body"><%= @surface.body %></p>
            <%= if @surface.actions != [] do %>
              <div class="chat-surface-actions">
                <%= for action <- @surface.actions do %>
                  <button
                    class="chat-surface-action-button"
                    type="button"
                    phx-click="chat_surface_action"
                    phx-value-surface-id={@surface.id}
                    phx-value-action={action.action}
                    phx-value-payload={payload_json(action.payload)}
                    data-testid="chat-surface-action"
                    data-action={action.action}
                  >
                    <%= action.label %>
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>

        <% "table" -> %>
          <%= if present?(@surface.title) do %>
            <h3><%= @surface.title %></h3>
          <% end %>
          <div class="chat-tool-surface-table-wrap">
            <table class="chat-tool-surface-table">
              <thead>
                <tr>
                  <%= for column <- @surface.columns do %>
                    <th><%= column %></th>
                  <% end %>
                </tr>
              </thead>
              <tbody>
                <%= for row <- @surface.rows do %>
                  <tr>
                    <%= for value <- row do %>
                      <td><%= value %></td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

        <% "chart" -> %>
          <%= if present?(@surface.title) do %>
            <h3><%= @surface.title %></h3>
          <% end %>
          <p class="chat-surface-chart-type"><%= @surface.chart_type %></p>
          <div class="chat-surface-chart-list">
            <%= for series <- @surface.series do %>
              <div class="chat-surface-chart-row">
                <div class="chat-surface-chart-meta">
                  <span><%= series.label %></span>
                  <span><%= series.value %></span>
                </div>
                <div class="chat-surface-chart-bar">
                  <span style={"width: #{chart_width(@surface.max_value, series.value)}%"}></span>
                </div>
              </div>
            <% end %>
          </div>

        <% "metric" -> %>
          <div class="chat-surface-metric">
            <span class="chat-surface-metric-label"><%= @surface.label %></span>
            <strong class="chat-surface-metric-value"><%= @surface.value %></strong>
          </div>

        <% "list" -> %>
          <%= if present?(@surface.title) do %>
            <h3><%= @surface.title %></h3>
          <% end %>
          <ul class="chat-surface-list">
            <%= for item <- @surface.items do %>
              <li><%= item %></li>
            <% end %>
          </ul>

        <% "mindmap" -> %>
          <%= if present?(@surface.title) do %>
            <h3><%= @surface.title %></h3>
          <% end %>
          <ul class="chat-surface-mindmap">
            <%= for node <- @surface.nodes do %>
              <li>
                <strong><%= node.label %></strong>
                <%= if node.children != [] do %>
                  <span class="chat-surface-mindmap-children"><%= Enum.join(node.children, ", ") %></span>
                <% end %>
              </li>
            <% end %>
          </ul>

        <% "tabs" -> %>
          <%= if present?(@surface.title) do %>
            <h3><%= @surface.title %></h3>
          <% end %>
          <div class="chat-surface-tabs">
            <div class="chat-surface-tab-list">
              <%= for {tab, index} <- Enum.with_index(@surface.tabs) do %>
                <button
                  class={["chat-surface-tab-button", if(index == @surface.selected_index, do: "active")]}
                  type="button"
                  phx-click="select_chat_surface_tab"
                  phx-value-surface-id={@surface.id}
                  phx-value-index={index}
                >
                  <%= tab.label %>
                </button>
              <% end %>
            </div>

            <%= case Enum.at(@surface.tabs, @surface.selected_index || 0) do %>
              <% nil -> %>
              <% tab -> %>
                <div class="chat-surface-tab-panel">
                  <%= for content <- tab.content do %>
                    <.chat_surface surface={content} />
                  <% end %>
                </div>
            <% end %>
          </div>

        <% "form" -> %>
          <%= if present?(@surface.title) do %>
            <h3><%= @surface.title %></h3>
          <% end %>
          <form class="chat-surface-form" phx-change="change_chat_surface_form">
            <input type="hidden" name="surface[id]" value={@surface.id} />

            <%= for field <- @surface.fields do %>
              <label class="chat-surface-form-field">
                <span><%= field.label %></span>

                <%= case field.input_type do %>
                  <% "textarea" -> %>
                    <textarea name={"surface[fields][#{field.key}]"} placeholder={field.placeholder}><%= field.value || "" %></textarea>

                  <% "select" -> %>
                    <select name={"surface[fields][#{field.key}]"}>
                      <%= for option <- field.options do %>
                        <option value={option.value} selected={to_string(field.value || "") == to_string(option.value)}><%= option.label %></option>
                      <% end %>
                    </select>

                  <% "checkbox" -> %>
                    <span class="chat-surface-form-checkbox">
                      <input type="hidden" name={"surface[fields][#{field.key}]"} value="false" />
                      <input type="checkbox" name={"surface[fields][#{field.key}]"} value="true" checked={truthy?(field.value)} />
                    </span>

                  <% _other -> %>
                    <input type={surface_input_type(field.input_type)} name={"surface[fields][#{field.key}]"} value={field.value || ""} placeholder={field.placeholder} />
                <% end %>
              </label>
            <% end %>
          </form>

          <%= if present?(@surface.submit_label) do %>
            <div class="chat-surface-actions">
              <button
                class="chat-surface-action-button"
                type="button"
                phx-click="chat_surface_action"
                phx-value-surface-id={@surface.id}
                phx-value-action={@surface.submit_action}
                phx-value-payload="{}"
                data-testid="chat-surface-action"
                data-action={@surface.submit_action}
              >
                <%= @surface.submit_label %>
              </button>
            </div>
          <% end %>

        <% "text" -> %>
          <div class="chat-surface-text"><%= @surface.body %></div>

        <% _other -> %>
          <pre class="chat-tool-surface-json"><%= Jason.encode!(@surface.raw || %{}, pretty: true) %></pre>
      <% end %>
      </div>
    </details>
    """
  end

  defp surface_icon("chart"), do: "▥"
  defp surface_icon("table"), do: "▦"
  defp surface_icon("form"), do: "▤"
  defp surface_icon("card"), do: "▣"
  defp surface_icon("metric"), do: "#"
  defp surface_icon("list"), do: "☰"
  defp surface_icon("tabs"), do: "▧"
  defp surface_icon(_type), do: "■"

  defp surface_title(surface) do
    cond do
      present?(Map.get(surface, :title)) -> Map.get(surface, :title)
      present?(Map.get(surface, :label)) -> Map.get(surface, :label)
      true -> surface.type |> to_string() |> String.capitalize()
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp update_request(socket, conversation_id, updater, reload) do
    case Map.get(socket.assigns.chat_editor_requests, conversation_id) do
      nil ->
        socket

      request ->
        socket
        |> assign(
          :chat_editor_requests,
          Map.put(socket.assigns.chat_editor_requests, conversation_id, updater.(request))
        )
        |> reload.(socket.assigns.workbench)
    end
  end

  defp allow_repo_sandbox(pid) when is_pid(pid) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), pid)
      rescue
        _error -> :ok
      end
    else
      :ok
    end

    :ok
  end

  defp rewrite_external_images(html) do
    html =
      Regex.replace(
        ~r/<img\b(?=[^>]*\bsrc="(https?:\/\/[^\"]+)")(?=[^>]*\balt="([^\"]*)")[^>]*\/?>/i,
        html,
        fn _match, src, alt -> external_image_link(src, alt) end
      )

    Regex.replace(~r/<img\b(?=[^>]*\bsrc="(https?:\/\/[^\"]+)")[^>]*\/?>/i, html, fn _match,
                                                                                     src ->
      external_image_link(src, src)
    end)
  end

  defp external_image_link(src, text) do
    escaped_src = src |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    escaped_text = (text || src) |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    ~s(<a href="#{escaped_src}" rel="noopener noreferrer" target="_blank">#{escaped_text}</a>)
  end

  defp surface_input_type("number"), do: "number"
  defp surface_input_type("date"), do: "date"
  defp surface_input_type(_type), do: "text"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp format_error(%{kind: :endpoint_not_configured}),
    do: translated("chat.apiKeyRequiredDescription")

  defp format_error(reason), do: inspect(reason)

  @spec translated(term(), term()) :: term()
  def translated(text, bindings \\ %{}),
    do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
