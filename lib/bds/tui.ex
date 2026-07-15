defmodule BDS.TUI do
  @moduledoc """
  Terminal UI shell (issue #26, phase 4).

  An `ExRatatui.App` over the shared UI core: `BDS.UI.Sidebar` for view
  data, `BDS.UI.PostEditor.*` for the draft/save/publish workflow, and
  `BDS.Events` for multi-client synchronization. Served per SSH connection
  by `ExRatatui.SSH.Daemon` in server mode and runnable locally.

  ## Keys

  Sidebar focus: `↑/↓`/`j/k` navigate, `enter` open, `n` new post,
  `1..5` switch view (posts/media/templates/scripts/tags), `r` refresh.
  Editor focus: text keys edit, `ctrl+s` save, `ctrl+p` publish,
  `ctrl+t` edit title, `ctrl+l` cycle language, `ctrl+g` AI suggestions,
  `esc` back to sidebar. `ctrl+q` quits, `esc` also closes a media
  preview. The UI locale is the server-side UI language setting.
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
  alias ExRatatui.Widgets.{Block, List, Paragraph, Tabs, Textarea}

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

    {:ok, load_sidebar(state)}
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

  # ── Events: editor focus ─────────────────────────────────────────────────

  defp editor_key(%{code: "esc"}, %{editor: %{editing_title?: true}} = state),
    do: {:noreply, put_in(state.editor.editing_title?, false)}

  defp editor_key(%{code: "esc"}, state), do: {:noreply, %{state | focus: :sidebar}}

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

  def handle_info(_message, state), do: {:noreply, state}

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
      image_widgets(state, body_rect)
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
         selected: state.selected,
         highlight_style:
           if(focused?,
             do: %Style{fg: :black, bg: :cyan},
             else: %Style{modifiers: [:bold]}
           ),
         block: %Block{title: view_label(state.view), borders: [:all]}
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

    body_title =
      "#{dgettext("ui", "Content")} [#{editor.language}]" <>
        if(editor.dirty, do: " •", else: "")

    body_widget =
      {%Textarea{
         state: editor.textarea,
         block: %Block{title: body_title, borders: [:all]},
         cursor_style:
           if(state.focus == :editor and not editor.editing_title?,
             do: %Style{bg: :cyan},
             else: %Style{}
           )
       }, body_rect}

    [title_widget, body_widget]
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
      {%Block{title: title <> " — " <> dgettext("ui", "esc to close"), borders: [:all]}, overlay},
      {widget,
       %Rect{x: inner.x + 1, y: inner.y + 1, width: inner.width - 2, height: inner.height - 2}}
    ]
  end

  defp default_status(%{focus: :sidebar}),
    do:
      dgettext(
        "ui",
        "enter open · n new post · 1-5 views · r refresh · ctrl+q quit"
      )

  defp default_status(%{focus: :editor}),
    do:
      dgettext(
        "ui",
        "ctrl+s save · ctrl+p publish · ctrl+t title · ctrl+l language · ctrl+g AI · esc back"
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
