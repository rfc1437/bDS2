defmodule BDS.AI.HttpClientTest do
  use ExUnit.Case, async: false

  alias BDS.AI.HttpClient

  defmodule TestPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{path_info: ["ok"]} = conn, _opts) do
      conn
      |> put_resp_header("x-test-header", "Value-1")
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"hello":"world"}))
    end

    def call(%Plug.Conn{path_info: ["echo"], method: "POST"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid(), {:echo_request, conn.req_headers, body})
      send_resp(conn, 200, body)
    end

    def call(%Plug.Conn{path_info: ["slow"]} = conn, _opts) do
      Process.sleep(1_000)
      send_resp(conn, 200, "late")
    end

    def call(%Plug.Conn{path_info: ["flaky-get"]} = conn, _opts) do
      send(test_pid(), :flaky_hit)

      if :ets.update_counter(:bds_http_client_test, :flaky_get, 1) == 1 do
        send_resp(conn, 500, "boom")
      else
        send_resp(conn, 200, "recovered")
      end
    end

    def call(%Plug.Conn{path_info: ["fail-post"], method: "POST"} = conn, _opts) do
      send(test_pid(), :post_hit)
      send_resp(conn, 500, "boom")
    end

    defp test_pid, do: Application.get_env(:bds, :http_client_test_pid)
  end

  setup do
    if :ets.whereis(:bds_http_client_test) == :undefined do
      :ets.new(:bds_http_client_test, [:named_table, :public, :set])
    end

    :ets.insert(:bds_http_client_test, {:flaky_get, 0})
    Application.put_env(:bds, :http_client_test_pid, self())

    original_config = Application.fetch_env(:bds, HttpClient)

    # Fast retries so retry tests don't slow the suite down.
    Application.put_env(:bds, HttpClient, retry_delay_ms: 10)

    on_exit(fn ->
      case original_config do
        {:ok, value} -> Application.put_env(:bds, HttpClient, value)
        :error -> Application.delete_env(:bds, HttpClient)
      end
    end)

    server = start_supervised!({Bandit, plug: TestPlug, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok, base_url: "http://127.0.0.1:#{port}"}
  end

  defp put_config(extra) do
    Application.put_env(:bds, HttpClient, Keyword.merge([retry_delay_ms: 10], extra))
  end

  test "GET returns status, body, and downcased single-valued headers", %{base_url: base_url} do
    assert {:ok, response} = HttpClient.get(base_url <> "/ok", %{"accept" => "application/json"})

    assert response.status == 200
    assert response.body == ~s({"hello":"world"})
    assert response.headers["x-test-header"] == "Value-1"
    assert response.headers["content-type"] =~ "application/json"
    refute Map.has_key?(response.headers, "X-Test-Header")
  end

  test "POST sends the raw body and headers and returns the raw response body", %{
    base_url: base_url
  } do
    payload = ~s({"model":"gpt-test"})

    assert {:ok, response} =
             HttpClient.post(
               base_url <> "/echo",
               %{"content-type" => "application/json", "authorization" => "Bearer sk-123"},
               payload
             )

    assert response.status == 200
    assert response.body == payload

    assert_received {:echo_request, req_headers, ^payload}
    assert {"authorization", "Bearer sk-123"} in req_headers
    assert {"content-type", "application/json"} in req_headers
  end

  test "a hung endpoint times out within the configured budget", %{base_url: base_url} do
    put_config(receive_timeout_ms: 100, get_max_retries: 0)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = HttpClient.post(base_url <> "/slow", %{}, "{}")
    assert {:error, :timeout} = HttpClient.get(base_url <> "/slow", %{})
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 2_000
  end

  test "a refused connection returns an error instead of raising" do
    put_config(get_max_retries: 0)

    # An ephemeral port nothing listens on.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    assert {:error, :econnrefused} = HttpClient.get("http://127.0.0.1:#{port}/ok", %{})
  end

  test "GET retries transient server errors", %{base_url: base_url} do
    assert {:ok, %{status: 200, body: "recovered"}} =
             HttpClient.get(base_url <> "/flaky-get", %{})

    assert_received :flaky_hit
    assert_received :flaky_hit
  end

  test "POST is never retried, even on transient server errors", %{base_url: base_url} do
    assert {:ok, %{status: 500, body: "boom"}} =
             HttpClient.post(base_url <> "/fail-post", %{}, "{}")

    assert_received :post_hit
    refute_received :post_hit
  end
end
