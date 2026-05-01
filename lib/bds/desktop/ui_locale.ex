defmodule BDS.Desktop.UILocale do
  @moduledoc """
  Per-render UI locale binding for the desktop LiveView shell.

  The shell renders the UI in the user's selected language, which can differ
  from the OS locale and from the project's `mainLanguage`. Phoenix HEEx
  templates call `translated/1,2` helpers without an explicit locale, so we
  bind the active locale once per `render/1` and the helpers read it back.

  This module encapsulates that binding so call sites do not touch the raw
  process dictionary directly. Use `with_locale/2` around any render or
  component that needs a locale binding; use `current/0` to read it.

  Direct use of `Process.put(:bds_ui_locale, _)` or
  `Process.get(:bds_ui_locale)` is forbidden outside this module.
  """

  @key :bds_ui_locale

  @typedoc "A normalized UI locale code such as `\"en\"` or `\"de\"`."
  @type locale :: String.t() | nil

  @doc """
  Bind `locale` for any subsequent reads of `current/0` in this process.

  Used at LiveView render boundaries. The binding persists past the call
  (mirroring per-process locale state) so that lazily evaluated child
  components see the active locale. Each render boundary overwrites it.
  """
  @spec put(locale()) :: :ok
  def put(locale) do
    Process.put(@key, locale)
    :ok
  end

  @doc """
  Set the UI locale for the duration of `fun`, then restore the prior value.

  Safe under exceptions: the prior binding is restored in an `after` clause.
  Use this for short-lived non-LiveView contexts (background tasks, scripts)
  where eager evaluation guarantees the binding is consumed before `fun`
  returns. Do not use around LiveView `render/1` because the returned
  `Phoenix.LiveView.Rendered` struct evaluates its dynamic parts lazily.
  """
  @spec with_locale(locale(), (-> result)) :: result when result: var
  def with_locale(locale, fun) when is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, locale)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc """
  Read the active UI locale binding for this process, or `nil` when unset.
  """
  @spec current() :: locale()
  def current, do: Process.get(@key)

  defp restore(nil), do: Process.delete(@key)
  defp restore(value), do: Process.put(@key, value)
end
