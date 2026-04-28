defmodule BDS.Desktop.ShellLive.ChatEditor do
  @moduledoc false

  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]

  alias BDS.{AI, Repo}
  alias BDS.AI.ChatConversation
  alias BDS.Desktop.ShellData

  @render_tool_names MapSet.new([
                       "render_card",
                       "render_chart",
                       "render_form",
                       "render_list",
                       "render_metric",
                       "render_mindmap",
                       "render_table",
                       "render_tabs"
                     ])
  @tool_args_max_length 30

  embed_templates "chat_editor_html/*"

  def assign_socket(socket) do
    assign(socket, :chat_editor, build(socket.assigns))
  end

  def toggle_model_selector(socket, reload) do
    %{id: conversation_id} = socket.assigns.current_tab
    current = Map.get(socket.assigns.chat_model_selectors_open, conversation_id, false)

    socket
    |> assign(:chat_model_selectors_open, Map.put(socket.assigns.chat_model_selectors_open, conversation_id, not current))
    |> reload.(socket.assigns.workbench)
  end

  def set_model(socket, model_id, reload, append_output) do
    %{id: conversation_id} = socket.assigns.current_tab

    case AI.set_conversation_model(conversation_id, model_id) do
      {:ok, _conversation} ->
        socket
        |> assign(:chat_model_selectors_open, Map.put(socket.assigns.chat_model_selectors_open, conversation_id, false))
        |> reload.(socket.assigns.workbench)

      {:error, reason} ->
        socket
        |> append_output.(translated("Chat"), inspect(reason), nil, "error")
        |> reload.(socket.assigns.workbench)
    end
  end

  def update_input(socket, value, reload) do
    %{id: conversation_id} = socket.assigns.current_tab

    socket
    |> assign(:chat_editor_inputs, Map.put(socket.assigns.chat_editor_inputs, conversation_id, to_string(value || "")))
    |> reload.(socket.assigns.workbench)
  end

  def update_surface_form(socket, surface_id, fields, reload)
      when is_binary(surface_id) and is_map(fields) do
    next_data = Map.put(socket.assigns.chat_editor_surface_data, surface_id, fields)

    socket
    |> assign(:chat_editor_surface_data, next_data)
    |> reload.(socket.assigns.workbench)
  end

  def select_surface_tab(socket, surface_id, index, reload)
      when is_binary(surface_id) and is_integer(index) and index >= 0 do
    socket
    |> assign(:chat_editor_surface_tabs, Map.put(socket.assigns.chat_editor_surface_tabs, surface_id, index))
    |> reload.(socket.assigns.workbench)
  end

  def current_surface_data(socket, surface_id) when is_binary(surface_id) do
    Map.get(socket.assigns.chat_editor_surface_data, surface_id, %{})
  end

  def set_action_error(socket, conversation_id, message, reload)
      when is_binary(conversation_id) and is_binary(message) do
    socket
    |> assign(:chat_editor_action_errors, Map.put(socket.assigns.chat_editor_action_errors, conversation_id, message))
    |> reload.(socket.assigns.workbench)
  end

  def clear_action_error(socket, conversation_id, reload) when is_binary(conversation_id) do
    socket
    |> assign(:chat_editor_action_errors, Map.delete(socket.assigns.chat_editor_action_errors, conversation_id))
    |> reload.(socket.assigns.workbench)
  end

  def send_message(socket, reload, append_output) do
    %{id: conversation_id} = socket.assigns.current_tab
    message = socket.assigns.chat_editor_inputs |> Map.get(conversation_id, "") |> String.trim()

    cond do
      message == "" -> reload.(socket, socket.assigns.workbench)
      Map.has_key?(socket.assigns.chat_editor_requests, conversation_id) -> reload.(socket, socket.assigns.workbench)
      socket.assigns.offline_mode ->
        socket
        |> append_output.(translated("Chat"), translated("Automatic AI actions stay gated by airplane mode."), nil, "info")
        |> reload.(socket.assigns.workbench)

      needs_api_key?(false) ->
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
        |> assign(:chat_editor_inputs, Map.put(socket.assigns.chat_editor_inputs, conversation_id, ""))
        |> assign(:chat_editor_requests, Map.put(socket.assigns.chat_editor_requests, conversation_id, %{ref: task.ref, pid: task.pid, message: message, content: "", tool_events: []}))
        |> assign(:chat_editor_request_refs, Map.put(socket.assigns.chat_editor_request_refs, task.ref, conversation_id))
        |> assign(:chat_editor_action_errors, Map.delete(socket.assigns.chat_editor_action_errors, conversation_id))
        |> reload.(socket.assigns.workbench)
    end
  end

  def abort_message(socket, reload) do
    %{id: conversation_id} = socket.assigns.current_tab

    case Map.get(socket.assigns.chat_editor_requests, conversation_id) do
      nil -> reload.(socket, socket.assigns.workbench)

      %{ref: ref} = _request ->
        :ok = AI.cancel_chat(conversation_id)

        socket
        |> assign(:chat_editor_requests, Map.delete(socket.assigns.chat_editor_requests, conversation_id))
        |> assign(:chat_editor_request_refs, Map.delete(socket.assigns.chat_editor_request_refs, ref))
        |> reload.(socket.assigns.workbench)
    end
  end

  def note_tool_call(socket, conversation_id, tool_call, reload)
      when is_binary(conversation_id) and is_map(tool_call) do
    update_request(socket, conversation_id, fn request ->
      update_in(request.tool_events, &(&1 ++ [%{type: :call, name: tool_call_name(tool_call), arguments: tool_call_arguments(tool_call)}]))
    end, reload)
  end

  def note_tool_result(socket, conversation_id, name, reload)
      when is_binary(conversation_id) and is_binary(name) do
    update_request(socket, conversation_id, fn request ->
      update_in(request.tool_events, &(&1 ++ [%{type: :result, name: name}]))
    end, reload)
  end

  def note_streaming_content(socket, conversation_id, content, reload)
      when is_binary(conversation_id) and is_binary(content) do
    update_request(socket, conversation_id, fn request ->
      %{request | content: content}
    end, reload)
  end

  def finish_request(socket, ref, result, reload, append_output) when is_reference(ref) do
    case Map.pop(socket.assigns.chat_editor_request_refs, ref) do
      {nil, _remaining_refs} ->
        socket

      {conversation_id, remaining_refs} ->
        socket =
          socket
          |> assign(:chat_editor_request_refs, remaining_refs)
          |> assign(:chat_editor_requests, Map.delete(socket.assigns.chat_editor_requests, conversation_id))

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

  def build(%{current_tab: %{type: :chat, id: conversation_id}} = assigns) do
    case Repo.get(ChatConversation, conversation_id) do
      nil -> nil
      %ChatConversation{} = conversation ->
        messages = AI.list_chat_messages(conversation.id)
        request = Map.get(assigns.chat_editor_requests, conversation.id)
        available_models = AI.available_chat_models(conversation.model)

        %{
          id: conversation.id,
          title: conversation.title || translated("chat.newChat"),
          model: conversation.model,
          available_models: available_models,
          available_model_groups: group_available_models(available_models),
          model_selector_open?: Map.get(assigns.chat_model_selectors_open, conversation.id, false),
          input: Map.get(assigns.chat_editor_inputs, conversation.id, ""),
          messages: build_entries(messages, assigns),
          pending_user_message: pending_user_message(messages, request),
          is_streaming: not is_nil(request),
          streaming_content: streaming_content(request),
          streaming_tool_markers: tool_markers_from_events(request),
          offline?: Map.get(assigns, :offline_mode, true),
          needs_api_key?: needs_api_key?(Map.get(assigns, :offline_mode, true)),
          action_error: Map.get(assigns.chat_editor_action_errors, conversation.id),
          send_disabled?: String.trim(Map.get(assigns.chat_editor_inputs, conversation.id, "")) == "" or not is_nil(request)
        }
    end
  end

  def build(_assigns), do: nil

  def message_role_label(:user), do: translated("chat.role.you")
  def message_role_label(_role), do: translated("chat.role.assistant")

  def tool_call_name(tool_call) when is_map(tool_call) do
    Map.get(tool_call, "name") || Map.get(tool_call, :name) || "tool"
  end

  def tool_call_arguments(tool_call) when is_map(tool_call) do
    Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments) || Map.get(tool_call, "args") || Map.get(tool_call, :args) || %{}
  end

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

  def markdown_html(_content), do: ""

  defp group_available_models(models) when is_list(models) do
    models
    |> Enum.group_by(&Map.get(&1, :provider, "other"))
    |> Enum.map(fn {provider, entries} ->
      %{
        provider: provider,
        label: provider_group_label(entries, provider),
        models: Enum.sort_by(entries, &String.downcase(to_string(Map.get(&1, :name) || Map.get(&1, :id))))
      }
    end)
    |> Enum.sort_by(&String.downcase(to_string(&1.label)))
  end

  defp provider_group_label([%{provider_name: name} | _entries], _provider) when is_binary(name) and name != "",
    do: name

  defp provider_group_label(_entries, provider) when is_binary(provider), do: provider

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

  def chart_width(_max_value, _value), do: 0

  def truthy?(value) when value in [true, "true", 1, "1", "on"], do: true
  def truthy?(_value), do: false

  attr :markers, :list, required: true

  def chat_tool_markers(assigns) do
    ~H"""
    <%= if @markers != [] do %>
      <div class="chat-tool-markers">
        <%= for marker <- @markers do %>
          <div class={["chat-tool-marker", if(marker.complete?, do: "completed", else: "pending")]} data-testid="chat-tool-marker">
            <span class="chat-tool-marker-icon"><%= if marker.complete?, do: "✓", else: "●" %></span>
            <span class="chat-tool-marker-name"><%= marker.name %></span>
            <%= if marker.args_preview not in [nil, ""] do %>
              <span class="chat-tool-marker-args">(<%= marker.args_preview %>)</span>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :surface, :map, required: true

  def chat_surface(assigns) do
    ~H"""
    <article class={["chat-inline-surface", "chat-inline-surface-#{@surface.type}"]} data-testid="chat-inline-surface">
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
    </article>
    """
  end

  defp build_entries(messages, assigns) do
    {entries, current_entry, _turn_index} =
      Enum.reduce(messages, {[], nil, -1}, fn message, {entries, current_entry, turn_index} ->
        case message.role do
          :tool ->
            if current_entry && current_entry.role == :assistant do
              {entries, append_tool_surface(current_entry, message), turn_index}
            else
              {entries, current_entry, turn_index}
            end

          :system ->
            {entries, current_entry, turn_index}

          :user ->
            entries = finalize_entry(entries, current_entry)
            next_turn_index = turn_index + 1
            {entries, start_entry(message, next_turn_index, assigns), next_turn_index}

          _other ->
            entries = finalize_entry(entries, current_entry)
            {entries, start_entry(message, turn_index, assigns), turn_index}
        end
      end)

    entries
    |> finalize_entry(current_entry)
    |> Enum.reverse()
  end

  defp finalize_entry(entries, nil), do: entries
  defp finalize_entry(entries, entry), do: [entry | entries]

  defp start_entry(message, turn_index, assigns) do
    tool_markers = normalize_tool_calls(message.tool_calls)

    %{
      id: message.id,
      role: message.role,
      content: message.content || "",
      turn_index: turn_index,
      tool_markers: tool_markers,
      inline_surfaces: build_render_surfaces(tool_markers, message.id, assigns),
      tool_surfaces: []
    }
  end

  defp append_tool_surface(entry, message) do
    entry = mark_tool_call_completed(entry, message.tool_call_id)

    case normalize_tool_surface(message.content) do
      nil -> entry
      surface -> update_in(entry.tool_surfaces, &(&1 ++ [surface]))
    end
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      arguments = tool_call_arguments(tool_call)

      %{
        id: Map.get(tool_call, "id") || Map.get(tool_call, :id),
        name: tool_call_name(tool_call),
        arguments: arguments,
        args_preview: tool_arguments_preview(arguments),
        complete?: false
      }
    end)
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp build_render_surfaces(tool_calls, message_id, assigns) do
    tool_calls
    |> Enum.with_index()
    |> Enum.flat_map(fn {tool_call, index} ->
      case build_render_surface(tool_call, "#{message_id}-surface-#{index}", assigns) do
        nil -> []
        surface -> [surface]
      end
    end)
  end

  defp build_render_surface(%{name: name, arguments: arguments}, surface_id, assigns) do
    if MapSet.member?(@render_tool_names, name) do
      do_build_render_surface(name, arguments || %{}, surface_id, assigns)
    end
  end

  defp do_build_render_surface("render_card", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "card",
      title: map_value(arguments, "title"),
      subtitle: map_value(arguments, "subtitle"),
      body: map_value(arguments, "body", ""),
      actions: decode_surface_actions(map_value(arguments, "actions", []))
    }
  end

  defp do_build_render_surface("render_table", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "table",
      title: map_value(arguments, "title"),
      columns: stringify_list(map_value(arguments, "columns", [])),
      rows: Enum.map(List.wrap(map_value(arguments, "rows", [])), &stringify_list/1)
    }
  end

  defp do_build_render_surface("render_chart", arguments, surface_id, _assigns) do
    series =
      map_value(arguments, "series", [])
      |> List.wrap()
      |> Enum.map(fn entry ->
        %{
          label: map_value(entry, "label", translated("chat.role.assistant")),
          value: numeric_value(map_value(entry, "value", 0)),
          segments: List.wrap(map_value(entry, "segments", []))
        }
      end)

    %{
      id: surface_id,
      type: "chart",
      title: map_value(arguments, "title"),
      chart_type: map_value(arguments, "chart_type", "bar"),
      series: series,
      max_value: Enum.max([0 | Enum.map(series, & &1.value)])
    }
  end

  defp do_build_render_surface("render_metric", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "metric",
      label: map_value(arguments, "label", "Metric"),
      value: map_value(arguments, "value", "")
    }
  end

  defp do_build_render_surface("render_list", arguments, surface_id, _assigns) do
    %{
      id: surface_id,
      type: "list",
      title: map_value(arguments, "title"),
      items: stringify_list(map_value(arguments, "items", []))
    }
  end

  defp do_build_render_surface("render_mindmap", arguments, surface_id, _assigns) do
    nodes =
      arguments
      |> map_value("nodes", [])
      |> List.wrap()
      |> Enum.map(fn node ->
        %{
          id: map_value(node, "id"),
          label: map_value(node, "label", "Node"),
          children: stringify_list(map_value(node, "children", []))
        }
      end)

    %{
      id: surface_id,
      type: "mindmap",
      title: map_value(arguments, "title"),
      nodes: nodes
    }
  end

  defp do_build_render_surface("render_form", arguments, surface_id, assigns) do
    stored_fields = Map.get(assigns.chat_editor_surface_data, surface_id, %{})

    fields =
      arguments
      |> map_value("fields", [])
      |> List.wrap()
      |> Enum.map(fn field ->
        key = map_value(field, "key", "field")

        %{
          key: key,
          label: map_value(field, "label", key),
          input_type: map_value(field, "inputType") || map_value(field, "input_type", "text"),
          placeholder: map_value(field, "placeholder"),
          value: Map.get(stored_fields, key, map_value(field, "defaultValue") || map_value(field, "default_value")),
          options: decode_surface_options(map_value(field, "options", [])),
          required?: truthy?(map_value(field, "required", false))
        }
      end)

    %{
      id: surface_id,
      type: "form",
      title: map_value(arguments, "title"),
      fields: fields,
      submit_label: map_value(arguments, "submitLabel") || map_value(arguments, "submit_label", translated("chat.stop")),
      submit_action: map_value(arguments, "submitAction") || map_value(arguments, "submit_action", "submitForm")
    }
  end

  defp do_build_render_surface("render_tabs", arguments, surface_id, assigns) do
    tabs =
      arguments
      |> map_value("tabs", [])
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {tab, tab_index} ->
        %{
          label: map_value(tab, "label", "Tab #{tab_index + 1}"),
          content:
            tab
            |> map_value("content", [])
            |> List.wrap()
            |> Enum.with_index()
            |> Enum.map(fn {content, content_index} ->
              build_tab_surface(content, "#{surface_id}-tab-#{tab_index}-#{content_index}", assigns)
            end)
        }
      end)

    %{
      id: surface_id,
      type: "tabs",
      title: map_value(arguments, "title"),
      tabs: tabs,
      selected_index: Map.get(assigns.chat_editor_surface_tabs, surface_id, 0)
    }
  end

  defp do_build_render_surface(_name, arguments, surface_id, _assigns) do
    %{id: surface_id, type: "json", raw: arguments}
  end

  defp build_tab_surface(%{} = content, surface_id, assigns) do
    type = map_value(content, "type", "text")

    case type do
      render_type when render_type in ["card", "chart", "form", "list", "metric", "mindmap", "table", "tabs"] ->
        do_build_render_surface("render_#{render_type}", Map.delete(content, "type"), surface_id, assigns)

      "text" ->
        %{id: surface_id, type: "text", body: map_value(content, "body") || map_value(content, "text", "")}

      _other ->
        %{id: surface_id, type: "json", raw: content}
    end
  end

  defp build_tab_surface(content, surface_id, _assigns) do
    %{id: surface_id, type: "text", body: to_string(content || "")}
  end

  defp mark_tool_call_completed(entry, tool_call_id) when is_binary(tool_call_id) do
    update_in(entry.tool_markers, fn markers ->
      Enum.map(markers, fn marker ->
        if marker.id == tool_call_id do
          %{marker | complete?: true}
        else
          marker
        end
      end)
    end)
  end

  defp mark_tool_call_completed(entry, _tool_call_id), do: entry

  defp decode_surface_actions(actions) when is_list(actions) do
    Enum.map(actions, fn action ->
      %{
        label: map_value(action, "label", translated("chat.openSettings")),
        action: map_value(action, "action", "openSettings"),
        payload: map_value(action, "payload", %{})
      }
    end)
  end

  defp decode_surface_actions(_actions), do: []

  defp decode_surface_options(options) when is_list(options) do
    Enum.map(options, fn option ->
      %{
        label: map_value(option, "label", ""),
        value: map_value(option, "value", "")
      }
    end)
  end

  defp decode_surface_options(_options), do: []

  defp tool_arguments_preview(arguments) when is_map(arguments) do
    arguments
    |> Enum.map(fn {key, value} -> "#{key}: #{preview_value(value)}" end)
    |> Enum.join(", ")
  end

  defp tool_arguments_preview(_arguments), do: ""

  defp preview_value(value) when is_binary(value) do
    quoted = if String.length(value) > @tool_args_max_length, do: String.slice(value, 0, @tool_args_max_length) <> "...", else: value
    inspect(quoted)
  end

  defp preview_value(value), do: inspect(value)

  defp normalize_tool_surface(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"type" => type} = decoded} ->
        %{
          type: type,
          title: decoded["title"],
          columns: List.wrap(decoded["columns"]),
          rows: Enum.map(List.wrap(decoded["rows"]), &List.wrap/1),
          fields: List.wrap(decoded["fields"]),
          data: decoded
        }

      _other ->
        nil
    end
  end

  defp normalize_tool_surface(_content), do: nil

  defp pending_user_message(_messages, nil), do: nil

  defp pending_user_message(messages, %{message: message}) when is_binary(message) do
    case messages |> Enum.reverse() |> Enum.find(&(&1.role not in [:system, :tool])) do
      %{role: :user, content: ^message} -> nil
      _other -> message
    end
  end

  defp pending_user_message(_messages, _request), do: nil

  defp streaming_content(nil), do: ""
  defp streaming_content(%{content: content}) when is_binary(content), do: content
  defp streaming_content(_request), do: ""

  defp tool_markers_from_events(nil), do: []

  defp tool_markers_from_events(%{tool_events: tool_events}) do
    Enum.reduce(tool_events || [], [], fn event, markers ->
      case event.type do
        :call -> markers ++ [%{id: nil, name: event.name, arguments: event.arguments, args_preview: tool_arguments_preview(event.arguments || %{}), complete?: false}]

        :result ->
          Enum.reverse(markers)
          |> mark_last_matching_complete(event.name)
          |> Enum.reverse()
      end
    end)
  end

  defp mark_last_matching_complete(markers, name) do
    {updated, found?} =
      Enum.map_reduce(markers, false, fn marker, found? ->
        cond do
          found? -> {marker, true}
          marker.name == name and not marker.complete? -> {%{marker | complete?: true}, true}
          true -> {marker, false}
        end
      end)

    if found?, do: updated, else: updated
  end

  defp update_request(socket, conversation_id, updater, reload) do
    case Map.get(socket.assigns.chat_editor_requests, conversation_id) do
      nil -> socket

      request ->
        socket
        |> assign(:chat_editor_requests, Map.put(socket.assigns.chat_editor_requests, conversation_id, updater.(request)))
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

  defp needs_api_key?(true), do: false

  defp needs_api_key?(false) do
    case AI.get_endpoint(:online) do
      {:ok, %{url: url, model: model, api_key: api_key}} -> blank?(url) or blank?(model) or blank?(api_key)
      _other -> true
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp rewrite_external_images(html) do
    html =
      Regex.replace(~r/<img\b(?=[^>]*\bsrc="(https?:\/\/[^\"]+)")(?=[^>]*\balt="([^\"]*)")[^>]*\/?>/i, html, fn _match, src, alt ->
        external_image_link(src, alt)
      end)

    Regex.replace(~r/<img\b(?=[^>]*\bsrc="(https?:\/\/[^\"]+)")[^>]*\/?>/i, html, fn _match, src ->
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

  defp stringify_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp stringify_list(value), do: List.wrap(value) |> Enum.map(&to_string/1)

  defp numeric_value(value) when is_integer(value), do: value
  defp numeric_value(value) when is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> 0
    end
  end

  defp numeric_value(_value), do: 0

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp format_error(%{kind: :endpoint_not_configured}), do: translated("chat.apiKeyRequiredDescription")
  defp format_error(reason), do: inspect(reason)

  def translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, Process.get(:bds_ui_locale))
end
