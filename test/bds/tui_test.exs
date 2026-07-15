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

  defp key(code, modifiers \\ []), do: %Key{code: code, kind: "press", modifiers: modifiers}

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
        command_executor: fn action ->
          send(parent, {:executed, action})
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

    test "'?' opens the command help list with GUI markers" do
      state = mount_with_executor!() |> press("?")

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

      assert_receive {:executed, "metadata_diff"}
      assert state.command == nil
      assert state.status =~ "done"
    end

    test "up/down move the selection" do
      state = mount_with_executor!() |> press(":") |> press("down") |> press("enter")

      assert_receive {:executed, action}
      assert is_binary(action)
    end

    test "no match reports an unknown command" do
      state =
        mount_with_executor!()
        |> press(":")
        |> press("z")
        |> press("z")
        |> press("enter")

      refute_receive {:executed, _action}, 50
      assert state.command == nil
      assert state.status != nil
    end

    test "a queued task starts status polling and finishes with a toast" do
      parent = self()

      state =
        mount!(
          command_executor: fn action ->
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
