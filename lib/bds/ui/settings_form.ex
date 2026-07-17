defmodule BDS.UI.SettingsForm do
  @moduledoc """
  Renderer-agnostic preferences forms (issue #29).

  Exposes each settings section of the GUI settings editor as a flat list
  of typed fields (`:text`, `:bool`, `:enum`, `:info`) that the TUI can
  render and edit generically. `save/3` writes through the same backends
  as the GUI editor — `BDS.Metadata`, `BDS.Settings`, `BDS.AI` and
  `BDS.MCP.AgentConfig` — so both frontends operate on the same
  preferences.
  """

  use Gettext, backend: BDS.Gettext

  import Ecto.Query

  alias BDS.Desktop.ShellLive.SettingsEditor.AISettings
  alias BDS.Desktop.ShellLive.SettingsEditor.ManagedCategories
  alias BDS.Desktop.ShellLive.SettingsEditor.MCPConfig
  alias BDS.I18n
  alias BDS.MCP.AgentConfig
  alias BDS.Metadata
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Settings
  alias BDS.Templates.Template

  @type field :: %{
          key: String.t(),
          label: String.t(),
          type: :text | :bool | :enum | :info,
          value: term(),
          options: [String.t()]
        }

  @type form :: %{section: String.t(), title: String.t(), fields: [field()]}

  # ── Load ─────────────────────────────────────────────────────────────────

  @spec load(String.t(), String.t()) :: form()
  def load("project", project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    form("project", dgettext("ui", "Project"), [
      text("name", dgettext("ui", "Name"), metadata.name),
      text("description", dgettext("ui", "Description"), metadata.description),
      text("public_url", dgettext("ui", "Public URL"), metadata.public_url),
      enum(
        "main_language",
        dgettext("ui", "Main Language"),
        metadata.main_language || "en",
        supported_language_codes()
      ),
      text("default_author", dgettext("ui", "Default Author"), metadata.default_author),
      text(
        "max_posts_per_page",
        dgettext("ui", "Posts per Page"),
        Integer.to_string(metadata.max_posts_per_page)
      ),
      text(
        "image_import_concurrency",
        dgettext("ui", "Image Import Concurrency"),
        Integer.to_string(metadata.image_import_concurrency)
      ),
      enum(
        "blogmark_category",
        dgettext("ui", "Blogmark Category"),
        metadata.blogmark_category || List.first(metadata.categories) || "article",
        metadata.categories
      ),
      text(
        "blog_languages",
        dgettext("ui", "Blog Languages (comma-separated)"),
        Enum.join(metadata.blog_languages, ", ")
      ),
      bool(
        "semantic_similarity_enabled",
        dgettext("ui", "Semantic Similarity"),
        metadata.semantic_similarity_enabled
      )
    ])
  end

  def load("editor", _project_id) do
    stored = editor_settings()

    form("editor", dgettext("ui", "Editor"), [
      enum("default_mode", dgettext("ui", "Default Editor Mode"), stored["default_mode"], [
        "wysiwyg",
        "markdown",
        "preview"
      ]),
      enum("diff_view_style", dgettext("ui", "Diff View Style"), stored["diff_view_style"], [
        "inline",
        "side-by-side"
      ]),
      bool("wrap_long_lines", dgettext("ui", "Wrap Long Lines"), stored["wrap_long_lines"]),
      bool(
        "hide_unchanged_regions",
        dgettext("ui", "Hide Unchanged Regions"),
        stored["hide_unchanged_regions"]
      )
    ])
  end

  def load("content", project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    post_templates = [""] ++ template_slugs(project_id, :post)
    list_templates = [""] ++ template_slugs(project_id, :list)

    category_fields =
      metadata
      |> ManagedCategories.category_rows()
      |> Enum.flat_map(fn row ->
        [
          info("cat:#{row.name}", "── " <> row.name, ""),
          text("cat:#{row.name}:title", dgettext("ui", "Title"), row.title),
          bool("cat:#{row.name}:render_in_lists", dgettext("ui", "Render in Lists"), row.render_in_lists),
          bool("cat:#{row.name}:show_title", dgettext("ui", "Show Title"), row.show_title),
          enum(
            "cat:#{row.name}:post_template_slug",
            dgettext("ui", "Post Template"),
            row.post_template_slug || "",
            post_templates
          ),
          enum(
            "cat:#{row.name}:list_template_slug",
            dgettext("ui", "List Template"),
            row.list_template_slug || "",
            list_templates
          )
        ]
      end)

    form(
      "content",
      dgettext("ui", "Content"),
      [text("new_category", dgettext("ui", "New Category"), "")] ++ category_fields
    )
  end

  def load("ai", _project_id) do
    stored = AISettings.ai_form(%{})

    form("ai", dgettext("ui", "AI"), [
      bool("offline_mode", dgettext("ui", "Airplane Mode"), stored["offline_mode"]),
      text("system_prompt", dgettext("ui", "System Prompt"), stored["system_prompt"]),
      text("online_url", dgettext("ui", "Online Endpoint URL"), stored["online_url"]),
      text("online_api_key", dgettext("ui", "Online API Key"), stored["online_api_key"]),
      text("online_chat_model", dgettext("ui", "Online Chat Model"), stored["online_chat_model"]),
      bool("online_chat_tools", dgettext("ui", "Online Chat Tool Calls"), stored["online_chat_tools"]),
      bool(
        "online_chat_disable_reasoning",
        dgettext("ui", "Online Chat Disable Reasoning"),
        stored["online_chat_disable_reasoning"]
      ),
      text("online_title_model", dgettext("ui", "Online Title Model"), stored["online_title_model"]),
      text(
        "online_image_analysis_model",
        dgettext("ui", "Online Image Model"),
        stored["online_image_analysis_model"]
      ),
      bool("online_chat_images", dgettext("ui", "Online Image Support"), stored["online_chat_images"]),
      text("offline_url", dgettext("ui", "Offline Endpoint URL"), stored["offline_url"]),
      text("offline_api_key", dgettext("ui", "Offline API Key"), stored["offline_api_key"]),
      text("offline_chat_model", dgettext("ui", "Offline Chat Model"), stored["offline_chat_model"]),
      bool("offline_chat_tools", dgettext("ui", "Offline Chat Tool Calls"), stored["offline_chat_tools"]),
      bool(
        "offline_chat_disable_reasoning",
        dgettext("ui", "Offline Chat Disable Reasoning"),
        stored["offline_chat_disable_reasoning"]
      ),
      text("offline_title_model", dgettext("ui", "Offline Title Model"), stored["offline_title_model"]),
      text(
        "offline_image_analysis_model",
        dgettext("ui", "Offline Image Model"),
        stored["offline_image_analysis_model"]
      ),
      bool("offline_chat_images", dgettext("ui", "Offline Image Support"), stored["offline_chat_images"])
    ])
  end

  def load("technology", project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    form("technology", dgettext("ui", "Technology"), [
      bool(
        "semantic_similarity_enabled",
        dgettext("ui", "Semantic Similarity"),
        metadata.semantic_similarity_enabled
      )
    ])
  end

  def load("publishing", project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    prefs = metadata.publishing_preferences

    form("publishing", dgettext("ui", "Publishing"), [
      text("ssh_host", dgettext("ui", "SSH Host"), Map.get(prefs, "ssh_host", "")),
      text("ssh_user", dgettext("ui", "SSH User"), Map.get(prefs, "ssh_user", "")),
      text("ssh_remote_path", dgettext("ui", "SSH Remote Path"), Map.get(prefs, "ssh_remote_path", "")),
      enum("ssh_mode", dgettext("ui", "SSH Mode"), Map.get(prefs, "ssh_mode", "scp") || "scp", [
        "scp",
        "rsync"
      ])
    ])
  end

  def load("data", project_id) do
    project = Projects.get_project(project_id)
    data_path = if project, do: Projects.project_data_dir(project), else: ""

    form("data", dgettext("ui", "Data"), [
      info("data_path", dgettext("ui", "Data Folder"), data_path),
      info(
        "data_hint",
        dgettext("ui", "Maintenance"),
        dgettext("ui", "Rebuild and maintenance commands are available under the : prompt.")
      )
    ])
  end

  def load("mcp", _project_id) do
    fields =
      Enum.map(MCPConfig.mcp_rows(), fn row ->
        if row.supported? do
          bool("mcp:#{row.id}", row.label, row.configured?)
        else
          info("mcp:#{row.id}", row.label, dgettext("ui", "not supported yet"))
        end
      end)

    form("mcp", dgettext("ui", "MCP"), fields)
  end

  def load("style", project_id) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)
    current = if metadata.pico_theme in [nil, ""], do: "default", else: metadata.pico_theme

    form("style", dgettext("ui", "Style"), [
      enum("pico_theme", dgettext("ui", "Theme"), current, Metadata.supported_pico_themes())
    ])
  end

  def load(section, _project_id) do
    form(section, section, [])
  end

  # ── Save ─────────────────────────────────────────────────────────────────

  @spec save(String.t(), String.t(), %{String.t() => term()}) :: :ok | {:error, term()}
  def save("project", project_id, values) do
    save_project_metadata(project_id, %{
      name: blank_to_nil(values["name"]),
      description: blank_to_nil(values["description"]),
      public_url: blank_to_nil(values["public_url"]),
      main_language: blank_to_nil(values["main_language"]),
      default_author: blank_to_nil(values["default_author"]),
      max_posts_per_page: parse_integer(values["max_posts_per_page"], 50),
      image_import_concurrency: parse_integer(values["image_import_concurrency"], 4),
      blogmark_category: blank_to_nil(values["blogmark_category"]),
      blog_languages: split_languages(values["blog_languages"]),
      semantic_similarity_enabled: values["semantic_similarity_enabled"] == true
    })
  end

  def save("editor", _project_id, values) do
    with :ok <- Settings.put_global_setting("ui.preferred_editor_mode", values["default_mode"]),
         :ok <- Settings.put_global_setting("ui.git_diff_view_style", values["diff_view_style"]),
         :ok <-
           Settings.put_global_setting(
             "ui.git_diff_word_wrap",
             boolean_string(values["wrap_long_lines"])
           ) do
      Settings.put_global_setting(
        "ui.git_diff_hide_unchanged_regions",
        boolean_string(values["hide_unchanged_regions"])
      )
    end
  end

  def save("content", project_id, values) do
    with :ok <- maybe_add_category(project_id, values["new_category"]) do
      values
      |> category_settings_by_name()
      |> Enum.reduce_while(:ok, fn {category, settings}, _acc ->
        case Metadata.update_category_settings(project_id, category, settings) do
          {:ok, _metadata} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def save("ai", _project_id, values) do
    AISettings.save_attrs(%{
      online_url: blank_to_nil(values["online_url"]),
      online_api_key: blank_to_nil(values["online_api_key"]),
      online_chat_model: blank_to_nil(values["online_chat_model"]),
      online_chat_tools: values["online_chat_tools"] == true,
      online_chat_disable_reasoning: values["online_chat_disable_reasoning"] == true,
      online_title_model: blank_to_nil(values["online_title_model"]),
      online_image_analysis_model: blank_to_nil(values["online_image_analysis_model"]),
      online_chat_images: values["online_chat_images"] == true,
      offline_url: blank_to_nil(values["offline_url"]),
      offline_api_key: blank_to_nil(values["offline_api_key"]),
      offline_mode: values["offline_mode"] == true,
      offline_chat_model: blank_to_nil(values["offline_chat_model"]),
      offline_chat_tools: values["offline_chat_tools"] == true,
      offline_chat_disable_reasoning: values["offline_chat_disable_reasoning"] == true,
      offline_title_model: blank_to_nil(values["offline_title_model"]),
      offline_image_analysis_model: blank_to_nil(values["offline_image_analysis_model"]),
      offline_chat_images: values["offline_chat_images"] == true,
      system_prompt: to_string(values["system_prompt"] || "")
    })
  end

  def save("technology", project_id, values) do
    save_project_metadata(project_id, %{
      semantic_similarity_enabled: values["semantic_similarity_enabled"] == true
    })
  end

  def save("publishing", project_id, values) do
    case Metadata.set_publishing_preferences(project_id, %{
           ssh_host: blank_to_nil(values["ssh_host"]),
           ssh_user: blank_to_nil(values["ssh_user"]),
           ssh_remote_path: blank_to_nil(values["ssh_remote_path"]),
           ssh_mode: values["ssh_mode"] || "scp"
         }) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def save("mcp", _project_id, values) do
    MCPConfig.mcp_rows()
    |> Enum.filter(& &1.supported?)
    |> Enum.reduce_while(:ok, fn row, _acc ->
      case toggle_mcp_agent(row, Map.get(values, "mcp:#{row.id}", row.configured?)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def save("style", project_id, values) do
    save_project_metadata(project_id, %{pico_theme: values["pico_theme"]})
  end

  def save(_section, _project_id, _values), do: :ok

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp form(section, title, fields), do: %{section: section, title: title, fields: fields}

  defp text(key, label, value),
    do: %{key: key, label: label, type: :text, value: to_string(value || ""), options: []}

  defp bool(key, label, value),
    do: %{key: key, label: label, type: :bool, value: value == true, options: []}

  defp enum(key, label, value, options),
    do: %{key: key, label: label, type: :enum, value: to_string(value || ""), options: options}

  defp info(key, label, value),
    do: %{key: key, label: label, type: :info, value: value, options: []}

  defp editor_settings do
    %{
      "default_mode" => Settings.get_global_setting("ui.preferred_editor_mode") || "markdown",
      "diff_view_style" => Settings.get_global_setting("ui.git_diff_view_style") || "inline",
      "wrap_long_lines" => Settings.get_global_setting("ui.git_diff_word_wrap") == "true",
      "hide_unchanged_regions" =>
        Settings.get_global_setting("ui.git_diff_hide_unchanged_regions") == "true"
    }
  end

  defp supported_language_codes, do: Enum.map(I18n.supported_languages(), & &1.code)

  defp template_slugs(project_id, kind) do
    Repo.all(
      from template in Template,
        where: template.project_id == ^project_id and template.kind == ^kind,
        order_by: [asc: template.slug],
        select: template.slug
    )
  end

  # Project, technology and style all live in the same metadata record;
  # `Metadata.update_project_metadata/2` treats missing keys as nil, so the
  # current values are always passed along and only the edits override them.
  defp save_project_metadata(project_id, overrides) do
    {:ok, metadata} = Metadata.get_project_metadata(project_id)

    attrs =
      metadata
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
      |> Map.merge(overrides)

    case Metadata.update_project_metadata(project_id, attrs) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_category(project_id, name) do
    case String.trim(to_string(name || "")) do
      "" ->
        :ok

      category ->
        case Metadata.add_category(project_id, category) do
          {:ok, _metadata} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp category_settings_by_name(values) do
    values
    |> Enum.flat_map(fn {key, value} ->
      case String.split(key, ":", parts: 3) do
        ["cat", name, property] -> [{name, property, value}]
        _other -> []
      end
    end)
    |> Enum.group_by(fn {name, _property, _value} -> name end)
    |> Enum.map(fn {name, entries} ->
      {name, Map.new(entries, fn {_name, property, value} -> category_setting(property, value) end)}
    end)
  end

  defp category_setting("title", value), do: {:title, blank_to_nil(value)}
  defp category_setting("render_in_lists", value), do: {:render_in_lists, value == true}
  defp category_setting("show_title", value), do: {:show_title, value == true}
  defp category_setting("post_template_slug", value), do: {:post_template_slug, blank_to_nil(value)}
  defp category_setting("list_template_slug", value), do: {:list_template_slug, blank_to_nil(value)}

  defp toggle_mcp_agent(%{configured?: configured?}, wanted) when wanted == configured?, do: :ok

  defp toggle_mcp_agent(%{id: agent_id}, true) do
    case AgentConfig.add_to_config(agent_id, install_root: Application.app_dir(:bds)) do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp toggle_mcp_agent(%{id: agent_id}, _wanted) do
    case AgentConfig.remove_from_config(agent_id) do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp split_languages(value) do
    value
    |> to_string()
    |> String.split(~r/[,\s]+/, trim: true)
    |> Enum.uniq()
  end

  defp parse_integer(value, fallback) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _rest} -> parsed
      :error -> fallback
    end
  end

  defp boolean_string(true), do: "true"
  defp boolean_string(_value), do: "false"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(to_string(value)) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
