defmodule BDS.Desktop.Layouts do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={@page_language || "en"}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title><%= @page_title || "Blogging Desktop Server" %></title>
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <link phx-track-static rel="stylesheet" href="/assets/app.css" />
        <link phx-track-static rel="stylesheet" href="/assets/monaco.css" />
      </head>
      <body>
        <%= @inner_content %>
        <script defer phx-track-static src="/assets/app.js"></script>
      </body>
    </html>
    """
  end
end
