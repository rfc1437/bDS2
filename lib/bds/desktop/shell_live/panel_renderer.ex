defmodule BDS.Desktop.ShellLive.PanelRenderer do
  @moduledoc false

  use Phoenix.Component

  alias BDS.Desktop.ShellData
  alias BDS.Git
  alias BDS.Media.Media
  alias BDS.PostLinks
  alias BDS.Posts.Post
  alias BDS.Repo

  @doc "Render the active panel tab body."
  def render_panel_body(assigns) do
    case assigns.workbench.panel.active_tab do
      :tasks -> render_task_entries(assigns)
      :output -> render_output_entries(assigns)
      :post_links -> render_post_links(assigns)
      :git_log -> render_git_log(assigns)
      other -> render_generic_panel(assigns, other)
    end
  end

  @doc "Render the editor toolbar for the current tab."
  def render_editor_toolbar(assigns) do
    buttons = editor_toolbar_buttons(assigns.current_tab)
    assigns = assign(assigns, :editor_toolbar_buttons, buttons)

    ~H"""
    <%= if Enum.any?(@editor_toolbar_buttons) do %>
      <div class="editor-toolbar">
        <%= for button <- @editor_toolbar_buttons do %>
          <button
            class={["editor-toolbar-button", if(button.destructive, do: "is-destructive")]}
            data-testid="editor-toolbar-overlay-button"
            type="button"
            phx-click="open_overlay"
            phx-value-kind={button.kind}
          >
            <%= translated(button.label) %>
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_task_entries(assigns) do
    ~H"""
    <%= if Enum.empty?(Map.get(@task_status, :tasks, [])) do %>
      <div class="panel-entry panel-empty-state">
        <strong><%= translated("Tasks") %></strong>
        <span><%= translated("No background tasks running") %></span>
      </div>
    <% else %>
      <div class="task-list">
        <%= for task <- Map.get(@task_status, :tasks, []) do %>
          <div class="panel-entry task-entry">
            <div class="task-entry-header">
              <strong><%= task.name %></strong>
              <span class={"task-status task-status-#{task.status}"}><%= Map.get(task, :status_label, task.status |> to_string() |> String.capitalize()) %></span>
            </div>
            <span><%= task.message || task.group_name || "" %></span>
            <%= if is_number(task.progress) do %>
              <div class="task-progress-row">
                <progress max="1" value={task.progress}></progress>
                <span><%= Map.get(task, :progress_label, progress_percent(task.progress)) %></span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_output_entries(assigns) do
    ~H"""
    <%= if Enum.empty?(@output_entries) do %>
      <div class="panel-entry panel-empty-state output-list">
        <strong><%= translated("Output") %></strong>
        <span><%= translated("No shell output yet") %></span>
      </div>
    <% else %>
      <div class="output-list">
        <%= for entry <- @output_entries do %>
          <div class={[
            "panel-entry",
            "output-entry",
            if(Map.get(entry, :level) == "error", do: "output-entry-error")
          ]}>
            <strong><%= entry.title %></strong>
            <span><%= entry.message %></span>
            <%= if present?(entry.details) do %>
              <span><%= entry.details %></span>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_post_links(assigns) do
    links = post_link_entries(assigns)

    assigns =
      assigns
      |> assign(:backlinks, Map.get(links, :backlinks, []))
      |> assign(:outlinks, Map.get(links, :outlinks, []))

    ~H"""
    <%= if Enum.empty?(@backlinks) and Enum.empty?(@outlinks) do %>
      <div class="panel-entry panel-empty-state">
        <strong><%= translated("Post Links") %></strong>
        <span><%= translated("No post links yet") %></span>
      </div>
    <% else %>
      <div class="git-log-list">
        <%= if Enum.any?(@backlinks) do %>
          <div class="panel-entry"><strong><%= translated("Backlinks") %></strong></div>
          <%= for entry <- @backlinks do %>
            <button
              class="panel-entry task-entry"
              type="button"
              phx-click="pin_sidebar_item"
              phx-value-route="post"
              phx-value-id={entry.id}
              phx-value-title={entry.title}
              phx-value-subtitle="linked post"
            >
              <strong><%= entry.title %></strong>
              <span><%= entry.text %></span>
            </button>
          <% end %>
        <% end %>

        <%= if Enum.any?(@outlinks) do %>
          <div class="panel-entry"><strong><%= translated("Links To") %></strong></div>
          <%= for entry <- @outlinks do %>
            <button
              class="panel-entry task-entry"
              type="button"
              phx-click="pin_sidebar_item"
              phx-value-route="post"
              phx-value-id={entry.id}
              phx-value-title={entry.title}
              phx-value-subtitle="linked post"
            >
              <strong><%= entry.title %></strong>
              <span><%= entry.text %></span>
            </button>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_git_log(assigns) do
    entries = git_log_entries(assigns)
    assigns = assign(assigns, :git_entries, entries)

    ~H"""
    <%= if Enum.empty?(@git_entries) do %>
      <div class="git-log-list">
        <div class="panel-entry panel-empty-state">
          <strong><%= translated("Git Log") %></strong>
          <span><%= translated("No git history yet") %></span>
        </div>
      </div>
    <% else %>
      <div class="git-log-list">
        <%= for entry <- @git_entries do %>
          <div class="panel-entry task-entry">
            <strong><%= short_commit_hash(entry.hash) %> <%= entry.subject || translated("No commit subject") %></strong>
            <span><%= entry.hash %></span>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp render_generic_panel(assigns, tab) do
    assigns = assign(assigns, :panel_label, ShellData.route_label(tab))

    ~H"""
    <div class="panel-entry">
      <strong><%= @panel_label %></strong>
      <span><%= translated("The shared lower panel is available for tasks, output, git details, and editor-specific diagnostics.") %></span>
    </div>
    """
  end

  defp post_link_entries(assigns) do
    case assigns.current_tab do
      %{type: :post, id: post_id} ->
        %{
          backlinks: related_posts(PostLinks.list_incoming_links(post_id), :source_post_id),
          outlinks: related_posts(PostLinks.list_outgoing_links(post_id), :target_post_id)
        }

      _other ->
        %{backlinks: [], outlinks: []}
    end
  end

  defp related_posts(links, key) do
    Enum.map(links, fn link ->
      case Repo.get(Post, Map.fetch!(link, key)) do
        %Post{} = post -> %{id: post.id, title: post.title || post.slug || post.id, text: link.link_text || post.slug || post.id}
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp git_log_entries(assigns) do
    case git_history_target(assigns.current_tab) do
      nil ->
        []

      {project_id, file_path} ->
        case Git.file_history(project_id, file_path) do
          {:ok, %{commits: commits}} -> commits
          _other -> []
        end
    end
  end

  defp git_history_target(%{type: :post, id: post_id}) do
    case Repo.get(Post, post_id) do
      %Post{project_id: project_id, file_path: file_path} when file_path not in [nil, ""] -> {project_id, file_path}
      _other -> nil
    end
  end

  defp git_history_target(%{type: :media, id: media_id}) do
    case Repo.get(Media, media_id) do
      %Media{project_id: project_id, file_path: file_path} when file_path not in [nil, ""] -> {project_id, file_path}
      _other -> nil
    end
  end

  defp git_history_target(_tab), do: nil

  def editor_toolbar_buttons(nil), do: []

  def editor_toolbar_buttons(%{type: :post}) do
    [
      %{kind: "ai_suggestions", label: "AI Suggestions", destructive: false},
      %{kind: "insert_link", label: "Insert Link", destructive: false},
      %{kind: "insert_media", label: "Insert Media", destructive: false},
      %{kind: "language_picker", label: "Translate", destructive: false},
      %{kind: "gallery", label: "Gallery", destructive: false}
    ]
  end

  def editor_toolbar_buttons(%{type: :media}) do
    [
      %{kind: "ai_suggestions", label: "AI Suggestions", destructive: false},
      %{kind: "language_picker", label: "Translate", destructive: false},
      %{kind: "confirm_delete", label: "Delete Media", destructive: true}
    ]
  end

  def editor_toolbar_buttons(%{type: :tags}) do
    [
      %{kind: "confirm_merge", label: "Merge Tags", destructive: false},
      %{kind: "confirm_delete", label: "Delete Tag", destructive: true}
    ]
  end

  def editor_toolbar_buttons(_tab), do: []

  defp short_commit_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 7)
  defp short_commit_hash(_hash), do: "-------"

  defp progress_percent(progress) when is_number(progress) do
    rounded = progress |> Kernel.*(100) |> Float.round(0) |> trunc()
    "#{rounded}%"
  end

  defp progress_percent(_), do: ""

  defp present?(value), do: value not in [nil, ""]

  defp translated(text, bindings \\ %{}), do: ShellData.translate(text, bindings, BDS.Desktop.UILocale.current())
end
