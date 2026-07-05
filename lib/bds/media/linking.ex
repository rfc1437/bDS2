defmodule BDS.Media.Linking do
  @moduledoc false

  require Logger

  import Ecto.Query

  import BDS.Media.FileOps,
    only: [
      progress_callback: 1,
      report_rebuild_progress: 4,
      report_rebuild_started: 3
    ]

  alias BDS.Media.Media
  alias BDS.Media.Sidecars
  alias BDS.Persistence
  alias BDS.Posts.PostMedia
  alias BDS.Projects
  alias BDS.Repo

  @spec list_linked_posts(String.t()) ::
          [%{post_id: String.t(), title: String.t(), sort_order: integer()}]
  def list_linked_posts(media_id) when is_binary(media_id) do
    Repo.all(
      from post in BDS.Posts.Post,
        join: pm in PostMedia,
        on: pm.post_id == post.id,
        where: pm.media_id == ^media_id,
        order_by: [asc: pm.sort_order, asc: post.updated_at],
        select: %{
          post_id: post.id,
          title: fragment("COALESCE(?, ?, ?)", post.title, post.slug, post.id),
          sort_order: pm.sort_order
        }
    )
  end

  @spec link_media_to_post(String.t(), String.t()) ::
          {:ok, :linked} | {:error, :not_found | term()}
  def link_media_to_post(media_id, post_id) when is_binary(media_id) and is_binary(post_id) do
    case {Repo.get(Media, media_id), Repo.get(BDS.Posts.Post, post_id)} do
      {nil, _post} ->
        {:error, :not_found}

      {_media, nil} ->
        {:error, :not_found}

      {%Media{} = media, %BDS.Posts.Post{} = post} ->
        project = Projects.get_project!(media.project_id)

        case Repo.transaction(fn ->
               if Repo.exists?(
                    from pm in PostMedia,
                      where: pm.post_id == ^post.id and pm.media_id == ^media.id
                  ) do
                 :already_linked
               else
                 sort_order = next_sort_order(media.id)

                 %PostMedia{}
                 |> PostMedia.changeset(%{
                   id: Ecto.UUID.generate(),
                   project_id: media.project_id,
                   post_id: post.id,
                   media_id: media.id,
                   sort_order: sort_order,
                   created_at: Persistence.now_ms()
                 })
                 |> Repo.insert!()

                 :linked
               end
             end) do
          {:ok, _result} ->
            log_sidecar_error(Sidecars.write_sidecar(project, media), media.id)
            {:ok, :linked}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec unlink_media_from_post(String.t(), String.t()) ::
          {:ok, :unlinked} | {:error, :not_found | term()}
  def unlink_media_from_post(media_id, post_id) when is_binary(media_id) and is_binary(post_id) do
    case Repo.get(Media, media_id) do
      nil ->
        {:error, :not_found}

      %Media{} = media ->
        project = Projects.get_project!(media.project_id)

        case Repo.transaction(fn ->
               {_count, _} =
                 Repo.delete_all(
                   from pm in PostMedia,
                     where: pm.media_id == ^media.id and pm.post_id == ^post_id
                 )

               :ok
             end) do
          {:ok, :ok} ->
            log_sidecar_error(Sidecars.write_sidecar(project, media), media.id)
            {:ok, :unlinked}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec linked_post_ids(String.t()) :: [String.t()]
  def linked_post_ids(media_id) do
    Repo.all(
      from pm in PostMedia,
        where: pm.media_id == ^media_id,
        order_by: [asc: pm.sort_order, asc: pm.post_id],
        select: pm.post_id
    )
  end

  @doc """
  Restore `PostMedia` links for `media_id` from the list of `post_ids` persisted
  in the media sidecar (`linkedPostIds`).

  Used by rebuild-from-filesystem so gallery associations survive a rebuild (and
  so projects whose link data lives only in sidecars still populate galleries).
  Idempotent: skips links that already exist and post ids that are not present
  in the database. Does not re-write sidecars.
  """
  @spec restore_post_links(String.t(), String.t(), [String.t()] | term()) :: :ok
  def restore_post_links(project_id, media_id, post_ids)
      when is_binary(project_id) and is_binary(media_id) and is_list(post_ids) do
    post_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.each(fn post_id -> ensure_link(project_id, media_id, post_id) end)
  end

  def restore_post_links(_project_id, _media_id, _post_ids), do: :ok

  @doc """
  Rebuild the `post_media` junction for a project from every media sidecar's
  `linkedPostIds`.

  Media sidecars are the source of truth for gallery associations (matching the
  old bDS `rebuildFromSidecars`). Existing project links are cleared and then
  re-created from the on-disk sidecars, so galleries reflect the project's
  metadata even if the junction table drifted or was never populated. Links to
  posts that are not present in the database are skipped.
  """
  @spec rebuild_links_from_sidecars(String.t(), keyword()) ::
          {:ok, %{media: non_neg_integer(), links: non_neg_integer()}}
  def rebuild_links_from_sidecars(project_id, opts \\ []) when is_binary(project_id) do
    project = Projects.get_project!(project_id)
    on_progress = progress_callback(opts)

    media_list =
      Repo.all(from m in Media, where: m.project_id == ^project_id, order_by: [asc: m.id])

    total = length(media_list)
    :ok = report_rebuild_started(on_progress, total, "media links")

    {_cleared, _} =
      Repo.delete_all(from pm in PostMedia, where: pm.project_id == ^project_id)

    media_list
    |> Enum.with_index(1)
    |> Enum.each(fn {media, index} ->
      post_ids = Sidecars.read_linked_post_ids(project, media)
      restore_post_links(project_id, media.id, post_ids)
      :ok = report_rebuild_progress(on_progress, index, total, "media links")
    end)

    links =
      Repo.aggregate(from(pm in PostMedia, where: pm.project_id == ^project_id), :count)

    {:ok, %{media: total, links: links}}
  end

  defp ensure_link(project_id, media_id, post_id) do
    already_linked? =
      Repo.exists?(
        from pm in PostMedia,
          where: pm.media_id == ^media_id and pm.post_id == ^post_id
      )

    post_exists? = Repo.exists?(from p in BDS.Posts.Post, where: p.id == ^post_id)

    if not already_linked? and post_exists? do
      %PostMedia{}
      |> PostMedia.changeset(%{
        id: Ecto.UUID.generate(),
        project_id: project_id,
        post_id: post_id,
        media_id: media_id,
        sort_order: next_sort_order(media_id),
        created_at: Persistence.now_ms()
      })
      |> Repo.insert!()

      :ok
    else
      :ok
    end
  end

  defp log_sidecar_error(:ok, _media_id), do: :ok

  defp log_sidecar_error({:error, reason}, media_id) do
    Logger.warning("Sidecar write failed for media #{media_id}: #{inspect(reason)}")
  end

  defp next_sort_order(media_id) do
    case Repo.one(
           from pm in PostMedia,
             where: pm.media_id == ^media_id,
             select: max(pm.sort_order)
         ) do
      value when is_integer(value) -> value + 1
      _other -> 0
    end
  end
end
