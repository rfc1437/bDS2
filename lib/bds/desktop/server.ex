defmodule BDS.Desktop.Server do
  @moduledoc false

  use GenServer

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  @impl true
  def init(_opts) do
    {:ok, bandit_pid} =
      Bandit.start_link(
        plug: BDS.Desktop.Router,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port(),
        startup_log: false
      )

    {:ok, %{bandit_pid: bandit_pid}}
  end
end
