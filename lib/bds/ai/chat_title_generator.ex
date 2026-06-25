defmodule BDS.AI.ChatTitleGenerator do
  @moduledoc false

  require Logger

  alias BDS.AI.ChatMessage
  alias BDS.AI.OpenAICompatibleRuntime
  alias BDS.AI.Runtime
  alias BDS.Repo

  import Ecto.Query

  @title_max_output_tokens 256
  @chat_title_max_length 30

  def generate_chat_title(user_content, opts) when is_binary(user_content) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)

    with {:ok, endpoint, model, mode} <- Runtime.resolve_target(:chat_title, opts),
         :ok <- Runtime.validate_target(:chat_title, model, mode),
         request <- build_chat_title_request(user_content, model),
         {:ok, response} <-
           runtime.generate(Runtime.endpoint_with_model(endpoint, model), request, opts) do
      title = sanitize_chat_title(Map.get(response, :content))

      if title == "" do
        Logger.warning("Chat title generation returned an empty title",
          model: model,
          content: inspect(Map.get(response, :content)),
          usage: inspect(Map.get(response, :usage))
        )
      end

      {:ok, title}
    else
      {:error, reason} = error ->
        Logger.warning("Chat title generation failed", reason: inspect(reason))
        error

      other ->
        Logger.warning("Chat title generation failed", reason: inspect(other))
        other
    end
  end

  def build_chat_title_request(user_content, model) do
    %{
      operation: :chat_title,
      model: model,
      max_output_tokens: @title_max_output_tokens,
      messages: [
        %{
          "role" => "system",
          "content" =>
            "Generate an ultra-short title (2-3 words, max 25 characters) for this conversation. Focus ONLY on the topic. Ignore any capability disclaimers. Do not include reasoning. Output ONLY the title text."
        },
        %{"role" => "user", "content" => "Topic: #{String.slice(user_content, 0, 100)}"}
      ]
    }
  end

  def sanitize_chat_title(title) when is_binary(title) do
    title =
      title
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_leading("'")
      |> String.trim_trailing("\"")
      |> String.trim_trailing("'")
      |> String.trim_trailing(".")
      |> String.trim_trailing("!")
      |> String.trim_trailing("?")

    if String.length(title) > @chat_title_max_length do
      String.slice(title, 0, @chat_title_max_length - 3) <> "..."
    else
      title
    end
  end

  def sanitize_chat_title(_title), do: ""

  def chat_user_message_count(conversation_id) do
    Repo.aggregate(
      from(message in ChatMessage,
        where: message.conversation_id == ^conversation_id and message.role == :user
      ),
      :count,
      :id
    )
  end

  def generated_chat_title?(title, model) do
    title in [generated_chat_title(nil), generated_chat_title(model)]
  end

  def generated_chat_title(nil), do: "New Chat"
  def generated_chat_title(model), do: "Chat with #{model}"
end
