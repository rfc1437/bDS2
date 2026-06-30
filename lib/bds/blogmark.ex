defmodule BDS.Blogmark do
  @moduledoc """
  Receives `bds2://new-post` blogmark deep links and turns them into draft posts
  (spec: script.allium `BlogmarkReceived`/`ExecuteTransform`,
  editor_settings.allium `BookmarkletCopy`).

  The browser bookmarklet (`BDS.Scripting.Capabilities.AppShell`) navigates to a
  `bds2://new-post?title=&url=` URL. The desktop layer hands that URL here, where
  it is parsed into a post candidate, run through the enabled transform pipeline
  (`BDS.Scripts.Transforms`), and finally persisted as a draft post — defaulting
  the category from the project's `blogmark_category` setting when neither the
  link nor a transform supplied one.

  The `bds2://` scheme deliberately differs from the legacy app's `bds://` scheme
  so the two installs do not fight over the same registration.
  """

  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.Scripts.Transforms

  @scheme "bds2"
  @new_post_action "new-post"

  # Input-hardening limits mirrored from the legacy bDS app (shared/blogmark.ts).
  @max_title_length 200
  @max_url_length 2048
  @control_chars ~r/[\x00-\x1F\x7F]/

  @type candidate :: %{required(String.t()) => term()}

  @type receive_result :: %{
          post: Posts.Post.t(),
          toasts: [String.t()],
          errors: [%{slug: String.t() | nil, reason: term()}]
        }

  @doc """
  Parses a `bds2://new-post` deep link into a post candidate map.

  Returns `{:ok, candidate}` with string-keyed `title`, `url`, `content`,
  `tags`, `categories` and optional `project_id`, or an error when the scheme
  or action is unsupported.
  """
  @spec parse_deep_link(String.t()) ::
          {:ok, candidate()} | {:error, :unsupported_scheme | :unsupported_action | :invalid_url}
  def parse_deep_link(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: @scheme, host: @new_post_action, query: query} ->
        {:ok, candidate_from_query(query)}

      %URI{scheme: @scheme} ->
        {:error, :unsupported_action}

      %URI{scheme: nil} ->
        {:error, :invalid_url}

      %URI{} ->
        {:error, :unsupported_scheme}
    end
  end

  @doc """
  Returns the `project_id` a deep link targets, or `nil` when the link carries
  none or cannot be parsed. Used by the shell to switch to the link's project
  before importing.
  """
  @spec deep_link_project_id(String.t()) :: String.t() | nil
  def deep_link_project_id(url) when is_binary(url) do
    case parse_deep_link(url) do
      {:ok, %{"project_id" => project_id}} -> project_id
      _other -> nil
    end
  end

  @doc """
  Receives a blogmark deep link for `project_id`: parses it, runs the transform
  pipeline, and creates a draft post from the resulting candidate.

  When the deep link URL carries a `project_id` query parameter, it takes
  precedence over the passed `project_id` so the bookmarklet can target a
  specific project regardless of which project is currently active.

  Returns `{:ok, %{post:, toasts:, errors:}}` where `toasts` are the
  budget-enforced transform messages and `errors` records any failed transforms.
  """
  @spec receive_deep_link(String.t(), String.t(), keyword()) ::
          {:ok, receive_result()} | {:error, term()}
  def receive_deep_link(project_id, url, opts \\ [])
      when is_binary(project_id) and is_binary(url) and is_list(opts) do
    with {:ok, candidate} <- parse_deep_link(url),
         target_project <- resolve_target_project(project_id, candidate),
         candidate <- apply_default_content(candidate),
         {:ok, %{data: data, toasts: toasts, errors: errors}} <-
           Transforms.run(target_project, candidate, opts),
         data <- apply_default_category(target_project, data),
         {:ok, post} <- create_draft(target_project, data) do
      {:ok, %{post: post, toasts: toasts, errors: errors}}
    end
  end

  defp candidate_from_query(query) do
    params = URI.decode_query(query || "")

    project_id =
      case Map.get(params, "project_id") do
        nil -> nil
        "" -> nil
        id -> id
      end

    url = sanitize_http_url(Map.get(params, "url"))

    %{
      "title" => sanitize_title(Map.get(params, "title"), url_host(url)),
      "url" => url,
      "content" => optional(params, "content"),
      "tags" => list_param(params, "tags"),
      "categories" => list_param(params, "categories"),
      "project_id" => project_id
    }
  end

  # Strip control characters, trim, cap length; fall back to the URL host when
  # blank — mirrors bDS sanitizeTitle. Title/url are single-line fields, so
  # control-character stripping is safe here (unlike the multi-line body).
  defp sanitize_title(raw, fallback_host) do
    title =
      raw
      |> to_string()
      |> strip_control()
      |> String.trim()
      |> String.slice(0, @max_title_length)

    if title == "", do: fallback_host || "", else: title
  end

  # Accept only http(s) URLs, strip credentials and fragment, enforce a length
  # cap; anything else collapses to nil so it can never reach the post body.
  defp sanitize_http_url(raw) when is_binary(raw) do
    trimmed = raw |> strip_control() |> String.trim()

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        normalized = URI.to_string(%URI{uri | userinfo: nil, fragment: nil})
        if String.length(normalized) <= @max_url_length, do: normalized, else: nil

      _ ->
        nil
    end
  end

  defp sanitize_http_url(_other), do: nil

  defp url_host(url) when is_binary(url), do: URI.parse(url).host
  defp url_host(_other), do: nil

  defp strip_control(value), do: String.replace(value, @control_chars, "")

  # If the deep link carries a project_id, route to that project; otherwise
  # use the currently active project passed by the caller. This lets the
  # bookmarklet target a specific project even when a different one is open.
  defp resolve_target_project(_caller_project_id, %{"project_id" => pid}) when is_binary(pid) do
    pid
  end

  defp resolve_target_project(project_id, _candidate), do: project_id

  # Match the legacy bDS app: when the bookmarklet supplies no body, seed the
  # post content with a markdown link to the bookmarked page so transforms run
  # against the same input. Explicit content always wins.
  defp apply_default_content(candidate) do
    with nil <- optional_string(Map.get(candidate, "content")),
         url when is_binary(url) <- optional_string(Map.get(candidate, "url")) do
      title = Map.get(candidate, "title", "")
      Map.put(candidate, "content", blogmark_markdown_link(title, url))
    else
      _ -> candidate
    end
  end

  defp blogmark_markdown_link(title, url) do
    "[" <> escape_markdown_link_text(title) <> "](" <> url <> ")"
  end

  # Mirrors bDS escapeMarkdownLinkText: backslash first, then brackets/parens,
  # then collapse newlines to spaces.
  defp escape_markdown_link_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
    |> String.replace(~r/\r?\n/, " ")
  end

  defp optional(params, key) do
    case Map.get(params, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp list_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # Apply the project default category only when neither the deep link nor a
  # transform produced one, so explicit categories always win.
  defp apply_default_category(project_id, data) do
    case Map.get(data, "categories") do
      categories when is_list(categories) and categories != [] ->
        data

      _ ->
        case default_category(project_id) do
          nil -> data
          category -> Map.put(data, "categories", [category])
        end
    end
  end

  defp default_category(project_id) do
    case Metadata.get_project_metadata(project_id) do
      {:ok, %{blogmark_category: category}} when is_binary(category) and category != "" ->
        category

      _ ->
        nil
    end
  end

  defp create_draft(project_id, data) do
    Posts.create_post(%{
      project_id: project_id,
      title: Map.get(data, "title", ""),
      content: optional_string(Map.get(data, "content")),
      tags: string_list(Map.get(data, "tags")),
      categories: string_list(Map.get(data, "categories"))
    })
  end

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_value), do: nil

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []
end
