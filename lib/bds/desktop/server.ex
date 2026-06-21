defmodule BDS.Desktop.Server do
  @moduledoc false

  def child_spec(opts) do
    Supervisor.child_spec(
      {Bandit,
       Keyword.merge(opts,
         plug: BDS.Desktop.Endpoint,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: port(),
         startup_log: false
       )},
      id: __MODULE__
    )
  end

  def url do
    BDS.Desktop.url(port())
  end

  def port do
    case System.get_env("BDS_DESKTOP_PORT") do
      value when is_binary(value) -> String.to_integer(value)
      _other -> Application.get_env(:bds, :desktop)[:port] || 4010
    end
  end
end
