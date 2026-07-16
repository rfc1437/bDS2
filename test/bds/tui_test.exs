defmodule BDS.TUITest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key

  defp post_count(project_id) do
    BDS.Repo.aggregate(from(p in BDS.Posts.Post, where: p.project_id == ^project_id), :count)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual) end)

    temp_dir = Path.join(System.tmp_dir!(), "bds-tui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "TUI", data_path: temp_dir})
    {:ok, _} = BDS.Projects.set_active_project(project.id)

    {:ok, post} =
      BDS.Posts.create_post(%{
        project_id: project.id,
        title: "Hello TUI",
        content: "terminal body",
        language: "en"
      })

    %{project: project, post: post}
  end

  defp mount!(opts \\ []) do
    {:ok, state} = BDS.TUI.mount(opts)
    state
  end

  defp screen_text(state, width \\ 100, height \\ 32) do
    session = CellSession.new(width, height)
    frame = %ExRatatui.Frame{width: width, height: height}
    :ok = CellSession.draw(session, BDS.TUI.render(state, frame))
    snapshot = CellSession.take_cells(session)
    :ok = CellSession.close(session)

    snapshot.cells
    |> Enum.group_by(& &1.row)
    |> Enum.sort_by(fn {row, _} -> row end)
    |> Enum.map_join("\n", fn {_row, cells} ->
      cells |> Enum.sort_by(& &1.col) |> Enum.map_join("", & &1.symbol)
    end)
  end

  defp key(code, modifiers), do: %Key{code: code, kind: "press", modifiers: modifiers}

  defp press(state, code, modifiers \\ []) do
    {:noreply, state} = BDS.TUI.handle_event(key(code, modifiers), state)
    state
  end

  test "mounts against the active project and lists posts", %{post: post} do
    state = mount!()

    assert state.project_id == post.project_id
    text = screen_text(state)
    assert text =~ "Hello TUI"
  end

  test "navigates and opens a post in the editor", %{post: post} do
    state = mount!() |> press("enter")

    assert state.focus == :editor
    assert state.editor.post.id == post.id
    assert ExRatatui.textarea_get_value(state.editor.textarea) == "terminal body"
    assert screen_text(state) =~ "terminal body"
  end

  test "ctrl+s persists textarea edits", %{post: post} do
    state = mount!() |> press("enter")

    :ok = ExRatatui.textarea_insert_str(state.editor.textarea, "more words ")
    state = press(state, "s", ["ctrl"])

    assert state.editor.dirty == false
    assert BDS.Posts.get_post(post.id).content =~ "more words"
  end

  test "ctrl+p publishes the open post", %{post: post} do
    state = mount!() |> press("enter") |> press("p", ["ctrl"])

    published = BDS.Posts.get_post(post.id)
    assert published.status == :published
    assert state.editor.post.status == :published
  end

  test "n creates a new draft post", %{project: project} do
    count_before = post_count(project.id)
    state = mount!() |> press("n")

    assert post_count(project.id) == count_before + 1
    assert state.focus == :editor
    assert state.editor.post.status == :draft
  end

  test "esc returns focus to the sidebar" do
    state = mount!() |> press("enter") |> press("esc")
    assert state.focus == :sidebar
  end

  test "ctrl+e toggles a word-wrapped preview of the draft", %{post: post} do
    long_line = String.duplicate("lorem ipsum dolor sit amet ", 8) <> "FINALWORD"
    {:ok, _} = BDS.Posts.update_post(post.id, %{content: long_line})

    state = mount!() |> press("enter") |> press("e", ["ctrl"])
    assert state.editor.preview?

    # The textarea cannot soft-wrap, so the tail of a long line is off-screen
    # there; the preview renders through the Markdown widget, which wraps.
    assert screen_text(state, 80, 32) =~ "FINALWORD"

    state = press(state, "e", ["ctrl"])
    refute state.editor.preview?
  end

  test "keys in preview mode do not edit the content" do
    state = mount!() |> press("enter") |> press("e", ["ctrl"])
    before = ExRatatui.textarea_get_value(state.editor.textarea)

    state = press(state, "x")
    assert ExRatatui.textarea_get_value(state.editor.textarea) == before
    refute state.editor.dirty
  end

  test "esc in preview returns to editing, not to the sidebar" do
    state = mount!() |> press("enter") |> press("e", ["ctrl"]) |> press("esc")

    refute state.editor.preview?
    assert state.focus == :editor
  end

  test "entity_changed refreshes the sidebar", %{project: project} do
    state = mount!()

    {:ok, other} =
      BDS.Posts.create_post(%{project_id: project.id, title: "From Pipeline", content: "x"})

    {:noreply, state} =
      BDS.TUI.handle_info(
        {:entity_changed, %{entity: "post", entity_id: other.id, action: :created}},
        state
      )

    assert screen_text(state) =~ "From Pipeline"
  end

  test "view switching shows media view" do
    state = mount!() |> press("2")
    assert state.view == "media"
  end

  test "quit key stops the app" do
    assert {:stop, _state} = BDS.TUI.handle_event(key("q", ["ctrl"]), mount!())
  end

  describe "command prompt" do
    defp mount_with_executor! do
      parent = self()

      mount!(
        command_executor: fn action, params ->
          send(parent, {:executed, action, params})
          {:ok, %{kind: "output", title: "T", message: "done"}}
        end
      )
    end

    test "':' opens the prompt and lists commands" do
      state = mount_with_executor!() |> press(":")

      assert state.command != nil
      text = screen_text(state)
      assert text =~ "metadata_diff"
      assert text =~ "validate_site"
    end

    test "the palette clears the background underneath" do
      state = mount_with_executor!()
      assert screen_text(state) =~ "Select an entry"

      state = press(state, ":")
      refute screen_text(state) =~ "Select an entry"
    end

    test "'?' alone does nothing; ':?' opens the command help with GUI markers" do
      state = mount_with_executor!() |> press("?")
      assert state.command == nil

      state = state |> press(":") |> press("?")
      assert state.command.help?
      text = screen_text(state)
      assert text =~ "metadata_diff"
      # Commands whose report/apply UI lives in the GUI are marked.
      assert text =~ "GUI"

      state = press(state, "esc")
      assert state.command == nil
    end

    test "typing filters and enter runs the selected command" do
      state =
        mount_with_executor!()
        |> press(":")
        |> press("m")
        |> press("e")
        |> press("t")
        |> press("a")
        |> press("enter")

      assert_receive {:executed, "metadata_diff", %{}}
      assert state.command == nil
      assert state.status =~ "done"
    end

    test "up/down move the selection" do
      _state = mount_with_executor!() |> press(":") |> press("down") |> press("enter")

      assert_receive {:executed, action, %{}}
      assert is_binary(action)
    end

    test "input that matches no command renders without errors" do
      state = mount_with_executor!() |> press(":") |> press("j")

      # Filtering down to zero commands must not blow up the render
      # (List panics on a selected index into an empty item list).
      text = screen_text(state)
      assert text =~ ":j"
    end

    test "no match reports an unknown command" do
      state =
        mount_with_executor!()
        |> press(":")
        |> press("z")
        |> press("z")
        |> press("enter")

      refute_receive {:executed, _action, _params}, 50
      assert state.command == nil
      assert state.status != nil
    end

    test "a queued task starts status polling and finishes with a toast" do
      parent = self()

      state =
        mount!(
          command_executor: fn action, _params ->
            send(parent, {:executed, action})
            {:ok, %{kind: "task_queued", title: "Rebuild", message: "queued"}}
          end
        )
        |> press(":")
        |> press("enter")

      assert_receive {:executed, _action}
      assert state.task_polling

      # No tasks are actually running in this test, so the first poll ends it.
      {:noreply, state} = BDS.TUI.handle_info(:poll_tasks, state)
      refute state.task_polling
      assert state.status != nil
    end
  end

  describe "report panels" do
    defp diff_snapshot do
      %{
        running_task_message: nil,
        tasks: [
          %{
            id: "task-diff",
            status: :completed,
            result: %{
              kind: "open_editor",
              route: "metadata_diff",
              title: "Metadata Diff",
              payload: %{
                summary: %{diff_count: 1, orphan_count: 1},
                diff_reports: [
                  %{
                    "entity_type" => "post",
                    "entity_id" => "p1",
                    "differences" => [
                      %{"name" => "title", "db_value" => "Old", "file_value" => "New"}
                    ]
                  }
                ],
                orphan_reports: [%{"file_path" => "posts/2026/07/lost.md"}]
              }
            }
          }
        ]
      }
    end

    defp validation_snapshot do
      %{
        running_task_message: nil,
        tasks: [
          %{
            id: "task-validate",
            status: :completed,
            result: %{
              kind: "open_editor",
              route: "site_validation",
              title: "Site Validation",
              payload: %{
                sitemap_path: "sitemap.xml",
                sitemap_changed: true,
                summary: %{
                  expected_count: 10,
                  existing_count: 8,
                  missing_count: 2,
                  extra_count: 1,
                  updated_count: 1
                },
                missing_url_paths: ["/2026/07/a/", "/2026/07/b/"],
                extra_url_paths: ["/stale/"],
                updated_post_url_paths: ["/2026/07/c/"],
                expected_url_count: 10,
                existing_html_url_count: 8
              }
            }
          }
        ]
      }
    end

    defp mount_for_report!(snapshot) do
      parent = self()

      state =
        mount!(
          command_executor: fn action, params ->
            send(parent, {:executed, action, params})
            {:ok, %{kind: "task_queued", title: "T", message: "queued"}}
          end,
          task_snapshot_fun: fn -> snapshot end,
          # Pre-existing completed tasks must not pop up reports, so the
          # tests hand the snapshot in only after mount via this switch.
          initial_task_snapshot: %{running_task_message: nil, tasks: []}
        )

      {:noreply, state} = BDS.TUI.handle_info(:poll_tasks, %{state | task_polling: true})
      state
    end

    test "a completed metadata diff task opens the report panel" do
      state = mount_for_report!(diff_snapshot())

      assert state.report.route == "metadata_diff"
      text = screen_text(state)
      assert text =~ "post p1"
      assert text =~ "title"
      assert text =~ "lost.md"
    end

    test "esc closes the report without applying" do
      state = mount_for_report!(diff_snapshot()) |> press("esc")

      assert state.report == nil
      refute_receive {:executed, _action, _params}, 50
    end

    test "enter repairs all metadata diffs from files and imports orphans" do
      state = mount_for_report!(diff_snapshot()) |> press("enter")

      assert state.report == nil

      assert_receive {:executed, "repair_metadata_diff", %{items: items, direction: "file_to_db"}}
      assert [%{"entity_type" => "post", "entity_id" => "p1"} | _] = items

      assert_receive {:executed, "import_metadata_diff_orphans", %{orphans: orphans}}
      assert [%{"file_path" => "posts/2026/07/lost.md"}] = orphans
    end

    test "a completed site validation task opens the report and enter applies it" do
      state = mount_for_report!(validation_snapshot())

      assert state.report.route == "site_validation"
      text = screen_text(state)
      assert text =~ "/2026/07/a/"
      assert text =~ "/stale/"

      state = press(state, "enter")
      assert state.report == nil

      assert_receive {:executed, "apply_site_validation", %{report: report}}
      assert report.missing_url_paths == ["/2026/07/a/", "/2026/07/b/"]
    end

    test "completed tasks from before mount never open a report" do
      parent = self()

      state =
        mount!(
          command_executor: fn action, params -> send(parent, {:executed, action, params}) end,
          task_snapshot_fun: fn -> diff_snapshot() end
        )

      {:noreply, state} = BDS.TUI.handle_info(:poll_tasks, %{state | task_polling: true})
      assert state.report == nil
    end
  end

  describe "projects overlay" do
    defp type(state, text) do
      text |> String.graphemes() |> Enum.reduce(state, &press(&2, &1))
    end

    defp move_to(state, index) do
      moves = index - state.projects.selected
      code = if moves >= 0, do: "down", else: "up"
      Enum.reduce(List.duplicate(code, abs(moves)), state, &press(&2, &1))
    end

    test "'p' opens the overlay listing all projects with the active one selected", %{
      project: project
    } do
      state = mount!() |> press("p")

      assert state.projects.mode == :list
      active = Enum.at(state.projects.projects, state.projects.selected)
      assert active.id == project.id

      text = screen_text(state, 140, 40)
      assert text =~ project.name
    end

    test "esc closes the overlay" do
      state = mount!() |> press("p") |> press("esc")
      assert state.projects == nil
    end

    test "enter switches the active project and reloads the sidebar", %{project: project} do
      other_dir = Path.join(System.tmp_dir!(), "bds-tui-other-#{System.unique_integer([:positive])}")
      File.mkdir_p!(other_dir)
      on_exit(fn -> File.rm_rf(other_dir) end)

      {:ok, other} = BDS.Projects.create_project(%{name: "Other Blog", data_path: other_dir})

      {:ok, _} =
        BDS.Posts.create_post(%{project_id: other.id, title: "Other Post", content: "x"})

      state = mount!() |> press("p")
      index = Enum.find_index(state.projects.projects, &(&1.id == other.id))
      state = state |> move_to(index) |> press("enter")

      assert state.projects == nil
      assert state.project_id == other.id
      assert BDS.Projects.get_active_project().id == other.id
      assert screen_text(state) =~ "Other Post"

      # switching back must not churn: selecting the active project is a no-op
      {:ok, _} = BDS.Projects.set_active_project(project.id)
    end

    test "'o' plus a valid path opens the folder as a project and queues a rebuild" do
      parent = self()

      import_dir =
        Path.join(System.tmp_dir!(), "bds-tui-import-#{System.unique_integer([:positive])}")

      File.mkdir_p!(import_dir)
      on_exit(fn -> File.rm_rf(import_dir) end)

      state =
        mount!(
          command_executor: fn action, params ->
            send(parent, {:executed, action, params})
            {:ok, %{kind: "task_queued", title: "Rebuild", message: "queued"}}
          end
        )
        |> press("p")
        |> press("o")

      assert state.projects.mode == :open

      state = state |> type(import_dir) |> press("enter")

      assert state.projects == nil
      imported = Enum.find(BDS.Projects.list_projects(), &(&1.data_path == import_dir))
      assert imported != nil
      assert BDS.Projects.get_active_project().id == imported.id
      assert state.project_id == imported.id

      assert_receive {:executed, "rebuild_database", %{}}
      assert state.task_polling
    end

    test "an invalid path keeps the prompt open and reports the error" do
      parent = self()
      count_before = length(BDS.Projects.list_projects())

      state =
        mount!(command_executor: fn action, params -> send(parent, {:executed, action, params}) end)
        |> press("p")
        |> press("o")
        |> type("/nonexistent-bds-folder-xyz")
        |> press("enter")

      assert state.projects.mode == :open
      assert state.status != nil
      assert length(BDS.Projects.list_projects()) == count_before
      refute_receive {:executed, _action, _params}, 50
    end

    test "esc in the path prompt returns to the project list" do
      state = mount!() |> press("p") |> press("o") |> press("esc")
      assert state.projects.mode == :list
    end
  end

  describe "sidebar search" do
    setup %{project: project} do
      {:ok, tagged} =
        BDS.Posts.create_post(%{
          project_id: project.id,
          title: "Tagged Post",
          content: "x",
          tags: ["elixir"],
          categories: ["news"]
        })

      {:ok, tagged: tagged}
    end

    defp item_titles(state) do
      for {:item, item} <- state.items, do: to_string(item[:title] || item[:name])
    end

    defp search(state, query) do
      state |> press("/") |> type(query)
    end

    test "'/' opens the prompt and typing filters the list live" do
      state = mount!() |> search("tagged")

      assert state.search != nil
      assert item_titles(state) == ["Tagged Post"]
      assert screen_text(state) =~ "/tagged"
    end

    test "tag: filters by tag" do
      state = mount!() |> search("tag:elixir")
      assert item_titles(state) == ["Tagged Post"]
    end

    test "category: filters by category" do
      state = mount!() |> search("category:news")
      assert item_titles(state) == ["Tagged Post"]
    end

    test "an ISO date shows the posts from that date", %{post: post} do
      on_ms =
        DateTime.new!(~D[2026-07-04], ~T[10:00:00], "Etc/UTC") |> DateTime.to_unix(:millisecond)

      BDS.Repo.update_all(
        from(p in BDS.Posts.Post, where: p.id == ^post.id),
        set: [updated_at: on_ms]
      )

      state = mount!() |> search("2026-07-04")
      assert item_titles(state) == ["Hello TUI"]
    end

    test "tokens combine: tag plus text must both match" do
      state = mount!() |> search("tag:elixir hello")
      assert item_titles(state) == []
    end

    test "enter keeps the filter and shows it in the sidebar title" do
      state = mount!() |> search("tag:elixir") |> press("enter")

      assert state.search == nil
      assert item_titles(state) == ["Tagged Post"]
      assert screen_text(state) =~ "/tag:elixir"
    end

    test "esc clears the filter and restores the full list" do
      state = mount!() |> search("tag:elixir") |> press("esc")

      assert state.search == nil
      assert "Hello TUI" in item_titles(state)
      assert "Tagged Post" in item_titles(state)
    end

    test "the filter applies per view and works for media", %{project: project} do
      media_file = Path.join(System.tmp_dir!(), "bds-tui-media-#{System.unique_integer([:positive])}.txt")
      File.write!(media_file, "media body")
      on_exit(fn -> File.rm(media_file) end)

      {:ok, _media} =
        BDS.Media.import_media(%{
          project_id: project.id,
          source_path: media_file,
          title: "Findable Media"
        })

      state = mount!() |> press("2") |> search("findable") |> press("enter")
      assert item_titles(state) == ["Findable Media"]

      # posts view keeps its own (empty) filter
      state = press(state, "1")
      assert "Hello TUI" in item_titles(state)
    end
  end

  describe "path completion" do
    setup do
      base = Path.join(System.tmp_dir!(), "bds-tui-tab-#{System.unique_integer([:positive])}")

      for dir <- ["blog-one", "blog-two", "alpha-unique", ".secret"] do
        File.mkdir_p!(Path.join(base, dir))
      end

      File.write!(Path.join(base, "blog-notes.txt"), "not a folder")
      on_exit(fn -> File.rm_rf(base) end)
      {:ok, base: base}
    end

    defp prompt!(path) do
      mount!() |> press("p") |> press("o") |> type(path)
    end

    test "tab completes a unique directory prefix with a trailing slash", %{base: base} do
      state = prompt!(Path.join(base, "alph")) |> press("tab")

      assert state.projects.input == Path.join(base, "alpha-unique") <> "/"
      assert state.projects.matches == []
    end

    test "tab completes ambiguous prefixes to the longest common prefix and lists candidates",
         %{base: base} do
      state = prompt!(Path.join(base, "bl")) |> press("tab")

      # Files are not offered — this is a folder picker.
      assert state.projects.input == Path.join(base, "blog-")
      assert state.projects.matches == ["blog-one", "blog-two"]
      assert screen_text(state, 140, 40) =~ "blog-one"
    end

    test "candidates are cleared as soon as typing continues", %{base: base} do
      state = prompt!(Path.join(base, "bl")) |> press("tab") |> press("o")
      assert state.projects.matches == []
    end

    test "hidden folders are not offered unless the prefix starts with a dot", %{base: base} do
      state = prompt!(base <> "/") |> press("tab")
      refute ".secret" in state.projects.matches

      state = prompt!(Path.join(base, ".se")) |> press("tab")
      assert state.projects.input == Path.join(base, ".secret") <> "/"
    end

    test "tab with no matches leaves the input unchanged", %{base: base} do
      input = Path.join(base, "zzz")
      state = prompt!(input) |> press("tab")

      assert state.projects.input == input
      assert state.projects.matches == []
    end

    test "a leading ~ expands to the home directory" do
      state = prompt!("~/") |> press("tab")
      assert String.starts_with?(state.projects.input, System.user_home!() <> "/")
    end
  end

  test "local tui mode stops the VM when the app exits" do
    parent = self()
    state = mount!(stop_vm_on_exit: true, stop_fun: fn -> send(parent, :vm_stopped) end)

    assert :ok = BDS.TUI.terminate(:normal, state)
    assert_receive :vm_stopped
  end

  test "ssh-served sessions never stop the VM on exit" do
    parent = self()
    state = mount!(stop_fun: fn -> send(parent, :vm_stopped) end)

    assert :ok = BDS.TUI.terminate(:normal, state)
    refute_receive :vm_stopped, 100
  end
end
