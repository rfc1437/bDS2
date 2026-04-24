defmodule BDS.Desktop.Router do
  @moduledoc false

  use Plug.Router

  plug :put_secret_key_base

  plug Plug.Session,
    store: :cookie,
    key: "_bds_desktop_key",
    signing_salt: "desktop-shell"

  plug :match
  plug Desktop.Auth

  plug Plug.Static,
    at: "/assets",
    from: {:bds, "priv/ui"},
    only: ["app.css", "app.js"]

  plug :dispatch

  get "/" do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.index_html())
  end

  get "/health" do
    Plug.Conn.send_resp(conn, 200, "ok")
  end

  match _ do
    Plug.Conn.send_resp(conn, 404, "not found")
  end

  defp put_secret_key_base(conn, _opts) do
    if conn.secret_key_base do
      conn
    else
      %{conn | secret_key_base: desktop_secret_key_base()}
    end
  end

  defp desktop_secret_key_base do
    Application.get_env(:bds, :desktop)[:secret_key_base] ||
      raise "missing :desktop secret_key_base configuration"
  end
end
