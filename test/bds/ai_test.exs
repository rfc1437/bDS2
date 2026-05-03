defmodule BDS.AITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query
  require Logger

  alias BDS.Media.Media
  alias BDS.Persistence
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Settings.Setting

  defmodule FakeSecretBackend do
    def encrypt(value), do: {:ok, "enc:" <> value}

    def decrypt("enc:" <> value), do: {:ok, value}
    def decrypt(_other), do: {:error, :invalid_ciphertext}
  end

  defmodule FakeHttpClient do
    def get("https://models.dev/api.json", headers) do
      send(self(), {:http_headers, headers})

      if Map.has_key?(headers, "if-none-match") do
        {:ok, %{status: 304, headers: %{"etag" => headers["if-none-match"]}, body: ""}}
      else
        {:ok,
         %{
           status: 200,
           headers: %{"etag" => "W/\"catalog-v1\""},
           body: Jason.encode!(sample_catalog())
         }}
      end
    end

    def sample_catalog do
      %{
        "openai" => %{
          "name" => "OpenAI",
          "env" => ["OPENAI_API_KEY"],
          "api" => "https://api.openai.com/v1",
          "doc" => "https://platform.openai.com/docs",
          "models" => %{
            "gpt-4o-mini" => %{
              "name" => "GPT-4o mini",
              "family" => "gpt-4o",
              "attachment" => false,
              "reasoning" => false,
              "tool_call" => true,
              "structured_output" => true,
              "temperature" => true,
              "open_weights" => false,
              "cost" => %{"input" => 15, "output" => 60, "cache_read" => 5, "cache_write" => 10},
              "limit" => %{"context" => 128_000, "input" => 128_000, "output" => 16_384},
              "input_modalities" => ["text"],
              "output_modalities" => ["text"]
            },
            "gpt-4o" => %{
              "name" => "GPT-4o",
              "family" => "gpt-4o",
              "attachment" => true,
              "reasoning" => false,
              "tool_call" => true,
              "structured_output" => true,
              "temperature" => true,
              "open_weights" => false,
              "cost" => %{"input" => 250, "output" => 1000},
              "limit" => %{"context" => 128_000, "input" => 128_000, "output" => 16_384},
              "input_modalities" => ["text", "image"],
              "output_modalities" => ["text"]
            }
          }
        }
      }
    end
  end

  defmodule FakeEndpointHttpClient do
    def get("https://api.example.test/v1/models", _headers) do
      {:ok,
       %{
         status: 200,
         headers: %{},
         body: Jason.encode!(%{"data" => [%{"id" => "gpt-4.1"}, %{"id" => "gpt-4.1-mini"}]})
       }}
    end

    def get(_url, _headers), do: {:error, :not_found}
  end

  defmodule BadJsonEndpointHttpClient do
    def get("https://api.example.test/v1/models", _headers) do
      {:ok, %{status: 200, headers: %{}, body: "not json"}}
    end
  end

  defmodule BadJsonCompletionServer do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "not json")
    end
  end

  defmodule RecordingCompletionServer do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(Application.fetch_env!(:bds, :test_pid), {:completion_payload, Jason.decode!(body)})

      response = %{
        "choices" => [%{"message" => %{"content" => "Short Title"}}],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  defmodule ErrorCompletionServer do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(Application.fetch_env!(:bds, :test_pid), {:error_payload, Jason.decode!(body)})

      response = %{
        "error" => %{
          "message" => "Invalid image data",
          "type" => "invalid_request_error"
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(response))
    end
  end

  defmodule NonJsonContentServer do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/v1/chat/completions" do
      response = %{
        "choices" => [%{"message" => %{"content" => "This is not valid JSON"}}],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  defmodule FakeRuntime do
    def generate(endpoint, request, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runtime_request, endpoint, request})

      case request.operation do
        :detect_language ->
          {:ok, %{json: %{"language_code" => "fr"}, usage: usage(11, 3, 0, 0)}}

        :translate_post ->
          {:ok,
           %{
             json: %{
               "title" => "Hallo Welt",
               "excerpt" => "Kurze Zusammenfassung",
               "content" => "# Hallo Welt\n\nUbersetzter Inhalt"
             },
             usage: usage(22, 14, 0, 0)
           }}

        :analyze_post ->
          {:ok,
           %{
             json: %{
               "title" => "Analyzed " <> (get_in(request.messages, [Access.at(1), "content"]) || ""),
               "excerpt" => "Analyzed excerpt",
               "slug" => "analyzed-slug"
             },
             usage: usage(15, 10, 0, 0)
           }}

        :analyze_image ->
          {:ok,
           %{
             json: %{
               "title" => "Sunset",
               "alt" => "Orange sunset over calm water",
               "caption" => "Evening light over the bay"
             },
             usage: usage(13, 9, 0, 0)
           }}

        :import_taxonomy_mapping ->
          {:ok,
           %{
             json: %{
               "categoryMappings" => %{"General" => "article", "Unknown" => "missing"},
               "tagMappings" => %{"News" => "updates", "Ghost" => "missing"}
             },
             usage: usage(19, 7, 0, 0)
           }}

        :chat ->
          if Enum.any?(request.messages, &(&1["role"] == "tool")) do
            {:ok,
             %{
               content: "You currently have 1 post and 1 media item.",
               usage: usage(64, 21, 3, 1)
             }}
          else
            {:ok,
             %{
               tool_calls: [
                 %{
                   id: "call-blog-stats",
                   name: "blog_stats",
                   arguments: %{}
                 }
               ],
               usage: usage(31, 8, 0, 0)
             }}
          end

        :chat_title ->
          {:ok, %{content: "Blog Stats", usage: usage(12, 3, 0, 0)}}
      end
    end

    defp usage(input_tokens, output_tokens, cache_read_tokens, cache_write_tokens) do
      %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cache_read_tokens: cache_read_tokens,
        cache_write_tokens: cache_write_tokens
      }
    end
  end

  defmodule BlockingRuntime do
    def generate(endpoint, request, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:blocking_runtime_started, endpoint, request})
      Process.sleep(5_000)
      {:ok, %{content: "too late", usage: %{input_tokens: 1, output_tokens: 1}}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok
  end

  test "put_endpoint, get_endpoint, and delete_endpoint manage encrypted endpoint settings" do
    assert {:ok, endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "top-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert endpoint.kind == :online
    assert endpoint.url == "https://api.example.test/v1"
    assert endpoint.api_key == "top-secret"
    assert endpoint.model == "gpt-4o-mini"

    assert %Setting{value: "https://api.example.test/v1"} = Repo.get(Setting, "ai.online.url")
    assert %Setting{value: "gpt-4o-mini"} = Repo.get(Setting, "ai.online.model")
    assert %Setting{value: encrypted_value} = Repo.get(Setting, "__encrypted_ai.online.api_key")
    refute encrypted_value == "top-secret"

    assert {:ok, fetched} = BDS.AI.get_endpoint(:online, secret_backend: FakeSecretBackend)
    assert fetched.api_key == "top-secret"

    assert :ok = BDS.AI.delete_endpoint(:online)
    assert {:ok, nil} = BDS.AI.get_endpoint(:online, secret_backend: FakeSecretBackend)
    assert Repo.get(Setting, "ai.online.url") == nil
    assert Repo.get(Setting, "__encrypted_ai.online.api_key") == nil
  end

  test "refresh_model_catalog stores providers, models, modalities, and etag metadata" do
    assert {:ok, result} =
             BDS.AI.refresh_model_catalog(http_client: FakeHttpClient)

    assert result.success == true
    assert result.models_updated == 2
    assert_received {:http_headers, %{"accept" => "application/json"}}

    providers = BDS.AI.list_catalog_providers()
    assert [%{id: "openai", name: "OpenAI"}] = providers

    assert {:ok, model} = BDS.AI.get_catalog_model("gpt-4o")
    assert model.provider == "openai"
    assert model.supports_tool_calls == true
    assert model.context_window == 128_000
    assert "image" in model.input_modalities

    modalities =
      Repo.all(
        from modality in "ai_model_modalities",
          where: modality.provider == ^"openai" and modality.model_id == ^"gpt-4o",
          select: {modality.direction, modality.modality}
      )

    assert {"input", "image"} in modalities

    assert {:ok, "W/\"catalog-v1\""} = BDS.AI.catalog_meta("etag")
    assert {:ok, last_fetched_at} = BDS.AI.catalog_meta("last_fetched_at")
    assert is_binary(last_fetched_at)
  end

  test "refresh_model_catalog uses conditional fetch metadata on subsequent refreshes" do
    assert {:ok, _first} = BDS.AI.refresh_model_catalog(http_client: FakeHttpClient)

    http_client = fn url, headers ->
      send(self(), {:conditional_headers, headers})
      FakeHttpClient.get(url, Map.put(headers, "if-none-match", "W/\"catalog-v1\""))
    end

    assert {:ok, result} = BDS.AI.refresh_model_catalog(http_client: http_client)
    assert result.not_modified == true

    assert_received {:conditional_headers,
                     %{"accept" => "application/json", "if-none-match" => "W/\"catalog-v1\""}}
  end

  test "list_endpoint_models reads openai-compatible models from the configured endpoint" do
    assert {:ok, models} =
             BDS.AI.list_endpoint_models(
               %{url: "https://api.example.test/v1", api_key: "online-secret"},
               http_client: FakeEndpointHttpClient
             )

    assert [%{id: "gpt-4.1", label: "gpt-4.1"}, %{id: "gpt-4.1-mini", label: "gpt-4.1-mini"}] =
             models
  end

  test "list_endpoint_models returns an error for malformed endpoint JSON" do
    assert {:error, %{kind: :invalid_json_response, reason: %Jason.DecodeError{}}} =
             BDS.AI.list_endpoint_models(
               %{url: "https://api.example.test/v1", api_key: "online-secret"},
               http_client: BadJsonEndpointHttpClient
             )
  end

  test "openai-compatible generation returns an error for malformed completion JSON" do
    server =
      start_supervised!({Bandit, plug: BadJsonCompletionServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:error, %{kind: :invalid_json_response, reason: %Jason.DecodeError{}}} =
             BDS.AI.OpenAICompatibleRuntime.generate(
               %{url: "http://127.0.0.1:#{port}/v1", api_key: nil},
               %{
                 model: "gpt-test",
                 messages: [%{"role" => "user", "content" => "Hello"}],
                 max_output_tokens: 128,
                 tools: []
               },
               []
             )
  end

  test "openai-compatible generation accepts title requests without tools" do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: RecordingCompletionServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    log =
      capture_log(fn ->
        assert {:ok, %{content: "Short Title"}} =
                 BDS.AI.OpenAICompatibleRuntime.generate(
                   %{url: "http://127.0.0.1:#{port}/v1", api_key: nil},
                   %{
                     operation: :chat_title,
                     model: "qwen3.5-122b",
                     messages: [%{"role" => "user", "content" => "Topic: posts per month"}],
                     max_output_tokens: 20
                   },
                   []
                 )
      end)

    Logger.configure(level: previous_level)

    assert log =~ "AI OpenAI-compatible request operation=:chat_title"
    assert log =~ ~s(model="qwen3.5-122b")

    assert_received {:completion_payload, payload}
    assert payload["model"] == "qwen3.5-122b"
    assert payload["max_tokens"] == 20
    refute Map.has_key?(payload, "tools")
    refute Map.has_key?(payload, "tool_choice")
  end

  test "openai-compatible generation disables thinking for configured models" do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: RecordingCompletionServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    assert :ok = BDS.AI.put_model_capabilities("qwen3.5-122b", %{disables_reasoning: true})

    assert {:ok, %{content: "Short Title"}} =
             BDS.AI.OpenAICompatibleRuntime.generate(
               %{url: "http://127.0.0.1:#{port}/v1", api_key: nil},
               %{
                 operation: :chat_title,
                 model: "qwen3.5-122b",
                 messages: [%{"role" => "user", "content" => "Topic: posts per month"}],
                 max_output_tokens: 256
               },
               []
             )

    assert_received {:completion_payload, payload}
    assert payload["chat_template_kwargs"] == %{"enable_thinking" => false}
  end

  test "openai-compatible generation includes response body in HTTP error details" do
    Application.put_env(:bds, :test_pid, self())

    server =
      start_supervised!({Bandit, plug: ErrorCompletionServer, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    previous_level = Logger.level()
    Logger.configure(level: :error)

    log =
      capture_log(fn ->
        assert {:error, %{kind: :http_error, status: 400, body: body}} =
                 BDS.AI.OpenAICompatibleRuntime.generate(
                   %{url: "http://127.0.0.1:#{port}/v1", api_key: nil},
                   %{
                     model: "gpt-test",
                     messages: [%{"role" => "user", "content" => "Hello"}],
                     max_output_tokens: 128,
                     tools: []
                   },
                   []
                 )

        assert body =~ "Invalid image data"
      end)

    Logger.configure(level: previous_level)

    assert log =~ "AI OpenAI-compatible HTTP error status=400"
    assert log =~ "Invalid image data"
    assert_received {:error_payload, payload}
    assert payload["model"] == "gpt-test"
  end

  test "analyze_image logs non-JSON content when the model returns invalid JSON" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :airplane,
               %{
                 url: "http://localhost:11434/v1",
                 api_key: nil,
                 model: "llama-default"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_image_analysis, "llava")

    assert :ok =
             BDS.AI.put_model_capabilities("llava", %{
               supports_attachment: true,
               supports_tool_calls: false,
               disables_reasoning: false
             })

    defmodule NonJsonContentRuntime do
      def generate(_endpoint, _request, _opts) do
        {:ok,
         %{
           content: "This is not valid JSON",
           json: nil,
           tool_calls: [],
           usage: %{input_tokens: 4, output_tokens: 2}
         }}
      end
    end

    previous_level = Logger.level()
    Logger.configure(level: :error)

    log =
      capture_log(fn ->
        assert {:error, %{kind: :invalid_json_response, content: "This is not valid JSON"}} =
                 BDS.AI.analyze_image(
                   %{
                     mime_type: "image/png",
                     image_url: "data:image/png;base64,abc123"
                   },
                   runtime: NonJsonContentRuntime,
                   test_pid: self(),
                   secret_backend: FakeSecretBackend
                 )
      end)

    Logger.configure(level: previous_level)

    assert log =~ "AI extract_json_response failed to parse content as JSON"
    assert log =~ "This is not valid JSON"
  end

  test "airplane mode routes title tasks to airplane endpoint and offline title model" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :airplane,
               %{
                 url: "http://localhost:11434/v1",
                 api_key: nil,
                 model: "llama-default"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_title, "llama3.1")

    assert {:ok, result} =
             BDS.AI.detect_language("Bonjour tout le monde",
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert result.language_code == "fr"

    assert_received {:runtime_request, endpoint, request}
    assert endpoint.kind == :airplane
    assert endpoint.url == "http://localhost:11434/v1"
    assert request.operation == :detect_language
    assert request.model == "llama3.1"
  end

  test "translate_post uses the online title model when airplane mode is disabled" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert :ok = BDS.AI.put_model_preference(:title, "gpt-4.1-mini")

    assert {:ok, translation} =
             BDS.AI.translate_post(
               %{
                 title: "Hello World",
                 excerpt: "Short summary",
                 content: "# Hello\n\nSource body"
               },
               "de",
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert translation.title == "Hallo Welt"
    assert translation.excerpt == "Kurze Zusammenfassung"

    assert_received {:runtime_request, endpoint, request}
    assert endpoint.kind == :online
    assert request.operation == :translate_post
    assert request.model == "gpt-4.1-mini"
  end

  test "analyze_post uses editor_body so published posts include filesystem content" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert :ok = BDS.AI.put_model_preference(:title, "gpt-4.1-mini")

    assert {:ok, result} =
             BDS.AI.analyze_post(
               %{
                 title: "Draft Post",
                 excerpt: "Short summary",
                 content: "# Draft body"
               },
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert result.title =~ "Draft Post"
    assert result.excerpt == "Analyzed excerpt"
    assert result.slug == "analyzed-slug"

    assert_received {:runtime_request, _endpoint, request}
    assert request.operation == :analyze_post
    message = get_in(request.messages, [Access.at(1), "content"]) || ""
    assert message =~ "# Draft body"
  end

  test "analyze_import_taxonomy uses the selected model override and returns only valid existing-term mappings" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert :ok = BDS.AI.put_model_preference(:title, "gpt-4.1-mini")

    assert {:ok, result} =
             BDS.AI.analyze_import_taxonomy(
               %{categories: ["General"], tags: ["News"]},
               %{categories: ["article", "page"], tags: ["updates"]},
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend,
               model: "gpt-4o"
             )

    assert result.category_mappings == %{"General" => "article"}
    assert result.tag_mappings == %{"News" => "updates"}

    assert_received {:runtime_request, endpoint, request}
    assert endpoint.kind == :online
    assert request.operation == :import_taxonomy_mapping
    assert request.model == "gpt-4o"
  end

  test "analyze_image requires a vision-capable airplane model before sending image input" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :airplane,
               %{
                 url: "http://localhost:11434/v1",
                 api_key: nil,
                 model: "llama-default"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_image_analysis, "llama3.2")

    assert {:error, %{kind: :model_capability_missing}} =
             BDS.AI.analyze_image(
               %{
                 mime_type: "image/png",
                 title: "Source",
                 alt: nil,
                 caption: nil,
                 image_url: "https://example.com/test.png"
               },
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert :ok =
             BDS.AI.put_model_capabilities("llama3.2", %{
               supports_attachment: true,
               supports_tool_calls: false,
               disables_reasoning: true
             })

    assert {:ok, analysis} =
             BDS.AI.analyze_image(
               %{
                 mime_type: "image/png",
                 title: "Source",
                 alt: nil,
                 caption: nil,
                 image_url: "https://example.com/test.png"
               },
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert analysis.alt == "Orange sunset over calm water"

    assert_received {:runtime_request, endpoint, request}
    assert endpoint.kind == :airplane
    assert request.operation == :analyze_image
    assert request.model == "llama3.2"
    assert BDS.AI.Catalog.model_capabilities("llama3.2").disables_reasoning
  end

  test "analyze_image converts file:// URLs to base64 data URLs before sending" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :airplane,
               %{
                 url: "http://localhost:11434/v1",
                 api_key: nil,
                 model: "llama-default"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_image_analysis, "llama3.2")

    assert :ok =
             BDS.AI.put_model_capabilities("llama3.2", %{
               supports_attachment: true,
               supports_tool_calls: false,
               disables_reasoning: false
             })

    tmp_path =
      Path.join(System.tmp_dir!(), "bds-test-image-#{System.unique_integer([:positive])}.png")

    File.write!(tmp_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)
    on_exit(fn -> File.rm(tmp_path) end)

    assert {:ok, analysis} =
             BDS.AI.analyze_image(
               %{
                 mime_type: "image/png",
                 title: "Source",
                 alt: nil,
                 caption: nil,
                 image_url: "file://#{tmp_path}"
               },
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert analysis.title == "Sunset"

    assert_received {:runtime_request, _endpoint, request}
    user_message = Enum.at(request.messages, 1)
    image_content = Enum.at(user_message["content"], 1)
    assert image_content["type"] == "image_url"
    assert image_content["image_url"]["url"] =~ ~r/^data:image\/png;base64,/
  end

  test "analyze_image reads local media files and sends them as base64 data URLs" do
    {:ok, project} = create_project_fixture("Image Analysis")

    image_dir = Path.join(project.data_path, "media")
    File.mkdir_p!(image_dir)
    image_path = Path.join(image_dir, "test.png")
    File.write!(image_path, <<137, 80, 78, 71, 13, 10, 26, 10>>)

    media =
      Repo.insert!(
        Media.changeset(%Media{}, %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          filename: "test.png",
          original_name: "test.png",
          mime_type: "image/png",
          size: 8,
          title: "Test",
          file_path: "media/test.png",
          sidecar_path: "media/test.png.meta",
          created_at: Persistence.now_ms(),
          updated_at: Persistence.now_ms()
        })
      )

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :airplane,
               %{
                 url: "http://localhost:11434/v1",
                 api_key: nil,
                 model: "llama-default"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_image_analysis, "llama3.2")

    assert :ok =
             BDS.AI.put_model_capabilities("llama3.2", %{
               supports_attachment: true,
               supports_tool_calls: false,
               disables_reasoning: false
             })

    assert {:ok, analysis} =
             BDS.AI.analyze_image(
               media.id,
               runtime: FakeRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert analysis.title == "Sunset"

    assert_received {:runtime_request, _endpoint, request}
    user_message = Enum.at(request.messages, 1)
    image_content = Enum.at(user_message["content"], 1)
    assert image_content["type"] == "image_url"
    assert image_content["image_url"]["url"] =~ ~r/^data:image\/png;base64,/
  end

  test "chat persists user, tool, and assistant messages with usage and blog stats prompt augmentation" do
    {:ok, project} = create_project_fixture("AI Chat")
    _fixtures = seed_project_content(project.id)

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert {:ok, conversation} = BDS.AI.start_chat(%{model: "gpt-4o-mini"})

    assert {:ok, reply} =
             BDS.AI.send_chat_message(conversation.id, "How many items are in the blog?",
               runtime: FakeRuntime,
               test_pid: self(),
               project_id: project.id,
               secret_backend: FakeSecretBackend
             )

    assert reply.assistant_message.content == "You currently have 1 post and 1 media item."

    messages = BDS.AI.list_chat_messages(conversation.id)
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :assistant]

    assistant_tool_call = Enum.at(messages, 1)
    tool_message = Enum.at(messages, 2)
    assistant_message = Enum.at(messages, 3)

    assert [%{"id" => "call-blog-stats", "name" => "blog_stats"}] = assistant_tool_call.tool_calls
    assert tool_message.tool_call_id == "call-blog-stats"
    assert tool_message.content =~ "post_count"
    assert assistant_message.token_usage_input == 64
    assert assistant_message.token_usage_output == 21
    assert assistant_message.cache_read_tokens == 3
    assert assistant_message.cache_write_tokens == 1

    assert_received {:runtime_request, _endpoint, first_request}
    assert_received {:runtime_request, _endpoint, second_request}

    assert Enum.any?(first_request.messages, fn message ->
             message["role"] == "system" and String.contains?(message["content"], "Posts: 1") and
               String.contains?(message["content"], "Media: 1") and
               String.contains?(message["content"], "Available blog data tools") and
               String.contains?(message["content"], "get_blog_stats") and
               String.contains?(message["content"], "list_posts") and
               String.contains?(message["content"], "get_media") and
               String.contains?(message["content"], "view_image") and
               String.contains?(message["content"], "update_post_metadata") and
               String.contains?(message["content"], "Available UI Render Tools") and
               String.contains?(message["content"], "render_chart") and
               String.contains?(message["content"], "heatmap") and
               String.contains?(message["content"], "render_tabs")
           end)

    tool_descriptions =
      first_request.tools
      |> Map.new(fn tool ->
        {get_in(tool, ["function", "name"]), get_in(tool, ["function", "description"])}
      end)

    expected_old_app_tools = [
      "get_blog_stats",
      "search_posts",
      "read_post",
      "read_post_by_slug",
      "list_posts",
      "get_media",
      "list_media",
      "view_image",
      "update_post_metadata",
      "update_media_metadata",
      "list_tags",
      "list_categories",
      "get_post_backlinks",
      "get_post_outlinks",
      "get_post_media",
      "get_media_posts",
      "render_chart",
      "render_table",
      "render_form",
      "render_card",
      "render_metric",
      "render_list",
      "render_tabs",
      "render_mindmap"
    ]

    assert Enum.all?(expected_old_app_tools, &Map.has_key?(tool_descriptions, &1))
    assert tool_descriptions["get_blog_stats"] =~ "comprehensive blog statistics"
    assert tool_descriptions["list_posts"] =~ "titles"
    assert tool_descriptions["list_posts"] =~ "URLs"
    assert tool_descriptions["list_media"] =~ "filenames"
    assert tool_descriptions["render_chart"] =~ "interactive chart"
    assert tool_descriptions["render_chart"] =~ "heatmap"
    assert tool_descriptions["render_table"] =~ "tabular data"
    assert tool_descriptions["render_tabs"] =~ "multiple tabs"

    render_chart_schema =
      first_request.tools
      |> Enum.find(&(get_in(&1, ["function", "name"]) == "render_chart"))
      |> get_in(["function", "parameters", "properties"])

    assert get_in(render_chart_schema, ["chartType", "enum"]) == [
             "bar",
             "stacked-bar",
             "line",
             "area",
             "pie",
             "donut",
             "heatmap"
           ]

    assert get_in(render_chart_schema, ["series", "items", "properties", "segments"]) != nil

    assert Enum.any?(second_request.messages, fn message -> message["role"] == "tool" end)

    assert Enum.any?(second_request.messages, fn message ->
             message["role"] == "assistant" and
               message["tool_calls"] == [
                 %{
                   "id" => "call-blog-stats",
                   "type" => "function",
                   "function" => %{"name" => "blog_stats", "arguments" => "{}"}
                 }
               ]
           end)
  end

  test "chat generates a short title after the first user turn using the title model" do
    {:ok, project} = create_project_fixture("Title Chat")
    _fixtures = seed_project_content(project.id)

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert :ok = BDS.AI.put_model_preference(:title, "title-model")
    assert {:ok, conversation} = BDS.AI.start_chat(%{model: "gpt-4o-mini"})

    assert {:ok, reply} =
             BDS.AI.send_chat_message(conversation.id, "How many items are in the blog?",
               runtime: FakeRuntime,
               test_pid: self(),
               project_id: project.id,
               secret_backend: FakeSecretBackend
             )

    assert reply.conversation.title == "Blog Stats"
    assert BDS.AI.get_chat_conversation(conversation.id).title == "Blog Stats"

    assert_received {:runtime_request, _endpoint, %{operation: :chat}}
    assert_received {:runtime_request, _endpoint, %{operation: :chat}}

    assert_received {:runtime_request, _endpoint, title_request}
    assert title_request.operation == :chat_title
    assert title_request.model == "title-model"
    assert title_request.max_output_tokens == 256
    assert Enum.any?(title_request.messages, &(&1["content"] =~ "2-3 words"))
    assert Enum.any?(title_request.messages, &(&1["content"] =~ "Do not include reasoning"))
    assert Enum.any?(title_request.messages, &(&1["content"] =~ "How many items"))
  end

  test "chat retries title generation on later turns while the title is still generated" do
    {:ok, project} = create_project_fixture("Retry Title Chat")
    _fixtures = seed_project_content(project.id)

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert :ok = BDS.AI.put_model_preference(:title, "title-model")
    assert {:ok, conversation} = BDS.AI.start_chat(%{title: "New Chat", model: "gpt-4o-mini"})

    Repo.insert!(%BDS.AI.ChatMessage{
      conversation_id: conversation.id,
      role: :user,
      content: "Earlier turn whose title attempt failed",
      created_at: Persistence.now_ms()
    })

    assert {:ok, reply} =
             BDS.AI.send_chat_message(conversation.id, "How many items are in the blog now?",
               runtime: FakeRuntime,
               test_pid: self(),
               project_id: project.id,
               secret_backend: FakeSecretBackend
             )

    assert reply.conversation.title == "Blog Stats"
    assert BDS.AI.get_chat_conversation(conversation.id).title == "Blog Stats"

    assert_received {:runtime_request, _endpoint, %{operation: :chat}}
    assert_received {:runtime_request, _endpoint, %{operation: :chat}}
    assert_received {:runtime_request, _endpoint, %{operation: :chat_title} = title_request}
    assert Enum.any?(title_request.messages, &(&1["content"] =~ "How many items"))
  end

  test "chat does not prompt models to emit textual tool calls when tools are unavailable" do
    {:ok, project} = create_project_fixture("No Tool Chat")
    _fixtures = seed_project_content(project.id)

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :airplane,
               %{
                 url: "http://localhost:11434/v1",
                 api_key: nil,
                 model: "llama-plain"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_chat, "llama-plain")
    assert {:ok, conversation} = BDS.AI.start_chat(%{model: "llama-plain"})

    assert {:ok, _reply} =
             BDS.AI.send_chat_message(conversation.id, "Show posts per month",
               runtime: FakeRuntime,
               test_pid: self(),
               project_id: project.id,
               secret_backend: FakeSecretBackend
             )

    assert_received {:runtime_request, _endpoint, first_request}
    assert first_request.tools == []

    refute Enum.any?(first_request.messages, fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "Available blog data tools")
           end)
  end

  test "non-stat chat tools expose concrete project data" do
    {:ok, project} = create_project_fixture("Concrete Tools")
    %{post: post, media: media} = seed_project_content(project.id)

    assert %{posts: [listed_post], total: 1} =
             BDS.AI.ChatTools.execute("list_posts", %{"limit" => 5}, project.id)

    assert listed_post["title"] == post.title
    assert listed_post["slug"] == post.slug
    assert listed_post["url"] == "/posts/#{post.slug}"
    assert listed_post["updated_at"] == post.updated_at

    assert %{post: read_post} =
             BDS.AI.ChatTools.execute("read_post", %{"postId" => post.id}, project.id)

    assert read_post["title"] == post.title
    assert read_post["content"] == post.content

    assert [listed_media] = BDS.AI.ChatTools.execute("list_media", %{"limit" => 5}, project.id)
    assert listed_media.filename == "image.png"
    assert listed_media.mime_type == "image/png"
    assert listed_media.updated_at

    assert %{media: loaded_media} =
             BDS.AI.ChatTools.execute("get_media", %{"mediaId" => media.id}, project.id)

    assert loaded_media.id == media.id
    assert loaded_media.title == "Hero"

    assert %{linked_by: []} =
             BDS.AI.ChatTools.execute("get_post_backlinks", %{"postId" => post.id}, project.id)

    assert %{links_to: []} =
             BDS.AI.ChatTools.execute("get_post_outlinks", %{"postId" => post.id}, project.id)

    assert %{media: []} =
             BDS.AI.ChatTools.execute("get_post_media", %{"postId" => post.id}, project.id)

    assert %{posts: []} =
             BDS.AI.ChatTools.execute("get_media_posts", %{"mediaId" => media.id}, project.id)

    assert %{success: true, post: updated_post} =
             BDS.AI.ChatTools.execute(
               "update_post_metadata",
               %{"postId" => post.id, "title" => "Updated AI Post"},
               project.id
             )

    assert updated_post["title"] == "Updated AI Post"

    assert %{success: true, media: updated_media} =
             BDS.AI.ChatTools.execute(
               "update_media_metadata",
               %{"mediaId" => media.id, "alt" => "Updated alt"},
               project.id
             )

    assert updated_media.alt == "Updated alt"

    assert %{
             type: "chart",
             chart_type: "heatmap",
             series: [%{"label" => "2026", "segments" => [%{"label" => "Jan", "value" => 2}]}]
           } =
             BDS.AI.ChatTools.execute(
               "render_chart",
               %{
                 "chartType" => "heatmap",
                 "series" => [
                   %{"label" => "2026", "segments" => [%{"label" => "Jan", "value" => 2}]}
                 ]
               },
               project.id
             )
  end

  test "chat count_posts groups every matching post before returning groups" do
    {:ok, project} = create_project_fixture("Count Posts")

    month_counts = [{2, 4}, {3, 6}, {4, 3}]

    for {month, count} <- month_counts,
        index <- 1..count do
      created_at = unix_ms!(NaiveDateTime.new!(Date.new!(2026, month, index), ~T[12:00:00]))

      Repo.insert!(
        Post.changeset(%Post{}, %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          title: "AI Count #{month}-#{index}",
          slug: "ai-count-#{month}-#{index}",
          content: "Body",
          status: :draft,
          created_at: created_at,
          updated_at: created_at,
          do_not_translate: false
        })
      )
    end

    assert %{groups: groups, total_posts: 13} =
             BDS.AI.ChatTools.execute(
               "count_posts",
               %{"groupBy" => ["month"], "year" => 2026},
               project.id
             )

    assert Enum.sort_by(groups, & &1["month"]) == [
             %{"count" => 4, "month" => 2},
             %{"count" => 6, "month" => 3},
             %{"count" => 3, "month" => 4}
           ]
  end

  test "cancel_chat aborts an in-flight chat turn" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert {:ok, conversation} = BDS.AI.start_chat(%{model: "gpt-4o-mini"})

    parent = self()

    task =
      Task.async(fn ->
        BDS.AI.send_chat_message(conversation.id, "Please wait",
          runtime: BlockingRuntime,
          test_pid: parent,
          secret_backend: FakeSecretBackend
        )
      end)

    assert_receive {:blocking_runtime_started, _endpoint, request}, 500
    assert request.operation == :chat

    assert :ok = BDS.AI.cancel_chat(conversation.id)
    assert {:error, :cancelled} = Task.await(task)

    messages = BDS.AI.list_chat_messages(conversation.id)
    assert Enum.map(messages, & &1.role) == [:user]
  end

  defp create_project_fixture(name) do
    temp_dir = Path.join(System.tmp_dir!(), "bds-ai-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(temp_dir) end)

    with {:ok, project} <- Projects.create_project(%{name: name, data_path: temp_dir}),
         {:ok, _active} <- Projects.set_active_project(project.id) do
      {:ok, project}
    end
  end

  defp seed_project_content(project_id) do
    now = Persistence.now_ms()

    post =
      Repo.insert!(
        Post.changeset(%Post{}, %{
          id: Ecto.UUID.generate(),
          project_id: project_id,
          title: "AI Post",
          slug: "ai-post",
          excerpt: "Summary",
          content: "Body",
          status: :draft,
          created_at: now,
          updated_at: now,
          do_not_translate: false
        })
      )

    media =
      Repo.insert!(
        Media.changeset(%Media{}, %{
          id: Ecto.UUID.generate(),
          project_id: project_id,
          filename: "image.png",
          original_name: "image.png",
          mime_type: "image/png",
          size: 128,
          title: "Hero",
          file_path: "media/image.png",
          sidecar_path: "media/image.png.meta",
          created_at: now,
          updated_at: now
        })
      )

    %{post: post, media: media}
  end

  defp unix_ms!(%NaiveDateTime{} = naive_datetime) do
    naive_datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end
end
