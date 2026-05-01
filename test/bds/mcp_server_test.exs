defmodule BDS.MCPServerTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-mcp-server-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "MCP Server", data_path: temp_dir})
    {:ok, _active} = BDS.Projects.set_active_project(project.id)

    %{project: project, temp_dir: temp_dir}
  end

  test "HTTP MCP server binds localhost, answers initialize, and exposes tool capabilities" do
    :inets.start()

    assert {:ok, server} = BDS.MCP.Server.start(0)
    assert server.host == "127.0.0.1"
    assert server.port > 0

    initialize_body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-03-26",
          capabilities: %{},
          clientInfo: %{name: "test-client", version: "1.0.0"}
        }
      })

    assert {:ok, {{_version, 200, _reason}, headers, body}} =
             :httpc.request(
               :post,
               {to_charlist("http://127.0.0.1:#{server.port}/mcp"),
                [{~c"content-type", ~c"application/json"}], ~c"application/json",
                initialize_body},
               [],
               body_format: :binary
             )

    assert Enum.any?(headers, fn {name, value} ->
             String.downcase(to_string(name)) == "access-control-allow-methods" and
               to_string(value) =~ "POST"
           end)

    decoded = Jason.decode!(body)
    assert decoded["result"]["serverInfo"]["name"] == "Blogging Desktop Server"
    assert decoded["result"]["capabilities"]["tools"] == %{}

    assert :ok = BDS.MCP.Server.stop()
  end

  test "HTTP MCP server rejects non-local origins and can list tools" do
    :inets.start()
    assert {:ok, server} = BDS.MCP.Server.start(0)

    initialize_body =
      Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})

    assert {:ok, {{_version, 403, _reason}, _headers, _body}} =
             :httpc.request(
               :post,
               {to_charlist("http://127.0.0.1:#{server.port}/mcp"),
                [
                  {~c"content-type", ~c"application/json"},
                  {~c"origin", ~c"https://evil.example"}
                ], ~c"application/json", initialize_body},
               [],
               body_format: :binary
             )

    tools_body = Jason.encode!(%{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}})

    assert {:ok, {{_version, 200, _reason}, _headers, body}} =
             :httpc.request(
               :post,
               {to_charlist("http://127.0.0.1:#{server.port}/mcp"),
                [{~c"content-type", ~c"application/json"}], ~c"application/json", tools_body},
               [],
               body_format: :binary
             )

    decoded = Jason.decode!(body)
    tool_names = Enum.map(decoded["result"]["tools"], & &1["name"])
    assert "check_term" in tool_names
    assert "draft_post" in tool_names

    assert :ok = BDS.MCP.Server.stop()
  end

  test "HTTP MCP server returns media image resources as blob contents", %{
    project: project,
    temp_dir: temp_dir
  } do
    :inets.start()

    source_path = Path.join(temp_dir, "server-image.png")
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, "server-bytes">>
    File.write!(source_path, image_bytes)

    assert {:ok, media} =
             BDS.Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Server Image"
             })

    assert {:ok, server} = BDS.MCP.Server.start(0)

    read_body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 3,
        method: "resources/read",
        params: %{uri: "bds://media/#{media.id}/image"}
      })

    assert {:ok, {{_version, 200, _reason}, _headers, body}} =
             :httpc.request(
               :post,
               {to_charlist("http://127.0.0.1:#{server.port}/mcp"),
                [{~c"content-type", ~c"application/json"}], ~c"application/json", read_body},
               [],
               body_format: :binary
             )

    decoded = Jason.decode!(body)
    assert [content] = decoded["result"]["contents"]
    assert content["uri"] == "bds://media/#{media.id}/image"
    assert content["mimeType"] == "image/png"
    assert Base.decode64!(content["blob"]) == image_bytes
    refute Map.has_key?(content, "text")

    assert :ok = BDS.MCP.Server.stop()
  end
end
