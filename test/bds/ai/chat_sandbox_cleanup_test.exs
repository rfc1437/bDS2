defmodule BDS.AI.ChatSandboxCleanupTest do
  use ExUnit.Case, async: false

  alias BDS.AI
  alias BDS.Repo

  defmodule FakeSecretBackend do
    def encrypt(value), do: {:ok, "enc:" <> value}

    def decrypt("enc:" <> value), do: {:ok, value}
    def decrypt(_other), do: {:error, :invalid_ciphertext}
  end

  defmodule FinalReplyRuntime do
    def generate(endpoint, request, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_request, endpoint, request})
      {:ok, %{content: "All set.", usage: %{input_tokens: 5, output_tokens: 2}}}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    :ok
  end

  test "chat module does not carry SQL sandbox scaffolding" do
    source_path = Path.expand("../../../lib/bds/ai/chat.ex", __DIR__)
    source = File.read!(source_path)

    refute source =~ "sandbox_ready"
    refute source =~ "allow_repo_sandbox"
    refute source =~ "Ecto.Adapters.SQL.Sandbox"
  end

  test "send_chat_message persists through the supervised task without explicit sandbox allowance" do
    assert {:ok, _endpoint} =
             AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               },
               secret_backend: FakeSecretBackend
             )

    assert :ok = AI.set_airplane_mode(false)
    assert {:ok, conversation} = AI.start_chat(%{title: "Sandbox Cleanup", model: "gpt-4o-mini"})

    assert {:ok, reply} =
             AI.send_chat_message(conversation.id, "How many items are in the blog?",
               runtime: FinalReplyRuntime,
               test_pid: self(),
               secret_backend: FakeSecretBackend
             )

    assert reply.assistant_message.content == "All set."

    messages = AI.list_chat_messages(conversation.id)
    assert Enum.map(messages, & &1.role) == [:user, :assistant]

    assert Repo.aggregate(BDS.AI.ChatMessage, :count, :id) == 2
    assert_received {:runtime_request, _endpoint, %{operation: :chat}}
  end
end
