defmodule BDS.TUI do
  @moduledoc """
  Terminal UI shell (issue #26, phase 4).

  An `ExRatatui.App` over the shared UI core: `BDS.UI.Sidebar` for view
  data, `BDS.UI.PostEditor.*` for the draft/save/publish workflow, and
  `BDS.Events` for multi-client synchronization. Served per SSH connection
  by `ExRatatui.SSH.Daemon` in server mode and runnable locally.

  ## Keys

  Sidebar focus: `↑/↓`/`j/k` navigate, `enter` open, `n` new post,
  `1..5` switch view (posts/media/templates/scripts/tags), `r` refresh,
  `p` projects overlay (switch the active project or open an existing
  blog folder by path — opening one queues a full database rebuild),
  `:` vi-style command prompt over the Blog-menu shell commands, `?`
  command help (commands whose report/apply UI is GUI-only are marked).
  Editor focus: text keys edit, `ctrl+s` save, `ctrl+p` publish,
  `ctrl+e` word-wrapped preview, `ctrl+t` edit title, `ctrl+l` cycle
  language, `ctrl+g` AI suggestions, `esc` back to sidebar. `ctrl+q`
  quits, `esc` also closes a media preview. The UI locale is the
  server-side UI language setting.
  """

  use ExRatatui.App
  use Gettext, backend: BDS.Gettext

  alias BDS.AI
  alias BDS.Desktop.UILocale
  alias BDS.Events
  alias BDS.Posts
  alias BDS.Projects
  alias BDS.UI.PostEditor.{Draft, Metadata, Persistence}
  alias BDS.UI.Sidebar
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Clear, List, Markdown, Paragraph, Tabs, Textarea}

  @views ~w(posts media templates scripts tags)

  # ── Mount ────────────────────────────────────────────────────────────────

  @impl true
  def mount(opts) do
    UILocale.put(BDS.Desktop.ShellData.ui_language())
    :ok = Events.subscribe()

    project_id = Projects.shell_snapshot().active_project_id

    state = %{
      # Set only for the local BDS_MODE=tui child: quitting the TUI then
      # shuts the VM down instead of leaving a headless server behind.
      stop_vm_on_exit: Keyword.get(opts, :stop_vm_on_exit, false),
      stop_fun: Keyword.get(opts, :stop_fun, &System.stop/0),
      command_executor:
        Keyword.get(opts, :command_executor, &BDS.Desktop.ShellCommands.execute/2),
      task_snapshot_fun: Keyword.get(opts, :task_snapshot_fun, &BDS.Tasks.status_snapshot/0),
      command: nil,
      projects: nil,
      report: nil,
      handled_task_ids: nil,
      task_polling: false,
      project_id: project_id,
      view: "posts",
      sidebar: nil,
      items: [],
      selected: 0,
      focus: :sidebar,
      editor: nil,
      preview: nil,
      image: nil,
      busy: false,
      status: nil
    }

    # Tasks completed before this session started must never pop their
    # report panels here — another client already consumed them.
    initial_snapshot =
      Keyword.get_lazy(opts, :initial_task_snapshot, state.task_snapshot_fun)

    state = %{state | handled_task_ids: completed_task_ids(initial_snapshot)}

    {:ok, load_sidebar(state)}
  end

  defp completed_task_ids(snapshot) do
    snapshot
    |> Map.get(:tasks, [])
    |> Enum.filter(&(&1.status == :completed))
    |> MapSet.new(& &1.id)
  end

  @impl true
  def terminate(_reason, %{stop_vm_on_exit: true, stop_fun: stop_fun}) do
    stop_fun.()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Events: global keys ──────────────────────────────────────────────────

  @impl true
  def handle_event(%ExRatatui.Event.Key{code: "q", modifiers: ["ctrl"]}, state),
    do: {:stop, state}

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{report: report} = state)
      when report != nil,
      do: report_key(key, state)

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{command: command} = state)
      when command != nil,
      do: command_key(key, state)

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{projects: projects} = state)
      when projects != nil,
      do: projects_key(key, state)

  def handle_event(%ExRatatui.Event.Key{code: "esc"}, %{image: image} = state)
      when image != nil,
      do: {:noreply, %{state | image: nil}}

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{focus: :sidebar} = state),
    do: sidebar_key(key, state)

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{focus: :editor} = state),
    do: editor_key(key, state)

  def handle_event(_event, state), do: {:noreply, state}

  # ── Events: sidebar focus ────────────────────────────────────────────────

  defp sidebar_key(%{code: code}, state) when code in ["down", "j"],
    do: {:noreply, move_selection(state, 1)}

  defp sidebar_key(%{code: code}, state) when code in ["up", "k"],
    do: {:noreply, move_selection(state, -1)}

  defp sidebar_key(%{code: code}, state) when code in ~w(1 2 3 4 5) do
    view = Enum.at(@views, String.to_integer(code) - 1)
    {:noreply, load_sidebar(%{state | view: view, selected: 0, image: nil})}
  end

  defp sidebar_key(%{code: "r"}, state), do: {:noreply, load_sidebar(state)}

  defp sidebar_key(%{code: ":"}, state),
    do: {:noreply, %{state | command: %{input: "", selected: 0, help?: false}}}

  defp sidebar_key(%{code: "p"}, state) do
    snapshot = Projects.shell_snapshot()
    selected = Enum.find_index(snapshot.projects, & &1.is_active) || 0

    {:noreply,
     %{state | projects: %{mode: :list, projects: snapshot.projects, selected: selected, input: ""}}}
  end

  defp sidebar_key(%{code: "n"}, %{project_id: project_id} = state)
       when is_binary(project_id) do
    case Posts.create_post(%{project_id: project_id, title: "", content: ""}) do
      {:ok, post} ->
        {:noreply, state |> load_sidebar() |> open_post(post.id)}

      {:error, reason} ->
        {:noreply, toast(state, dgettext("ui", "New Post"), inspect(reason))}
    end
  end

  defp sidebar_key(%{code: "enter"}, state) do
    case selected_item(state) do
      %{route: "post", id: post_id} -> {:noreply, open_post(state, post_id)}
      %{route: "media", id: media_id} -> {:noreply, open_media(state, media_id)}
      %{id: _id} -> {:noreply, toast(state, view_label(state.view), dgettext("ui", "Editing this item is not available in the terminal UI yet."))}
      _other -> {:noreply, state}
    end
  end

  defp sidebar_key(%{code: "tab"}, %{editor: editor} = state) when editor != nil,
    do: {:noreply, %{state | focus: :editor}}

  defp sidebar_key(_key, state), do: {:noreply, state}

  # ── Events: report panels (metadata diff / site validation) ──────────────

  defp report_key(%{code: "esc"}, state), do: {:noreply, %{state | report: nil}}

  defp report_key(%{code: "enter"}, %{report: report} = state),
    do: {:noreply, apply_report(%{state | report: nil}, report)}

  defp report_key(%{code: code}, %{report: report} = state) when code in ["down", "j"] do
    max_scroll = max(length(report_lines(report)) - 1, 0)
    {:noreply, put_in(state.report.scroll, min(report.scroll + 1, max_scroll))}
  end

  defp report_key(%{code: code}, %{report: report} = state) when code in ["up", "k"],
    do: {:noreply, put_in(state.report.scroll, max(report.scroll - 1, 0))}

  defp report_key(_key, state), do: {:noreply, state}

  # Whole-report application, mirroring the GUI defaults: metadata diffs are
  # repaired from the filesystem (file → db, all items, orphans imported);
  # site validation applies the full report incrementally.
  defp apply_report(state, %{route: "metadata_diff", payload: payload}) do
    items = BDS.MapUtils.attr(payload, :diff_reports, [])
    orphans = BDS.MapUtils.attr(payload, :orphan_reports, [])

    if items == [] and orphans == [] do
      toast(state, dgettext("ui", "Metadata Diff"), dgettext("ui", "Nothing to repair."))
    else
      state =
        if items == [] do
          state
        else
          execute_action(state, dgettext("ui", "Metadata Diff"), "repair_metadata_diff", %{
            items: items,
            direction: "file_to_db"
          })
        end

      if orphans == [] do
        state
      else
        execute_action(
          state,
          dgettext("ui", "Metadata Diff"),
          "import_metadata_diff_orphans",
          %{orphans: orphans}
        )
      end
    end
  end

  defp apply_report(state, %{route: "site_validation", payload: payload}) do
    nothing_to_apply? =
      BDS.MapUtils.attr(payload, :missing_url_paths, []) == [] and
        BDS.MapUtils.attr(payload, :extra_url_paths, []) == [] and
        BDS.MapUtils.attr(payload, :updated_post_url_paths, []) == [] and
        not BDS.MapUtils.attr(payload, :sitemap_changed, false)

    if nothing_to_apply? do
      toast(state, dgettext("ui", "Site Validation"), dgettext("ui", "Nothing to apply."))
    else
      execute_action(state, dgettext("ui", "Site Validation"), "apply_site_validation", %{
        report: payload
      })
    end
  end

  defp apply_report(state, _report), do: state

  # ── Events: projects overlay (switch / open existing) ────────────────────

  defp projects_key(%{code: "esc"}, %{projects: %{mode: :open} = projects} = state),
    do: {:noreply, %{state | projects: %{projects | mode: :list, input: ""}}}

  defp projects_key(%{code: "esc"}, state), do: {:noreply, %{state | projects: nil}}

  defp projects_key(%{code: "enter"}, %{projects: %{mode: :open, input: input}} = state),
    do: {:noreply, open_existing_project(state, input)}

  defp projects_key(%{code: "backspace"}, %{projects: %{mode: :open} = projects} = state),
    do: {:noreply, %{state | projects: %{projects | input: String.slice(projects.input, 0..-2//1)}}}

  defp projects_key(%{code: code, modifiers: []}, %{projects: %{mode: :open} = projects} = state)
       when byte_size(code) >= 1 do
    if String.length(code) == 1 do
      {:noreply, %{state | projects: %{projects | input: projects.input <> code}}}
    else
      {:noreply, state}
    end
  end

  defp projects_key(%{code: "o"}, %{projects: projects} = state),
    do: {:noreply, %{state | projects: %{projects | mode: :open}}}

  defp projects_key(%{code: code}, %{projects: projects} = state) when code in ["down", "j"] do
    count = length(projects.projects)
    {:noreply, put_in(state.projects.selected, min(projects.selected + 1, max(count - 1, 0)))}
  end

  defp projects_key(%{code: code}, %{projects: projects} = state) when code in ["up", "k"],
    do: {:noreply, put_in(state.projects.selected, max(projects.selected - 1, 0))}

  defp projects_key(%{code: "enter"}, %{projects: projects} = state) do
    case Enum.at(projects.projects, projects.selected) do
      nil -> {:noreply, %{state | projects: nil}}
      summary -> {:noreply, switch_project(%{state | projects: nil}, summary.id)}
    end
  end

  defp projects_key(_key, state), do: {:noreply, state}

  defp switch_project(%{project_id: project_id} = state, project_id), do: state

  defp switch_project(state, project_id) do
    case Projects.set_active_project(project_id) do
      {:ok, project} ->
        %{
          state
          | project_id: project.id,
            view: "posts",
            selected: 0,
            focus: :sidebar,
            editor: nil,
            image: nil
        }
        |> load_sidebar()
        |> toast(
          dgettext("ui", "Projects"),
          dgettext("ui", "Switched to %{name}.", name: project.name)
        )

      {:error, reason} ->
        toast(state, dgettext("ui", "Projects"), inspect(reason))
    end
  end

  defp open_existing_project(state, input) do
    path = input |> String.trim() |> Path.expand()

    if File.dir?(path) do
      name =
        case Path.basename(path) do
          "" -> dgettext("ui", "Imported Blog")
          value -> value
        end

      case Projects.create_project(%{name: name, data_path: path}) do
        {:ok, project} ->
          # The folder's content only exists on disk at this point: activate
          # the project, then queue the full database rebuild automatically.
          %{state | projects: nil}
          |> switch_project(project.id)
          |> execute_action(dgettext("ui", "Rebuild Database"), "rebuild_database", %{})

        {:error, reason} ->
          toast(%{state | projects: nil}, dgettext("ui", "Open Existing Blog"), inspect(reason))
      end
    else
      toast(
        state,
        dgettext("ui", "Open Existing Blog"),
        dgettext("ui", "Not a folder: %{path}", path: path)
      )
    end
  end

  # ── Events: command prompt (vi-style) ────────────────────────────────────

  defp command_key(%{code: "esc"}, state), do: {:noreply, %{state | command: nil}}

  defp command_key(_key, %{command: %{help?: true}} = state),
    do: {:noreply, %{state | command: nil}}

  defp command_key(%{code: "enter"}, %{command: command} = state) do
    case Enum.at(filtered_commands(command.input), command.selected) do
      nil ->
        {:noreply,
         toast(%{state | command: nil}, ":" <> command.input, dgettext("ui", "Unknown command."))}

      entry ->
        {:noreply, run_command(%{state | command: nil}, entry)}
    end
  end

  defp command_key(%{code: "down"}, %{command: command} = state) do
    count = length(filtered_commands(command.input))
    {:noreply, put_in(state.command.selected, min(command.selected + 1, max(count - 1, 0)))}
  end

  defp command_key(%{code: "up"}, %{command: command} = state),
    do: {:noreply, put_in(state.command.selected, max(command.selected - 1, 0))}

  defp command_key(%{code: "backspace"}, %{command: command} = state) do
    {:noreply,
     %{state | command: %{command | input: String.slice(command.input, 0..-2//1), selected: 0}}}
  end

  # `:?` — the vi way to reach help from the prompt.
  defp command_key(%{code: "?"}, %{command: %{input: ""}} = state),
    do: {:noreply, put_in(state.command.help?, true)}

  defp command_key(%{code: code, modifiers: []}, %{command: command} = state)
       when byte_size(code) >= 1 do
    if String.length(code) == 1 do
      {:noreply, %{state | command: %{command | input: command.input <> code, selected: 0}}}
    else
      {:noreply, state}
    end
  end

  defp command_key(_key, state), do: {:noreply, state}

  # ── Events: editor focus ─────────────────────────────────────────────────

  defp editor_key(%{code: "esc"}, %{editor: %{editing_title?: true}} = state),
    do: {:noreply, put_in(state.editor.editing_title?, false)}

  defp editor_key(%{code: "esc"}, %{editor: %{preview?: true}} = state),
    do: {:noreply, put_in(state.editor.preview?, false)}

  defp editor_key(%{code: "esc"}, state), do: {:noreply, %{state | focus: :sidebar}}

  defp editor_key(%{code: "e", modifiers: ["ctrl"]}, state),
    do: {:noreply, update_in(state.editor.preview?, &(not &1))}

  defp editor_key(%{code: "s", modifiers: ["ctrl"]}, state), do: {:noreply, persist(state, :save)}

  defp editor_key(%{code: "p", modifiers: ["ctrl"]}, state),
    do: {:noreply, persist(state, :publish)}

  defp editor_key(%{code: "t", modifiers: ["ctrl"]}, state),
    do: {:noreply, update_in(state.editor.editing_title?, &(not &1))}

  defp editor_key(%{code: "l", modifiers: ["ctrl"]}, state), do: {:noreply, cycle_language(state)}

  defp editor_key(%{code: "g", modifiers: ["ctrl"]}, state),
    do: {:noreply, request_ai_suggestions(state)}

  defp editor_key(key, %{editor: %{editing_title?: true}} = state),
    do: {:noreply, title_key(key, state)}

  # While previewing, text keys must not edit the (invisible) textarea.
  defp editor_key(_key, %{editor: %{preview?: true}} = state), do: {:noreply, state}

  defp editor_key(%{code: code, modifiers: modifiers}, %{editor: editor} = state) do
    :ok = ExRatatui.textarea_handle_key(editor.textarea, code, modifiers)
    dirty = editor.dirty or code not in ~w(up down left right home end pageup pagedown)
    {:noreply, put_in(state.editor.dirty, dirty)}
  end

  defp title_key(%{code: "enter"}, state), do: put_in(state.editor.editing_title?, false)

  defp title_key(%{code: "backspace"}, state),
    do: state |> update_in([:editor, :title], &String.slice(&1, 0..-2//1)) |> mark_dirty()

  defp title_key(%{code: code, modifiers: modifiers}, state)
       when byte_size(code) >= 1 and modifiers == [] do
    if String.length(code) == 1 do
      state |> update_in([:editor, :title], &(&1 <> code)) |> mark_dirty()
    else
      state
    end
  end

  defp title_key(_key, state), do: state

  defp mark_dirty(state), do: put_in(state.editor.dirty, true)

  # ── Info: event bus + AI results ─────────────────────────────────────────

  @impl true
  def handle_info({:entity_changed, %{entity: entity, entity_id: id, action: action}}, state) do
    state = load_sidebar(state)

    state =
      if state.editor && state.editor.post.id == id && entity == "post" do
        if action == :deleted, do: %{state | editor: nil, focus: :sidebar}, else: state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:settings_changed, "ui.language"}, state) do
    UILocale.put(BDS.Desktop.ShellData.ui_language())
    {:noreply, load_sidebar(state)}
  end

  def handle_info({:ai_suggestions_result, :post, post_id, result}, state) do
    state = %{state | busy: false}

    if state.editor && state.editor.post.id == post_id do
      attrs =
        %{}
        |> maybe_put_suggestion(:title, Map.get(result, :title))
        |> maybe_put_suggestion(:excerpt, Map.get(result, :excerpt))

      case attrs == %{} || Posts.update_post(post_id, attrs) do
        {:ok, _post} ->
          {:noreply,
           state
           |> reload_editor()
           |> toast(dgettext("ui", "AI Suggestions"), dgettext("ui", "Suggestions applied."))}

        true ->
          {:noreply, toast(state, dgettext("ui", "AI Suggestions"), dgettext("ui", "No suggestions returned."))}

        {:error, reason} ->
          {:noreply, toast(state, dgettext("ui", "AI Suggestions"), inspect(reason))}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:ai_suggestions_error, :post, _post_id, reason}, state) do
    {:noreply, toast(%{state | busy: false}, dgettext("ui", "AI Suggestions"), inspect(reason))}
  end

  def handle_info(:poll_tasks, %{task_polling: true} = state) do
    snapshot = state.task_snapshot_fun.()
    state = open_completed_reports(state, snapshot)

    case snapshot do
      %{running_task_message: message} when is_binary(message) and message != "" ->
        Process.send_after(self(), :poll_tasks, 1_000)
        {:noreply, %{state | status: message}}

      _idle ->
        {:noreply,
         %{state | task_polling: false}
         |> load_sidebar()
         |> toast(dgettext("ui", "Tasks"), dgettext("ui", "All tasks finished."))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A finished metadata diff / site validation task carries its report as
  # the task result; unseen ones open the report panel.
  defp open_completed_reports(state, snapshot) do
    completed = Map.get(snapshot, :tasks, []) |> Enum.filter(&(&1.status == :completed))

    report_task =
      Enum.find(completed, fn task ->
        is_map(task.result) and
          Map.get(task.result, :kind) == "open_editor" and
          Map.get(task.result, :route) in ["metadata_diff", "site_validation"] and
          not MapSet.member?(state.handled_task_ids, task.id)
      end)

    state = %{
      state
      | handled_task_ids: MapSet.union(state.handled_task_ids, MapSet.new(completed, & &1.id))
    }

    case report_task do
      nil ->
        state

      task ->
        %{
          state
          | report: %{
              route: task.result.route,
              payload: Map.get(task.result, :payload, %{}),
              scroll: 0
            }
        }
    end
  end

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [tabs_rect, body_rect, status_rect] = Layout.split(area, :vertical, [
      {:length, 1},
      {:min, 3},
      {:length, 1}
    ])

    [sidebar_rect, main_rect] = Layout.split(body_rect, :horizontal, [
      {:length, min(40, div(frame.width, 3))},
      {:min, 20}
    ])

    view_tabs(state, tabs_rect) ++
      sidebar_widgets(state, sidebar_rect) ++
      main_widgets(state, main_rect) ++
      status_widgets(state, status_rect) ++
      image_widgets(state, body_rect) ++
      report_widgets(state, body_rect) ++
      command_widgets(state, body_rect) ++
      projects_widgets(state, body_rect)
  end

  defp view_tabs(state, rect) do
    [
      {%Tabs{
         titles: Enum.map(@views, &view_label/1),
         selected: Enum.find_index(@views, &(&1 == state.view)),
         highlight_style: %Style{fg: :cyan, modifiers: [:bold]}
       }, rect}
    ]
  end

  defp sidebar_widgets(state, rect) do
    items =
      Enum.map(state.items, fn
        {:header, title} -> "── #{title}"
        {:item, item} -> "  #{item_label(item)}"
      end)

    focused? = state.focus == :sidebar

    [
      {%List{
         items: items,
         selected: list_selected(items, state.selected),
         highlight_style:
           if(focused?,
             do: %Style{fg: :black, bg: :cyan},
             else: %Style{modifiers: [:bold]}
           ),
         block: %Block{title: view_label(state.view), borders: [:all]}
       }, rect}
    ]
  end

  # The List widget requires selected: nil when the collection is empty
  # and raises otherwise — clamp every dynamic list through this.
  defp list_selected([], _selected), do: nil
  defp list_selected(items, selected), do: min(selected, length(items) - 1)

  defp main_widgets(%{editor: nil} = state, rect) do
    text =
      case selected_item(state) do
        %{route: "media"} = item ->
          dgettext("ui", "Press enter to preview %{name}.", name: item_label(item))

        _other ->
          dgettext("ui", "Select an entry and press enter to open it.")
      end

    [{%Paragraph{text: text, block: %Block{title: "bDS2", borders: [:all]}}, rect}]
  end

  defp main_widgets(%{editor: editor} = state, rect) do
    [title_rect, body_rect] = Layout.split(rect, :vertical, [{:length, 3}, {:min, 3}])

    title_block_label =
      if editor.editing_title?,
        do: dgettext("ui", "Title (editing — enter to confirm)"),
        else: dgettext("ui", "Title (ctrl+t to edit)")

    title_widget =
      {%Paragraph{
         text: editor.title,
         block: %Block{title: title_block_label, borders: [:all]},
         style:
           if(editor.editing_title?, do: %Style{fg: :yellow}, else: %Style{})
       }, title_rect}

    [title_widget, body_widget(state, editor, body_rect)]
  end

  # The editing textarea cannot soft-wrap (upstream ratatui-textarea
  # limitation), so ctrl+e flips to a word-wrapped read-only Markdown
  # preview of the current draft. Wrap moves into the editor itself with
  # the planned MarkdownEditor custom widget.
  defp body_widget(_state, %{preview?: true} = editor, body_rect) do
    preview_title =
      "#{dgettext("ui", "Preview (ctrl+e to edit)")} [#{editor.language}]"

    {%Markdown{
       content: ExRatatui.textarea_get_value(editor.textarea),
       wrap: true,
       block: %Block{title: preview_title, borders: [:all]}
     }, body_rect}
  end

  defp body_widget(state, editor, body_rect) do
    body_title =
      "#{dgettext("ui", "Content")} [#{editor.language}]" <>
        if(editor.dirty, do: " •", else: "")

    {%Textarea{
       state: editor.textarea,
       block: %Block{title: body_title, borders: [:all]},
       cursor_style:
         if(state.focus == :editor and not editor.editing_title?,
           do: %Style{bg: :cyan},
           else: %Style{}
         )
     }, body_rect}
  end

  defp status_widgets(state, rect) do
    text =
      cond do
        state.busy -> dgettext("ui", "Working…")
        state.status -> state.status
        true -> default_status(state)
      end

    [{%Paragraph{text: text, style: %Style{fg: :dark_gray}}, rect}]
  end

  defp image_widgets(%{image: nil}, _rect), do: []

  defp image_widgets(%{image: %{widget: widget, title: title}}, rect) do
    overlay = %Rect{
      x: rect.x + 2,
      y: rect.y + 1,
      width: max(rect.width - 4, 10),
      height: max(rect.height - 2, 5)
    }

    [inner] = Layout.split(overlay, :vertical, [{:min, 3}])

    [
      {%Clear{}, overlay},
      {%Block{title: title <> " — " <> dgettext("ui", "esc to close"), borders: [:all]}, overlay},
      {widget,
       %Rect{x: inner.x + 1, y: inner.y + 1, width: inner.width - 2, height: inner.height - 2}}
    ]
  end

  defp command_widgets(%{command: nil}, _rect), do: []

  defp command_widgets(%{command: command}, rect) do
    overlay = %Rect{
      x: rect.x + 4,
      y: rect.y + 1,
      width: max(rect.width - 8, 20),
      height: max(rect.height - 2, 6)
    }

    gui_marker = dgettext("ui", "[report/apply in GUI]")

    items =
      Enum.map(filtered_commands(command.input), fn entry ->
        marker = if entry.gui, do: " " <> gui_marker, else: ""
        "#{entry.action} — #{entry.label}#{marker}"
      end)

    title =
      if command.help? do
        dgettext("ui", "Commands — esc to close")
      else
        ":" <> command.input
      end

    [
      {%Clear{}, overlay},
      {%List{
         items: items,
         selected: if(command.help?, do: nil, else: list_selected(items, command.selected)),
         highlight_style: %Style{fg: :black, bg: :cyan},
         block: %Block{title: title, borders: [:all]}
       }, overlay}
    ]
  end

  defp projects_widgets(%{projects: nil}, _rect), do: []

  defp projects_widgets(%{projects: %{mode: :open} = projects}, rect) do
    overlay = %Rect{
      x: rect.x + 4,
      y: rect.y + 2,
      width: max(rect.width - 8, 20),
      height: 3
    }

    [
      {%Clear{}, overlay},
      {%Paragraph{
         text: projects.input,
         block: %Block{
           title: dgettext("ui", "Open Existing Blog — type a folder path · enter open · esc back"),
           borders: [:all]
         }
       }, overlay}
    ]
  end

  defp projects_widgets(%{projects: projects}, rect) do
    overlay = %Rect{
      x: rect.x + 4,
      y: rect.y + 1,
      width: max(rect.width - 8, 20),
      height: max(rect.height - 2, 6)
    }

    items =
      Enum.map(projects.projects, fn summary ->
        marker = if summary.is_active, do: "● ", else: "  "
        path = summary.data_path || ""
        marker <> summary.name <> if(path == "", do: "", else: " — " <> path)
      end)

    [
      {%Clear{}, overlay},
      {%List{
         items: items,
         selected: list_selected(items, projects.selected),
         highlight_style: %Style{fg: :black, bg: :cyan},
         block: %Block{
           title: dgettext("ui", "Projects — enter switch · o open existing · esc close"),
           borders: [:all]
         }
       }, overlay}
    ]
  end

  defp report_widgets(%{report: nil}, _rect), do: []

  defp report_widgets(%{report: report}, rect) do
    overlay = %Rect{
      x: rect.x + 2,
      y: rect.y + 1,
      width: max(rect.width - 4, 30),
      height: max(rect.height - 2, 8)
    }

    [
      {%Clear{}, overlay},
      {%List{
         items: report_lines(report),
         selected: list_selected(report_lines(report), report.scroll),
         scroll_padding: 2,
         highlight_style: %Style{modifiers: [:bold]},
         block: %Block{title: report_title(report), borders: [:all]}
       }, overlay}
    ]
  end

  defp report_title(%{route: "metadata_diff"}) do
    dgettext("ui", "Metadata Diff") <>
      " — " <> dgettext("ui", "enter repair all from files · esc close")
  end

  defp report_title(%{route: "site_validation"}) do
    dgettext("ui", "Site Validation") <>
      " — " <> dgettext("ui", "enter apply changes · esc close")
  end

  defp report_title(_report), do: ""

  defp report_lines(%{route: "metadata_diff", payload: payload}) do
    diffs = BDS.MapUtils.attr(payload, :diff_reports, [])
    orphans = BDS.MapUtils.attr(payload, :orphan_reports, [])

    summary =
      dgettext("ui", "%{diffs} differences · %{orphans} orphan files",
        diffs: length(diffs),
        orphans: length(orphans)
      )

    diff_lines =
      Enum.flat_map(diffs, fn item ->
        entity =
          "#{BDS.MapUtils.attr(item, :entity_type)} #{BDS.MapUtils.attr(item, :entity_id)}"

        differences =
          item
          |> BDS.MapUtils.attr(:differences, [])
          |> Enum.map(fn diff ->
            "    #{BDS.MapUtils.attr(diff, :name)}: db=#{format_value(BDS.MapUtils.attr(diff, :db_value))} → file=#{format_value(BDS.MapUtils.attr(diff, :file_value))}"
          end)

        ["  " <> entity | differences]
      end)

    orphan_lines =
      case orphans do
        [] -> []
        _some -> ["", dgettext("ui", "Orphan files (not in database):")] ++
            Enum.map(orphans, &("  " <> to_string(BDS.MapUtils.attr(&1, :file_path))))
      end

    [summary, ""] ++ diff_lines ++ orphan_lines
  end

  defp report_lines(%{route: "site_validation", payload: payload}) do
    summary =
      dgettext("ui", "Expected %{expected} · Existing %{existing}",
        expected: BDS.MapUtils.attr(payload, :expected_url_count, 0),
        existing: BDS.MapUtils.attr(payload, :existing_html_url_count, 0)
      )

    sitemap =
      if BDS.MapUtils.attr(payload, :sitemap_changed, false),
        do: [dgettext("ui", "Sitemap changed.")],
        else: []

    [summary, ""] ++
      sitemap ++
      path_section(
        dgettext("ui", "Missing pages (will be rendered):"),
        BDS.MapUtils.attr(payload, :missing_url_paths, [])
      ) ++
      path_section(
        dgettext("ui", "Extra files (will be removed):"),
        BDS.MapUtils.attr(payload, :extra_url_paths, [])
      ) ++
      path_section(
        dgettext("ui", "Updated posts (will be re-rendered):"),
        BDS.MapUtils.attr(payload, :updated_post_url_paths, [])
      )
  end

  defp report_lines(_report), do: []

  defp path_section(_title, []), do: []
  defp path_section(title, paths), do: [title | Enum.map(paths, &("  " <> to_string(&1)))] ++ [""]

  defp format_value(value) when is_binary(value), do: truncate(value)
  defp format_value(value), do: truncate(inspect(value))

  defp truncate(text) when byte_size(text) > 40, do: String.slice(text, 0, 40) <> "…"
  defp truncate(text), do: text

  defp default_status(%{focus: :sidebar}),
    do:
      dgettext(
        "ui",
        "enter open · n new post · 1-5 views · p projects · : commands (:? help) · r refresh · ctrl+q quit"
      )

  defp default_status(%{focus: :editor}),
    do:
      dgettext(
        "ui",
        "ctrl+s save · ctrl+p publish · ctrl+e preview · ctrl+t title · ctrl+l language · ctrl+g AI · esc back"
      )

  # ── Sidebar data ─────────────────────────────────────────────────────────

  defp load_sidebar(state) do
    view = Sidebar.view(state.project_id, state.view)
    items = flatten_items(view, state.view)

    selected =
      case items do
        [] -> 0
        _some -> seek_item(items, clamp(state.selected, length(items)), 1)
      end

    %{state | sidebar: view, items: items, selected: selected}
  end

  defp flatten_items(view, route) do
    sections =
      cond do
        is_list(view[:sections]) -> view[:sections]
        is_list(view[:items]) -> [%{title: nil, items: view[:items]}]
        true -> []
      end

    Enum.flat_map(sections, fn section ->
      headers = if section[:title], do: [{:header, section.title}], else: []

      headers ++
        Enum.map(section[:items] || [], fn item ->
          {:item, Map.put_new(item, :route, route_for(item, route))}
        end)
    end)
  end

  defp route_for(item, route), do: item[:route] || String.trim_trailing(route, "s")

  defp move_selection(state, delta) do
    count = length(state.items)

    if count == 0 do
      state
    else
      next = seek_item(state.items, clamp(state.selected + delta, count), delta)
      %{state | selected: next}
    end
  end

  # Selection skips section headers in the given direction; parks on the
  # boundary when only headers remain that way.
  defp seek_item(items, index, delta) do
    case Enum.at(items, index) do
      {:item, _} ->
        index

      {:header, _} ->
        next = clamp(index + sign(delta), length(items))
        if next == index, do: index, else: seek_item(items, next, delta)

      nil ->
        index
    end
  end

  defp sign(delta) when delta < 0, do: -1
  defp sign(_delta), do: 1

  defp clamp(value, count), do: value |> max(0) |> min(count - 1)

  defp selected_item(state) do
    case Enum.at(state.items, state.selected) do
      {:item, item} -> item
      _other -> nil
    end
  end

  defp item_label(item) do
    title =
      item[:title] || item[:name] || item[:original_name] || item[:label] || item[:id] || "?"

    status = item[:status]
    if status, do: "#{title} (#{status})", else: to_string(title)
  end

  defp view_label("posts"), do: dgettext("ui", "Posts")
  defp view_label("media"), do: dgettext("ui", "Media")
  defp view_label("templates"), do: dgettext("ui", "Templates")
  defp view_label("scripts"), do: dgettext("ui", "Scripts")
  defp view_label("tags"), do: dgettext("ui", "Tags")

  # ── Post editor ──────────────────────────────────────────────────────────

  defp open_post(state, post_id) do
    case Posts.get_post(post_id) do
      nil ->
        toast(state, dgettext("ui", "Posts"), dgettext("ui", "Post not found."))

      post ->
        metadata = Metadata.project_metadata(post.project_id)
        language = Metadata.canonical_language(post, metadata)
        %{state | editor: build_editor(post, metadata, language), focus: :editor, image: nil}
    end
  end

  defp build_editor(post, metadata, language) do
    form = Draft.persisted_form(post, metadata, language)
    textarea = ExRatatui.textarea_new()
    :ok = ExRatatui.textarea_insert_str(textarea, form["content"] || "")

    %{
      post: post,
      metadata: metadata,
      language: language,
      form: form,
      title: form["title"] || "",
      textarea: textarea,
      editing_title?: false,
      preview?: false,
      dirty: false
    }
  end

  defp reload_editor(%{editor: nil} = state), do: state

  defp reload_editor(%{editor: editor} = state) do
    case Posts.get_post(editor.post.id) do
      nil -> %{state | editor: nil, focus: :sidebar}
      post -> %{state | editor: build_editor(post, editor.metadata, editor.language)}
    end
  end

  defp persist(%{editor: editor} = state, action) do
    draft = %{
      editor.form
      | "title" => editor.title,
        "content" => ExRatatui.textarea_get_value(editor.textarea)
    }

    case Persistence.persist(editor.post, draft, editor.language, editor.metadata, action) do
      {:ok, _result} ->
        message =
          case action do
            :publish -> dgettext("ui", "Published.")
            _save -> dgettext("ui", "Saved.")
          end

        state
        |> reload_editor()
        |> load_sidebar()
        |> toast(editor_title(editor), message)

      {:error, reason} ->
        toast(state, editor_title(editor), inspect(reason))
    end
  end

  defp cycle_language(%{editor: editor} = state) do
    if editor.dirty do
      toast(state, editor_title(editor), dgettext("ui", "Save before switching languages."))
    else
      languages = Metadata.languages(editor.metadata)
      index = Enum.find_index(languages, &(&1 == editor.language)) || 0
      next = Enum.at(languages, rem(index + 1, length(languages)))
      %{state | editor: build_editor(editor.post, editor.metadata, next)}
    end
  end

  defp request_ai_suggestions(%{editor: editor} = state) do
    if AI.airplane_mode?() and not AI.airplane_endpoint_configured?() do
      toast(
        state,
        dgettext("ui", "AI Suggestions"),
        dgettext("ui", "AI is unavailable in airplane mode without a local endpoint.")
      )
    else
      parent = self()
      post_id = editor.post.id
      language = editor.metadata.main_language || "en"

      {:ok, _pid} =
        Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
          case AI.analyze_post(post_id, language: language) do
            {:ok, result} -> send(parent, {:ai_suggestions_result, :post, post_id, result})
            {:error, reason} -> send(parent, {:ai_suggestions_error, :post, post_id, reason})
          end
        end)

      %{state | busy: true}
    end
  end

  defp maybe_put_suggestion(attrs, _key, nil), do: attrs

  defp maybe_put_suggestion(attrs, key, value) do
    case String.trim(to_string(value)) do
      "" -> attrs
      trimmed -> Map.put(attrs, key, trimmed)
    end
  end

  defp editor_title(editor),
    do: Metadata.display_title(editor.title, editor.post.slug, editor.post.id)

  # ── Shell commands (main-menu functionality) ─────────────────────────────

  # The parameterless Blog-menu commands. `gui: true` marks commands whose
  # report/apply follow-up UI exists only in the GUI shell for now — the
  # command still runs here, but acting on its report needs the desktop
  # app. Metadata diff and site validation have TUI report panels with
  # whole-report apply, so they are not marked.
  defp commands do
    [
      %{action: "metadata_diff", label: dgettext("ui", "Metadata Diff"), gui: false},
      %{action: "validate_site", label: dgettext("ui", "Validate Site"), gui: false},
      %{action: "force_render_site", label: dgettext("ui", "Force Render Site"), gui: false},
      %{action: "generate_sitemap", label: dgettext("ui", "Generate Site"), gui: false},
      %{action: "rebuild_database", label: dgettext("ui", "Rebuild Database"), gui: false},
      %{action: "reindex_text", label: dgettext("ui", "Reindex Text"), gui: false},
      %{
        action: "rebuild_embedding_index",
        label: dgettext("ui", "Rebuild Embedding Index"),
        gui: false
      },
      %{action: "regenerate_calendar", label: dgettext("ui", "Regenerate Calendar"), gui: false},
      %{
        action: "validate_translations",
        label: dgettext("ui", "Validate Translations"),
        gui: true
      },
      %{
        action: "fill_missing_translations",
        label: dgettext("ui", "Fill Missing Translations"),
        gui: false
      },
      %{action: "find_duplicates", label: dgettext("ui", "Find Duplicate Posts"), gui: true},
      %{action: "upload_site", label: dgettext("ui", "Upload Site"), gui: false},
      %{action: "open_in_browser", label: dgettext("ui", "Open in Browser"), gui: false}
    ]
  end

  defp filtered_commands(""), do: commands()

  defp filtered_commands(input) do
    needle = String.downcase(input)

    Enum.filter(commands(), fn entry ->
      String.contains?(entry.action, needle) or String.contains?(String.downcase(entry.label), needle)
    end)
  end

  defp run_command(state, entry), do: execute_action(state, entry.label, entry.action, %{})

  defp execute_action(state, label, action, params) do
    case state.command_executor.(action, params) do
      {:ok, %{kind: "task_queued", title: title, message: message}} ->
        state
        |> toast(title, message)
        |> start_task_polling()

      {:ok, %{kind: "open_url", title: title, url: url}} ->
        toast(state, title, url)

      {:ok, %{kind: kind, title: title, message: message}}
      when kind in ["output", "open_editor"] ->
        toast(state, title, message)

      {:ok, _other} ->
        toast(state, label, dgettext("ui", "Command completed"))

      {:error, %{message: message}} ->
        toast(state, label, message)

      {:error, reason} ->
        toast(state, label, inspect(reason))
    end
  end

  defp start_task_polling(%{task_polling: true} = state), do: state

  defp start_task_polling(state) do
    Process.send_after(self(), :poll_tasks, 1_000)
    %{state | task_polling: true}
  end

  # ── Media preview ────────────────────────────────────────────────────────

  defp open_media(state, media_id) do
    with %{} = media <- BDS.Media.get_media(media_id),
         true <- String.starts_with?(to_string(media.mime_type || ""), "image/"),
         project when project != nil <- Projects.get_project(media.project_id),
         path = Path.join(Projects.project_data_dir(project), media.file_path),
         {:ok, bytes} <- File.read(path),
         {:ok, widget} <- ExRatatui.Image.new(bytes) do
      %{state | image: %{title: item_media_title(media), widget: widget}}
    else
      false ->
        toast(state, dgettext("ui", "Media"), dgettext("ui", "Only images can be previewed."))

      _other ->
        toast(state, dgettext("ui", "Media"), dgettext("ui", "Could not load this file."))
    end
  end

  defp item_media_title(media), do: media.title || media.original_name || media.id

  # ── Status line ──────────────────────────────────────────────────────────

  defp toast(state, title, message), do: %{state | status: "#{title}: #{message}"}
end
