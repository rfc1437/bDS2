defmodule BDS.Desktop.ShellLive.Notify do
  @moduledoc """
  Standardized parent notification API for LiveComponent editors.

  Instead of each editor defining its own `notify_parent/1` and sending
  editor-specific message atoms (e.g. `{:post_editor_output, ...}`),
  all editors call functions from this module, which sends generic
  messages that Bridges handles with a single clause per action type.
  """

  @spec output(String.t(), String.t(), String.t()) :: :ok
  def output(title, message, level) do
    send(self(), {:editor_output, title, message, nil, level})
    :ok
  end

  @spec output(String.t(), String.t(), String.t() | nil, String.t()) :: :ok
  def output(title, message, detail, level) do
    send(self(), {:editor_output, title, message, detail, level})
    :ok
  end

  @spec tab_meta(atom(), term(), String.t(), String.t()) :: :ok
  def tab_meta(type, id, title, subtitle) do
    send(self(), {:editor_tab_meta, type, id, %{title: title, subtitle: subtitle || ""}})
    :ok
  end

  @spec tab_meta_merge(atom(), term(), map()) :: :ok
  def tab_meta_merge(type, id, updates) when is_map(updates) do
    send(self(), {:editor_tab_meta, type, id, updates})
    :ok
  end

  @spec close_tab(atom(), term()) :: :ok
  def close_tab(type, id) do
    send(self(), {:close_tab, type, id})
    :ok
  end

  @spec reload :: :ok
  def reload do
    send(self(), :reload_shell)
    :ok
  end

  @spec dirty(atom(), term(), boolean()) :: :ok
  def dirty(type, id, dirty?) do
    send(self(), {:editor_dirty, type, id, dirty?})
    :ok
  end

  @spec command(atom() | String.t(), map()) :: :ok
  def command(action, params \\ %{}) do
    send(self(), {:editor_command, action, params})
    :ok
  end

  @spec open_sidebar_item(map(), atom() | nil) :: :ok
  def open_sidebar_item(params, intent \\ nil) do
    send(self(), {:open_sidebar_item, params, intent})
    :ok
  end

  @spec parent(term()) :: :ok
  def parent(message) do
    send(self(), message)
    :ok
  end
end
