defmodule BDS.Desktop do
  @moduledoc false

  def url do
    BDS.Desktop.Server.port()
    |> url()
  end

  def url(port) when is_integer(port) do
    "http://127.0.0.1:#{port}/"
  end
end
