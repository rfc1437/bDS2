defmodule BDS.Scripting.Capabilities.Bridges do
  @moduledoc false

  import BDS.Scripting.Capabilities.Util

  alias BDS.AI
  alias BDS.Embeddings
  alias BDS.Git
  alias BDS.Media
  alias BDS.Posts
  alias BDS.Publishing

  # --- Sync / Git ---

  def sync_available?, do: not is_nil(System.find_executable("git"))

  def repo_state(project_id, opts) do
    project_id
    |> Git.repository(git_opts(opts))
    |> unwrap_result()
  end

  def repo_status(project_id, opts) do
    project_id
    |> Git.status(git_opts(opts))
    |> unwrap_result()
  end

  def repo_history(project_id, opts) do
    case Git.repository(project_id, git_opts(opts)) do
      {:ok, %{current_branch: branch}} when is_binary(branch) and branch != "" ->
        Git.history(project_id, branch, git_opts(opts))
        |> unwrap_result()

      _other ->
        %{"commits" => []}
    end
  end

  def repo_fetch(project_id, opts), do: project_id |> Git.fetch(git_opts(opts)) |> unwrap_result()
  def repo_pull(project_id, opts), do: project_id |> Git.pull(git_opts(opts)) |> unwrap_result()
  def repo_push(project_id, opts), do: project_id |> Git.push(git_opts(opts)) |> unwrap_result()

  def repo_commit_all(project_id, message, opts) do
    project_id
    |> Git.commit_all(string_or_nil(message) || "", git_opts(opts))
    |> unwrap_result()
  end

  # --- Publishing ---

  def upload_site(project_id, credentials, opts) do
    project_id
    |> Publishing.upload_site(normalize_map(credentials), publishing_opts(opts))
    |> unwrap_result()
  end

  # --- AI ---

  def detect_post_language(title, content, opts) do
    text = Enum.join([string_or_nil(title) || "", string_or_nil(content) || ""], "\n\n")

    case AI.detect_language(text, ai_opts(opts)) do
      {:ok, %{language_code: language_code}} -> %{"success" => true, "language" => language_code}
      {:error, reason} -> %{"success" => false, "error" => inspect(reason)}
    end
  end

  def analyze_post(post_id, opts) do
    post_id
    |> string_or_nil()
    |> AI.analyze_post(ai_opts(opts))
    |> unwrap_result()
  end

  def translate_post(post_id, language, opts) do
    post_id = string_or_nil(post_id)
    language = string_or_nil(language) || ""

    with {:ok, translation} <- AI.translate_post(post_id, language, ai_opts(opts)),
         {:ok, saved_translation} <-
           Posts.upsert_post_translation(post_id, language, %{
             title: translation.title,
             excerpt: translation.excerpt,
             content: translation.content
           }) do
      sanitize(saved_translation)
    else
      _other -> nil
    end
  end

  def analyze_media_image(media_id, opts) do
    case AI.analyze_image(string_or_nil(media_id), ai_opts(opts)) do
      {:ok, result} -> sanitize(result)
      {:error, _reason} -> nil
    end
  end

  def detect_media_language(title, alt, caption, opts) do
    text = Enum.join([string_or_nil(title) || "", string_or_nil(alt) || "", string_or_nil(caption) || ""], "\n")

    case AI.detect_language(text, ai_opts(opts)) do
      {:ok, %{language_code: language_code}} -> %{"success" => true, "language" => language_code}
      {:error, reason} -> %{"success" => false, "error" => inspect(reason)}
    end
  end

  def translate_media_metadata(media_id, language, opts) do
    media_id = string_or_nil(media_id)
    language = string_or_nil(language) || ""

    with {:ok, translation} <- AI.translate_media(media_id, language, ai_opts(opts)),
         {:ok, saved_translation} <-
           Media.upsert_media_translation(media_id, language, %{
             title: translation.title,
             alt: translation.alt,
             caption: translation.caption
           }) do
      sanitize(saved_translation)
    else
      _other -> nil
    end
  end

  # --- Embeddings ---

  def embedding_progress(project_id), do: project_id |> Embeddings.get_indexing_progress() |> unwrap_result()

  def find_similar(post_id, limit) do
    post_id
    |> string_or_nil()
    |> Embeddings.find_similar(integer_or_default(limit, 5))
    |> unwrap_result()
  end

  def compute_similarities(post_id, target_ids) do
    post_id
    |> string_or_nil()
    |> Embeddings.compute_similarities(normalize_string_list(target_ids))
    |> unwrap_result()
  end

  def suggest_tags(post_id, exclude_tags) do
    post_id
    |> string_or_nil()
    |> Embeddings.suggest_tags(normalize_string_list(exclude_tags))
    |> unwrap_result()
  end

  def find_duplicates(project_id), do: project_id |> Embeddings.find_duplicates() |> unwrap_result()
  def dismiss_pair(post_id_a, post_id_b), do: atom_result(Embeddings.dismiss_duplicate_pair(string_or_nil(post_id_a) || "", string_or_nil(post_id_b) || ""), :ok)
  def index_unindexed_posts(project_id), do: project_id |> Embeddings.index_unindexed() |> unwrap_result()

  # --- Opt builders ---

  def git_opts(opts) do
    case Keyword.get(opts, :git_runner) do
      nil -> []
      runner -> [runner: runner]
    end
  end

  def publishing_opts(opts) do
    case Keyword.get(opts, :publishing_uploader) do
      nil -> []
      uploader -> [uploader: uploader]
    end
  end

  def ai_opts(opts) do
    []
    |> maybe_put_opt(:runtime, Keyword.get(opts, :ai_runtime))
    |> maybe_put_opt(:secret_backend, Keyword.get(opts, :ai_secret_backend))
  end
end
