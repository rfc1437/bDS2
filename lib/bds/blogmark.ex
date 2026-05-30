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

  @type candidate :: %{required(String.t()) => term()}

  @type receive_result :: %{
          post: Posts.Post.t(),
          toasts: [String.t()],
          errors: [%{slug: String.t() | nil, reason: term()}]
        }

  @doc """
  Parses a `bds2://new-post` deep link into a post candidate map.

  Returns `{:ok, candidate}` with string-keyed `title`, `url`, `content`,
  `tags` and `categories`, or an error when the scheme or action is unsupported.
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
  Receives a blogmark deep link for `project_id`: parses it, runs the transform
  pipeline, and creates a draft post from the resulting candidate.

  Returns `{:ok, %{post:, toasts:, errors:}}` where `toasts` are the
  budget-enforced transform messages and `errors` records any failed transforms.
  """
  @spec receive_deep_link(String.t(), String.t(), keyword()) ::
          {:ok, receive_result()} | {:error, term()}
  def receive_deep_link(project_id, url, opts \\ [])
      when is_binary(project_id) and is_binary(url) and is_list(opts) do
    with {:ok, candidate} <- parse_deep_link(url),
         {:ok, %{data: data, toasts: toasts, errors: errors}} <-
           Transforms.run(project_id, candidate, opts),
         data <- apply_default_category(project_id, data),
         {:ok, post} <- create_draft(project_id, data) do
      {:ok, %{post: post, toasts: toasts, errors: errors}}
    end
  end

  defp candidate_from_query(query) do
    params = URI.decode_query(query || "")

    %{
      "title" => Map.get(params, "title", "") |> to_string(),
      "url" => optional(params, "url"),
      "content" => optional(params, "content"),
      "tags" => list_param(params, "tags"),
      "categories" => list_param(params, "categories")
    }
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
