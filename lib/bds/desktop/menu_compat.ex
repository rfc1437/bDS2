defmodule BDS.Desktop.MenuCompat do
  @moduledoc false

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Module.register_attribute(__MODULE__, :is_menu_server, persist: true, accumulate: false)
      Module.put_attribute(__MODULE__, :is_menu_server, Keyword.get(opts, :server, true))

      @behaviour Desktop.Menu
      import Desktop.Menu, only: [assign: 2, connected?: 1]
      import Phoenix.LiveView.Helpers, only: [sigil_L: 2]
      import Phoenix.Component, only: [sigil_H: 2]
      alias Desktop.Menu

      @before_compile Desktop.Menu
    end
  end
end