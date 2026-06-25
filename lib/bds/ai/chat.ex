defmodule BDS.AI.Chat do
  @moduledoc false

  import Ecto.Query
  require Logger

  alias BDS.AI
  alias BDS.AI.Catalog
  alias BDS.AI.CatalogProvider
  alias BDS.AI.ChatConversation
  alias BDS.AI.ChatMessage
  alias BDS.AI.ChatTitleGenerator
  alias BDS.AI.ChatTools
  alias BDS.AI.InFlight
  alias BDS.AI.OpenAICompatibleRuntime
  alias BDS.AI.Runtime
  alias BDS.AI.SecretBackend
  alias BDS.MapUtils
  import BDS.AI.SettingsStore, only: [get_setting: 1]
  alias BDS.Media.Media
  alias BDS.Persistence
  alias BDS.Posts.Post
  alias BDS.Projects.Project
  alias BDS.Repo

  @default_system_prompt "You are the bDS AI backend. Be precise, prefer structured JSON when asked, and avoid inventing blog facts."
  @default_max_output_tokens 16_384
  @chat_max_tool_rounds 10
  @chat_await_timeout_margin_ms 5_000
  @default_context_window 128_000

  @spec start_chat(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def start_chat(attrs \\ %{}) when is_map(attrs) do
    now = Persistence.now_ms()
    model = MapUtils.attr(attrs, :model)
    title = MapUtils.attr(attrs, :title) || ChatTitleGenerator.generated_chat_title(model)

    %ChatConversation{}
    |> ChatConversation.changeset(%{
      id: Ecto.UUID.generate(),
      title: title,
      model: model,
      copilot_session_id: MapUtils.attr(attrs, :copilot_session_id),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, conversation} -> {:ok, format_conversation(conversation)}
      error -> error
    end
  end

  @spec list_chat_conversations() :: [map()]
  def list_chat_conversations do
    Repo.all(from conversation in ChatConversation, order_by: [desc: conversation.updated_at])
    |> Enum.map(&format_conversation/1)
  end

  @spec get_chat_conversation(String.t()) :: ChatConversation.t() | nil
  def get_chat_conversation(conversation_id) when is_binary(conversation_id) do
    Repo.get(ChatConversation, conversation_id)
  end

  @spec get_surface_state(String.t()) :: map()
  def get_surface_state(conversation_id) when is_binary(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      %ChatConversation{surface_state: state} when is_map(state) -> state
      _other -> %{}
    end
  end

  @spec put_surface_state(String.t(), map(), map(), MapSet.t()) ::
          {:ok, map()} | {:error, term()}
  def put_surface_state(conversation_id, surface_data, surface_tabs, dismissed_surfaces)
      when is_binary(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      nil ->
        {:error, :not_found}

      %ChatConversation{} = conversation ->
        state = %{
          "surface_data" => surface_data,
          "surface_tabs" => surface_tabs,
          "dismissed_surfaces" => MapSet.to_list(dismissed_surfaces)
        }

        conversation
        |> ChatConversation.changeset(%{
          surface_state: state,
          updated_at: Persistence.now_ms()
        })
        |> Repo.update()
        |> case do
          {:ok, _updated} -> {:ok, state}
          error -> error
        end
    end
  end

  @spec delete_chat_conversation(String.t()) :: {:ok, :deleted} | {:error, :not_found | term()}
  def delete_chat_conversation(conversation_id) when is_binary(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      nil ->
        {:error, :not_found}

      %ChatConversation{} = conversation ->
        Repo.transaction(fn ->
          Repo.delete_all(
            from message in ChatMessage, where: message.conversation_id == ^conversation_id
          )

          case delete_chat_conversation_test_hook(conversation_id) do
            :ok ->
              case Repo.delete(conversation) do
                {:ok, _conversation} -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, :ok} -> {:ok, :deleted}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec available_chat_models(String.t() | nil) :: [map()]
  def available_chat_models(current_model \\ nil) do
    endpoint_models = configured_chat_models()

    preference_models =
      [:chat, :airplane_chat]
      |> Enum.flat_map(fn key ->
        case AI.get_model_preference(key) do
          {:ok, model} when is_binary(model) and model != "" -> [model]
          _other -> []
        end
      end)

    provider_names = catalog_provider_name_map()
    endpoint_provider_map = Map.new(endpoint_models, &{&1.id, &1.provider})

    [current_model | Enum.map(endpoint_models, & &1.id) ++ preference_models]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.map(&build_available_chat_model(&1, endpoint_provider_map, provider_names))
    |> Enum.sort_by(fn model ->
      {
        String.downcase(to_string(model.provider_name || model.provider || "")),
        String.downcase(to_string(model.name || model.id))
      }
    end)
  end

  @spec effective_chat_model(ChatConversation.t() | map() | nil) :: String.t() | nil
  def effective_chat_model(%ChatConversation{} = conversation) do
    resolve_effective_chat_model(conversation.model)
  end

  def effective_chat_model(%{model: model}), do: resolve_effective_chat_model(model)
  def effective_chat_model(%{"model" => model}), do: resolve_effective_chat_model(model)
  def effective_chat_model(_conversation), do: resolve_effective_chat_model(nil)

  @spec set_conversation_model(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_conversation_model(conversation_id, model_id)
      when is_binary(conversation_id) and is_binary(model_id) do
    case Repo.get(ChatConversation, conversation_id) do
      nil ->
        {:error, :not_found}

      %ChatConversation{} = conversation ->
        conversation
        |> ChatConversation.changeset(%{model: model_id, updated_at: Persistence.now_ms()})
        |> Repo.update()
        |> case do
          {:ok, updated_conversation} -> {:ok, format_conversation(updated_conversation)}
          error -> error
        end
    end
  end

  @spec list_chat_messages(String.t()) :: [map()]
  def list_chat_messages(conversation_id) when is_binary(conversation_id) do
    Repo.all(
      from message in ChatMessage,
        where: message.conversation_id == ^conversation_id,
        order_by: [asc: message.created_at, asc: message.id]
    )
    |> Enum.map(&format_chat_message/1)
  end

  @spec send_chat_message(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def send_chat_message(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and is_binary(content) and is_list(opts) do
    with %ChatConversation{} = conversation <- Repo.get(ChatConversation, conversation_id),
         {:ok, user_message} <-
           persist_chat_message(%{
             conversation_id: conversation.id,
             role: :user,
             content: content,
             created_at: Persistence.now_ms()
           }) do
      task =
        Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
          do_send_chat_message(conversation, user_message, opts)
        end)

      InFlight.register(conversation.id, task.pid)

      try do
        await_chat_task(task, chat_await_timeout_ms())
      after
        InFlight.unregister(conversation.id)
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @spec cancel_chat(String.t()) :: :ok
  def cancel_chat(conversation_id) when is_binary(conversation_id) do
    case InFlight.lookup(conversation_id) do
      nil ->
        :ok

      pid ->
        _ = Task.Supervisor.terminate_child(BDS.Tasks.TaskSupervisor, pid)
        :ok
    end
  end

  @doc false
  def count_distinct_string_list(schema, field, project_id) do
    Repo.all(
      from record in schema,
        where: field(record, :project_id) == ^project_id,
        select: field(record, ^field)
    )
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  @doc false
  def normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"],
      output_tokens: usage[:output_tokens] || usage["output_tokens"],
      cache_read_tokens: usage[:cache_read_tokens] || usage["cache_read_tokens"],
      cache_write_tokens: usage[:cache_write_tokens] || usage["cache_write_tokens"]
    }
  end

  def normalize_usage(_usage) do
    %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_tokens: nil,
      cache_write_tokens: nil
    }
  end

  defp format_conversation(conversation) do
    %{
      id: conversation.id,
      title: conversation.title,
      model: conversation.model,
      copilot_session_id: conversation.copilot_session_id,
      created_at: conversation.created_at,
      updated_at: conversation.updated_at
    }
  end

  defp format_chat_message(message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      role: message.role,
      content: message.content,
      tool_call_id: message.tool_call_id,
      tool_calls: Catalog.decode_nullable_json(message.tool_calls),
      token_usage_input: message.token_usage_input,
      token_usage_output: message.token_usage_output,
      cache_read_tokens: message.cache_read_tokens,
      cache_write_tokens: message.cache_write_tokens,
      created_at: message.created_at
    }
  end

  defp configured_chat_models do
    [:online, :airplane]
    |> Enum.flat_map(fn kind ->
      case AI.get_endpoint(kind) do
        {:ok, %{model: model, url: url}} when is_binary(model) and model != "" ->
          [%{id: model, provider: infer_endpoint_provider(kind, url)}]

        _other ->
          []
      end
    end)
  end

  defp build_available_chat_model(model_id, endpoint_provider_map, provider_names) do
    case Catalog.get_catalog_model(model_id) do
      {:ok, model} ->
        provider = model.provider || Map.get(endpoint_provider_map, model_id, "other")

        %{
          id: model.model_id,
          name: model.name || model.model_id,
          provider: provider,
          provider_name: Map.get(provider_names, provider, fallback_provider_name(provider)),
          context_window: model.context_window,
          max_output_tokens: model.max_output_tokens
        }

      {:error, :not_found} ->
        provider = Map.get(endpoint_provider_map, model_id, "other")

        %{
          id: model_id,
          name: model_id,
          provider: provider,
          provider_name: Map.get(provider_names, provider, fallback_provider_name(provider)),
          context_window: nil,
          max_output_tokens: nil
        }
    end
  end

  defp resolve_effective_chat_model(model) when is_binary(model) and model != "", do: model

  defp resolve_effective_chat_model(_model) do
    mode = if AI.airplane_mode?(), do: :airplane, else: :online

    preference_key = if mode == :airplane, do: :airplane_chat, else: :chat

    case Runtime.model_preference_value(preference_key) do
      model when is_binary(model) and model != "" ->
        model

      _other ->
        case AI.get_endpoint(mode) do
          {:ok, %{model: model}} when is_binary(model) and model != "" -> model
          _other -> nil
        end
    end
  end

  defp catalog_provider_name_map do
    Repo.all(from provider in CatalogProvider, select: {provider.id, provider.name})
    |> Map.new()
  end

  defp infer_endpoint_provider(:online, _url), do: "generic-openai"

  defp infer_endpoint_provider(:airplane, url) when is_binary(url) do
    normalized_url = String.downcase(url)

    cond do
      String.contains?(normalized_url, "11434") or String.contains?(normalized_url, "ollama") ->
        "ollama"

      String.contains?(normalized_url, "1234") or String.contains?(normalized_url, "lmstudio") ->
        "lmstudio"

      true ->
        "generic-openai"
    end
  end

  defp infer_endpoint_provider(:airplane, _url), do: "generic-openai"

  defp fallback_provider_name("generic-openai"), do: "Generic OpenAI"
  defp fallback_provider_name("lmstudio"), do: "LM Studio"
  defp fallback_provider_name("mistral"), do: "Mistral"
  defp fallback_provider_name("ollama"), do: "Ollama"
  defp fallback_provider_name("openai"), do: "OpenAI"

  defp fallback_provider_name(provider) when is_binary(provider) and provider != "" do
    provider
    |> String.split(["-", "_"], trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp fallback_provider_name(_provider), do: "Other"

  defp do_send_chat_message(conversation, user_message, opts) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)
    project_id = Keyword.get(opts, :project_id, active_project_id())

    with {:ok, endpoint, model, mode} <-
           Runtime.resolve_target(
             :chat,
             conversation: conversation,
             secret_backend: Keyword.get(opts, :secret_backend, SecretBackend)
           ),
         :ok <- Runtime.validate_target(:chat, model, mode),
         messages <- load_chat_messages(conversation.id),
         tools <- available_chat_tools(project_id, model),
         {:ok, reply} <-
           chat_round(
             conversation,
             messages,
             endpoint,
             model,
             project_id,
             tools,
             runtime,
             opts,
             chat_max_tool_rounds()
           ),
         {:ok, reply} <-
           maybe_generate_chat_title(conversation.id, user_message.content, reply, opts) do
      {:ok, reply}
    end
  end

  defp maybe_generate_chat_title(conversation_id, user_content, reply, opts) do
    conversation = Repo.get!(ChatConversation, conversation_id)

    cond do
      ChatTitleGenerator.chat_user_message_count(conversation_id) < 1 ->
        Logger.debug("Chat title generation skipped reason=:no_user_messages")
        {:ok, reply}

      not ChatTitleGenerator.generated_chat_title?(conversation.title, conversation.model) ->
        Logger.debug(
          "Chat title generation skipped reason=:conversation_already_titled title=#{inspect(conversation.title)}"
        )

        {:ok, reply}

      true ->
        Logger.debug("Chat title generation requested conversation_id=#{conversation_id}")

        case ChatTitleGenerator.generate_chat_title(user_content, opts) do
          {:ok, title} when is_binary(title) and title != "" ->
            now = Persistence.now_ms()

            conversation
            |> ChatConversation.changeset(%{title: title, updated_at: now})
            |> Repo.update()
            |> case do
              {:ok, updated_conversation} ->
                {:ok, %{reply | conversation: format_conversation(updated_conversation)}}

              {:error, _reason} ->
                {:ok, reply}
            end

          _other ->
            {:ok, reply}
        end
    end
  end

  defp chat_round(
         _conversation,
         _messages,
         _endpoint,
         _model,
         _project_id,
         _tools,
         _runtime,
         _opts,
         0
       ) do
    {:error, %{kind: :tool_loop_exhausted}}
  end

  defp chat_round(
         conversation,
         messages,
         endpoint,
         model,
         project_id,
         tools,
         runtime,
         opts,
         rounds_left
       ) do
    request = build_chat_request(conversation, messages, model, project_id, tools)
    generate_opts = put_stream_callback(opts, conversation.id)

    with {:ok, response} <-
           runtime.generate(Runtime.endpoint_with_model(endpoint, model), request, generate_opts),
         {:ok, assistant_message} <- persist_assistant_response(conversation.id, response),
         :ok <- touch_conversation(conversation.id) do
      notify_assistant_content(response, conversation.id, opts)

      response
      |> Map.get(:tool_calls)
      |> decode_tool_calls()
      |> continue_chat_round(
        conversation.id,
        assistant_message,
        endpoint,
        model,
        project_id,
        tools,
        runtime,
        opts,
        rounds_left
      )
    end
  end

  defp delete_chat_conversation_test_hook(conversation_id) do
    case Application.get_env(:bds, :chat_delete_conversation_test_hook) do
      hook when is_function(hook, 1) -> hook.(conversation_id)
      _other -> :ok
    end
  end

  defp persist_assistant_response(conversation_id, response) do
    usage = normalize_usage(response.usage)

    content =
      case Map.get(response, :content) do
        nil -> encode_nullable(Map.get(response, :json))
        value -> value
      end

    persist_chat_message(%{
      conversation_id: conversation_id,
      role: :assistant,
      content: content,
      tool_calls: encode_nullable(Map.get(response, :tool_calls)),
      token_usage_input: usage.input_tokens,
      token_usage_output: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      created_at: Persistence.now_ms()
    })
  end

  defp execute_tool_calls(conversation_id, tool_calls, project_id, opts) do
    tool_messages =
      Enum.map(tool_calls, fn tool_call ->
        result = ChatTools.execute(tool_call.name, tool_call.arguments || %{}, project_id)

        {:ok, message} =
          persist_chat_message(%{
            conversation_id: conversation_id,
            role: :tool,
            content: Jason.encode!(result),
            tool_call_id: tool_call.id,
            created_at: Persistence.now_ms()
          })

        notify_chat_event(opts, {:chat_tool_result, conversation_id, tool_call.name})

        format_chat_message(message)
      end)

    {:ok, tool_messages}
  end

  defp continue_chat_round(
         tool_calls,
         conversation_id,
         assistant_message,
         endpoint,
         model,
         project_id,
         tools,
         runtime,
         opts,
         rounds_left
       ) do
    Enum.each(tool_calls, fn tool_call ->
      notify_chat_event(opts, {:chat_tool_call, conversation_id, tool_call})
    end)

    if tool_calls != [] and tools != [] do
      with {:ok, tool_messages} <- execute_tool_calls(conversation_id, tool_calls, project_id, opts),
           updated_messages <- load_chat_messages(conversation_id),
           {:ok, reply} <-
             chat_round(
               Repo.get!(ChatConversation, conversation_id),
               updated_messages,
               endpoint,
               model,
               project_id,
               tools,
               runtime,
               opts,
               rounds_left - 1
             ) do
        {:ok, Map.put(reply, :tool_messages, tool_messages)}
      end
    else
      final_chat_reply(conversation_id, assistant_message)
    end
  end

  defp final_chat_reply(conversation_id, assistant_message) do
    {:ok,
     %{
       conversation: format_conversation(Repo.get!(ChatConversation, conversation_id)),
       assistant_message: format_chat_message(assistant_message),
       tool_messages: []
     }}
  end

  defp notify_assistant_content(response, conversation_id, opts) do
    content = Map.get(response, :content)

    if is_binary(content) and String.trim(content) != "" do
      notify_chat_event(opts, {:chat_streaming_content, conversation_id, content})
    end

    :ok
  end

  defp build_chat_request(conversation, messages, model, project_id, tools) do
    system_message = %{"role" => "system", "content" => chat_system_prompt(project_id, tools)}

    %{
      operation: :chat,
      conversation_id: conversation.id,
      model: model,
      max_output_tokens: @default_max_output_tokens,
      tools: Enum.map(tools, & &1.spec),
      messages:
        [system_message | Enum.map(messages, &message_for_runtime/1)]
        |> truncate_chat_messages(model, tools)
    }
  end

  defp message_for_runtime(%ChatMessage{} = message) do
    base = %{"role" => Atom.to_string(message.role)}

    base =
      if is_binary(message.content), do: Map.put(base, "content", message.content), else: base

    base =
      if is_binary(message.tool_call_id),
        do: Map.put(base, "tool_call_id", message.tool_call_id),
        else: base

    case Catalog.decode_nullable_json(message.tool_calls) do
      nil -> base
      tool_calls -> Map.put(base, "tool_calls", tool_calls_for_runtime(tool_calls))
    end
  end

  defp tool_calls_for_runtime(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, &tool_call_for_runtime/1)
  end

  defp tool_calls_for_runtime(tool_calls), do: tool_calls

  defp tool_call_for_runtime(%{"type" => "function", "function" => %{} = _function} = tool_call) do
    tool_call
  end

  defp tool_call_for_runtime(%{"id" => id, "name" => name} = tool_call) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(tool_call["arguments"] || %{})
      }
    }
  end

  defp tool_call_for_runtime(%{id: id, name: name} = tool_call) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(Map.get(tool_call, :arguments) || %{})
      }
    }
  end

  defp tool_call_for_runtime(tool_call), do: tool_call

  defp truncate_chat_messages(messages, model, tools) do
    context_window = model_context_window(model)
    reserve = min(@default_max_output_tokens, max(div(context_window, 4), 512))
    tool_budget = length(tools) * 120
    max_budget = max(context_window - reserve - tool_budget, 512)

    [system | remainder] = messages

    {kept, _tokens} =
      Enum.reduce(Enum.reverse(remainder), {[], approximate_message_tokens(system)}, fn message,
                                                                                        {acc,
                                                                                         used} ->
        message_tokens = approximate_message_tokens(message)

        if used + message_tokens <= max_budget do
          {[message | acc], used + message_tokens}
        else
          {acc, used}
        end
      end)

    [system | kept]
  end

  defp available_chat_tools(project_id, model) do
    ChatTools.available_specs(project_id, Catalog.model_capabilities(model))
  end

  # BoundedToolLoop: the tool-calling round count is capped by
  # config.chat_max_tool_rounds (falling back to the built-in default).
  defp chat_max_tool_rounds do
    chat_config(:max_tool_rounds, @chat_max_tool_rounds)
  end

  defp chat_await_timeout_ms do
    per_request_timeout_ms = BDS.AI.HttpClient.request_timeout_ms()

    per_request_timeout_ms * (chat_max_tool_rounds() + 1) +
      chat_config(:await_timeout_margin_ms, @chat_await_timeout_margin_ms)
  end

  defp chat_config(key, default) do
    :bds
    |> Application.get_env(:chat, [])
    |> Keyword.get(key, default)
  end

  defp chat_system_prompt(project_id, tools) do
    base = get_setting("ai.system_prompt") || @default_system_prompt

    with true <- tools != [],
         summary when is_binary(summary) <- project_stats_summary(project_id) do
      base <> "\n\nCurrent blog statistics:\n" <> summary <> "\n\n" <> blog_tool_guidance()
    else
      _other -> base
    end
  end

  defp blog_tool_guidance do
    Enum.join(
      [
        "Available blog data tools:",
        "- Use get_blog_stats for aggregate counts of posts, media, tags, and categories.",
        "- Use search_posts for full-text blog search and filtered post lookup by category, tag, language, year, month, or status.",
        "- Use read_post to read a post by ID, or read_post_by_slug to read a post by slug.",
        "- Use read_post_by_slug to read full post content and metadata when a slug is known.",
        "- Use list_posts when asked for post titles, slugs, URLs, statuses, backlinks, or recent/top/latest post lists. This is allowed project data access.",
        "- Use get_media for one media item by ID, list_media for media titles, filenames, MIME types, or recent media lists, and view_image for visual image inspection.",
        "- Use update_post_metadata and update_media_metadata when asked to change titles, excerpts, tags, categories, alt text, or captions.",
        "- Use get_post_backlinks, get_post_outlinks, get_post_media, and get_media_posts for relationship questions.",
        "- Use list_tags, list_categories, and count_posts for taxonomy and grouped analytics questions.",
        "If a requested blog fact is available through these tools, call the tool instead of saying you cannot access the data.",
        "",
        "Available UI Render Tools (use these to show rich interactive elements):",
        "- render_chart: Show data as a bar, stacked-bar, line, area, pie, donut, or heatmap chart. Use when presenting statistics or comparisons. Use stacked-bar when each bar has multiple segments (e.g., published vs draft posts per year). Use area for cumulative or trend data where the filled region emphasizes volume. Use donut for proportional breakdowns with a total displayed in the center. Use heatmap for grid/matrix visualizations where color intensity shows magnitude — e.g., posts per month across years (each series entry is a row like a year, each segment is a column like a month), or a calendar view where rows are weekdays and columns are week numbers. ALWAYS prefer heatmap over a table with emojis or color indicators when showing intensity grids or calendar-style activity views. IMPORTANT: a heatmap needs structured data — each entry in 'series' is a ROW and must include a 'segments' array whose entries are the COLUMNS (every segment needs a 'label' and a numeric 'value'); the row's own 'value' is ignored. Plan what the rows and columns represent before fetching data (e.g. rows = years, columns = months). A heatmap sent without segments renders empty.",
        "- render_table: Show data in a structured table. Use for tabular comparisons and listings.",
        "- render_form: Show an interactive form to collect user input (e.g., metadata edits, settings).",
        "- render_card: Show an information card with title, body, and action buttons.",
        "- render_metric: Show a single KPI or statistic prominently.",
        "- render_list: Show a bulleted list of items.",
        "- render_tabs: Organize information into switchable tabs. Tab content supports all content types: text, metrics, lists, charts, and tables.",
        "",
        "When presenting data, statistics, or comparisons, prefer using render tools (render_chart, render_table, render_metric) to show rich interactive UI instead of plain text. When you need user input for a multi-field operation, use render_form to present a structured form. Use render_card with action buttons when presenting items the user might want to navigate to (e.g., posts, media). When comparing data across multiple dimensions (e.g., statistics per year), use render_tabs with embedded charts or tables in each tab. When building any visualization, render it as soon as you have enough data."
      ],
      "\n"
    )
  end

  defp project_stats_summary(nil), do: nil

  defp project_stats_summary(project_id) do
    post_count =
      Repo.aggregate(from(post in Post, where: post.project_id == ^project_id), :count, :id)

    media_count =
      Repo.aggregate(from(media in Media, where: media.project_id == ^project_id), :count, :id)

    tag_count = count_distinct_string_list(Post, :tags, project_id)
    category_count = count_distinct_string_list(Post, :categories, project_id)

    Enum.join(
      [
        "Posts: #{post_count}",
        "Media: #{media_count}",
        "Tags: #{tag_count}",
        "Categories: #{category_count}"
      ],
      "\n"
    )
  end

  defp load_chat_messages(conversation_id) do
    Repo.all(
      from message in ChatMessage,
        where: message.conversation_id == ^conversation_id,
        order_by: [asc: message.created_at, asc: message.id]
    )
  end

  defp persist_chat_message(attrs) do
    %ChatMessage{}
    |> ChatMessage.changeset(attrs)
    |> Repo.insert()
  end

  defp touch_conversation(conversation_id) do
    now = Persistence.now_ms()

    Repo.update_all(
      from(conversation in ChatConversation, where: conversation.id == ^conversation_id),
      set: [updated_at: now]
    )

    :ok
  end

  defp await_chat_task(task, timeout_ms) do
    ref = task.ref

    receive do
      {^ref, result} ->
        Process.demonitor(task.ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        case reason do
          :normal ->
            receive do
              {^ref, result} -> result
            after
              10 -> {:error, :cancelled}
            end

          :shutdown ->
            {:error, :cancelled}

          {:shutdown, _detail} ->
            {:error, :cancelled}

          _other ->
            {:error, :cancelled}
        end
    after
      timeout_ms ->
        _ = Task.shutdown(task, 100)
        {:error, :chat_timeout}
    end
  end

  defp decode_tool_calls(nil), do: []

  defp decode_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tool_call ->
      %{
        id: tool_call[:id] || tool_call["id"],
        name: tool_call[:name] || tool_call["name"],
        arguments: tool_call[:arguments] || tool_call["arguments"] || %{}
      }
    end)
  end

  defp approximate_message_tokens(message) when is_map(message) do
    message
    |> Map.values()
    |> Enum.map(&approximate_value_tokens/1)
    |> Enum.sum()
    |> Kernel.+(4)
  end

  defp approximate_value_tokens(value) when is_binary(value), do: div(String.length(value), 4) + 1

  defp approximate_value_tokens(value) when is_list(value),
    do: Enum.map(value, &approximate_value_tokens/1) |> Enum.sum()

  defp approximate_value_tokens(value) when is_map(value),
    do: Jason.encode!(value) |> approximate_value_tokens()

  defp approximate_value_tokens(_value), do: 1

  defp model_context_window(model_id) do
    case Catalog.get_catalog_model(model_id) do
      {:ok, model} when is_integer(model.context_window) and model.context_window > 0 ->
        model.context_window

      _other ->
        @default_context_window
    end
  end

  # When someone is listening for chat events, ask the runtime to stream:
  # it emits cumulative content snapshots, which the editor renders with
  # replace semantics. The full-content notify after each round stays the
  # authoritative final state (and the only event for non-streaming runtimes).
  defp put_stream_callback(opts, conversation_id) do
    case Keyword.get(opts, :event_target) do
      nil ->
        opts

      _target ->
        Keyword.put(opts, :on_stream, fn %{content: content} ->
          if is_binary(content) and String.trim(content) != "" do
            notify_chat_event(opts, {:chat_streaming_content, conversation_id, content})
          end

          :ok
        end)
    end
  end

  defp notify_chat_event(opts, event) do
    case Keyword.get(opts, :event_target) do
      pid when is_pid(pid) -> send(pid, event)
      callback when is_function(callback, 1) -> callback.(event)
      _other -> :ok
    end

    :ok
  end

  defp active_project_id do
    Repo.one(from project in Project, where: project.is_active == true, select: project.id)
  end

  defp encode_nullable(nil), do: nil
  defp encode_nullable(value), do: Jason.encode!(value)

  defp blank?(value), do: value in [nil, ""]
end
