defmodule BDS.Metadata do
  @moduledoc false

  require Logger

  alias BDS.Embeddings
  alias BDS.I18n
  alias BDS.Persistence
  alias BDS.Projects
  alias BDS.Projects.Project
  alias BDS.Repo
  alias BDS.Settings.Setting

  @default_max_posts_per_page 50
  @default_categories ["article", "aside", "page", "picture"]
  @min_posts_per_page 1
  @max_posts_per_page 500
  @default_image_import_concurrency 4
  @min_image_import_concurrency 1
  @max_image_import_concurrency 8
  @supported_pico_themes MapSet.new([
                           "default",
                           "amber",
                           "blue",
                           "cyan",
                           "fuchsia",
                           "green",
                           "grey",
                           "indigo",
                           "jade",
                           "lime",
                           "orange",
                           "pink",
                           "pumpkin",
                           "purple",
                           "red",
                           "sand",
                           "slate",
                           "violet",
                           "yellow",
                           "zinc"
                         ])

  @typedoc "Project metadata state map."
  @type metadata_state :: map()

  @typedoc "Attribute map for `update_project_metadata/2`."
  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @spec get_project_metadata(String.t()) :: {:ok, metadata_state()}
  def get_project_metadata(project_id) do
    project = Projects.get_project!(project_id)
    {:ok, load_state(project)}
  end

  @spec read_project_metadata_from_filesystem(String.t()) :: {:ok, metadata_state()}
  def read_project_metadata_from_filesystem(project_id) do
    project = Projects.get_project!(project_id)
    {:ok, load_state_from_filesystem(project)}
  end

  @spec update_project_metadata(String.t(), attrs()) ::
          {:ok, metadata_state()} | {:error, term()}
  def update_project_metadata(project_id, attrs) do
    project = Projects.get_project!(project_id)
    state = load_state(project)
    now = Persistence.now_ms()

    project_metadata =
      state
      |> Map.take([
        :name,
        :description,
        :public_url,
        :main_language,
        :default_author,
        :max_posts_per_page,
        :image_import_concurrency,
        :blogmark_category,
        :pico_theme,
        :semantic_similarity_enabled,
        :blog_languages
      ])
      |> Map.merge(normalize_project_metadata_attrs(attrs, project))

    Repo.transaction(fn ->
      updated_project =
        project
        |> Project.changeset(%{
          name: project_metadata.name,
          description: project_metadata.description,
          updated_at: now
        })
        |> Repo.update!()

      persist_setting(project_id, "project", stringify_project_metadata(project_metadata), now)
      {updated_project, project_metadata}
    end)
    |> unwrap_transaction()
    |> flush_project_metadata_update(state)
    |> maybe_backfill_embeddings(project_id, state, project_metadata)
  end

  @spec add_category(String.t(), String.t()) :: {:ok, metadata_state()} | {:error, term()}
  def add_category(project_id, name) do
    update_state(project_id, fn project, state, now ->
      categories =
        state.categories
        |> Kernel.++([String.trim(name)])
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      persist_setting(project.id, "categories", %{"categories" => categories}, now)
      {%{state | categories: categories}, fn -> write_categories_json(project, categories) end}
    end)
  end

  @spec remove_category(String.t(), String.t()) :: {:ok, metadata_state()} | {:error, term()}
  def remove_category(project_id, name) do
    update_state(project_id, fn project, state, now ->
      categories = Enum.reject(state.categories, &(&1 == name))
      category_settings = Map.delete(state.category_settings, name)

      persist_setting(project.id, "categories", %{"categories" => categories}, now)
      persist_setting(project.id, "category_meta", %{"categories" => category_settings}, now)

      {%{state | categories: categories, category_settings: category_settings},
       fn ->
         with :ok <- write_categories_json(project, categories),
              :ok <- write_category_meta_json(project, category_settings) do
           :ok
         end
       end}
    end)
  end

  @spec update_category_settings(String.t(), String.t(), map()) ::
          {:ok, metadata_state()} | {:error, term()}
  def update_category_settings(project_id, category, settings) do
    update_state(project_id, fn project, state, now ->
      normalized = normalize_category_settings(settings)
      category_settings = Map.put(state.category_settings, category, normalized)

      persist_setting(project.id, "category_meta", %{"categories" => category_settings}, now)

      {%{state | category_settings: category_settings},
       fn -> write_category_meta_json(project, category_settings) end}
    end)
  end

  @spec set_publishing_preferences(String.t(), map()) ::
          {:ok, metadata_state()} | {:error, term()}
  def set_publishing_preferences(project_id, prefs) do
    update_state(project_id, fn project, state, now ->
      publishing_preferences = normalize_publishing_preferences(prefs)
      persist_setting(project.id, "publishing", publishing_preferences, now)

      {%{state | publishing_preferences: publishing_preferences},
       fn -> write_publishing_json(project, publishing_preferences) end}
    end)
  end

  @spec sync_project_metadata_from_filesystem(String.t()) ::
          {:ok, metadata_state()} | {:error, term()}
  def sync_project_metadata_from_filesystem(project_id) do
    project = Projects.get_project!(project_id)
    now = Persistence.now_ms()
    filesystem_state = load_state_from_filesystem(project)

    Repo.transaction(fn ->
      updated_project =
        project
        |> Project.changeset(%{
          name: filesystem_state.name,
          description: filesystem_state.description,
          updated_at: now
        })
        |> Repo.update!()

      persist_setting(project_id, "project", stringify_project_metadata(filesystem_state), now)

      persist_setting(
        project_id,
        "categories",
        %{"categories" => filesystem_state.categories},
        now
      )

      persist_setting(
        project_id,
        "category_meta",
        %{"categories" => filesystem_state.category_settings},
        now
      )

      persist_setting(project_id, "publishing", filesystem_state.publishing_preferences, now)
      updated_project
    end)
    |> unwrap_transaction()
    |> flush_synced_project_metadata(filesystem_state)
  end

  @spec flush_project_metadata_to_filesystem(String.t()) :: {:ok, metadata_state()}
  def flush_project_metadata_to_filesystem(project_id) do
    project = Projects.get_project!(project_id)
    state = load_state(project)

    write_project_metadata_files(project, state, state)

    {:ok, state}
  end

  defp update_state(project_id, updater) do
    project = Projects.get_project!(project_id)
    state = load_state(project)
    now = Persistence.now_ms()

    Repo.transaction(fn -> updater.(project, state, now) end)
    |> unwrap_transaction()
    |> flush_state_update()
  end

  defp load_state(project) do
    project_metadata =
      load_setting(project.id, "project") ||
        stringify_project_metadata(default_project_metadata(project))

    categories =
      (load_setting(project.id, "categories") || %{"categories" => @default_categories})[
        "categories"
      ]

    category_settings =
      (load_setting(project.id, "category_meta") || %{"categories" => %{}})["categories"]

    publishing_preferences = load_setting(project.id, "publishing") || %{"ssh_mode" => "scp"}

    %{
      name: Map.get(project_metadata, "name", project.name),
      description: Map.get(project_metadata, "description"),
      public_url: Map.get(project_metadata, "public_url"),
      main_language: Map.get(project_metadata, "main_language"),
      default_author: Map.get(project_metadata, "default_author"),
      max_posts_per_page:
        Map.get(project_metadata, "max_posts_per_page", @default_max_posts_per_page),
      image_import_concurrency:
        Map.get(project_metadata, "image_import_concurrency", @default_image_import_concurrency),
      blogmark_category: Map.get(project_metadata, "blogmark_category"),
      pico_theme: Map.get(project_metadata, "pico_theme"),
      semantic_similarity_enabled:
        Map.get(project_metadata, "semantic_similarity_enabled", false),
      blog_languages: Map.get(project_metadata, "blog_languages", []),
      categories: categories,
      category_settings: category_settings,
      publishing_preferences: publishing_preferences
    }
  end

  defp load_state_from_filesystem(project) do
    project_metadata =
      read_json(project, "project.json") ||
        stringify_project_metadata(default_project_metadata(project))

    categories =
      normalized_categories(
        read_json(project, "categories.json") || %{"categories" => @default_categories}
      )

    category_settings =
      normalized_category_settings(
        read_json(project, "category-meta.json") || %{"categories" => %{}}
      )

    publishing_preferences = read_json(project, "publishing.json") || %{"ssh_mode" => "scp"}

    %{
      name: Map.get(project_metadata, "name", project.name),
      description: Map.get(project_metadata, "description"),
      public_url: Map.get(project_metadata, "public_url"),
      main_language: Map.get(project_metadata, "main_language"),
      default_author: Map.get(project_metadata, "default_author"),
      max_posts_per_page:
        Map.get(project_metadata, "max_posts_per_page", @default_max_posts_per_page),
      image_import_concurrency:
        Map.get(project_metadata, "image_import_concurrency", @default_image_import_concurrency),
      blogmark_category: Map.get(project_metadata, "blogmark_category"),
      pico_theme: Map.get(project_metadata, "pico_theme"),
      semantic_similarity_enabled:
        Map.get(project_metadata, "semantic_similarity_enabled", false),
      blog_languages: Map.get(project_metadata, "blog_languages", []),
      categories: categories,
      category_settings: category_settings,
      publishing_preferences: publishing_preferences
    }
  end

  defp default_project_metadata(project) do
    %{
      name: project.name,
      description: project.description,
      public_url: nil,
      main_language: nil,
      default_author: nil,
      max_posts_per_page: @default_max_posts_per_page,
      image_import_concurrency: @default_image_import_concurrency,
      blogmark_category: nil,
      pico_theme: nil,
      semantic_similarity_enabled: false,
      blog_languages: []
    }
  end

  defp normalize_project_metadata_attrs(attrs, project) do
    %{
      name: attr(attrs, :name) || project.name,
      description: attr(attrs, :description),
      public_url: attr(attrs, :public_url),
      main_language: normalize_optional_language(attr(attrs, :main_language)),
      default_author: attr(attrs, :default_author),
      max_posts_per_page: normalize_posts_per_page(attr(attrs, :max_posts_per_page)),
      image_import_concurrency:
        normalize_image_import_concurrency(attr(attrs, :image_import_concurrency)),
      blogmark_category: attr(attrs, :blogmark_category),
      pico_theme: normalize_pico_theme(attr(attrs, :pico_theme)),
      semantic_similarity_enabled: attr(attrs, :semantic_similarity_enabled) || false,
      blog_languages: normalize_language_list(attr(attrs, :blog_languages) || [])
    }
  end

  defp normalize_category_settings(settings) do
    %{
      "render_in_lists" => attr(settings, :render_in_lists, true),
      "show_title" => attr(settings, :show_title, true),
      "post_template_slug" => attr(settings, :post_template_slug),
      "list_template_slug" => attr(settings, :list_template_slug),
      "title" => attr(settings, :title)
    }
  end

  defp normalize_publishing_preferences(prefs) do
    %{
      "ssh_host" => attr(prefs, :ssh_host),
      "ssh_user" => attr(prefs, :ssh_user),
      "ssh_remote_path" => attr(prefs, :ssh_remote_path),
      "ssh_mode" => normalize_ssh_mode(attr(prefs, :ssh_mode))
    }
  end

  defp stringify_project_metadata(project_metadata) do
    %{
      "name" => project_metadata.name,
      "description" => project_metadata.description,
      "public_url" => project_metadata.public_url,
      "main_language" => project_metadata.main_language,
      "default_author" => project_metadata.default_author,
      "max_posts_per_page" => project_metadata.max_posts_per_page,
      "image_import_concurrency" => project_metadata.image_import_concurrency,
      "blogmark_category" => project_metadata.blogmark_category,
      "pico_theme" => project_metadata.pico_theme,
      "semantic_similarity_enabled" => project_metadata.semantic_similarity_enabled,
      "blog_languages" => project_metadata.blog_languages
    }
  end

  defp flush_project_metadata_update({:ok, {updated_project, project_metadata}}, state) do
    with :ok <- write_project_metadata_files(updated_project, state, project_metadata) do
      {:ok, load_state(updated_project)}
    end
  end

  defp flush_project_metadata_update(error, _state), do: error

  defp flush_synced_project_metadata({:ok, updated_project}, filesystem_state) do
    with :ok <- write_project_json(updated_project, stringify_project_metadata(filesystem_state)),
         :ok <- write_categories_json(updated_project, filesystem_state.categories),
         :ok <- write_category_meta_json(updated_project, filesystem_state.category_settings),
         :ok <- write_publishing_json(updated_project, filesystem_state.publishing_preferences) do
      {:ok, load_state(updated_project)}
    end
  end

  defp flush_synced_project_metadata(error, _filesystem_state), do: error

  defp flush_state_update({:ok, {state, write_files}}) when is_function(write_files, 0) do
    with :ok <- write_files.() do
      {:ok, state}
    end
  end

  defp flush_state_update(error), do: error

  defp write_project_metadata_files(project, state, project_metadata) do
    with :ok <- write_project_json(project, stringify_project_metadata(project_metadata)),
         :ok <- write_categories_json(project, state.categories),
         :ok <- write_category_meta_json(project, state.category_settings),
         :ok <- write_publishing_json(project, state.publishing_preferences) do
      :ok
    end
  end

  defp write_project_json(project, project_json),
    do: write_json(project, "project.json", render_project_metadata_json(project_json))

  defp write_categories_json(project, categories) do
    write_json(project, "categories.json", Enum.sort(categories))
  end

  defp write_category_meta_json(project, category_settings) do
    write_json(project, "category-meta.json", render_category_meta_json(category_settings))
  end

  defp write_publishing_json(project, publishing_preferences) do
    write_json(project, "publishing.json", render_publishing_json(publishing_preferences))
  end

  defp write_json(project, file_name, payload) do
    meta_dir = Path.join(Projects.project_data_dir(project), "meta")
    path = Path.join(meta_dir, file_name)
    Persistence.atomic_write(path, Jason.encode!(payload))
  end

  defp read_json(project, file_name) do
    path = Path.join([Projects.project_data_dir(project), "meta", file_name])

    case File.read(path) do
      {:ok, contents} -> contents |> Jason.decode!() |> normalize_json(file_name)
      {:error, :enoent} -> nil
    end
  end

  defp normalize_json(payload, "project.json"), do: parse_project_metadata_json(payload)
  defp normalize_json(payload, "categories.json"), do: parse_categories_json(payload)
  defp normalize_json(payload, "category-meta.json"), do: parse_category_meta_json(payload)
  defp normalize_json(payload, "publishing.json"), do: parse_publishing_json(payload)
  defp normalize_json(payload, _file_name), do: payload

  defp parse_project_metadata_json(payload) when is_map(payload) do
    %{
      "name" => Map.get(payload, "name"),
      "description" => Map.get(payload, "description"),
      "public_url" => Map.get(payload, "publicUrl"),
      "main_language" => Map.get(payload, "mainLanguage"),
      "default_author" => Map.get(payload, "defaultAuthor"),
      "max_posts_per_page" => Map.get(payload, "maxPostsPerPage", @default_max_posts_per_page),
      "image_import_concurrency" =>
        Map.get(payload, "imageImportConcurrency", @default_image_import_concurrency),
      "blogmark_category" => Map.get(payload, "blogmarkCategory"),
      "pico_theme" => Map.get(payload, "picoTheme"),
      "semantic_similarity_enabled" => Map.get(payload, "semanticSimilarityEnabled", false),
      "blog_languages" => Map.get(payload, "blogLanguages", [])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp parse_categories_json(payload) when is_list(payload), do: %{"categories" => payload}
  defp parse_categories_json(_payload), do: %{"categories" => @default_categories}

  defp parse_category_meta_json(payload) when is_map(payload) do
    %{"categories" => normalized_category_settings(payload)}
  end

  defp parse_publishing_json(payload) when is_map(payload) do
    %{
      "ssh_host" => Map.get(payload, "sshHost"),
      "ssh_user" => Map.get(payload, "sshUser"),
      "ssh_remote_path" => Map.get(payload, "sshRemotePath"),
      "ssh_mode" => Map.get(payload, "sshMode", "scp")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalized_categories(%{"categories" => categories}) when is_list(categories),
    do: categories

  defp normalized_categories(categories) when is_list(categories), do: categories
  defp normalized_categories(_payload), do: @default_categories

  defp normalized_category_settings(%{"categories" => settings}) when is_map(settings),
    do: normalized_category_settings(settings)

  defp normalized_category_settings(settings) when is_map(settings) do
    Map.new(settings, fn {category, category_settings} ->
      {category,
       %{
         "render_in_lists" =>
           Map.get(
             category_settings,
             "render_in_lists",
             Map.get(category_settings, "renderInLists", true)
           ),
         "show_title" =>
           Map.get(category_settings, "show_title", Map.get(category_settings, "showTitle", true)),
         "post_template_slug" =>
           Map.get(
             category_settings,
             "post_template_slug",
             Map.get(category_settings, "postTemplateSlug")
           ),
         "list_template_slug" =>
           Map.get(
             category_settings,
             "list_template_slug",
             Map.get(category_settings, "listTemplateSlug")
           ),
         "title" => Map.get(category_settings, "title")
       }
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.new()}
    end)
  end

  defp render_project_metadata_json(project_metadata) when is_map(project_metadata) do
    %{
      "name" => Map.get(project_metadata, "name"),
      "description" => Map.get(project_metadata, "description"),
      "publicUrl" => Map.get(project_metadata, "public_url"),
      "mainLanguage" => Map.get(project_metadata, "main_language"),
      "defaultAuthor" => Map.get(project_metadata, "default_author"),
      "maxPostsPerPage" =>
        Map.get(project_metadata, "max_posts_per_page", @default_max_posts_per_page),
      "imageImportConcurrency" =>
        Map.get(project_metadata, "image_import_concurrency", @default_image_import_concurrency),
      "blogmarkCategory" => Map.get(project_metadata, "blogmark_category"),
      "picoTheme" => Map.get(project_metadata, "pico_theme"),
      "semanticSimilarityEnabled" =>
        Map.get(project_metadata, "semantic_similarity_enabled", false),
      "blogLanguages" => Map.get(project_metadata, "blog_languages", [])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp render_category_meta_json(category_settings) when is_map(category_settings) do
    Map.new(category_settings, fn {category, settings} ->
      {category,
       %{
         "renderInLists" => Map.get(settings, "render_in_lists", true),
         "showTitle" => Map.get(settings, "show_title", true),
         "postTemplateSlug" => Map.get(settings, "post_template_slug"),
         "listTemplateSlug" => Map.get(settings, "list_template_slug"),
         "title" => Map.get(settings, "title")
       }
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.new()}
    end)
  end

  defp render_publishing_json(publishing_preferences) when is_map(publishing_preferences) do
    %{
      "sshHost" => Map.get(publishing_preferences, "ssh_host"),
      "sshUser" => Map.get(publishing_preferences, "ssh_user"),
      "sshRemotePath" => Map.get(publishing_preferences, "ssh_remote_path"),
      "sshMode" => Map.get(publishing_preferences, "ssh_mode", "scp")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp load_setting(project_id, suffix) do
    case Repo.get(Setting, setting_key(project_id, suffix)) do
      nil -> nil
      setting -> Jason.decode!(setting.value)
    end
  end

  defp persist_setting(project_id, suffix, payload, now) do
    key = setting_key(project_id, suffix)
    setting = Repo.get(Setting, key) || %Setting{}

    setting
    |> Setting.changeset(%{key: key, value: Jason.encode!(payload), updated_at: now})
    |> Repo.insert_or_update!()
  end

  defp setting_key(project_id, suffix), do: "project:#{project_id}:#{suffix}"

  defp normalize_posts_per_page(nil), do: @default_max_posts_per_page

  defp normalize_posts_per_page(value) when is_integer(value) do
    value
    |> max(@min_posts_per_page)
    |> min(@max_posts_per_page)
  end

  defp normalize_posts_per_page(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> normalize_posts_per_page(integer)
      _ -> @default_max_posts_per_page
    end
  end

  defp normalize_posts_per_page(_value), do: @default_max_posts_per_page

  defp normalize_image_import_concurrency(nil), do: @default_image_import_concurrency

  defp normalize_image_import_concurrency(value) when is_integer(value) do
    value
    |> max(@min_image_import_concurrency)
    |> min(@max_image_import_concurrency)
  end

  defp normalize_image_import_concurrency(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> normalize_image_import_concurrency(integer)
      _ -> @default_image_import_concurrency
    end
  end

  defp normalize_image_import_concurrency(_value), do: @default_image_import_concurrency

  defp normalize_optional_language(nil), do: nil
  defp normalize_optional_language(""), do: nil

  defp normalize_optional_language(value) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()
    supported_language_codes = Enum.map(I18n.supported_languages(), & &1.code)

    if normalized in supported_language_codes do
      normalized
    else
      nil
    end
  end

  defp normalize_language_list(values) do
    values
    |> Enum.map(&normalize_optional_language/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_pico_theme(nil), do: nil
  defp normalize_pico_theme(""), do: nil

  defp normalize_pico_theme(value) do
    normalized = value |> to_string() |> String.trim()
    if MapSet.member?(@supported_pico_themes, normalized), do: normalized, else: nil
  end

  defp normalize_ssh_mode(:rsync), do: "rsync"
  defp normalize_ssh_mode("rsync"), do: "rsync"
  defp normalize_ssh_mode(_mode), do: "scp"

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp maybe_backfill_embeddings(
         {:ok, _metadata} = result,
         project_id,
         previous_state,
         project_metadata
       ) do
    if previous_state.semantic_similarity_enabled != true and
         project_metadata.semantic_similarity_enabled == true do
      # Backfill is best-effort: if the embedding model is unavailable, keep the
      # setting enabled and log it rather than failing the metadata update.
      case Embeddings.index_unindexed(project_id) do
        {:ok, _indexed_post_ids} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Embedding backfill skipped for project #{project_id}: #{inspect(reason)}"
          )
      end
    end

    result
  end

  defp maybe_backfill_embeddings(result, _project_id, _previous_state, _project_metadata),
    do: result

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end

  defp attr(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> default
    end
  end
end
