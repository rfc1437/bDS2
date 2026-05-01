defmodule BDS.Posts.Translations do
  @moduledoc false

  import Ecto.Query

  alias BDS.Persistence
  alias BDS.Posts
  alias BDS.Posts.FileSync
  alias BDS.Posts.Post
  alias BDS.Posts.RebuildFromFiles
  alias BDS.Posts.Translation
  alias BDS.Projects
  alias BDS.Repo
  alias BDS.Search

  @type attrs :: %{optional(atom()) => term(), optional(String.t()) => term()}

  @spec publish_post_translation(String.t(), String.t() | atom()) ::
          {:ok, Translation.t()} | {:error, :not_found | term()}
  def publish_post_translation(post_id, language) do
    normalized_language = language |> to_string() |> String.trim() |> String.downcase()

    case Repo.get_by(Translation, translation_for: post_id, language: normalized_language) do
      nil ->
        {:error, :not_found}

      %Translation{} ->
        with {:ok, _post} <- Posts.publish_post(post_id),
             %Translation{} = translation <-
               Repo.get_by(Translation, translation_for: post_id, language: normalized_language) do
          {:ok, translation}
        else
          nil -> {:error, :not_found}
          error -> error
        end
    end
  end

  @spec list_post_translations(String.t()) :: {:ok, [Translation.t()]}
  def list_post_translations(post_id) do
    {:ok,
     Repo.all(
       from(translation in Translation,
         where: translation.translation_for == ^post_id,
         order_by: [asc: translation.language]
       )
     )}
  end

  @spec upsert_post_translation(String.t(), String.t() | atom(), attrs()) ::
          {:ok, Translation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def upsert_post_translation(post_id, language, attrs) do
    case Repo.get(Post, post_id) do
      nil ->
        {:error, :not_found}

      %Post{do_not_translate: true} = post ->
        {:error,
         post
         |> Post.changeset(%{})
         |> Ecto.Changeset.add_error(
           :do_not_translate,
           "cannot add translations when do_not_translate is true"
         )}

      %Post{} = post ->
        now = Persistence.now_ms()
        normalized_language = normalize_language(language)

        translation =
          Repo.get_by(Translation, translation_for: post.id, language: normalized_language) ||
            %Translation{}

        updates =
          normalize_translation_updates(post, translation, normalized_language, attrs, now)

        translation
        |> Translation.changeset(updates)
        |> Repo.insert_or_update()
        |> case do
          {:ok, saved_translation} ->
            {:ok, _post} = maybe_reopen_source_post_for_manual_translation(post, attrs)
            :ok = Search.sync_post(post.id)
            {:ok, saved_translation}

          error ->
            error
        end
    end
  end

  @spec delete_post_translation(String.t()) :: {:ok, :deleted} | {:error, :not_found}
  def delete_post_translation(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{} = translation ->
        :ok = FileSync.delete_translation_file(translation)
        Repo.delete!(translation)
        :ok = Search.sync_post(translation.translation_for)
        {:ok, :deleted}
    end
  end

  @spec sync_post_translation_from_file(String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found}
  def sync_post_translation_from_file(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{file_path: file_path} when file_path in [nil, ""] ->
        {:error, :not_found}

      %Translation{} = translation ->
        project = Projects.get_project!(translation.project_id)
        full_path = Path.join(Projects.project_data_dir(project), translation.file_path)

        with true <- File.exists?(full_path),
             {:ok, rebuild_file} <- RebuildFromFiles.parse_rebuild_file(project, full_path) do
          {:ok,
           RebuildFromFiles.upsert_post_translation_from_rebuild_file(
             translation.project_id,
             rebuild_file,
             sync_search: true
           )}
        else
          false -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec rewrite_published_post_translation(String.t()) ::
          {:ok, Translation.t()} | {:error, :not_found}
  def rewrite_published_post_translation(translation_id) do
    case Repo.get(Translation, translation_id) do
      nil ->
        {:error, :not_found}

      %Translation{file_path: file_path, status: status} = translation
      when file_path not in [nil, ""] and status == :published ->
        post = Repo.get!(Post, translation.translation_for)
        :ok = publish_translation(post, translation)
        {:ok, Repo.get!(Translation, translation_id)}

      %Translation{} ->
        {:error, :not_found}
    end
  end

  @doc false
  def publish_post_translations(%Post{} = post) do
    Repo.all(from(translation in Translation, where: translation.translation_for == ^post.id))
    |> Enum.each(fn translation ->
      if translation.status == :draft do
        publish_translation(post, translation)
      end
    end)

    :ok
  end

  @doc false
  def publish_translation(%Post{} = post, %Translation{} = translation) do
    project = Projects.get_project!(post.project_id)
    published_at = translation.published_at || Persistence.now_ms()
    relative_path = FileSync.translation_relative_path(post, translation.language)
    full_path = Path.join(Projects.project_data_dir(project), relative_path)
    updated_at = Persistence.now_ms()
    body = FileSync.publishable_translation_body(translation, full_path)

    :ok =
      Persistence.atomic_write(
        full_path,
        FileSync.serialize_translation_file(
          %{translation | updated_at: updated_at, content: body},
          published_at
        )
      )

    translation
    |> Translation.changeset(%{
      status: :published,
      published_at: published_at,
      file_path: relative_path,
      content: nil,
      updated_at: updated_at
    })
    |> Repo.update!()

    :ok
  end

  defp normalize_translation_updates(post, %Translation{} = translation, language, attrs, now) do
    requested_status =
      case attr(attrs, :status) do
        nil -> nil
        status -> RebuildFromFiles.parse_translation_status(status)
      end

    updates =
      %{}
      |> maybe_put(:title, attr(attrs, :title))
      |> maybe_put(:excerpt, attr(attrs, :excerpt))
      |> maybe_put(:content, attr(attrs, :content))

    reopened? =
      translation.status == :published and translation_content_change?(translation, updates)

    status = if(reopened?, do: :draft, else: requested_status || translation.status || :draft)

    %{
      id: translation.id || Ecto.UUID.generate(),
      project_id: post.project_id,
      translation_for: post.id,
      language: language,
      title: Map.get(updates, :title, translation.title),
      excerpt: Map.get(updates, :excerpt, translation.excerpt),
      content: Map.get(updates, :content, translation.content),
      status: status,
      created_at: translation.created_at || now,
      updated_at: now,
      published_at: translation.published_at || if(status == :published, do: now, else: nil),
      file_path: translation.file_path || "",
      checksum: translation.checksum
    }
  end

  defp translation_content_change?(translation, updates) do
    Enum.any?([:title, :excerpt, :content], fn field ->
      case Map.fetch(updates, field) do
        {:ok, value} -> value != Map.get(translation, field)
        :error -> false
      end
    end)
  end

  defp maybe_reopen_source_post_for_manual_translation(%Post{} = post, attrs) do
    if attr(attrs, :auto_generated) == true or post.status != :published or
         post.file_path in [nil, ""] do
      {:ok, post}
    else
      project = Projects.get_project!(post.project_id)
      full_path = Path.join(Projects.project_data_dir(project), post.file_path)
      restored_content = FileSync.published_post_body(post, full_path)

      post
      |> Post.changeset(%{
        status: :draft,
        content: restored_content,
        updated_at: Persistence.now_ms()
      })
      |> Repo.update()
    end
  end

  defp normalize_language(nil), do: ""

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp attr(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.get(attrs, Atom.to_string(key))
      true -> nil
    end
  end
end
