defmodule BDS.Metadata do
  @moduledoc false

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

  def get_project_metadata(project_id) do
    project = Projects.get_project!(project_id)
    {:ok, load_state(project)}
  end

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
      write_project_metadata_files(updated_project, state, project_metadata)
      load_state(updated_project)
    end)
    |> unwrap_transaction()
    |> maybe_backfill_embeddings(project_id, state, project_metadata)
  end

  def add_category(project_id, name) do
    update_state(project_id, fn project, state, now ->
      categories =
        state.categories
        |> Kernel.++([String.trim(name)])
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      persist_setting(project.id, "categories", %{"categories" => categories}, now)
      write_categories_json(project, categories)
      %{state | categories: categories}
    end)
  end

  def remove_category(project_id, name) do
    update_state(project_id, fn project, state, now ->
      categories = Enum.reject(state.categories, &(&1 == name))
      category_settings = Map.delete(state.category_settings, name)

      persist_setting(project.id, "categories", %{"categories" => categories}, now)
      persist_setting(project.id, "category_meta", %{"categories" => category_settings}, now)
      write_categories_json(project, categories)
      write_category_meta_json(project, category_settings)
      %{state | categories: categories, category_settings: category_settings}
    end)
  end

  def update_category_settings(project_id, category, settings) do
    update_state(project_id, fn project, state, now ->
      normalized = normalize_category_settings(settings)
      category_settings = Map.put(state.category_settings, category, normalized)

      persist_setting(project.id, "category_meta", %{"categories" => category_settings}, now)
      write_category_meta_json(project, category_settings)
      %{state | category_settings: category_settings}
    end)
  end

  def set_publishing_preferences(project_id, prefs) do
    update_state(project_id, fn project, state, now ->
      publishing_preferences = normalize_publishing_preferences(prefs)
      persist_setting(project.id, "publishing", publishing_preferences, now)
      write_publishing_json(project, publishing_preferences)
      %{state | publishing_preferences: publishing_preferences}
    end)
  end

  def sync_project_metadata_from_filesystem(project_id) do
    project = Projects.get_project!(project_id)
    now = Persistence.now_ms()

    project_metadata_from_files =
      read_json(project, "project.json") ||
        stringify_project_metadata(default_project_metadata(project))

    categories_from_files =
      read_json(project, "categories.json") || %{"categories" => @default_categories}

    category_meta_from_files = read_json(project, "category-meta.json") || %{"categories" => %{}}
    publishing_from_files = read_json(project, "publishing.json") || %{"ssh_mode" => "scp"}

    Repo.transaction(fn ->
      updated_project =
        project
        |> Project.changeset(%{
          name: Map.get(project_metadata_from_files, "name", project.name),
          description: Map.get(project_metadata_from_files, "description"),
          updated_at: now
        })
        |> Repo.update!()

      persist_setting(project_id, "project", project_metadata_from_files, now)
      persist_setting(project_id, "categories", categories_from_files, now)
      persist_setting(project_id, "category_meta", category_meta_from_files, now)
      persist_setting(project_id, "publishing", publishing_from_files, now)
      write_project_json(updated_project, project_metadata_from_files)
      write_categories_json(updated_project, categories_from_files["categories"] || @default_categories)
      write_category_meta_json(updated_project, category_meta_from_files["categories"] || %{})
      write_publishing_json(updated_project, publishing_from_files)
      load_state(updated_project)
    end)
    |> unwrap_transaction()
  end

  defp update_state(project_id, updater) do
    project = Projects.get_project!(project_id)
    state = load_state(project)
    now = Persistence.now_ms()

    Repo.transaction(fn ->
      updater.(project, state, now)
    end)
    |> unwrap_transaction()
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
      blogmark_category: attr(attrs, :blogmark_category),
      pico_theme: normalize_pico_theme(attr(attrs, :pico_theme)),
      semantic_similarity_enabled: attr(attrs, :semantic_similarity_enabled) || false,
      blog_languages: normalize_language_list(attr(attrs, :blog_languages) || [])
    }
  end

  defp normalize_category_settings(settings) do
    %{
      "render_in_lists" =>
        Map.get(settings, :render_in_lists, Map.get(settings, "render_in_lists", true)),
      "show_title" => Map.get(settings, :show_title, Map.get(settings, "show_title", true)),
      "post_template_slug" =>
        Map.get(settings, :post_template_slug, Map.get(settings, "post_template_slug")),
      "list_template_slug" =>
        Map.get(settings, :list_template_slug, Map.get(settings, "list_template_slug"))
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
      "blogmark_category" => project_metadata.blogmark_category,
      "pico_theme" => project_metadata.pico_theme,
      "semantic_similarity_enabled" => project_metadata.semantic_similarity_enabled,
      "blog_languages" => project_metadata.blog_languages
    }
  end

  defp write_project_metadata_files(project, state, project_metadata) do
    write_project_json(project, stringify_project_metadata(project_metadata))
    write_categories_json(project, state.categories)
    write_category_meta_json(project, state.category_settings)
    write_publishing_json(project, state.publishing_preferences)
  end

  defp write_project_json(project, project_json),
    do: write_json(project, "project.json", project_json)

  defp write_categories_json(project, categories) do
    write_json(project, "categories.json", %{"categories" => Enum.sort(categories)})
  end

  defp write_category_meta_json(project, category_settings) do
    write_json(project, "category-meta.json", %{"categories" => category_settings})
  end

  defp write_publishing_json(project, publishing_preferences) do
    write_json(project, "publishing.json", publishing_preferences)
  end

  defp write_json(project, file_name, payload) do
    meta_dir = Path.join(Projects.project_data_dir(project), "meta")
    path = Path.join(meta_dir, file_name)
    :ok = Persistence.atomic_write(path, Jason.encode!(payload))
  end

  defp read_json(project, file_name) do
    path = Path.join([Projects.project_data_dir(project), "meta", file_name])

    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      {:error, :enoent} -> nil
    end
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

  defp maybe_backfill_embeddings({:ok, _metadata} = result, project_id, previous_state, project_metadata) do
    if previous_state.semantic_similarity_enabled != true and
         project_metadata.semantic_similarity_enabled == true do
      {:ok, _indexed_post_ids} = Embeddings.index_unindexed(project_id)
    end

    result
  end

  defp maybe_backfill_embeddings(result, _project_id, _previous_state, _project_metadata), do: result

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
