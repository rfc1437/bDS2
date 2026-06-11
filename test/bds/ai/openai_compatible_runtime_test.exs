defmodule BDS.AI.OpenAICompatibleRuntimeTest do
  use ExUnit.Case, async: false

  alias BDS.AI.HttpClient
  alias BDS.AI.OpenAICompatibleRuntime

  defmodule SlowPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      Process.sleep(1_000)
      send_resp(conn, 200, ~s({"choices":[],"data":[]}))
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    original_config = Application.fetch_env(:bds, HttpClient)

    Application.put_env(:bds, HttpClient,
      receive_timeout_ms: 100,
      get_max_retries: 0,
      retry_delay_ms: 10
    )

    on_exit(fn ->
      case original_config do
        {:ok, value} -> Application.put_env(:bds, HttpClient, value)
        :error -> Application.delete_env(:bds, HttpClient)
      end
    end)

    server = start_supervised!({Bandit, plug: SlowPlug, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, url: "http://127.0.0.1:#{port}/v1"}
  end

  test "generate returns a structured timeout error within the configured budget", %{url: url} do
    endpoint = %{url: url, api_key: "sk-test"}

    request = %{
      operation: :chat,
      model: "gpt-test",
      max_output_tokens: 16,
      messages: [%{"role" => "user", "content" => "hello"}]
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %{kind: :http_error, reason: :timeout}} =
             OpenAICompatibleRuntime.generate(endpoint, request, [])

    assert System.monotonic_time(:millisecond) - started_at < 2_000
  end

  test "list_models returns a structured timeout error within the configured budget", %{url: url} do
    endpoint = %{url: url, api_key: "sk-test"}

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %{kind: :http_error, reason: :timeout}} =
             OpenAICompatibleRuntime.list_models(endpoint)

    assert System.monotonic_time(:millisecond) - started_at < 2_000
  end
end
