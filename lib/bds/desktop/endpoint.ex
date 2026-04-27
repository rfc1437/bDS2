defmodule BDS.Desktop.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :bds

  @session_options [
    store: :cookie,
    key: "_bds_desktop_key",
    signing_salt: "desktop-shell"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options
  plug :maybe_require_desktop_auth

  plug Plug.Static,
    at: "/assets",
    from: {:bds, "priv/ui"},
    only: ["app.css", "live.js", "monaco"]

  plug Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ["phoenix.min.js"]

  plug Plug.Static,
    at: "/vendor/live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ["phoenix_live_view.min.js"]

  plug BDS.Desktop.Router

  defp maybe_require_desktop_auth(conn, _opts) do
    if System.get_env("BDS_DESKTOP_AUTOMATION") in ["1", "true", "TRUE"] do
      conn
    else
      Desktop.Auth.call(conn, [])
    end
  end
end
