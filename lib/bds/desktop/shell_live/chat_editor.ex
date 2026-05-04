defmodule BDS.Desktop.ShellLive.ChatEditor do
  @moduledoc false

  use Phoenix.LiveComponent

  import Phoenix.HTML, only: [raw: 1]

  alias BDS.{AI, BoundedAtoms, MapUtils, Persistence}
  alias BDS.Desktop.ShellLive.ChatEditor.{MessageBuild, ModelSelection, ToolTracking}
  alias BDS.Desktop.ShellLive.TabHelpers
  use Gettext, backend: BDS.Gettext

  embed_templates("chat_editor_html/*")

  # ── LiveComponent lifecycle ────────────────────────────────────────────────

  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  @impl true
  def update(%{action: :finish_request, result: result}, socket) do
    {:ok, do_finish_request(socket, result)}
  end

  def update(%{action: :note_tool_call, tool_call: tool_call}, socket) do
    {:ok, do_note_tool_call(socket, tool_call)}
  end

  def update(%{action: :note_tool_result, name: name}, socket) do
    {:ok, do_note_tool_result(socket, name)}
  end

  def update(%{action: :note_streaming_content, content: content}, socket) do
    {:ok, do_note_streaming_content(socket, content)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> ensure_state()
      |> build_data()

    {:ok, socket}
  end

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  @impl true
  def render(%{chat_editor: nil} = assigns), do: ~H"<div></div>"

  def render(assigns) do
    chat_editor(assigns)
  end

  # ── Event handlers ─────────────────────────────────────────────────────────

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  @impl true
  def handle_event("change_chat_editor_input", %{"message" => message}, socket) do
    {:noreply, assign(socket, :input, to_string(message || "")) |> build_data()}
  end

  def handle_event("toggle_chat_model_selector", _params, socket) do
    {:noreply,
     assign(socket, :model_selector_open?, not socket.assigns.model_selector_open?)
     |> build_data()}
  end

  def handle_event("select_chat_model", %{"model" => model_id}, socket) do
    conversation_id = socket.assigns.conversation_id

    case AI.set_conversation_model(conversation_id, model_id) do
      {:ok, _conversation} ->
        {:noreply, assign(socket, :model_selector_open?, false) |> build_data()}

      {:error, reason} ->
        notify_parent({:chat_editor_output, dgettext("ui", "Chat"), inspect(reason), "error"})
        {:noreply, assign(socket, :model_selector_open?, false) |> build_data()}
    end
  end

  def handle_event("send_chat_editor_message", _params, socket) do
    {:noreply, do_send_message(socket)}
  end

  def handle_event("abort_chat_editor_message", _params, socket) do
    {:noreply, do_abort_message(socket)}
  end

  def handle_event(
        "change_chat_surface_form",
        %{"surface" => %{"id" => surface_id, "fields" => fields}},
        socket
      ) do
    next_data = Map.put(socket.assigns.surface_data, surface_id, fields)
    {:noreply, assign(socket, :surface_data, next_data) |> build_data()}
  end

  def handle_event(
        "select_chat_surface_tab",
        %{"surface-id" => surface_id, "index" => index},
        socket
      ) do
    socket =
      socket
      |> assign(
        :surface_tabs,
        Map.put(socket.assigns.surface_tabs, surface_id, parse_integer(index))
      )
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("dismiss_chat_surface", %{"surface-id" => surface_id}, socket) do
    socket =
      socket
      |> assign(:dismissed_surfaces, MapSet.put(socket.assigns.dismissed_surfaces, surface_id))
      |> build_data()

    {:noreply, socket}
  end

  def handle_event("chat_surface_action", params, socket) do
    {:noreply, do_handle_surface_action(socket, params)}
  end

  def handle_event("open_chat_settings", _params, socket) do
    notify_parent(
      {:open_sidebar_item,
       %{
         "route" => "settings",
         "id" => "settings-ai",
         "title" => "Settings",
         "subtitle" => "AI"
       }, :pin}
    )

    {:noreply, socket}
  end

  # ── State initialisation ──────────────────────────────────────────────────

  defp ensure_state(socket) do
    conversation_id = socket.assigns.current_tab.id

    defaults = %{
      conversation_id: conversation_id,
      input: "",
      model_selector_open?: false,
      request: nil,
      surface_data: %{},
      surface_tabs: %{},
      dismissed_surfaces: MapSet.new(),
      action_error: nil
    }

    Enum.reduce(defaults, socket, fn {key, default}, acc ->
      if is_nil(Map.get(acc.assigns, key)) do
        assign(acc, key, default)
      else
        acc
      end
    end)
  end

  # ── Data builder ──────────────────────────────────────────────────────────

  defp build_data(socket) do
    conversation_id = socket.assigns.conversation_id
    request = socket.assigns.request

    fake_assigns = %{
      current_tab: socket.assigns.current_tab,
      chat_editor_requests: if(request, do: %{conversation_id => request}, else: %{}),
      chat_model_selectors_open: %{conversation_id => socket.assigns.model_selector_open?},
      chat_editor_inputs: %{conversation_id => socket.assigns.input},
      chat_editor_surface_data: socket.assigns.surface_data,
      chat_editor_surface_tabs: socket.assigns.surface_tabs,
      chat_editor_dismissed_surfaces: socket.assigns.dismissed_surfaces,
      chat_editor_action_errors: %{conversation_id => socket.assigns.action_error},
      offline_mode: socket.assigns.offline_mode
    }

    chat_editor = MessageBuild.build(fake_assigns)
    assign(socket, :chat_editor, chat_editor)
  end

  # ── Messaging ──────────────────────────────────────────────────────────────

  defp do_send_message(socket) do
    conversation_id = socket.assigns.conversation_id
    message = String.trim(socket.assigns.input || "")

    cond do
      message == "" ->
        build_data(socket)

      not is_nil(socket.assigns.request) ->
        build_data(socket)

      socket.assigns.offline_mode ->
        notify_parent(
          {:chat_editor_output, dgettext("ui", "Chat"),
           dgettext("ui", "Automatic AI actions stay gated by airplane mode."), "info"}
        )

        build_data(socket)

      ModelSelection.needs_api_key?(false) ->
        build_data(socket)

      true ->
        parent = self()
        started_at = Persistence.now_ms()

        task =
          Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
            AI.send_chat_message(conversation_id, message,
              project_id: active_project_id(socket),
              event_target: parent
            )
          end)

        :ok = allow_repo_sandbox(task.pid)

        notify_parent({:chat_editor_task_started, conversation_id, task.ref})

        socket
        |> assign(:input, "")
        |> assign(:request, %{
          ref: task.ref,
          pid: task.pid,
          started_at: started_at,
          message: message,
          content: "",
          tool_events: []
        })
        |> assign(:action_error, nil)
        |> build_data()
    end
  end

  defp do_abort_message(socket) do
    conversation_id = socket.assigns.conversation_id

    case socket.assigns.request do
      nil ->
        build_data(socket)

      %{ref: ref} = _request ->
        :ok = AI.cancel_chat(conversation_id)

        notify_parent({:chat_editor_task_cancelled, conversation_id, ref})

        # Allow the terminated task's DB connection to be cleaned up before rebuilding.
        Process.sleep(20)

        socket
        |> assign(:request, nil)
        |> build_data()
    end
  end

  defp do_finish_request(socket, result) do
    case result do
      {:ok, reply} ->
        socket
        |> update_tab_meta_from_reply(reply)
        |> assign(:request, nil)
        |> build_data()

      {:error, :cancelled} ->
        assign(socket, :request, nil) |> build_data()

      {:error, %{kind: :endpoint_not_configured}} ->
        assign(socket, :request, nil) |> build_data()

      {:error, reason} ->
        notify_parent(
          {:chat_editor_output, dgettext("ui", "Chat"), format_error(reason), "error"}
        )

        assign(socket, :request, nil) |> build_data()
    end
  end

  defp do_note_tool_call(socket, tool_call) when is_map(tool_call) do
    update_request(socket, fn request ->
      update_in(
        request.tool_events,
        &(&1 ++
            [
              %{
                type: :call,
                id: ToolTracking.tool_call_id(tool_call),
                name: ToolTracking.tool_call_name(tool_call),
                arguments: ToolTracking.tool_call_arguments(tool_call)
              }
            ])
      )
    end)
  end

  defp do_note_tool_result(socket, name) when is_binary(name) do
    update_request(socket, fn request ->
      update_in(request.tool_events, &(&1 ++ [%{type: :result, name: name}]))
    end)
  end

  defp do_note_streaming_content(socket, content) when is_binary(content) do
    update_request(socket, fn request -> %{request | content: content} end)
  end

  defp update_request(socket, updater) do
    case socket.assigns.request do
      nil ->
        socket

      request ->
        socket
        |> assign(:request, updater.(request))
        |> build_data()
    end
  end

  defp update_tab_meta_from_reply(socket, reply) do
    title =
      reply
      |> MapUtils.attr(:conversation, %{})
      |> MapUtils.attr(:title)

    if is_binary(title) and String.trim(title) != "" do
      notify_parent({:chat_editor_tab_meta, socket.assigns.conversation_id, title, ""})
    end

    socket
  end

  # ── Surface actions ────────────────────────────────────────────────────────

  defp do_handle_surface_action(socket, params) do
    surface_id = Map.get(params, "surface-id", "")

    payload =
      params
      |> Map.get("payload")
      |> decode_payload()
      |> maybe_put_form_data(socket, surface_id)

    case normalize_action(Map.get(params, "action", "")) do
      :open_post ->
        case Map.get(payload, "postId") || Map.get(payload, "post_id") do
          post_id when is_binary(post_id) and post_id != "" ->
            notify_parent(
              {:open_sidebar_item,
               %{
                 "route" => "post",
                 "id" => post_id,
                 "title" => TabHelpers.post_title(post_id),
                 "subtitle" => TabHelpers.post_subtitle(post_id)
               }, :pin}
            )

            assign(socket, :action_error, nil) |> build_data()

          _other ->
            set_action_error(socket, "Invalid payload for openPost action")
        end

      :open_media ->
        case Map.get(payload, "mediaId") || Map.get(payload, "media_id") do
          media_id when is_binary(media_id) and media_id != "" ->
            notify_parent(
              {:open_sidebar_item,
               %{
                 "route" => "media",
                 "id" => media_id,
                 "title" => TabHelpers.media_title(media_id),
                 "subtitle" => TabHelpers.media_subtitle(media_id)
               }, :pin}
            )

            assign(socket, :action_error, nil) |> build_data()

          _other ->
            set_action_error(socket, "Invalid payload for openMedia action")
        end

      :open_settings ->
        notify_parent(
          {:open_sidebar_item,
           %{
             "route" => "settings",
             "id" => "settings-ai",
             "title" => "Settings",
             "subtitle" => "AI"
           }, :pin}
        )

        assign(socket, :action_error, nil) |> build_data()

      :open_chat ->
        chat_id =
          Map.get(payload, "conversationId") || Map.get(payload, "conversation_id") ||
            socket.assigns.conversation_id

        notify_parent(
          {:open_sidebar_item,
           %{
             "route" => "chat",
             "id" => chat_id,
             "title" => Map.get(payload, "title", "Chat"),
             "subtitle" => Map.get(payload, "subtitle", "")
           }, :pin}
        )

        assign(socket, :action_error, nil) |> build_data()

      :switch_view ->
        case BoundedAtoms.sidebar_view(Map.get(payload, "view")) do
          nil ->
            set_action_error(socket, "Invalid payload for switchView action")

          view ->
            notify_parent({:chat_editor_switch_view, view})
            assign(socket, :action_error, nil) |> build_data()
        end

      :toggle_sidebar ->
        notify_parent({:chat_editor_toggle_sidebar})
        assign(socket, :action_error, nil) |> build_data()

      :toggle_panel ->
        notify_parent({:chat_editor_toggle_panel})
        assign(socket, :action_error, nil) |> build_data()

      :toggle_assistant_sidebar ->
        notify_parent({:chat_editor_toggle_assistant_sidebar})
        assign(socket, :action_error, nil) |> build_data()

      :unknown ->
        set_action_error(socket, "Unsupported assistant action")
    end
  end

  defp set_action_error(socket, message) do
    assign(socket, :action_error, message) |> build_data()
  end

  defp decode_payload(nil), do: %{}
  defp decode_payload(""), do: %{}

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_payload(_payload), do: %{}

  defp maybe_put_form_data(payload, socket, surface_id)
       when is_binary(surface_id) and surface_id != "" do
    form_data = Map.get(socket.assigns.surface_data, surface_id, %{})
    if form_data == %{}, do: payload, else: Map.put(payload, "formData", form_data)
  end

  defp maybe_put_form_data(payload, _socket, _surface_id), do: payload

  defp normalize_action(action) do
    action
    |> to_string()
    |> String.replace("_", "")
    |> String.downcase()
    |> case do
      "openpost" -> :open_post
      "openmedia" -> :open_media
      "opensettings" -> :open_settings
      "openchat" -> :open_chat
      "switchview" -> :switch_view
      "setactiveview" -> :switch_view
      "togglesidebar" -> :toggle_sidebar
      "togglepanel" -> :toggle_panel
      "openpanel" -> :toggle_panel
      "toggleassistantsidebar" -> :toggle_assistant_sidebar
      _other -> :unknown
    end
  end

  # ── HEEx-callable helpers ─────────────────────────────────────────────────

  @spec message_role_label(atom()) :: String.t()
  def message_role_label(:user), do: dgettext("ui", "You")
  def message_role_label(_role), do: dgettext("ui", "Assistant")

  defdelegate tool_call_name(tool_call), to: ToolTracking
  defdelegate tool_call_arguments(tool_call), to: ToolTracking

  @spec tool_surface_type(map()) :: String.t()
  def tool_surface_type(surface), do: Map.get(surface, :type, "json")

  @spec markdown_html(binary()) :: Phoenix.HTML.Safe.t()
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

  @spec payload_json(map() | nil) :: String.t()
  def payload_json(nil), do: "{}"
  def payload_json(payload) when is_map(payload), do: Jason.encode!(payload)

  @spec chart_width(number(), term()) :: number()
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

  @spec truthy?(term()) :: boolean()
  def truthy?(value) when value in [true, "true", 1, "1", "on"], do: true
  def truthy?(_value), do: false

  # ── HEEx components ───────────────────────────────────────────────────────

  attr(:markers, :list, required: true)

  @spec chat_tool_markers(map()) :: Phoenix.LiveView.Rendered.t()
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
              <div class="chat-tool-marker-detail-label"><%= dgettext("ui", "Arguments") %></div>
              <pre><%= Jason.encode!(marker.arguments || %{}, pretty: true) %></pre>
              <%= if marker.result not in [nil, ""] do %>
                <div class="chat-tool-marker-detail-label"><%= dgettext("ui", "Result") %></div>
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
  attr(:myself, :any, required: false)

  @spec chat_surface(map()) :: Phoenix.LiveView.Rendered.t()
  def chat_surface(assigns) do
    ~H"""
    <details id={@surface.id} class={["chat-inline-surface", "chat-inline-surface-#{@surface.type}"]} data-testid="chat-inline-surface" data-expanded={surface_expanded_attr(@surface)} open={Map.get(@surface, :expanded?, false)}>
      <summary class="chat-inline-surface-header">
        <span class="chat-inline-surface-icon"><%= surface_icon(@surface.type) %></span>
        <span class="chat-inline-surface-title"><%= surface_title(@surface) %></span>
        <button class="chat-inline-surface-dismiss" type="button" phx-click="dismiss_chat_surface" phx-target={@myself} phx-value-surface-id={@surface.id} aria-label={dgettext("ui", "Dismiss surface")} data-testid="chat-inline-surface-dismiss">×</button>
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
                    phx-target={@myself}
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
                  phx-target={@myself}
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
          <form class="chat-surface-form" phx-change="change_chat_surface_form" phx-target={@myself}>
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
                phx-target={@myself}
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

  defp surface_expanded_attr(surface) do
    if Map.get(surface, :expanded?, false), do: "true", else: "false"
  end

  defp surface_title(surface) do
    cond do
      present?(Map.get(surface, :title)) -> Map.get(surface, :title)
      present?(Map.get(surface, :label)) -> Map.get(surface, :label)
      true -> surface.type |> to_string() |> String.capitalize()
    end
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp notify_parent(message) do
    send(self(), message)
  end

  defp active_project_id(socket) do
    socket.assigns[:project_id]
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
    do: dgettext("ui", "Configure an API key in Settings to enable AI chat.")

  defp format_error(reason), do: inspect(reason)

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> 0
    end
  end
end
