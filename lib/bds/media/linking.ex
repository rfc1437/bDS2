defmodule BDS.Media.Linking do
  @moduledoc false

  import Ecto.Query

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
            :ok = Sidecars.write_sidecar(project, media)
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
            :ok = Sidecars.write_sidecar(project, media)
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
