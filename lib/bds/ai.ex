defmodule BDS.AI do
  @moduledoc false

  import Ecto.Query

  alias BDS.AI.CatalogMeta
  alias BDS.AI.CatalogProvider
  alias BDS.AI.ChatConversation
  alias BDS.AI.ChatMessage
  alias BDS.AI.InFlight
  alias BDS.AI.Model
  alias BDS.AI.ModelModality
  alias BDS.AI.OpenAICompatibleRuntime
  alias BDS.AI.SecretBackend
  alias BDS.Media.Media
  alias BDS.Persistence
  alias BDS.Posts.Post
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Settings.Setting

  @catalog_url "https://models.dev/api.json"
  @default_system_prompt "You are the bDS AI backend. Be precise, prefer structured JSON when asked, and avoid inventing blog facts."
  @default_max_output_tokens 16_384
  @chat_max_tool_rounds 10
  @default_context_window 128_000
  @model_preference_keys %{
    default: "ai.model.default",
    chat: "ai.model.chat",
    title: "ai.model.title",
    image_analysis: "ai.model.image_analysis",
    airplane_chat: "ai.airplane.model.chat",
    airplane_title: "ai.airplane.model.title",
    airplane_image_analysis: "ai.airplane.model.image_analysis"
  }

  def put_endpoint(kind, attrs, opts \\ []) when is_atom(kind) and is_map(attrs) and is_list(opts) do
    backend = Keyword.get(opts, :secret_backend, SecretBackend)
    kind_key = Atom.to_string(kind)

    url = Map.get(attrs, :url) || Map.get(attrs, "url")
    model = Map.get(attrs, :model) || Map.get(attrs, "model")
    api_key = Map.get(attrs, :api_key) || Map.get(attrs, "api_key")

    with :ok <- put_setting("ai.#{kind_key}.url", url),
         :ok <- put_setting("ai.#{kind_key}.model", model),
         :ok <- put_secret("ai.#{kind_key}.api_key", api_key, backend) do
      {:ok, %{kind: kind, url: url, api_key: api_key, model: model}}
    end
  end

  def get_endpoint(kind, opts \\ []) when is_atom(kind) and is_list(opts) do
    backend = Keyword.get(opts, :secret_backend, SecretBackend)
    kind_key = Atom.to_string(kind)
    url = get_setting("ai.#{kind_key}.url")
    model = get_setting("ai.#{kind_key}.model")
    encrypted_api_key = get_setting(encrypted_key("ai.#{kind_key}.api_key"))

    cond do
      is_nil(url) and is_nil(model) and is_nil(encrypted_api_key) ->
        {:ok, nil}

      true ->
        with {:ok, api_key} <- get_secret(encrypted_api_key, backend) do
          {:ok, %{kind: kind, url: url, api_key: api_key, model: model}}
        end
    end
  end

  def delete_endpoint(kind) when is_atom(kind) do
    kind_key = Atom.to_string(kind)
    delete_setting("ai.#{kind_key}.url")
    delete_setting("ai.#{kind_key}.model")
    delete_setting(encrypted_key("ai.#{kind_key}.api_key"))
    :ok
  end

  def refresh_model_catalog(opts \\ []) when is_list(opts) do
    http_client = Keyword.get(opts, :http_client, BDS.AI.HttpClient)

    headers =
      %{"accept" => "application/json"}
      |> maybe_put_header("if-none-match", get_catalog_meta_value("etag"))

    with {:ok, response} <- http_get(http_client, @catalog_url, headers) do
      case response.status do
        304 ->
          :ok = put_catalog_meta("last_fetched_at", DateTime.utc_now() |> DateTime.to_iso8601())
          {:ok, %{success: true, models_updated: 0, not_modified: true}}

        200 ->
          payload = Jason.decode!(response.body)
          models_updated = persist_catalog(payload)

          if etag = response.headers["etag"] do
            :ok = put_catalog_meta("etag", etag)
          end

          :ok = put_catalog_meta("last_fetched_at", DateTime.utc_now() |> DateTime.to_iso8601())

          {:ok, %{success: true, models_updated: models_updated, not_modified: false}}

        status ->
          {:error, %{kind: :http_error, status: status}}
      end
    end
  end

  def list_catalog_providers do
    Repo.all(from provider in CatalogProvider, order_by: [asc: provider.id])
    |> Enum.map(fn provider ->
      %{
        id: provider.id,
        name: provider.name,
        env_keys: decode_json_list(provider.env_keys),
        package_ref: provider.package_ref,
        api_url: provider.api_url,
        doc_url: provider.doc_url,
        updated_at: provider.updated_at
      }
    end)
  end

  def get_catalog_model(model_id, provider_id \\ nil) when is_binary(model_id) do
    query =
      from model in Model,
        where: model.model_id == ^model_id,
        order_by: [asc: model.provider]

    query =
      case provider_id do
        nil -> query
        provider -> from model in query, where: model.provider == ^provider
      end

    case Repo.one(query) do
      nil -> {:error, :not_found}
      model -> {:ok, format_model(model)}
    end
  end

  def catalog_meta(key) when is_binary(key) do
    {:ok, get_catalog_meta_value(key)}
  end

  def set_airplane_mode(enabled) when is_boolean(enabled) do
    put_setting("ai.airplane_mode_enabled", Atom.to_string(enabled))
  end

  def airplane_mode? do
    get_setting("ai.airplane_mode_enabled") == "true"
  end

  def put_model_preference(key, model) when is_atom(key) and is_binary(model) do
    case Map.fetch(@model_preference_keys, key) do
      {:ok, setting_key} -> put_setting(setting_key, model)
      :error -> {:error, :unknown_model_preference}
    end
  end

  def get_model_preference(key) when is_atom(key) do
    case Map.fetch(@model_preference_keys, key) do
      {:ok, setting_key} -> {:ok, get_setting(setting_key)}
      :error -> {:error, :unknown_model_preference}
    end
  end

  def put_model_capabilities(model_id, attrs) when is_binary(model_id) and is_map(attrs) do
    capabilities = %{
      supports_attachment: truthy?(Map.get(attrs, :supports_attachment) || Map.get(attrs, "supports_attachment")),
      supports_tool_calls: truthy?(Map.get(attrs, :supports_tool_calls) || Map.get(attrs, "supports_tool_calls"))
    }

    put_setting("ai.model_capabilities.#{model_id}", Jason.encode!(capabilities))
  end

  def detect_language(text, opts \\ []) when is_binary(text) and is_list(opts) do
    run_one_shot(
      :detect_language,
      %{text: text},
      opts,
      fn json, usage ->
        {:ok, %{language_code: json["language_code"], usage: usage}}
      end
    )
  end

  def analyze_taxonomy(post_input, opts \\ []) when is_list(opts) do
    with {:ok, post} <- normalize_post_input(post_input) do
      run_one_shot(
        :analyze_taxonomy,
        post,
        opts,
        fn json, usage ->
          {:ok,
           %{
             tags: json["tags"] || [],
             categories: json["categories"] || [],
             usage: usage
           }}
        end
      )
    end
  end

  def analyze_post(post_input, opts \\ []) when is_list(opts) do
    with {:ok, post} <- normalize_post_input(post_input) do
      run_one_shot(
        :analyze_post,
        post,
        opts,
        fn json, usage ->
          {:ok,
           %{
             title: json["title"],
             excerpt: json["excerpt"],
             slug: json["slug"],
             usage: usage
           }}
        end
      )
    end
  end

  def translate_post(post_input, target_language, opts \\ [])
      when is_binary(target_language) and is_list(opts) do
    with {:ok, post} <- normalize_post_input(post_input) do
      run_one_shot(
        :translate_post,
        Map.put(post, :target_language, target_language),
        opts,
        fn json, usage ->
          {:ok,
           %{
             title: json["title"],
             excerpt: json["excerpt"],
             content: json["content"],
             usage: usage
           }}
        end
      )
    end
  end

  def analyze_image(media_input, opts \\ []) when is_list(opts) do
    with {:ok, media} <- normalize_media_input(media_input),
         :ok <- ensure_image_media(media) do
      run_one_shot(
        :analyze_image,
        media,
        opts,
        fn json, usage ->
          {:ok,
           %{
             title: json["title"],
             alt: json["alt"],
             caption: json["caption"],
             usage: usage
           }}
        end
      )
    end
  end

  def translate_media(media_input, target_language, opts \\ [])
      when is_binary(target_language) and is_list(opts) do
    with {:ok, media} <- normalize_media_input(media_input) do
      run_one_shot(
        :translate_media,
        Map.put(media, :target_language, target_language),
        opts,
        fn json, usage ->
          {:ok,
           %{
             title: json["title"],
             alt: json["alt"],
             caption: json["caption"],
             usage: usage
           }}
        end
      )
    end
  end

  def start_chat(attrs \\ %{}) when is_map(attrs) do
    now = Persistence.now_ms()
    model = Map.get(attrs, :model) || Map.get(attrs, "model")
    title = Map.get(attrs, :title) || Map.get(attrs, "title") || generated_chat_title(model)

    %ChatConversation{}
    |> ChatConversation.changeset(%{
      id: Ecto.UUID.generate(),
      title: title,
      model: model,
      copilot_session_id: Map.get(attrs, :copilot_session_id) || Map.get(attrs, "copilot_session_id"),
      created_at: now,
      updated_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, conversation} -> {:ok, format_conversation(conversation)}
      error -> error
    end
  end

  def list_chat_conversations do
    Repo.all(from conversation in ChatConversation, order_by: [desc: conversation.updated_at])
    |> Enum.map(&format_conversation/1)
  end

  def list_chat_messages(conversation_id) when is_binary(conversation_id) do
    Repo.all(
      from message in ChatMessage,
        where: message.conversation_id == ^conversation_id,
        order_by: [asc: message.created_at, asc: message.id]
    )
    |> Enum.map(&format_chat_message/1)
  end

  def send_chat_message(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and is_binary(content) and is_list(opts) do
    with %ChatConversation{} = conversation <- Repo.get(ChatConversation, conversation_id),
         {:ok, user_message} <- persist_chat_message(%{
           conversation_id: conversation.id,
           role: :user,
           content: content,
           created_at: Persistence.now_ms()
         }) do
      task =
        Task.Supervisor.async_nolink(BDS.Tasks.TaskSupervisor, fn ->
          receive do
            :sandbox_ready -> :ok
          end

          do_send_chat_message(conversation, user_message, opts)
        end)

      InFlight.register(conversation.id, task.pid)
      :ok = allow_repo_sandbox(task.pid)
      send(task.pid, :sandbox_ready)

      try do
        await_chat_task(task)
      after
        InFlight.unregister(conversation.id)
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def cancel_chat(conversation_id) when is_binary(conversation_id) do
    case InFlight.lookup(conversation_id) do
      nil -> :ok
      pid ->
        _ = Task.Supervisor.terminate_child(BDS.Tasks.TaskSupervisor, pid)
        :ok
    end
  end

  defp format_model(model) do
    modalities =
      Repo.all(
        from modality in ModelModality,
          where: modality.provider == ^model.provider and modality.model_id == ^model.model_id
      )

    %{
      provider: model.provider,
      model_id: model.model_id,
      name: model.name,
      family: model.family,
      supports_attachment: model.supports_attachment,
      supports_reasoning: model.supports_reasoning,
      supports_tool_calls: model.supports_tool_calls,
      supports_structured_output: model.supports_structured_output,
      supports_temperature: model.supports_temperature,
      knowledge: model.knowledge,
      release_date: model.release_date,
      last_updated_date: model.last_updated_date,
      open_weights: model.open_weights,
      input_price: model.input_price,
      output_price: model.output_price,
      cache_read_price: model.cache_read_price,
      cache_write_price: model.cache_write_price,
      context_window: model.context_window,
      max_input_tokens: model.max_input_tokens,
      max_output_tokens: model.max_output_tokens,
      interleaved: model.interleaved,
      status: model.status,
      updated_at: model.updated_at,
      input_modalities:
        modalities
        |> Enum.filter(&(&1.direction == :input))
        |> Enum.map(&Atom.to_string(&1.modality)),
      output_modalities:
        modalities
        |> Enum.filter(&(&1.direction == :output))
        |> Enum.map(&Atom.to_string(&1.modality))
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
      tool_calls: decode_nullable_json(message.tool_calls),
      token_usage_input: message.token_usage_input,
      token_usage_output: message.token_usage_output,
      cache_read_tokens: message.cache_read_tokens,
      cache_write_tokens: message.cache_write_tokens,
      created_at: message.created_at
    }
  end

  defp run_one_shot(operation, payload, opts, formatter) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)

    with {:ok, endpoint, model, mode} <- resolve_runtime_target(operation, secret_backend: Keyword.get(opts, :secret_backend, SecretBackend)),
         :ok <- validate_runtime_target(operation, model, mode),
         request <- build_one_shot_request(operation, payload, model),
         {:ok, response} <- runtime.generate(endpoint_with_model(endpoint, model), request, opts),
         {:ok, json} <- extract_json_response(response),
         usage <- normalize_usage(response.usage),
         {:ok, result} <- formatter.(json, usage) do
      {:ok, result}
    end
  end

  defp do_send_chat_message(conversation, _user_message, opts) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)
    project_id = Keyword.get(opts, :project_id, active_project_id())

    with {:ok, endpoint, model, mode} <-
           resolve_runtime_target(
             :chat,
             conversation: conversation,
             secret_backend: Keyword.get(opts, :secret_backend, SecretBackend)
           ),
         :ok <- validate_runtime_target(:chat, model, mode),
         messages <- load_chat_messages(conversation.id),
         tools <- available_chat_tools(project_id, model),
         {:ok, reply} <- chat_round(conversation, messages, endpoint, model, project_id, tools, runtime, opts, @chat_max_tool_rounds) do
      {:ok, reply}
    end
  end

  defp chat_round(_conversation, _messages, _endpoint, _model, _project_id, _tools, _runtime, _opts, 0) do
    {:error, %{kind: :tool_loop_exhausted}}
  end

  defp chat_round(conversation, messages, endpoint, model, project_id, tools, runtime, opts, rounds_left) do
    request = build_chat_request(conversation, messages, model, project_id, tools)

    with {:ok, response} <- runtime.generate(endpoint_with_model(endpoint, model), request, opts),
         {:ok, assistant_message} <- persist_assistant_response(conversation.id, response),
         :ok <- touch_conversation(conversation.id) do
      tool_calls = decode_tool_calls(Map.get(response, :tool_calls))

      cond do
        tool_calls != [] and tools != [] ->
          with {:ok, tool_messages} <- execute_tool_calls(conversation.id, tool_calls, project_id),
               updated_messages <- load_chat_messages(conversation.id),
               {:ok, reply} <-
                 chat_round(
                   Repo.get!(ChatConversation, conversation.id),
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

        true ->
          {:ok,
           %{
             conversation: format_conversation(Repo.get!(ChatConversation, conversation.id)),
             assistant_message: format_chat_message(assistant_message),
             tool_messages: []
           }}
      end
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

  defp execute_tool_calls(conversation_id, tool_calls, project_id) do
    tool_messages =
      Enum.map(tool_calls, fn tool_call ->
        result = execute_tool(tool_call.name, tool_call.arguments || %{}, project_id)

        {:ok, message} =
          persist_chat_message(%{
            conversation_id: conversation_id,
            role: :tool,
            content: Jason.encode!(result),
            tool_call_id: tool_call.id,
            created_at: Persistence.now_ms()
          })

        format_chat_message(message)
      end)

    {:ok, tool_messages}
  end

  defp execute_tool("blog_stats", _arguments, project_id) do
    project_id = project_id || active_project_id()

    %{
      post_count: Repo.aggregate(from(post in Post, where: post.project_id == ^project_id), :count, :id),
      media_count: Repo.aggregate(from(media in Media, where: media.project_id == ^project_id), :count, :id),
      tag_count: count_distinct_string_list(Post, :tags, project_id),
      category_count: count_distinct_string_list(Post, :categories, project_id)
    }
  end

  defp execute_tool("list_posts", arguments, project_id) do
    limit = normalize_limit(arguments["limit"])

    Repo.all(
      from post in Post,
        where: post.project_id == ^project_id,
        order_by: [desc: post.updated_at],
        limit: ^limit,
        select: %{id: post.id, title: post.title, slug: post.slug, status: post.status}
    )
  end

  defp execute_tool("list_media", arguments, project_id) do
    limit = normalize_limit(arguments["limit"])

    Repo.all(
      from media in Media,
        where: media.project_id == ^project_id,
        order_by: [desc: media.updated_at],
        limit: ^limit,
        select: %{id: media.id, title: media.title, mime_type: media.mime_type, filename: media.filename}
    )
  end

  defp execute_tool("render_table", arguments, _project_id) do
    %{
      type: "table",
      title: arguments["title"],
      columns: arguments["columns"] || [],
      rows: arguments["rows"] || []
    }
  end

  defp execute_tool("render_chart", arguments, _project_id) do
    %{
      type: "chart",
      title: arguments["title"],
      chart_type: arguments["chart_type"] || "bar",
      series: arguments["series"] || []
    }
  end

  defp execute_tool("render_form", arguments, _project_id) do
    %{
      type: "form",
      title: arguments["title"],
      fields: arguments["fields"] || []
    }
  end

  defp execute_tool(name, _arguments, _project_id) do
    %{error: "unknown_tool", name: name}
  end

  defp build_one_shot_request(operation, payload, model) do
    %{
      operation: operation,
      model: model,
      max_output_tokens: @default_max_output_tokens,
      messages: [
        %{"role" => "system", "content" => one_shot_system_prompt(operation)},
        %{"role" => "user", "content" => one_shot_user_content(operation, payload)}
      ]
    }
  end

  defp build_chat_request(conversation, messages, model, project_id, tools) do
    system_message = %{"role" => "system", "content" => chat_system_prompt(project_id)}

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

    base = if is_binary(message.content), do: Map.put(base, "content", message.content), else: base
    base = if is_binary(message.tool_call_id), do: Map.put(base, "tool_call_id", message.tool_call_id), else: base

    case decode_nullable_json(message.tool_calls) do
      nil -> base
      tool_calls -> Map.put(base, "tool_calls", tool_calls)
    end
  end

  defp truncate_chat_messages(messages, model, tools) do
    context_window = model_context_window(model)
    reserve = min(@default_max_output_tokens, max(div(context_window, 4), 512))
    tool_budget = length(tools) * 120
    max_budget = max(context_window - reserve - tool_budget, 512)

    [system | remainder] = messages

    {kept, _tokens} =
      Enum.reduce(Enum.reverse(remainder), {[], approximate_message_tokens(system)}, fn message, {acc, used} ->
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
    if model_capabilities(model).supports_tool_calls do
      project_tools =
        if is_binary(project_id) do
          [
            %{name: "blog_stats", spec: tool_spec("blog_stats", "Return aggregate blog statistics", %{"type" => "object", "properties" => %{}})},
            %{name: "list_posts", spec: tool_spec("list_posts", "List recent posts in the active project", limit_schema())},
            %{name: "list_media", spec: tool_spec("list_media", "List recent media items in the active project", limit_schema())}
          ]
        else
          []
        end

      project_tools ++
        [
          %{name: "render_table", spec: tool_spec("render_table", "Return a structured table payload", render_table_schema())},
          %{name: "render_chart", spec: tool_spec("render_chart", "Return a structured chart payload", render_chart_schema())},
          %{name: "render_form", spec: tool_spec("render_form", "Return a structured form payload", render_form_schema())}
        ]
    else
      []
    end
  end

  defp resolve_runtime_target(operation, extra) do
    mode = if airplane_mode?(), do: :airplane, else: :online
    secret_backend = Keyword.get(extra, :secret_backend, SecretBackend)

    with {:ok, endpoint} <- fetch_endpoint_for_mode(mode, secret_backend),
         {:ok, model} <- resolve_model_for_operation(operation, mode, endpoint, extra) do
      {:ok, endpoint, model, mode}
    end
  end

  defp resolve_model_for_operation(:chat, :airplane, endpoint, _extra) do
    {:ok, get_model_preference_value(:airplane_chat) || endpoint.model}
  end

  defp resolve_model_for_operation(:chat, :online, endpoint, conversation: conversation) do
    {:ok, conversation.model || get_model_preference_value(:chat) || get_model_preference_value(:default) || endpoint.model}
  end

  defp resolve_model_for_operation(:chat, :online, endpoint, _extra) do
    {:ok, get_model_preference_value(:chat) || get_model_preference_value(:default) || endpoint.model}
  end

  defp resolve_model_for_operation(:analyze_image, :airplane, endpoint, _extra) do
    {:ok, get_model_preference_value(:airplane_image_analysis) || endpoint.model}
  end

  defp resolve_model_for_operation(:analyze_image, :online, endpoint, _extra) do
    {:ok, get_model_preference_value(:image_analysis) || get_model_preference_value(:default) || endpoint.model}
  end

  defp resolve_model_for_operation(_operation, :airplane, endpoint, _extra) do
    {:ok, get_model_preference_value(:airplane_title) || endpoint.model}
  end

  defp resolve_model_for_operation(_operation, :online, endpoint, _extra) do
    {:ok, get_model_preference_value(:title) || get_model_preference_value(:default) || endpoint.model}
  end

  defp validate_runtime_target(:analyze_image, model, _mode) do
    if model_capabilities(model).supports_attachment do
      :ok
    else
      {:error, %{kind: :model_capability_missing, capability: :supports_attachment, model: model}}
    end
  end

  defp validate_runtime_target(_operation, _model, _mode), do: :ok

  defp fetch_endpoint_for_mode(mode, secret_backend) do
    with {:ok, endpoint} <- get_endpoint(mode, secret_backend: secret_backend) do
      case endpoint do
        %{url: url, model: model} = loaded when is_binary(url) and url != "" and is_binary(model) and model != "" ->
          if mode == :online and blank?(loaded.api_key) do
            {:error, %{kind: :endpoint_not_configured, endpoint: mode}}
          else
            {:ok, loaded}
          end

        _other ->
          {:error, %{kind: :endpoint_not_configured, endpoint: mode}}
      end
    end
  end

  defp endpoint_with_model(endpoint, model), do: Map.put(endpoint, :model, model)

  defp get_model_preference_value(key) do
    case get_model_preference(key) do
      {:ok, value} -> value
      _other -> nil
    end
  end

  defp chat_system_prompt(project_id) do
    base = get_setting("ai.system_prompt") || @default_system_prompt

    case project_stats_summary(project_id) do
      nil -> base
      summary -> base <> "\n\nCurrent blog statistics:\n" <> summary
    end
  end

  defp project_stats_summary(nil), do: nil

  defp project_stats_summary(project_id) do
    post_count = Repo.aggregate(from(post in Post, where: post.project_id == ^project_id), :count, :id)
    media_count = Repo.aggregate(from(media in Media, where: media.project_id == ^project_id), :count, :id)
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

  defp count_distinct_string_list(schema, field, project_id) do
    Repo.all(from record in schema, where: field(record, :project_id) == ^project_id, select: field(record, ^field))
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp one_shot_system_prompt(:detect_language) do
    "Return JSON with exactly one key: language_code."
  end

  defp one_shot_system_prompt(:analyze_taxonomy) do
    "Return JSON with keys tags and categories, each an array of short strings."
  end

  defp one_shot_system_prompt(:analyze_post) do
    "Return JSON with keys title, excerpt, and slug."
  end

  defp one_shot_system_prompt(:translate_post) do
    "Return JSON with keys title, excerpt, and content. Preserve Markdown structure."
  end

  defp one_shot_system_prompt(:analyze_image) do
    "Return JSON with keys title, alt, and caption for the provided image."
  end

  defp one_shot_system_prompt(:translate_media) do
    "Return JSON with keys title, alt, and caption translated to the requested language."
  end

  defp one_shot_user_content(:detect_language, %{text: text}) do
    "Detect the language of this text: #{text}"
  end

  defp one_shot_user_content(:analyze_taxonomy, post) do
    "Suggest categories and tags for the following post.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{truncate_text(post.content, 2000)}"
  end

  defp one_shot_user_content(:analyze_post, post) do
    "Suggest an improved title, excerpt, and slug.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{truncate_text(post.content, 2000)}"
  end

  defp one_shot_user_content(:translate_post, post) do
    "Translate this post to #{post.target_language}.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{post.content}"
  end

  defp one_shot_user_content(:analyze_image, media) do
    [
      %{"type" => "text", "text" => "Analyze this image and return title, alt text, and caption."},
      %{"type" => "image_url", "image_url" => %{"url" => media.image_url}}
    ]
  end

  defp one_shot_user_content(:translate_media, media) do
    "Translate this media metadata to #{media.target_language}.\nTitle: #{media.title}\nAlt: #{media.alt}\nCaption: #{media.caption}"
  end

  defp extract_json_response(%{json: json}) when is_map(json), do: {:ok, json}

  defp extract_json_response(%{content: content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _other -> {:error, %{kind: :invalid_json_response}}
    end
  end

  defp extract_json_response(_response), do: {:error, %{kind: :invalid_json_response}}

  defp normalize_post_input(%Post{} = post) do
    {:ok, %{title: post.title || "", excerpt: post.excerpt || "", content: post.content || ""}}
  end

  defp normalize_post_input(post_id) when is_binary(post_id) do
    case Repo.get(Post, post_id) do
      nil -> {:error, :not_found}
      post -> normalize_post_input(post)
    end
  end

  defp normalize_post_input(attrs) when is_map(attrs) do
    {:ok,
     %{
       title: Map.get(attrs, :title) || Map.get(attrs, "title") || "",
       excerpt: Map.get(attrs, :excerpt) || Map.get(attrs, "excerpt") || "",
       content: Map.get(attrs, :content) || Map.get(attrs, "content") || ""
     }}
  end

  defp normalize_media_input(%Media{} = media) do
    {:ok,
     %{
       mime_type: media.mime_type,
       title: media.title || "",
       alt: media.alt || "",
       caption: media.caption || "",
       image_url: Map.get(media, :image_url) || media_path_to_file_url(media.file_path)
     }}
  end

  defp normalize_media_input(media_id) when is_binary(media_id) do
    case Repo.get(Media, media_id) do
      nil -> {:error, :not_found}
      media -> normalize_media_input(media)
    end
  end

  defp normalize_media_input(attrs) when is_map(attrs) do
    {:ok,
     %{
       mime_type: Map.get(attrs, :mime_type) || Map.get(attrs, "mime_type"),
       title: Map.get(attrs, :title) || Map.get(attrs, "title") || "",
       alt: Map.get(attrs, :alt) || Map.get(attrs, "alt") || "",
       caption: Map.get(attrs, :caption) || Map.get(attrs, "caption") || "",
       image_url: Map.get(attrs, :image_url) || Map.get(attrs, "image_url")
     }}
  end

  defp ensure_image_media(%{mime_type: "image/" <> _rest}), do: :ok
  defp ensure_image_media(_media), do: {:error, %{kind: :invalid_media_type}}

  defp media_path_to_file_url(nil), do: nil
  defp media_path_to_file_url(path), do: "file://" <> path

  defp model_capabilities(model_id) do
    overrides = decode_model_capabilities_override(model_id)

    from_catalog =
      case get_catalog_model(model_id) do
        {:ok, model} ->
          %{
            supports_attachment: model.supports_attachment or ("image" in model.input_modalities),
            supports_tool_calls: model.supports_tool_calls
          }

        _other ->
          inferred_model_capabilities(model_id)
      end

    Map.merge(from_catalog, overrides)
  end

  defp inferred_model_capabilities(model_id) do
    normalized = String.downcase(model_id)

    %{
      supports_attachment:
        String.contains?(normalized, "4o") or String.contains?(normalized, "vision") or
          String.contains?(normalized, "llava"),
      supports_tool_calls:
        String.contains?(normalized, "gpt") or String.contains?(normalized, "claude") or
          String.contains?(normalized, "tool")
    }
  end

  defp decode_model_capabilities_override(model_id) do
    case get_setting("ai.model_capabilities.#{model_id}") do
      nil -> %{}
      value -> Jason.decode!(value) |> atomize_map_keys()
    end
  end

  defp atomize_map_keys(map) do
    Enum.into(map, %{}, fn {key, value} -> {String.to_atom(key), value} end)
  end

  defp generated_chat_title(nil), do: "New Chat"
  defp generated_chat_title(model), do: "Chat with #{model}"

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

  defp await_chat_task(task) do
    receive do
      {ref, result} when ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        result

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        case reason do
          :normal ->
            receive do
              {^ref, result} -> result
            after
              10 -> {:error, :cancelled}
            end

          :shutdown -> {:error, :cancelled}
          {:shutdown, _detail} -> {:error, :cancelled}
          _other -> {:error, :cancelled}
        end
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
  defp approximate_value_tokens(value) when is_list(value), do: Enum.map(value, &approximate_value_tokens/1) |> Enum.sum()
  defp approximate_value_tokens(value) when is_map(value), do: Jason.encode!(value) |> approximate_value_tokens()
  defp approximate_value_tokens(_value), do: 1

  defp model_context_window(model_id) do
    case get_catalog_model(model_id) do
      {:ok, model} when is_integer(model.context_window) and model.context_window > 0 -> model.context_window
      _other -> @default_context_window
    end
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"],
      output_tokens: usage[:output_tokens] || usage["output_tokens"],
      cache_read_tokens: usage[:cache_read_tokens] || usage["cache_read_tokens"],
      cache_write_tokens: usage[:cache_write_tokens] || usage["cache_write_tokens"]
    }
  end

  defp normalize_usage(_usage) do
    %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_tokens: nil,
      cache_write_tokens: nil
    }
  end

  defp tool_spec(name, description, parameters) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => description,
        "parameters" => parameters
      }
    }
  end

  defp limit_schema do
    %{
      "type" => "object",
      "properties" => %{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
      }
    }
  end

  defp render_table_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "columns" => %{"type" => "array"},
        "rows" => %{"type" => "array"}
      }
    }
  end

  defp render_chart_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "chart_type" => %{"type" => "string"},
        "series" => %{"type" => "array"}
      }
    }
  end

  defp render_form_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "fields" => %{"type" => "array"}
      }
    }
  end

  defp normalize_limit(value) when is_integer(value) and value > 0 and value <= 50, do: value
  defp normalize_limit(_value), do: 10

  defp truncate_text(nil, _max_length), do: ""

  defp truncate_text(text, max_length) when is_binary(text) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length)
    end
  end

  defp active_project_id do
    Repo.one(from project in Project, where: project.is_active == true, select: project.id)
  end

  defp allow_repo_sandbox(pid) when is_pid(pid) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(BDS.Repo, self(), pid)
      rescue
        _error -> :ok
      end
    else
      :ok
    end

    :ok
  end

  defp persist_catalog(payload) do
    now = Persistence.now_ms()

    Repo.transaction(fn ->
      Repo.delete_all(ModelModality)
      Repo.delete_all(Model)
      Repo.delete_all(CatalogProvider)

      Enum.reduce(payload, 0, fn {provider_id, provider_data}, count ->
        provider_attrs = %{
          id: provider_id,
          name: Map.get(provider_data, "name", provider_id),
          env_keys: Jason.encode!(Map.get(provider_data, "env", [])),
          package_ref: Map.get(provider_data, "npm"),
          api_url: Map.get(provider_data, "api"),
          doc_url: Map.get(provider_data, "doc"),
          updated_at: now
        }

        %CatalogProvider{}
        |> CatalogProvider.changeset(provider_attrs)
        |> Repo.insert!()

        models = Map.get(provider_data, "models", %{})

        Enum.reduce(models, count, fn {model_id, model_data}, inner_count ->
          model_attrs = %{
            provider: provider_id,
            model_id: model_id,
            name: Map.get(model_data, "name", model_id),
            family: Map.get(model_data, "family"),
            supports_attachment: Map.get(model_data, "attachment", false),
            supports_reasoning: Map.get(model_data, "reasoning", false),
            supports_tool_calls: Map.get(model_data, "tool_call", false),
            supports_structured_output: Map.get(model_data, "structured_output", false),
            supports_temperature: Map.get(model_data, "temperature", false),
            knowledge: Map.get(model_data, "knowledge"),
            release_date: Map.get(model_data, "release_date"),
            last_updated_date: Map.get(model_data, "last_updated"),
            open_weights: Map.get(model_data, "open_weights", false),
            input_price: get_in(model_data, ["cost", "input"]),
            output_price: get_in(model_data, ["cost", "output"]),
            cache_read_price: get_in(model_data, ["cost", "cache_read"]),
            cache_write_price: get_in(model_data, ["cost", "cache_write"]),
            context_window: get_in(model_data, ["limit", "context"]) || 0,
            max_input_tokens: get_in(model_data, ["limit", "input"]) || 0,
            max_output_tokens: get_in(model_data, ["limit", "output"]) || 0,
            interleaved: encode_nullable(Map.get(model_data, "interleaved")),
            status: Map.get(model_data, "status"),
            updated_at: now
          }

          %Model{}
          |> Model.changeset(model_attrs)
          |> Repo.insert!()

          insert_modalities(provider_id, model_id, Map.get(model_data, "input_modalities", []), :input)
          insert_modalities(provider_id, model_id, Map.get(model_data, "output_modalities", []), :output)

          inner_count + 1
        end)
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, reason} -> raise reason
    end
  end

  defp insert_modalities(provider_id, model_id, modalities, direction) do
    Enum.each(modalities, fn modality ->
      %ModelModality{}
      |> ModelModality.changeset(%{
        provider: provider_id,
        model_id: model_id,
        direction: direction,
        modality: parse_modality(modality)
      })
      |> Repo.insert!()
    end)
  end

  defp parse_modality("text"), do: :text
  defp parse_modality("image"), do: :image
  defp parse_modality("audio"), do: :audio
  defp parse_modality("file"), do: :file
  defp parse_modality("tool"), do: :tool
  defp parse_modality(other) when is_binary(other), do: String.to_atom(other)

  defp encode_nullable(nil), do: nil
  defp encode_nullable(value), do: Jason.encode!(value)

  defp decode_nullable_json(nil), do: nil
  defp decode_nullable_json(value) when is_binary(value), do: Jason.decode!(value)

  defp http_get(client, url, headers) when is_atom(client), do: client.get(url, headers)
  defp http_get(client, url, headers) when is_function(client, 2), do: client.(url, headers)

  defp put_secret(_key, nil, _backend), do: :ok

  defp put_secret(key, value, backend) do
    with {:ok, encrypted_value} <- backend.encrypt(value) do
      put_setting(encrypted_key(key), encrypted_value)
    end
  end

  defp get_secret(nil, _backend), do: {:ok, nil}

  defp get_secret(value, backend) do
    backend.decrypt(value)
  end

  defp encrypted_key(key), do: "__encrypted_#{key}"

  defp get_catalog_meta_value(key) do
    case Repo.get(CatalogMeta, key) do
      nil -> get_setting("ai.catalog.#{key}")
      meta -> meta.value
    end
  end

  defp put_catalog_meta(key, value) do
    %CatalogMeta{}
    |> CatalogMeta.changeset(%{key: key, value: value})
    |> Repo.insert(
      on_conflict: [set: [value: value]],
      conflict_target: [:key]
    )

    :ok
  end

  defp get_setting(key) do
    case Repo.get(Setting, key) do
      nil -> nil
      setting -> setting.value
    end
  end

  defp put_setting(key, value) when is_binary(key) and is_binary(value) do
    now = Persistence.now_ms()

    (%Setting{}
     |> Setting.changeset(%{key: key, value: value, updated_at: now}))
    |> Repo.insert(
      on_conflict: [set: [value: value, updated_at: now]],
      conflict_target: [:key]
    )

    :ok
  end

  defp delete_setting(key) do
    Repo.delete_all(from setting in Setting, where: setting.key == ^key)
    :ok
  end

  defp blank?(value), do: value in [nil, ""]

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, key, value), do: Map.put(headers, key, value)

  defp decode_json_list(nil), do: []
  defp decode_json_list(value), do: Jason.decode!(value)
end
