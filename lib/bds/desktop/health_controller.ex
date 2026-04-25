defmodule BDS.Desktop.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  def show(conn, _params) do
    text(conn, "ok")
  end
end
