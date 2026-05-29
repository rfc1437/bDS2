defmodule BDS.Scripting.Capabilities.AppShell do
  @moduledoc false

  import BDS.Scripting.Capabilities.Util

  alias BDS.Desktop.FolderPicker
  alias BDS.Desktop.MenuBar

  @compiled_env Application.compile_env(:bds, :current_env, Mix.env())

  def copy_to_clipboard(text, opts) do
    case Keyword.get(opts, :copy_to_clipboard) do
      callback when is_function(callback, 1) -> callback.(string_or_nil(text) || "")
      _other -> do_copy_to_clipboard(text)
    end
  end

  defp do_copy_to_clipboard(text) do
    if test_mode?() do
      true
    else
      command = string_or_nil(text)

      case :os.type() do
        {:unix, :darwin} ->
          match?({_output, 0}, System.cmd("pbcopy", [], input: command, stderr_to_stdout: true))

        {:unix, _other} ->
          match?(
            {_output, 0},
            System.cmd("xclip", ["-selection", "clipboard"],
              input: command,
              stderr_to_stdout: true
            )
          )

        {:win32, _other} ->
          match?(
            {_output, 0},
            System.cmd("cmd", ["/c", "clip"], input: command, stderr_to_stdout: true)
          )
      end
    end
  rescue
    _error -> false
  end

  def blogmark_bookmarklet do
    "javascript:(()=>{const t=encodeURIComponent(document.title||'');const u=encodeURIComponent(location.href||'');location.href='bds2://new-post?title='+t+'&url='+u;})();"
  end

  def title_bar_metrics(opts) do
    case Keyword.get(opts, :title_bar_metrics) do
      callback when is_function(callback, 0) -> callback.()
      _other -> do_title_bar_metrics()
    end
  end

  defp do_title_bar_metrics do
    case :os.type() do
      {:unix, :darwin} -> %{macos_left_inset: 72}
      _other -> nil
    end
  end

  def notify_renderer_ready(opts) do
    case Keyword.get(opts, :notify_renderer_ready) do
      callback when is_function(callback, 0) -> callback.()
      _other -> true
    end
  end

  def open_folder(folder_path, opts) do
    case Keyword.get(opts, :open_folder) do
      callback when is_function(callback, 1) -> callback.(string_or_nil(folder_path))
      _other -> do_open_folder(folder_path)
    end
  end

  defp do_open_folder(folder_path) do
    if test_mode?() do
      ""
    else
      case shell_open_system_path(string_or_nil(folder_path)) do
        :ok -> ""
        {:error, reason} -> inspect(reason)
      end
    end
  end

  def select_folder(title, opts) do
    case Keyword.get(opts, :select_folder) do
      callback when is_function(callback, 1) -> callback.(string_or_nil(title) || "Select Folder")
      _other -> do_select_folder(title)
    end
  end

  defp do_select_folder(title) do
    if test_mode?() do
      nil
    else
      case FolderPicker.choose_directory(string_or_nil(title) || "Select Folder") do
        {:ok, path} -> path
        :cancel -> nil
        {:error, _reason} -> nil
      end
    end
  end

  def set_preview_post_target(post_id) do
    :persistent_term.put(
      {BDS.Scripting.Capabilities, :preview_post_target},
      string_or_nil(post_id)
    )

    true
  end

  def show_item_in_folder(item_path, opts) do
    callback = Keyword.get(opts, :show_item_in_folder)

    cond do
      is_function(callback, 1) -> callback.(string_or_nil(item_path))
      test_mode?() -> :ok
      true -> _ = shell_reveal_system_path(string_or_nil(item_path))
    end

    nil
  end

  def trigger_menu_action(action, opts) do
    callback = Keyword.get(opts, :trigger_menu_action)

    cond do
      is_function(callback, 1) -> callback.(string_or_nil(action))
      test_mode?() -> :ok
      true -> _ = MenuBar.handle_event(string_or_nil(action), nil)
    end

    nil
  rescue
    _error -> nil
  end

  def test_mode? do
    Application.get_env(:bds, :test_mode, false) or current_env() == :test
  end

  def current_env do
    Application.get_env(:bds, :current_env_override) || @compiled_env
  end
end
