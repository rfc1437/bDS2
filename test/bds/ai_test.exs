defmodule BDS.AITest do
  use ExUnit.Case, async: false

  import Ecto.Query

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
             BDS.AI.put_endpoint(:online, %{
               url: "https://api.example.test/v1",
               api_key: "top-secret",
               model: "gpt-4o-mini"
             }, secret_backend: FakeSecretBackend)

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
    assert_received {:conditional_headers, %{"accept" => "application/json", "if-none-match" => "W/\"catalog-v1\""}}
  end

  test "list_endpoint_models reads openai-compatible models from the configured endpoint" do
    assert {:ok, models} =
             BDS.AI.list_endpoint_models(%{url: "https://api.example.test/v1", api_key: "online-secret"},
               http_client: FakeEndpointHttpClient
             )

    assert [%{id: "gpt-4.1", label: "gpt-4.1"}, %{id: "gpt-4.1-mini", label: "gpt-4.1-mini"}] = models
  end

  test "airplane mode routes title tasks to airplane endpoint and offline title model" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:online, %{
               url: "https://api.example.test/v1",
               api_key: "online-secret",
               model: "gpt-4o-mini"
             }, secret_backend: FakeSecretBackend)

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:airplane, %{
               url: "http://localhost:11434/v1",
               api_key: nil,
               model: "llama-default"
             }, secret_backend: FakeSecretBackend)

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
             BDS.AI.put_endpoint(:online, %{
               url: "https://api.example.test/v1",
               api_key: "online-secret",
               model: "gpt-4o-mini"
             }, secret_backend: FakeSecretBackend)

    assert :ok = BDS.AI.set_airplane_mode(false)
    assert :ok = BDS.AI.put_model_preference(:title, "gpt-4.1-mini")

    assert {:ok, translation} =
             BDS.AI.translate_post(
               %{title: "Hello World", excerpt: "Short summary", content: "# Hello\n\nSource body"},
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

  test "analyze_image requires a vision-capable airplane model before sending image input" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:airplane, %{
               url: "http://localhost:11434/v1",
               api_key: nil,
               model: "llama-default"
             }, secret_backend: FakeSecretBackend)

    assert :ok = BDS.AI.set_airplane_mode(true)
    assert :ok = BDS.AI.put_model_preference(:airplane_image_analysis, "llama3.2")

    assert {:error, %{kind: :model_capability_missing}} =
             BDS.AI.analyze_image(%{
               mime_type: "image/png",
               title: "Source",
               alt: nil,
               caption: nil,
               image_url: "file:///tmp/test.png"
             }, runtime: FakeRuntime, test_pid: self(), secret_backend: FakeSecretBackend)

    assert :ok =
             BDS.AI.put_model_capabilities("llama3.2", %{
               supports_attachment: true,
               supports_tool_calls: false
             })

    assert {:ok, analysis} =
             BDS.AI.analyze_image(%{
               mime_type: "image/png",
               title: "Source",
               alt: nil,
               caption: nil,
               image_url: "file:///tmp/test.png"
             }, runtime: FakeRuntime, test_pid: self(), secret_backend: FakeSecretBackend)

    assert analysis.alt == "Orange sunset over calm water"

    assert_received {:runtime_request, endpoint, request}
    assert endpoint.kind == :airplane
    assert request.operation == :analyze_image
    assert request.model == "llama3.2"
  end

  test "chat persists user, tool, and assistant messages with usage and blog stats prompt augmentation" do
    {:ok, project} = create_project_fixture("AI Chat")
    :ok = seed_project_content(project.id)

    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:online, %{
               url: "https://api.example.test/v1",
               api_key: "online-secret",
               model: "gpt-4o-mini"
             }, secret_backend: FakeSecretBackend)

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
               String.contains?(message["content"], "Media: 1")
           end)

    assert Enum.any?(second_request.messages, fn message -> message["role"] == "tool" end)
  end

  test "cancel_chat aborts an in-flight chat turn" do
    assert {:ok, _endpoint} =
             BDS.AI.put_endpoint(:online, %{
               url: "https://api.example.test/v1",
               api_key: "online-secret",
               model: "gpt-4o-mini"
             }, secret_backend: FakeSecretBackend)

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

    Repo.insert!(
      Media.changeset(%Media{}, %{
        id: Ecto.UUID.generate(),
        project_id: project_id,
        filename: "image.png",
        original_name: "image.png",
        mime_type: "image/png",
        size: 128,
        file_path: "media/image.png",
        sidecar_path: "media/image.png.meta",
        created_at: now,
        updated_at: now
      })
    )

    :ok
  end
end
