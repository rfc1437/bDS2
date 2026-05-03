defmodule BDS.AI.OneShot do
  @moduledoc false

  require Logger

  alias BDS.AI.Chat
  alias BDS.AI.OpenAICompatibleRuntime
  alias BDS.AI.Runtime
  alias BDS.Media.Media
  alias BDS.MapUtils
  alias BDS.Posts
  alias BDS.Posts.Post
  alias BDS.Projects
  alias BDS.Repo

  @default_max_output_tokens 16_384

  @spec detect_language(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec analyze_taxonomy(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec analyze_import_taxonomy(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze_import_taxonomy(import_terms, existing_terms, opts \\ [])
      when is_map(import_terms) and is_map(existing_terms) and is_list(opts) do
    payload = %{
      import_categories: normalize_string_list(MapUtils.attr(import_terms, :categories)),
      import_tags: normalize_string_list(MapUtils.attr(import_terms, :tags)),
      existing_categories: normalize_string_list(MapUtils.attr(existing_terms, :categories)),
      existing_tags: normalize_string_list(MapUtils.attr(existing_terms, :tags))
    }

    run_one_shot(
      :import_taxonomy_mapping,
      payload,
      opts,
      fn json, usage ->
        {:ok,
         %{
           category_mappings:
             filter_taxonomy_mapping_response(
               json["categoryMappings"] || json["category_mappings"],
               payload.import_categories,
               payload.existing_categories
             ),
           tag_mappings:
             filter_taxonomy_mapping_response(
               json["tagMappings"] || json["tag_mappings"],
               payload.import_tags,
               payload.existing_tags
             ),
           usage: usage
         }}
      end
    )
  end

  @spec analyze_post(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec translate_post(map() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
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

  @spec analyze_image(map() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec translate_media(map() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
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

  defp run_one_shot(:analyze_image = operation, payload, opts, formatter) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)

    with {:ok, endpoint, model, mode} <- Runtime.resolve_target(operation, opts),
         :ok <- Runtime.validate_target(operation, model, mode),
         {:ok, payload} <- resolve_image_data_url(payload),
         request <- build_one_shot_request(operation, payload, model, opts),
         {:ok, response} <-
           runtime.generate(Runtime.endpoint_with_model(endpoint, model), request, opts),
         {:ok, json} <- extract_json_response(response),
         usage <- Chat.normalize_usage(response.usage),
         {:ok, result} <- formatter.(json, usage) do
      {:ok, result}
    end
  end

  defp run_one_shot(operation, payload, opts, formatter) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)

    with {:ok, endpoint, model, mode} <- Runtime.resolve_target(operation, opts),
         :ok <- Runtime.validate_target(operation, model, mode),
         request <- build_one_shot_request(operation, payload, model, opts),
         {:ok, response} <-
           runtime.generate(Runtime.endpoint_with_model(endpoint, model), request, opts),
         {:ok, json} <- extract_json_response(response),
         usage <- Chat.normalize_usage(response.usage),
         {:ok, result} <- formatter.(json, usage) do
      {:ok, result}
    end
  end

  defp build_one_shot_request(operation, payload, model, opts) do
    language = Keyword.get(opts, :language)

    source_language =
      case Keyword.get(opts, :source_language) || Map.get(payload, :language) do
        value when value in [nil, ""] -> nil
        value -> value
      end

    %{
      operation: operation,
      model: model,
      max_output_tokens: @default_max_output_tokens,
      messages: [
        %{"role" => "system", "content" => one_shot_system_prompt(operation, language, source_language)},
        %{"role" => "user", "content" => one_shot_user_content(operation, payload, language, source_language)}
      ]
    }
  end

  defp one_shot_system_prompt(:detect_language, _language, _source_language) do
    "Return JSON with exactly one key: language_code."
  end

  defp one_shot_system_prompt(:analyze_taxonomy, _language, _source_language) do
    "Return JSON with keys tags and categories, each an array of short strings."
  end

  defp one_shot_system_prompt(:import_taxonomy_mapping, _language, _source_language) do
    "You are helping import WordPress taxonomy into an existing blog. Return JSON with exactly two keys: categoryMappings and tagMappings. Each value must be an object mapping imported term names to existing project term names. Only map when the imported term should reuse an existing term to avoid duplicates. Do not invent target terms. Leave unmapped items out of the objects."
  end

  defp one_shot_system_prompt(:analyze_post, nil, _source_language) do
    "Return JSON with keys title, excerpt, and slug. Each value must be a single string (not an array or object)."
  end

  defp one_shot_system_prompt(:analyze_post, language, _source_language) do
    "Return JSON with keys title, excerpt, and slug. Each value must be a single string (not an array or object). Respond in #{language_name(language)}."
  end

  defp one_shot_system_prompt(:translate_post, _language, nil) do
    "Return JSON with keys title, excerpt, and content. Preserve Markdown structure."
  end

  defp one_shot_system_prompt(:translate_post, _language, source_language) do
    "Return JSON with keys title, excerpt, and content. Preserve Markdown structure. Translate from #{language_name(source_language)} to the requested language."
  end

  defp one_shot_system_prompt(:analyze_image, nil, _source_language) do
    "Return JSON with keys title, alt, and caption for the provided image."
  end

  defp one_shot_system_prompt(:analyze_image, language, _source_language) do
    "Return JSON with keys title, alt, and caption for the provided image. Respond in #{language_name(language)}."
  end

  defp one_shot_system_prompt(:translate_media, _language, nil) do
    "Return JSON with keys title, alt, and caption translated to the requested language."
  end

  defp one_shot_system_prompt(:translate_media, _language, source_language) do
    "Return JSON with keys title, alt, and caption. Translate from #{language_name(source_language)} to the requested language."
  end

  defp one_shot_user_content(:detect_language, %{text: text}, _language, _source_language) do
    "Detect the language of this text: #{text}"
  end

  defp one_shot_user_content(:analyze_taxonomy, post, _language, _source_language) do
    "Suggest categories and tags for the following post.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{truncate_text(post.content, 2000)}"
  end

  defp one_shot_user_content(:import_taxonomy_mapping, payload, _language, _source_language) do
    [
      "Analyze these imported taxonomy terms and suggest which ones should map to existing project terms.",
      "",
      "Imported categories:",
      Enum.join(payload.import_categories, ", "),
      "",
      "Imported tags:",
      Enum.join(payload.import_tags, ", "),
      "",
      "Existing project categories:",
      Enum.join(payload.existing_categories, ", "),
      "",
      "Existing project tags:",
      Enum.join(payload.existing_tags, ", "),
      "",
      "Return JSON only."
    ]
    |> Enum.join("\n")
  end

  defp one_shot_user_content(:analyze_post, post, nil, _source_language) do
    "Suggest an improved title, excerpt, and slug.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{truncate_text(post.content, 2000)}"
  end

  defp one_shot_user_content(:analyze_post, post, language, _source_language) do
    "Suggest an improved title, excerpt, and slug in #{language_name(language)}.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{truncate_text(post.content, 2000)}"
  end

  defp one_shot_user_content(:translate_post, post, _language, nil) do
    "Translate this post to #{language_name(post.target_language)}.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{post.content}"
  end

  defp one_shot_user_content(:translate_post, post, _language, source_language) do
    "Translate this post from #{language_name(source_language)} to #{language_name(post.target_language)}.\nTitle: #{post.title}\nExcerpt: #{post.excerpt}\nContent: #{post.content}"
  end

  defp one_shot_user_content(:analyze_image, media, nil, _source_language) do
    [
      %{
        "type" => "text",
        "text" => "Analyze this image and return title, alt text, and caption."
      },
      %{"type" => "image_url", "image_url" => %{"url" => media.image_url}}
    ]
  end

  defp one_shot_user_content(:analyze_image, media, language, _source_language) do
    [
      %{
        "type" => "text",
        "text" => "Analyze this image and return title, alt text, and caption in #{language_name(language)}."
      },
      %{"type" => "image_url", "image_url" => %{"url" => media.image_url}}
    ]
  end

  defp one_shot_user_content(:translate_media, media, _language, nil) do
    "Translate this media metadata to #{language_name(media.target_language)}.\nTitle: #{media.title}\nAlt: #{media.alt}\nCaption: #{media.caption}"
  end

  defp one_shot_user_content(:translate_media, media, _language, source_language) do
    "Translate this media metadata from #{language_name(source_language)} to #{language_name(media.target_language)}.\nTitle: #{media.title}\nAlt: #{media.alt}\nCaption: #{media.caption}"
  end

  defp language_name("de"), do: "German"
  defp language_name("en"), do: "English"
  defp language_name("fr"), do: "French"
  defp language_name("it"), do: "Italian"
  defp language_name("es"), do: "Spanish"
  defp language_name(language), do: String.capitalize(to_string(language))

  defp extract_json_response(%{json: json}) when is_map(json), do: {:ok, json}

  defp extract_json_response(%{content: content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, json} when is_map(json) ->
        {:ok, json}

      _other ->
        Logger.error(
          "AI extract_json_response failed to parse content as JSON. Content: #{String.slice(content, 0, 1000)}"
        )

        {:error, %{kind: :invalid_json_response, content: content}}
    end
  end

  defp extract_json_response(response) do
    Logger.error(
      "AI extract_json_response received response with no JSON and no content: #{inspect(Map.take(response, [:content, :json, :tool_calls]))}"
    )

    {:error, %{kind: :invalid_json_response}}
  end

  defp normalize_post_input(%Post{} = post) do
    {:ok,
     %{
       title: post.title || "",
       excerpt: post.excerpt || "",
       content: Posts.editor_body(post),
       language: post.language || ""
     }}
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
       title: MapUtils.attr(attrs, :title) || "",
       excerpt: MapUtils.attr(attrs, :excerpt) || "",
       content: MapUtils.attr(attrs, :content) || "",
       language: MapUtils.attr(attrs, :language) || ""
     }}
  end

  defp normalize_media_input(%Media{} = media) do
    {:ok,
     %{
       mime_type: media.mime_type,
       title: media.title || "",
       alt: media.alt || "",
       caption: media.caption || "",
       image_url: Map.get(media, :image_url),
       file_path: media.file_path,
       project_id: media.project_id,
       language: media.language || ""
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
       mime_type: MapUtils.attr(attrs, :mime_type),
       title: MapUtils.attr(attrs, :title) || "",
       alt: MapUtils.attr(attrs, :alt) || "",
       caption: MapUtils.attr(attrs, :caption) || "",
       image_url: MapUtils.attr(attrs, :image_url),
       file_path: MapUtils.attr(attrs, :file_path),
       project_id: MapUtils.attr(attrs, :project_id),
       language: MapUtils.attr(attrs, :language) || ""
     }}
  end

  defp ensure_image_media(%{mime_type: "image/" <> _rest}), do: :ok
  defp ensure_image_media(_media), do: {:error, %{kind: :invalid_media_type}}

  defp resolve_image_data_url(%{image_url: "data:" <> _} = media) do
    Logger.debug("AI analyze_image using existing data URL")
    {:ok, media}
  end

  defp resolve_image_data_url(%{image_url: "http" <> _} = media) do
    Logger.debug("AI analyze_image using HTTP URL: #{media.image_url}")
    {:ok, media}
  end

  defp resolve_image_data_url(%{image_url: "file://" <> path, mime_type: mime_type} = media) do
    with {:ok, binary} <- File.read(path) do
      data_url = "data:#{mime_type};base64," <> Base.encode64(binary)
      Logger.debug("AI analyze_image converted file://#{path} to data URL (#{byte_size(data_url)} chars)")
      {:ok, %{media | image_url: data_url}}
    else
      {:error, reason} ->
        Logger.error("AI analyze_image failed to read file://#{path}: #{inspect(reason)}")
        {:error, :file_not_found}
    end
  end

  defp resolve_image_data_url(%{file_path: file_path, project_id: project_id, mime_type: mime_type} = media)
       when is_binary(file_path) and is_binary(project_id) do
    case Projects.get_project(project_id) do
      nil ->
        Logger.error("AI analyze_image project not found: #{project_id}")
        {:error, :file_not_found}

      project ->
        absolute_path = Path.join(Projects.project_data_dir(project), file_path)

        case File.read(absolute_path) do
          {:ok, binary} ->
            data_url = "data:#{mime_type};base64," <> Base.encode64(binary)
            Logger.debug("AI analyze_image converted #{absolute_path} to data URL (#{byte_size(data_url)} chars)")
            {:ok, %{media | image_url: data_url}}

          {:error, reason} ->
            Logger.error("AI analyze_image failed to read #{absolute_path}: #{inspect(reason)}")
            {:error, :file_not_found}
        end
    end
  end

  defp resolve_image_data_url(%{image_url: url} = media) when is_binary(url) and url != "" do
    Logger.debug("AI analyze_image using URL: #{url}")
    {:ok, media}
  end

  defp resolve_image_data_url(_media) do
    Logger.error("AI analyze_image missing image source (no file_path, project_id, or image_url)")
    {:error, :missing_image_source}
  end

  defp normalize_string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp filter_taxonomy_mapping_response(mappings, import_terms, existing_terms)
       when is_map(mappings) do
    import_lookup = canonical_term_lookup(import_terms)
    existing_lookup = canonical_term_lookup(existing_terms)

    Enum.reduce(mappings, %{}, fn {source, target}, acc ->
      with {:ok, canonical_source} <- resolve_canonical_term(source, import_lookup),
           {:ok, canonical_target} <- resolve_canonical_term(target, existing_lookup) do
        Map.put(acc, canonical_source, canonical_target)
      else
        _other -> acc
      end
    end)
  end

  defp filter_taxonomy_mapping_response(_mappings, _import_terms, _existing_terms), do: %{}

  defp canonical_term_lookup(terms) do
    Map.new(terms, fn term -> {normalize_term(term), term} end)
  end

  defp resolve_canonical_term(term, lookup) do
    case Map.get(lookup, normalize_term(term)) do
      nil -> :error
      canonical -> {:ok, canonical}
    end
  end

  defp normalize_term(term) do
    term
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp truncate_text(nil, _max_length), do: ""

  defp truncate_text(text, max_length) when is_binary(text) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length)
    end
  end
end
