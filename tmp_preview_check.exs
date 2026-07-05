Application.ensure_all_started(:ecto_sql)
Application.ensure_all_started(:exqlite)
{:ok, _} = BDS.Repo.start_link()

project_id = "aceac6d3-8f3f-4a9c-a2b4-517b59b20f44"

# 1) Replicate the preview data path exactly.
import Ecto.Query
alias BDS.Posts.Post

posts =
  BDS.Repo.all(
    from p in Post,
      where: p.project_id == ^project_id and p.status in [:published, :draft],
      order_by: [desc: p.created_at, desc: p.published_at, asc: p.slug]
  )

picture = Enum.filter(posts, fn p -> "picture" in (p.categories || []) end)

IO.puts("== preview data path, first 5 (expect newest) ==")
picture |> Enum.take(5) |> Enum.each(fn p -> IO.puts("  #{p.slug}  #{p.created_at}  #{p.language}") end)

# 2) Call the actual router render and extract the first post links.
case BDS.Preview.Router.render_route(project_id, "/category/picture") do
  {:ok, %{body: body}} ->
    body = IO.iodata_to_binary(body)

    links =
      Regex.scan(~r{href="[^"]*/20\d\d/\d\d/[^"]*"}, body)
      |> Enum.map(&hd/1)
      |> Enum.take(6)

    IO.puts("== render_route /category/picture, first link hrefs ==")
    Enum.each(links, &IO.puts("  #{&1}"))

  other ->
    IO.inspect(other, label: "render_route returned")
end
