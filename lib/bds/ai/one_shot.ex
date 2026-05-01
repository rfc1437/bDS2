defmodule BDS.AI.OneShot do
  @moduledoc false

  alias BDS.AI.Chat
  alias BDS.AI.OpenAICompatibleRuntime
  alias BDS.AI.Runtime
  alias BDS.Media.Media
  alias BDS.Posts.Post
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
      import_categories: normalize_string_list(Map.get(import_terms, :categories) || Map.get(import_terms, "categories")),
      import_tags: normalize_string_list(Map.get(import_terms, :tags) || Map.get(import_terms, "tags")),
      existing_categories: normalize_string_list(Map.get(existing_terms, :categories) || Map.get(existing_terms, "categories")),
      existing_tags: normalize_string_list(Map.get(existing_terms, :tags) || Map.get(existing_terms, "tags"))
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

  @spec translate_post(map() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  @spec translate_media(map() | String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
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

  defp run_one_shot(operation, payload, opts, formatter) do
    runtime = Keyword.get(opts, :runtime, OpenAICompatibleRuntime)

    with {:ok, endpoint, model, mode} <- Runtime.resolve_target(operation, opts),
         :ok <- Runtime.validate_target(operation, model, mode),
         request <- build_one_shot_request(operation, payload, model),
         {:ok, response} <- runtime.generate(Runtime.endpoint_with_model(endpoint, model), request, opts),
         {:ok, json} <- extract_json_response(response),
         usage <- Chat.normalize_usage(response.usage),
         {:ok, result} <- formatter.(json, usage) do
      {:ok, result}
    end
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

  defp one_shot_system_prompt(:detect_language) do
    "Return JSON with exactly one key: language_code."
  end

  defp one_shot_system_prompt(:analyze_taxonomy) do
    "Return JSON with keys tags and categories, each an array of short strings."
  end

  defp one_shot_system_prompt(:import_taxonomy_mapping) do
    "You are helping import WordPress taxonomy into an existing blog. Return JSON with exactly two keys: categoryMappings and tagMappings. Each value must be an object mapping imported term names to existing project term names. Only map when the imported term should reuse an existing term to avoid duplicates. Do not invent target terms. Leave unmapped items out of the objects."
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

  defp one_shot_user_content(:import_taxonomy_mapping, payload) do
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

  defp normalize_string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp filter_taxonomy_mapping_response(mappings, import_terms, existing_terms) when is_map(mappings) do
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
