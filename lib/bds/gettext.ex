defmodule BDS.Gettext do
  @moduledoc """
  Gettext backend for bDS2.

  Two domains are used:
    - "ui"     : application chrome, menus, settings, dashboard, toasts
    - "render" : blog output (Liquid templates, archive labels, pagination, etc.)

  The UI locale is managed per-process via `put_locale/1`.
  The render locale is passed explicitly via `lgettext/4` so that a single
  process can resolve UI strings in the OS language and render strings in
  the project's mainLanguage simultaneously.
  """

  use Gettext.Backend, otp_app: :bds

  @doc """
  Convenience wrapper around `lgettext/4` with empty bindings.

  Returns the resolved string directly (not a tuple).
  """
  def lgettext(locale, domain, msgid) do
    case lgettext(locale, domain, msgid, %{}) do
      {:ok, text} -> text
      {:default, text} -> text
    end
  end

  @doc """
  Sets the locale for this backend in the current process.
  """
  def put_locale(locale) do
    Gettext.put_locale(__MODULE__, locale)
  end

  @doc """
  Gets the locale for this backend in the current process.
  """
  def get_locale do
    Gettext.get_locale(__MODULE__)
  end
end
