defmodule BDS.CSM017ComponentChatterTest do
  use ExUnit.Case, async: true

  @editor_files [
    "lib/bds/desktop/shell_live/post_editor.ex",
    "lib/bds/desktop/shell_live/media_editor.ex",
    "lib/bds/desktop/shell_live/template_editor.ex",
    "lib/bds/desktop/shell_live/script_editor.ex",
    "lib/bds/desktop/shell_live/chat_editor.ex",
    "lib/bds/desktop/shell_live/settings_editor.ex",
    "lib/bds/desktop/shell_live/menu_editor.ex",
    "lib/bds/desktop/shell_live/tags_editor.ex",
    "lib/bds/desktop/shell_live/misc_editor.ex",
    "lib/bds/desktop/shell_live/import_editor.ex",
    "lib/bds/desktop/shell_live/overlay_manager.ex"
  ]

  describe "no direct send(self(), ...) in editor components" do
    for file <- @editor_files do
      test "#{Path.basename(file)} uses Notify instead of send(self(), ...)" do
        path = Path.join(File.cwd!(), unquote(file))
        content = File.read!(path)

        lines =
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _num} ->
            String.contains?(line, "send(self(),") and
              not String.contains?(line, "Process.send_after") and
              not String.contains?(line, "# send(self()")
          end)

        assert lines == [],
               "#{unquote(file)} still has direct send(self(), ...) calls at lines: #{inspect(Enum.map(lines, &elem(&1, 1)))}"
      end
    end
  end

  describe "Notify module is the single point of parent communication" do
    test "all send(self(), ...) calls in shell_live/ are in notify.ex" do
      shell_live_dir = Path.join(File.cwd!(), "lib/bds/desktop/shell_live")

      send_self_files =
        Path.wildcard(Path.join(shell_live_dir, "*.ex"))
        |> Enum.filter(fn path ->
          content = File.read!(path)
          basename = Path.basename(path)

          String.contains?(content, "send(self(),") and
            not String.contains?(content, "Process.send_after(self(),") and
            basename != "notify.ex" and
            basename != "bridges.ex"
        end)
        |> Enum.reject(fn path ->
          content = File.read!(path)

          lines =
            content
            |> String.split("\n")
            |> Enum.filter(fn line ->
              String.contains?(line, "send(self(),") and
                not String.contains?(line, "Process.send_after")
            end)

          Enum.empty?(lines)
        end)
        |> Enum.map(&Path.basename/1)

      assert send_self_files == [],
             "These files still have direct send(self(), ...) calls: #{inspect(send_self_files)}"
    end
  end

  describe "Bridges handles generic message types" do
    test "no editor-specific output handlers remain in Bridges" do
      bridges_path = Path.join(File.cwd!(), "lib/bds/desktop/shell_live/bridges.ex")
      content = File.read!(bridges_path)

      old_patterns = [
        ":import_editor_output",
        ":chat_editor_output",
        ":tags_editor_output",
        ":settings_output",
        ":menu_editor_output",
        ":script_editor_output",
        ":template_editor_output",
        ":misc_editor_output",
        ":post_editor_output",
        ":media_editor_output",
        ":post_editor_dirty",
        ":media_editor_dirty",
        ":post_editor_tab_meta",
        ":media_editor_tab_meta",
        ":import_editor_tab_meta",
        ":chat_editor_tab_meta",
        ":misc_editor_tab_meta",
        ":misc_editor_command"
      ]

      remaining =
        Enum.filter(old_patterns, fn pattern ->
          String.contains?(content, pattern)
        end)

      assert remaining == [],
             "Bridges still contains editor-specific handlers: #{inspect(remaining)}"
    end

    test "Bridges has generic editor_output handler" do
      bridges_path = Path.join(File.cwd!(), "lib/bds/desktop/shell_live/bridges.ex")
      content = File.read!(bridges_path)

      assert String.contains?(content, ":editor_output")
      assert String.contains?(content, ":editor_tab_meta")
      assert String.contains?(content, ":editor_dirty")
      assert String.contains?(content, ":editor_command")
    end
  end

  describe "Notify module API" do
    test "output/3 sends {:editor_output, ...} message" do
      BDS.Desktop.ShellLive.Notify.output("Title", "Message", "info")
      assert_received {:editor_output, "Title", "Message", nil, "info"}
    end

    test "output/4 sends {:editor_output, ...} with detail" do
      BDS.Desktop.ShellLive.Notify.output("Title", "Msg", "detail", "warning")
      assert_received {:editor_output, "Title", "Msg", "detail", "warning"}
    end

    test "tab_meta/4 sends {:editor_tab_meta, ...}" do
      BDS.Desktop.ShellLive.Notify.tab_meta(:post, "abc", "Title", "Subtitle")
      assert_received {:editor_tab_meta, :post, "abc", %{title: "Title", subtitle: "Subtitle"}}
    end

    test "tab_meta_merge/3 sends {:editor_tab_meta, ...} with arbitrary updates" do
      BDS.Desktop.ShellLive.Notify.tab_meta_merge(:misc, "id", %{title: "T"})
      assert_received {:editor_tab_meta, :misc, "id", %{title: "T"}}
    end

    test "close_tab/2 sends {:close_tab, ...}" do
      BDS.Desktop.ShellLive.Notify.close_tab(:templates, "t1")
      assert_received {:close_tab, :templates, "t1"}
    end

    test "reload/0 sends :reload_shell" do
      BDS.Desktop.ShellLive.Notify.reload()
      assert_received :reload_shell
    end

    test "dirty/3 sends {:editor_dirty, ...}" do
      BDS.Desktop.ShellLive.Notify.dirty(:post, "p1", true)
      assert_received {:editor_dirty, :post, "p1", true}
    end

    test "command/2 sends {:editor_command, ...}" do
      BDS.Desktop.ShellLive.Notify.command(:generate, %{force: true})
      assert_received {:editor_command, :generate, %{force: true}}
    end

    test "open_sidebar_item/2 sends {:open_sidebar_item, ...}" do
      BDS.Desktop.ShellLive.Notify.open_sidebar_item(%{"route" => "post"}, :pin)
      assert_received {:open_sidebar_item, %{"route" => "post"}, :pin}
    end

    test "parent/1 sends arbitrary message" do
      BDS.Desktop.ShellLive.Notify.parent({:custom, :message})
      assert_received {:custom, :message}
    end
  end
end
