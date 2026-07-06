defmodule BDS.Desktop.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BDS.Desktop.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", BDS.Desktop do
    pipe_through(:browser)

    get("/health", HealthController, :show)
    get("/media-thumbnail/:media_id", MediaController, :thumbnail)
    get("/media-file/:media_id", MediaController, :file)

    live_session :desktop_shell,
      root_layout: {BDS.Desktop.Layouts, :root} do
      live("/", ShellLive, :index)
    end
  end
end
