defmodule BDS.Desktop.Router do
  @moduledoc false

  use Plug.Router

  plug :put_secret_key_base

  plug Plug.Session,
    store: :cookie,
    key: "_bds_desktop_key",
    signing_salt: "desktop-shell"

  plug :match
  plug :maybe_require_desktop_auth

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

  get "/api/tasks" do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.task_status_json())
  end

  get "/api/projects" do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.projects_json())
  end

  get "/api/media-thumbnail/:media_id" do
    BDS.Desktop.ShellController.media_thumbnail(conn, media_id, conn.params)
  end

  post "/api/sidebar" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = if body == "", do: %{}, else: Jason.decode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.sidebar_json(payload))
  end

  post "/api/projects" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = if body == "", do: %{}, else: Jason.decode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.upsert_project_json(payload))
  end

  post "/api/project-folder" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = if body == "", do: %{}, else: Jason.decode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.choose_project_folder_json(payload))
  end

  post "/api/commands" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    payload = if body == "", do: %{}, else: Jason.decode!(body)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, BDS.Desktop.ShellController.command_json(payload))
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

  defp maybe_require_desktop_auth(conn, _opts) do
    if System.get_env("BDS_DESKTOP_AUTOMATION") in ["1", "true", "TRUE"] do
      conn
    else
      Desktop.Auth.call(conn, [])
    end
  end
end
