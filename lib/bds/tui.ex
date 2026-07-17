defmodule BDS.TUI do
  @moduledoc """
  Terminal UI shell (issue #26, phase 4).

  An `ExRatatui.App` over the shared UI core: `BDS.UI.Sidebar` for view
  data, `BDS.UI.PostEditor.*` for the draft/save/publish workflow, and
  `BDS.Events` for multi-client synchronization. Served per SSH connection
  by `ExRatatui.SSH.Daemon` in server mode and runnable locally.

  ## Keys

  Sidebar focus: `↑/↓`/`j/k` navigate, `enter` open, `n` new post,
  `1..5` switch view (posts/media/templates/scripts/tags), `6` settings
  (the GUI preferences sections as sidebar entries; enter opens a
  section's form — enter edits a text field in a status-line prompt,
  toggles a boolean or cycles an enum, `ctrl+s` saves through the same
  backends as the GUI, esc closes), `7` git panel
  (changed files plus commit history in the sidebar, scrollable
  whole-folder diff in the main area; `c` commit all, `u` pull, `s` push,
  enter jumps the diff to the selected file), `r` refresh,
  `p` projects overlay (switch the active project or open an existing
  blog folder by path, with bash-style tab completion — opening one
  queues a full database rebuild), `/` vi-style search that live-filters
  the current view (plain text, `tag:x`, `category:x`, or an ISO date
  `yyyy-mm-dd`; enter keeps the filter, esc clears it),
  `:` vi-style command prompt over the Blog-menu shell commands, `?`
  command help (commands whose report/apply UI is GUI-only are marked).
  Posts open in the rendered markdown preview (new empty posts open in
  the editor). Editor focus: `ctrl+e` toggles preview/editor, text keys
  edit, `ctrl+s` save, `ctrl+p` publish, `ctrl+t` edit title, `ctrl+l`
  cycle language, `ctrl+g` AI suggestions, `esc` back to sidebar. `ctrl+q`
  quits, `esc` also closes a media preview. The UI locale is the
  server-side UI language setting.
  """

  use ExRatatui.App
  use Gettext, backend: BDS.Gettext

  alias BDS.AI
  alias BDS.Desktop.UILocale
  alias BDS.Events
  alias BDS.Git
  alias BDS.Posts
  alias BDS.Projects
  alias BDS.UI.PostEditor.{Draft, Metadata, Persistence}
  alias BDS.UI.SettingsForm
  alias BDS.UI.Sidebar
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Clear, List, Markdown, Paragraph, Tabs, Textarea}

  @views ~w(posts media templates scripts tags settings git)
  @git_diff_scroll_step 10
  @git_max_diff_lines 5000

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
      search: nil,
      filters_by_view: %{},
      git: nil,
      git_commit: nil,
      settings_form: nil,
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

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{git_commit: git_commit} = state)
      when git_commit != nil,
      do: git_commit_key(key, state)

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{search: search} = state)
      when search != nil,
      do: search_key(key, state)

  def handle_event(%ExRatatui.Event.Key{kind: "press"} = key, %{settings_form: form} = state)
      when form != nil,
      do: settings_form_key(key, state)

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

  # Settings is panel "6" (issue #29) and git panel "7" (issue #30),
  # matching the GUI panel numbering.
  defp sidebar_key(%{code: code}, state) when code in ~w(1 2 3 4 5 6 7) do
    view = Enum.at(@views, String.to_integer(code) - 1)
    {:noreply, load_sidebar(%{state | view: view, selected: 0, image: nil})}
  end

  defp sidebar_key(%{code: "c"}, %{view: "git"} = state) do
    if state.git do
      {:noreply, %{state | git_commit: %{input: ""}}}
    else
      {:noreply, not_a_repo_toast(state)}
    end
  end

  defp sidebar_key(%{code: "u"}, %{view: "git"} = state), do: run_git_async(state, :pull)
  defp sidebar_key(%{code: "s"}, %{view: "git"} = state), do: run_git_async(state, :push)

  defp sidebar_key(%{code: "pagedown"}, %{view: "git", git: git} = state) when git != nil do
    max_scroll = max(length(git.lines) - 1, 0)
    {:noreply, put_in(state.git.scroll, min(git.scroll + @git_diff_scroll_step, max_scroll))}
  end

  defp sidebar_key(%{code: "pageup"}, %{view: "git", git: git} = state) when git != nil,
    do: {:noreply, put_in(state.git.scroll, max(git.scroll - @git_diff_scroll_step, 0))}

  defp sidebar_key(%{code: "r"}, state), do: {:noreply, load_sidebar(state)}

  defp sidebar_key(%{code: ":"}, state),
    do: {:noreply, %{state | command: %{input: "", selected: 0, help?: false}}}

  defp sidebar_key(%{code: "/"}, state),
    do: {:noreply, %{state | search: %{input: Map.get(state.filters_by_view, state.view, "")}}}

  defp sidebar_key(%{code: "p"}, state) do
    snapshot = Projects.shell_snapshot()
    selected = Enum.find_index(snapshot.projects, & &1.is_active) || 0

    {:noreply,
     %{
       state
       | projects: %{
           mode: :list,
           projects: snapshot.projects,
           selected: selected,
           input: "",
           matches: []
         }
     }}
  end

  defp sidebar_key(%{code: "n"}, %{project_id: project_id} = state)
       when is_binary(project_id) do
    case Posts.create_post(%{project_id: project_id, title: "", content: ""}) do
      {:ok, post} ->
        # A fresh, empty post starts in the editor — there is nothing to
        # preview yet; existing posts open in the preview instead.
        {:noreply, state |> load_sidebar() |> open_post(post.id, false)}

      {:error, reason} ->
        {:noreply, toast(state, dgettext("ui", "New Post"), inspect(reason))}
    end
  end

  defp sidebar_key(%{code: "enter"}, state) do
    case selected_item(state) do
      %{route: "post", id: post_id} -> {:noreply, open_post(state, post_id)}
      %{route: "media", id: media_id} -> {:noreply, open_media(state, media_id)}
      %{route: "git_file", id: path} -> {:noreply, jump_to_file_diff(state, path)}
      %{route: "settings", id: "settings-" <> section} -> {:noreply, open_settings_form(state, section)}
      %{route: "style"} -> {:noreply, open_settings_form(state, "style")}
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

  # ── Events: git panel (issue #30) ─────────────────────────────────────────

  # Commit prompt in the status line, mirroring the search prompt: enter
  # commits the whole working tree (git add -A + commit), esc cancels.
  defp git_commit_key(%{code: "esc"}, state), do: {:noreply, %{state | git_commit: nil}}

  defp git_commit_key(%{code: "enter"}, %{git_commit: %{input: input}} = state) do
    message = String.trim(input)
    state = %{state | git_commit: nil}

    cond do
      message == "" ->
        {:noreply,
         toast(state, dgettext("ui", "Commit"), dgettext("ui", "Commit message required."))}

      true ->
        case Git.commit_all(state.project_id, message) do
          {:ok, _result} ->
            {:noreply,
             state |> load_sidebar() |> toast(dgettext("ui", "Commit"), dgettext("ui", "Committed."))}

          {:error, reason} ->
            {:noreply, toast(state, dgettext("ui", "Commit"), format_git_error(reason))}
        end
    end
  end

  defp git_commit_key(%{code: "backspace"}, %{git_commit: git_commit} = state) do
    {:noreply,
     %{state | git_commit: %{git_commit | input: String.slice(git_commit.input, 0..-2//1)}}}
  end

  defp git_commit_key(%{code: code, modifiers: []}, %{git_commit: git_commit} = state)
       when byte_size(code) >= 1 do
    if String.length(code) == 1 do
      {:noreply, %{state | git_commit: %{git_commit | input: git_commit.input <> code}}}
    else
      {:noreply, state}
    end
  end

  defp git_commit_key(_key, state), do: {:noreply, state}

  # Pull and push hit the network, so they run off the UI process and
  # report back via {:git_result, op, result}.
  defp run_git_async(%{git: nil} = state, _operation),
    do: {:noreply, not_a_repo_toast(state)}

  defp run_git_async(state, operation) do
    parent = self()
    project_id = state.project_id

    {:ok, _pid} =
      Task.Supervisor.start_child(BDS.TCP.TaskSupervisor, fn ->
        result =
          case operation do
            :pull -> Git.pull(project_id)
            :push -> Git.push(project_id)
          end

        send(parent, {:git_result, operation, result})
      end)

    {:noreply, %{state | busy: true}}
  end

  defp not_a_repo_toast(state),
    do: toast(state, view_label("git"), dgettext("ui", "Not a git repository."))

  defp jump_to_file_diff(%{git: nil} = state, _path), do: state

  defp jump_to_file_diff(%{git: git} = state, path) do
    index =
      Enum.find_index(git.lines, fn line ->
        String.starts_with?(line, "diff --git") and String.contains?(line, " b/" <> path)
      end)

    case index do
      nil ->
        toast(state, view_label("git"), dgettext("ui", "No diff for this file."))

      scroll ->
        put_in(state.git.scroll, scroll)
    end
  end

  defp format_git_error({:git_failed, output}), do: output
  defp format_git_error(reason), do: inspect(reason)

  # ── Events: settings form (issue #29) ─────────────────────────────────────

  # A settings sidebar entry opens its section as a generic typed-field
  # form in the main area, backed by BDS.UI.SettingsForm — the same
  # preferences the GUI settings editor operates on.
  defp open_settings_form(state, section) do
    form = SettingsForm.load(section, state.project_id)

    %{
      state
      | settings_form: %{
          section: form.section,
          title: form.title,
          fields: form.fields,
          selected: seek_field(form.fields, 0, 1),
          input: nil,
          dirty: false
        },
        image: nil
    }
  end

  # Text fields edit in a status-line prompt (like the commit message):
  # enter commits the value into the field, esc cancels just the prompt.
  defp settings_form_key(%{code: "esc"}, %{settings_form: %{input: input}} = state)
       when input != nil,
       do: {:noreply, put_in(state.settings_form.input, nil)}

  defp settings_form_key(%{code: "enter"}, %{settings_form: %{input: input} = form} = state)
       when input != nil do
    fields =
      Enum.map(form.fields, fn field ->
        if field.key == input.key, do: %{field | value: input.value}, else: field
      end)

    {:noreply, %{state | settings_form: %{form | fields: fields, input: nil, dirty: true}}}
  end

  defp settings_form_key(%{code: "backspace"}, %{settings_form: %{input: input}} = state)
       when input != nil do
    {:noreply, put_in(state.settings_form.input.value, String.slice(input.value, 0..-2//1))}
  end

  defp settings_form_key(%{code: code, modifiers: []}, %{settings_form: %{input: input}} = state)
       when input != nil and byte_size(code) >= 1 do
    if String.length(code) == 1 do
      {:noreply, put_in(state.settings_form.input.value, input.value <> code)}
    else
      {:noreply, state}
    end
  end

  defp settings_form_key(_key, %{settings_form: %{input: input}} = state) when input != nil,
    do: {:noreply, state}

  defp settings_form_key(%{code: "esc"}, state),
    do: {:noreply, %{state | settings_form: nil}}

  defp settings_form_key(%{code: "s", modifiers: ["ctrl"]}, state),
    do: save_settings_form(state)

  defp settings_form_key(%{code: code}, state) when code in ["down", "j"],
    do: {:noreply, move_field_selection(state, 1)}

  defp settings_form_key(%{code: code}, state) when code in ["up", "k"],
    do: {:noreply, move_field_selection(state, -1)}

  defp settings_form_key(%{code: "enter"}, %{settings_form: form} = state) do
    case Enum.at(form.fields, form.selected) do
      %{type: :text} = field ->
        {:noreply,
         put_in(state.settings_form.input, %{key: field.key, label: field.label, value: field.value})}

      %{type: :bool} = field ->
        {:noreply, update_field(state, field.key, not field.value)}

      %{type: :enum, options: options} = field when options != [] ->
        index = Enum.find_index(options, &(&1 == field.value)) || 0
        {:noreply, update_field(state, field.key, Enum.at(options, rem(index + 1, length(options))))}

      _other ->
        {:noreply, state}
    end
  end

  defp settings_form_key(_key, state), do: {:noreply, state}

  defp update_field(%{settings_form: form} = state, key, value) do
    fields =
      Enum.map(form.fields, fn field ->
        if field.key == key, do: %{field | value: value}, else: field
      end)

    %{state | settings_form: %{form | fields: fields, dirty: true}}
  end

  defp save_settings_form(%{settings_form: form} = state) do
    values = Map.new(form.fields, fn field -> {field.key, field.value} end)

    case SettingsForm.save(form.section, state.project_id, values) do
      :ok ->
        reloaded = SettingsForm.load(form.section, state.project_id)

        state = %{
          state
          | settings_form: %{
              form
              | fields: reloaded.fields,
                selected: min(form.selected, max(length(reloaded.fields) - 1, 0)),
                input: nil,
                dirty: false
            }
        }

        {:noreply, toast(state, form.title, dgettext("ui", "Saved."))}

      {:error, reason} ->
        {:noreply, toast(state, form.title, settings_error(reason))}
    end
  end

  defp settings_error(reason) when is_binary(reason), do: reason
  defp settings_error(reason), do: inspect(reason)

  # Selection skips read-only :info rows in the given direction.
  defp move_field_selection(%{settings_form: form} = state, delta) do
    count = length(form.fields)

    if count == 0 do
      state
    else
      next = seek_field(form.fields, clamp(form.selected + delta, count), delta)
      put_in(state.settings_form.selected, next)
    end
  end

  defp seek_field(fields, index, delta) do
    case Enum.at(fields, index) do
      %{type: :info} ->
        next = clamp(index + sign(delta), length(fields))
        if next == index, do: index, else: seek_field(fields, next, delta)

      _other ->
        index
    end
  end

  # ── Events: sidebar search (vi-style "/") ─────────────────────────────────

  # The prompt lives in the status line and filters the current view live
  # on every keystroke. Esc clears the view's filter, enter keeps it (the
  # active filter stays visible in the sidebar title).
  defp search_key(%{code: "esc"}, state) do
    state = %{state | search: nil, filters_by_view: Map.delete(state.filters_by_view, state.view)}
    {:noreply, load_sidebar(state)}
  end

  defp search_key(%{code: "enter"}, state), do: {:noreply, %{state | search: nil}}

  defp search_key(%{code: "backspace"}, %{search: search} = state),
    do: {:noreply, apply_search(state, String.slice(search.input, 0..-2//1))}

  defp search_key(%{code: code, modifiers: []}, %{search: search} = state)
       when byte_size(code) >= 1 do
    if String.length(code) == 1 do
      {:noreply, apply_search(state, search.input <> code)}
    else
      {:noreply, state}
    end
  end

  defp search_key(_key, state), do: {:noreply, state}

  defp apply_search(state, input) do
    filters_by_view =
      case String.trim(input) do
        "" -> Map.delete(state.filters_by_view, state.view)
        _some -> Map.put(state.filters_by_view, state.view, input)
      end

    load_sidebar(%{
      state
      | search: %{input: input},
        filters_by_view: filters_by_view,
        selected: 0
    })
  end

  # "/" query syntax: plain words are a text search, "tag:x" and
  # "category:x" filter exactly like the GUI filter chips, and an ISO date
  # (yyyy-mm-dd) narrows to that day. Tokens combine with AND.
  defp parse_search_query(query) do
    initial = %{words: [], tags: [], categories: [], date: nil}

    parsed =
      query
      |> String.split()
      |> Enum.reduce(initial, fn token, acc ->
        cond do
          String.starts_with?(token, "tag:") ->
            add_filter_token(acc, :tags, String.replace_prefix(token, "tag:", ""))

          String.starts_with?(token, "category:") ->
            add_filter_token(acc, :categories, String.replace_prefix(token, "category:", ""))

          match?({:ok, _date}, Date.from_iso8601(token)) ->
            {:ok, date} = Date.from_iso8601(token)
            %{acc | date: date}

          true ->
            %{acc | words: acc.words ++ [token]}
        end
      end)

    %{
      search: if(parsed.words == [], do: nil, else: Enum.join(parsed.words, " ")),
      tags: parsed.tags,
      categories: parsed.categories,
      year: parsed.date && parsed.date.year,
      month: parsed.date && parsed.date.month,
      day: parsed.date && parsed.date.day
    }
  end

  defp add_filter_token(acc, _key, ""), do: acc
  defp add_filter_token(acc, key, value), do: Map.update!(acc, key, &(&1 ++ [value]))

  # ── Events: projects overlay (switch / open existing) ────────────────────

  defp projects_key(%{code: "esc"}, %{projects: %{mode: :open} = projects} = state),
    do: {:noreply, %{state | projects: %{projects | mode: :list, input: "", matches: []}}}

  defp projects_key(%{code: "esc"}, state), do: {:noreply, %{state | projects: nil}}

  defp projects_key(%{code: "enter"}, %{projects: %{mode: :open, input: input}} = state),
    do: {:noreply, open_existing_project(state, input)}

  defp projects_key(%{code: "tab"}, %{projects: %{mode: :open} = projects} = state) do
    {input, matches} = complete_path(projects.input)
    {:noreply, %{state | projects: %{projects | input: input, matches: matches}}}
  end

  defp projects_key(%{code: "backspace"}, %{projects: %{mode: :open} = projects} = state) do
    {:noreply,
     %{
       state
       | projects: %{projects | input: String.slice(projects.input, 0..-2//1), matches: []}
     }}
  end

  defp projects_key(%{code: code, modifiers: []}, %{projects: %{mode: :open} = projects} = state)
       when byte_size(code) >= 1 do
    if String.length(code) == 1 do
      {:noreply, %{state | projects: %{projects | input: projects.input <> code, matches: []}}}
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

  # Bash-style directory completion for the path prompt: a unique match
  # completes fully (plus trailing slash), an ambiguous one completes to
  # the longest common prefix and returns the candidates for display.
  # Only directories are offered, and dotfolders only when the typed
  # prefix itself starts with a dot.
  defp complete_path(""), do: {"", []}

  defp complete_path(input) do
    input = expand_tilde(input)
    {base, prefix} = split_at_last_slash(input)
    scan_dir = if base == "", do: ".", else: base

    case completion_candidates(scan_dir, prefix) do
      [] -> {input, []}
      [single] -> {base <> single <> "/", []}
      many -> {base <> longest_common_prefix(many), many}
    end
  end

  defp expand_tilde("~" <> rest), do: System.user_home!() <> rest
  defp expand_tilde(input), do: input

  defp split_at_last_slash(input) do
    case :binary.matches(input, "/") do
      [] ->
        {"", input}

      offsets ->
        # List is aliased to the ratatui widget here, so no List.last/1.
        {position, _length} = Enum.at(offsets, -1)
        String.split_at(input, position + 1)
    end
  end

  defp completion_candidates(scan_dir, prefix) do
    case File.ls(scan_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reject(&(String.starts_with?(&1, ".") and not String.starts_with?(prefix, ".")))
        |> Enum.filter(&File.dir?(Path.join(scan_dir, &1)))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp longest_common_prefix([first | rest]),
    do: Enum.reduce(rest, first, &grapheme_common_prefix/2)

  defp grapheme_common_prefix(a, b) do
    a
    |> String.graphemes()
    |> Enum.zip(String.graphemes(b))
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map_join("", fn {grapheme, _} -> grapheme end)
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

  def handle_info({:git_result, operation, result}, state) do
    title =
      case operation do
        :pull -> dgettext("ui", "Pull")
        :push -> dgettext("ui", "Push")
      end

    state = %{state | busy: false}

    case result do
      {:ok, %{output: output}} ->
        {:noreply, state |> load_sidebar() |> toast(title, first_output_line(output))}

      {:error, reason} ->
        {:noreply, toast(state, title, format_git_error(reason))}
    end
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

  # The git sidebar mirrors the GUI: changed files on top, commit history
  # in the lower half (↑ needs push, ↓ remote-only, blank when synced).
  defp sidebar_widgets(%{view: "git", sidebar: %{git_state: "active"} = sidebar} = state, rect) do
    [changes_rect, history_rect] =
      Layout.split(rect, :vertical, [{:percentage, 50}, {:percentage, 50}])

    history_items = Enum.map(sidebar.history_entries, &history_line/1)

    [
      sidebar_list_widget(state, changes_rect),
      {%List{
         items: history_items,
         selected: nil,
         block: %Block{title: dgettext("ui", "History"), borders: [:all]}
       }, history_rect}
    ]
  end

  defp sidebar_widgets(state, rect), do: [sidebar_list_widget(state, rect)]

  defp sidebar_list_widget(state, rect) do
    items =
      Enum.map(state.items, fn
        {:header, title} -> "── #{title}"
        {:item, item} -> "  #{item_label(item)}"
      end)

    focused? = state.focus == :sidebar

    {%List{
       items: items,
       selected: list_selected(items, state.selected),
       highlight_style:
         if(focused?,
           do: %Style{fg: :black, bg: :cyan},
           else: %Style{modifiers: [:bold]}
         ),
       block: %Block{title: sidebar_title(state), borders: [:all]}
     }, rect}
  end

  defp history_line(entry) do
    marker =
      case entry.sync_status do
        "local_only" -> "↑ "
        "remote_only" -> "↓ "
        _synced -> "  "
      end

    marker <> entry.short_hash <> " " <> to_string(entry.subject || "")
  end

  defp sidebar_title(%{view: "git", sidebar: %{git_state: "active"} = sidebar}) do
    branch = sidebar[:branch] || "?"
    view_label("git") <> " [#{branch} ↑#{sidebar[:ahead] || 0} ↓#{sidebar[:behind] || 0}]"
  end

  defp sidebar_title(state) do
    case Map.get(state.filters_by_view, state.view) do
      nil -> view_label(state.view)
      query -> view_label(state.view) <> " /" <> query
    end
  end

  # The List widget requires selected: nil when the collection is empty
  # and raises otherwise — clamp every dynamic list through this.
  defp list_selected([], _selected), do: nil
  defp list_selected(items, selected), do: min(selected, length(items) - 1)

  defp main_widgets(%{settings_form: form}, rect) when form != nil do
    items = Enum.map(form.fields, &field_line/1)

    title =
      form.title <>
        if(form.dirty, do: " •", else: "") <>
        " — " <> dgettext("ui", "enter edit · ctrl+s save · esc close")

    [
      {%List{
         items: items,
         selected: list_selected(items, form.selected),
         scroll_padding: 2,
         highlight_style: %Style{fg: :black, bg: :cyan},
         block: %Block{title: title, borders: [:all]}
       }, rect}
    ]
  end

  defp main_widgets(%{view: "git", editor: nil, git: nil}, rect) do
    [
      {%Paragraph{
         text: dgettext("ui", "Not a git repository."),
         block: %Block{title: view_label("git"), borders: [:all]}
       }, rect}
    ]
  end

  defp main_widgets(%{view: "git", editor: nil, git: git}, rect) do
    [
      {%List{
         items: git.lines,
         selected: list_selected(git.lines, git.scroll),
         scroll_padding: 2,
         highlight_style: %Style{modifiers: [:bold]},
         block: %Block{title: dgettext("ui", "Diff (pgup/pgdn scroll)"), borders: [:all]}
       }, rect}
    ]
  end

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
    settings_input = state.settings_form && state.settings_form.input

    text =
      cond do
        settings_input -> settings_input.label <> ": " <> settings_input.value
        state.git_commit -> dgettext("ui", "Commit message") <> ": " <> state.git_commit.input
        state.search -> "/" <> state.search.input
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

    input_widgets = [
      {%Clear{}, overlay},
      {%Paragraph{
         text: projects.input,
         block: %Block{
           title:
             dgettext(
               "ui",
               "Open Existing Blog — type a folder path · tab complete · enter open · esc back"
             ),
           borders: [:all]
         }
       }, overlay}
    ]

    input_widgets ++ completion_widgets(projects.matches, rect, overlay)
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

  defp completion_widgets([], _rect, _input_overlay), do: []

  defp completion_widgets(matches, rect, input_overlay) do
    below = input_overlay.y + input_overlay.height
    available = rect.y + rect.height - below

    if available < 3 do
      []
    else
      overlay = %Rect{
        x: input_overlay.x,
        y: below,
        width: input_overlay.width,
        height: min(length(matches) + 2, available)
      }

      [
        {%Clear{}, overlay},
        {%List{
           items: matches,
           selected: nil,
           block: %Block{title: dgettext("ui", "Matching folders"), borders: [:all]}
         }, overlay}
      ]
    end
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

  defp default_status(%{settings_form: form}) when form != nil,
    do:
      dgettext(
        "ui",
        "enter edit/toggle/cycle · ctrl+s save · esc close · ctrl+q quit"
      )

  defp default_status(%{focus: :sidebar, view: "git"}),
    do:
      dgettext(
        "ui",
        "c commit · u pull · s push · enter jump to file · pgup/pgdn scroll diff · 1-7 views · ctrl+q quit"
      )

  defp default_status(%{focus: :sidebar}),
    do:
      dgettext(
        "ui",
        "enter open · n new post · 1-7 views · p projects · / search · : commands (:? help) · r refresh · ctrl+q quit"
      )

  defp default_status(%{focus: :editor}),
    do:
      dgettext(
        "ui",
        "ctrl+s save · ctrl+p publish · ctrl+e preview · ctrl+t title · ctrl+l language · ctrl+g AI · esc back"
      )

  # ── Sidebar data ─────────────────────────────────────────────────────────

  defp load_sidebar(state) do
    view = Sidebar.view(state.project_id, state.view, search_filter_params(state))
    items = flatten_items(view, state.view)

    selected =
      case items do
        [] -> 0
        _some -> seek_item(items, clamp(state.selected, length(items)), 1)
      end

    %{state | sidebar: view, items: items, selected: selected, git: load_git_panel(state, view)}
  end

  # The whole-folder diff (staged + unstaged) shown in the git panel's main
  # area, reloaded together with the sidebar; the scroll position survives
  # refreshes. Capped so a giant working tree cannot flood the terminal.
  defp load_git_panel(%{view: "git"} = state, %{git_state: "active"}) do
    lines =
      case Git.diff(state.project_id) do
        {:ok, %{staged_diff: staged, unstaged_diff: unstaged}} ->
          case String.trim(staged <> "\n" <> unstaged) do
            "" -> [dgettext("ui", "No changes.")]
            diff -> diff |> String.split("\n") |> Enum.take(@git_max_diff_lines)
          end

        _error ->
          []
      end

    old_scroll = if state.git, do: state.git.scroll, else: 0
    %{lines: lines, scroll: min(old_scroll, max(length(lines) - 1, 0))}
  end

  defp load_git_panel(_state, _view), do: nil

  defp first_output_line(output) do
    output |> String.split("\n", parts: 2) |> hd() |> String.trim()
  end

  defp search_filter_params(state) do
    case Map.get(state.filters_by_view, state.view) do
      nil -> %{}
      query -> parse_search_query(query)
    end
  end

  # Git sidebar entries are the changed files from git status; enter jumps
  # the diff panel to that file.
  defp flatten_items(%{git_state: "active"} = view, "git") do
    Enum.map(view.status_files, fn file ->
      {:item, %{route: "git_file", id: file.path, label: "#{file.code} #{file.path}"}}
    end)
  end

  defp flatten_items(_view, "git"), do: []

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

  defp field_line(%{type: :bool} = field),
    do: if(field.value, do: "[x] ", else: "[ ] ") <> field.label

  defp field_line(%{type: :info, value: ""} = field), do: field.label
  defp field_line(field), do: "#{field.label}: #{field.value}"

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
  defp view_label("settings"), do: dgettext("ui", "Settings")
  defp view_label("git"), do: dgettext("ui", "Git")

  # ── Post editor ──────────────────────────────────────────────────────────

  # Posts open in the rendered markdown preview by default — the editor is
  # one ctrl+e away. New (empty) posts pass preview?: false.
  defp open_post(state, post_id, preview? \\ true) do
    case Posts.get_post(post_id) do
      nil ->
        toast(state, dgettext("ui", "Posts"), dgettext("ui", "Post not found."))

      post ->
        metadata = Metadata.project_metadata(post.project_id)
        language = Metadata.canonical_language(post, metadata)

        %{
          state
          | editor: build_editor(post, metadata, language, preview?),
            focus: :editor,
            image: nil
        }
    end
  end

  defp build_editor(post, metadata, language, preview?) do
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
      preview?: preview?,
      dirty: false
    }
  end

  defp reload_editor(%{editor: nil} = state), do: state

  defp reload_editor(%{editor: editor} = state) do
    case Posts.get_post(editor.post.id) do
      nil -> %{state | editor: nil, focus: :sidebar}
      post -> %{state | editor: build_editor(post, editor.metadata, editor.language, editor.preview?)}
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
      %{state | editor: build_editor(editor.post, editor.metadata, next, editor.preview?)}
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
