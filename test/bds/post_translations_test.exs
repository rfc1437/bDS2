defmodule BDS.PostTranslationsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias BDS.AI
  alias BDS.Media
  alias BDS.Metadata
  alias BDS.Posts
  alias BDS.Repo

  defmodule FakeRuntime do
    def generate(endpoint, request, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:runtime_request, endpoint, request})

      case request.operation do
        :translate_post ->
          {:ok,
           %{
             json: %{
               "title" => "Hallo Welt",
               "excerpt" => "Kurze Zusammenfassung",
               "content" => "# Hallo Welt\n\nUbersetzter Inhalt"
             },
             usage: %{
               input_tokens: 22,
               output_tokens: 14,
               cache_read_tokens: 0,
               cache_write_tokens: 0
             }
           }}

        :translate_media ->
          {:ok,
           %{
             json: %{
               "title" => "Medientitel",
               "alt" => "Medien Alt",
               "caption" => "Medien Beschriftung"
             },
             usage: %{
               input_tokens: 12,
               output_tokens: 10,
               cache_read_tokens: 0,
               cache_write_tokens: 0
             }
           }}
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual) end)
    :ok = BDS.Tasks.clear_finished()

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-post-translations-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    original_posts_config = Application.get_env(:bds, :posts, [])

    on_exit(fn ->
      File.rm_rf(temp_dir)
      Application.put_env(:bds, :posts, original_posts_config)
      _ = BDS.Tasks.clear_finished()
    end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Translations", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "upserted post translations publish with the canonical post, reopen on edit, and delete their file",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Canonical Post",
               excerpt: "English summary",
               content: "Hello world",
               language: "en"
             })

    assert {:ok, translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Kanonischer Beitrag",
               excerpt: "Deutsche Zusammenfassung",
               content: "Hallo Welt"
             })

    assert translation.translation_for == post.id
    assert translation.language == "de"
    assert translation.status == :draft
    assert translation.file_path == ""
    assert translation.content == "Hallo Welt"

    assert {:ok, [listed_translation]} = Posts.list_post_translations(post.id)
    assert listed_translation.id == translation.id

    assert {:ok, _published_post} = Posts.publish_post(post.id)
    assert published_translation = Posts.get_post_translation!(translation.id)

    assert published_translation.status == :published
    assert is_integer(published_translation.published_at)
    assert published_translation.content == nil
    assert published_translation.file_path =~ ~r/^posts\/\d{4}\/\d{2}\/canonical-post\.de\.md$/

    translation_path = Path.join(temp_dir, published_translation.file_path)
    assert File.exists?(translation_path)

    translation_contents = File.read!(translation_path)
    assert translation_contents =~ "translationFor: #{post.id}\n"
    assert translation_contents =~ "title: Kanonischer Beitrag\n"
    assert translation_contents =~ "language: de\n"
    assert translation_contents =~ "status: published\n"
    assert translation_contents =~ "\n---\nHallo Welt\n"

    assert {:ok, reopened_translation} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Neu formuliert",
               excerpt: "Aktualisiert",
               content: "Neuer Entwurf"
             })

    assert reopened_translation.status == :draft
    assert reopened_translation.title == "Neu formuliert"
    assert reopened_translation.excerpt == "Aktualisiert"
    assert reopened_translation.content == "Neuer Entwurf"
    assert reopened_translation.updated_at >= published_translation.updated_at

    reopened_source = Posts.get_post!(post.id)
    assert reopened_source.status == :draft
    assert reopened_source.content == "Hello world"

    assert reopened_source.file_path ==
             String.replace_suffix(published_translation.file_path, ".de.md", ".md")

    assert {:ok, :deleted} = Posts.delete_post_translation(reopened_translation.id)
    refute File.exists?(translation_path)
    assert {:ok, []} = Posts.list_post_translations(post.id)
  end

  test "create_post enqueues and completes auto-translation tasks for missing project languages",
       %{project: project} do
    configure_auto_translation_test_runtime()

    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de", "fr"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Hello World",
               excerpt: "Short summary",
               content: "# Hello\n\nSource body",
               language: "en"
             })

    translations = wait_for_post_translations(post.id, ["de", "fr"])

    assert Enum.map(translations, & &1.language) == ["de", "fr"]
    assert Enum.all?(translations, &(&1.title == "Hallo Welt"))
    assert Enum.all?(translations, &(&1.excerpt == "Kurze Zusammenfassung"))
    assert Enum.all?(translations, &(&1.content == "# Hallo Welt\n\nUbersetzter Inhalt"))

    tasks = wait_for_ai_tasks(2)

    assert Enum.any?(tasks, &(&1.name == "Auto-translate Post to de" and &1.status == :completed))
    assert Enum.any?(tasks, &(&1.name == "Auto-translate Post to fr" and &1.status == :completed))
    assert Enum.all?(tasks, &(&1.group_name == "AI"))
  end

  test "update_post auto-translates missing languages and cascades linked media translations",
       %{project: project, temp_dir: temp_dir} do
    configure_auto_translation_test_runtime()

    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de"]
             })

    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Needs Translation",
               excerpt: "Draft excerpt",
               content: "Source body",
               language: "en",
               do_not_translate: true
             })

    source_path = Path.join(temp_dir, "linked-media.txt")
    File.write!(source_path, "linked media")

    assert {:ok, media} =
             Media.import_media(%{
               project_id: project.id,
               source_path: source_path,
               title: "Source Media",
               alt: "Source Alt",
               caption: "Source Caption",
               language: "en"
             })

    Repo.insert_all("post_media", [
      %{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        post_id: post.id,
        media_id: media.id,
        sort_order: 0,
        created_at: BDS.Persistence.now_ms()
      }
    ])

    assert {:ok, _updated_post} =
             Posts.update_post(post.id, %{
               do_not_translate: false,
               content: "Updated source body"
             })

    [translation] = wait_for_post_translations(post.id, ["de"])
    assert translation.language == "de"

    media_translation = wait_for_media_translation(media.id, "de")
    assert media_translation.title == "Medientitel"
    assert media_translation.alt == "Medien Alt"
    assert media_translation.caption == "Medien Beschriftung"

    tasks = wait_for_ai_tasks(2)

    assert Enum.any?(tasks, &(&1.name == "Auto-translate Post to de" and &1.status == :completed))

    assert Enum.any?(tasks, fn task ->
             task.name == "Auto-translate Media to de" and task.status == :completed
           end)

    assert File.exists?(Path.join(temp_dir, media.file_path <> ".de.meta"))
  end

  test "validate_translations reports missing languages, orphan translation files, and do-not-translate posts",
       %{project: project, temp_dir: temp_dir} do
    assert {:ok, _metadata} =
             Metadata.update_project_metadata(project.id, %{
               main_language: "en",
               blog_languages: ["en", "de", "fr"]
             })

    assert {:ok, translatable_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Needs French",
               content: "Body",
               language: "en"
             })

    assert {:ok, _translation} =
             Posts.upsert_post_translation(translatable_post.id, "de", %{
               title: "Braucht Französisch",
               content: "Inhalt"
             })

    assert {:ok, _published} = Posts.publish_post(translatable_post.id)

    assert {:ok, ignored_post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Skip Me",
               content: "Body",
               language: "en"
             })

    assert {:ok, ignored_post} = Posts.update_post(ignored_post.id, %{do_not_translate: true})
    assert {:ok, _published_ignored_post} = Posts.publish_post(ignored_post.id)

    orphan_dir = Path.join([temp_dir, "posts", "2026", "04"])
    File.mkdir_p!(orphan_dir)

    orphan_path = Path.join(orphan_dir, "orphan.fr.md")

    File.write!(
      orphan_path,
      [
        "---",
        "id: orphan-translation",
        "translationFor: missing-post",
        "language: fr",
        "title: Orpheline",
        "status: published",
        "createdAt: 1711843200",
        "updatedAt: 1711929600",
        "publishedAt: 1712016000",
        "---",
        "Texte orphelin",
        ""
      ]
      |> Enum.join("\n")
    )

    assert {:ok, report} = Posts.validate_translations(project.id)

    assert report.missing == [%{post_id: translatable_post.id, language: "fr"}]
    assert report.orphan_files == ["posts/2026/04/orphan.fr.md"]
    assert report.do_not_translate_posts == [ignored_post.id]
  end

  test "UniqueTranslationPerLanguage: a post has at most one translation per language", %{
    project: project
  } do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "Canonical Post",
               content: "Hello world",
               language: "en"
             })

    assert {:ok, first} =
             Posts.upsert_post_translation(post.id, "de", %{title: "Titel"})

    # Re-upserting the same language updates the existing row instead of adding a second.
    assert {:ok, second} =
             Posts.upsert_post_translation(post.id, "de", %{title: "Geändert"})

    assert second.id == first.id

    assert [persisted] =
             BDS.Posts.Translation
             |> where([t], t.translation_for == ^post.id and t.language == "de")
             |> Repo.all()

    assert persisted.title == "Geändert"

    # A direct insert of a distinct row with the same (post, language) is rejected by the
    # unique constraint backing the invariant, returning a changeset error rather than crashing.
    now = BDS.Persistence.now_ms()

    duplicate =
      BDS.Posts.Translation.changeset(%BDS.Posts.Translation{}, %{
        id: Ecto.UUID.generate(),
        project_id: post.project_id,
        translation_for: post.id,
        language: "de",
        title: "Duplicate",
        status: :draft,
        created_at: now,
        updated_at: now
      })

    assert {:error, changeset} = Repo.insert(duplicate)
    assert %{language: ["has already been taken"]} = errors_on(changeset)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp configure_auto_translation_test_runtime do
    assert {:ok, _endpoint} =
             AI.put_endpoint(
               :online,
               %{
                 url: "https://api.example.test/v1",
                 api_key: "online-secret",
                 model: "gpt-4o-mini"
               }
             )

    assert :ok = AI.set_airplane_mode(false)
    assert :ok = AI.put_model_preference(:title, "gpt-4.1-mini")

    Application.put_env(:bds, :posts,
      auto_translation_ai_opts: [
        runtime: FakeRuntime,
        test_pid: self()
      ]
    )
  end

  defp wait_for_post_translations(post_id, languages, attempts \\ 100)

  defp wait_for_post_translations(_post_id, _languages, 0) do
    flunk("post translations did not reach expected state")
  end

  defp wait_for_post_translations(post_id, languages, attempts) do
    {:ok, translations} = Posts.list_post_translations(post_id)
    expected = Enum.sort(languages)

    if Enum.sort(Enum.map(translations, & &1.language)) == expected do
      translations
    else
      Process.sleep(20)
      wait_for_post_translations(post_id, languages, attempts - 1)
    end
  end

  defp wait_for_media_translation(media_id, language, attempts \\ 100)

  defp wait_for_media_translation(_media_id, _language, 0) do
    flunk("media translation did not reach expected state")
  end

  defp wait_for_media_translation(media_id, language, attempts) do
    translation =
      Repo.one(
        from translation in BDS.Media.Translation,
          where: translation.translation_for == ^media_id and translation.language == ^language
      )

    if translation do
      translation
    else
      Process.sleep(20)
      wait_for_media_translation(media_id, language, attempts - 1)
    end
  end

  defp wait_for_ai_tasks(count, attempts \\ 100)

  test "do_not_translate guard prevents translation upsert via the API", %{
    project: project
  } do
    assert {:ok, post} =
             Posts.create_post(%{
               project_id: project.id,
               title: "DNT Guarded",
               content: "Body",
               language: "en"
             })

    assert {:ok, post} = Posts.update_post(post.id, %{do_not_translate: true})
    assert post.do_not_translate == true

    assert {:error, changeset} =
             Posts.upsert_post_translation(post.id, "de", %{
               title: "Sollte fehlschlagen",
               content: "Inhalt"
             })

    assert changeset.errors[:do_not_translate] ==
             {"cannot add translations when do_not_translate is true", []}
  end

  defp wait_for_ai_tasks(_count, 0) do
    flunk("AI tasks did not reach expected state")
  end

  defp wait_for_ai_tasks(count, attempts) do
    tasks =
      BDS.Tasks.list_tasks()
      |> Enum.filter(&(&1.group_name == "AI"))

    if length(tasks) >= count and Enum.all?(tasks, &(&1.status == :completed)) do
      tasks
    else
      Process.sleep(20)
      wait_for_ai_tasks(count, attempts - 1)
    end
  end
end
