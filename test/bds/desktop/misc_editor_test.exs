defmodule BDS.Desktop.MiscEditorTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias BDS.Desktop.ShellLive.MiscEditor
  alias BDS.Projects

  @endpoint BDS.Desktop.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual) end)

    temp_dir =
      Path.join(System.tmp_dir!(), "bds-misc-editor-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = Projects.create_project(%{name: "Misc Editor Test", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  describe "translation_validation rendering" do
    test "shows summary with correct counts" do
      html = render_translation_validation(%{
        summary_text: "Checked DB rows: 5 · Checked files: 3 · Invalid DB rows: 2 · Invalid files: 1",
        invalid_database_rows: [],
        invalid_filesystem_files: [],
        can_fix?: false
      })

      assert html =~ "Checked DB rows: 5"
      assert html =~ "Checked files: 3"
      assert html =~ "Invalid DB rows: 2"
      assert html =~ "Invalid files: 1"
    end

    test "shows database issue cards with correct issue types" do
      html = render_translation_validation(%{
        invalid_database_rows: [
          %{
            "translation_for" => "post-1",
            "translation_id" => "trans-1",
            "canonical_language" => "en",
            "translation_language" => "en",
            "title" => "Test Post",
            "file_path" => "posts/test-post.de.md",
            "issue" => "same-language-as-canonical"
          },
          %{
            "translation_for" => "post-2",
            "canonical_language" => "en",
            "translation_language" => "de",
            "title" => "DNT Post",
            "issue" => "do-not-translate-has-translations"
          }
        ],
        can_fix?: true
      })

      assert html =~ "Translation language matches canonical post language"
      assert html =~ "Post is marked as do-not-translate but has translations"
      assert html =~ "trans-1"
      assert html =~ "posts/test-post.de.md"
      assert html =~ "Test Post"
      assert html =~ "DNT Post"
    end

    test "shows filesystem issue cards" do
      html = render_translation_validation(%{
        invalid_filesystem_files: [
          %{
            "translation_for" => "post-3",
            "canonical_language" => "en",
            "translation_language" => "fr",
            "title" => "Missing Source",
            "file_path" => "posts/missing-source.fr.md",
            "issue" => "missing_source_post"
          }
        ],
        can_fix?: true
      })

      assert html =~ "Translation points to a missing source post"
      assert html =~ "Missing Source"
      assert html =~ "posts/missing-source.fr.md"
    end

    test "fix button disabled when no issues" do
      html = render_translation_validation(%{
        can_fix?: false
      })

      assert html =~ ~s(data-testid="translation-validation-fix")
      assert html =~ ~r/data-testid="translation-validation-fix"[^>]*disabled/
    end

    test "fix button enabled when issues exist" do
      html = render_translation_validation(%{
        invalid_database_rows: [
          %{
            "translation_for" => "post-1",
            "issue" => "content-in-database",
            "canonical_language" => "en",
            "translation_language" => "de",
            "title" => "Content in DB",
            "file_path" => "posts/content-in-db.de.md"
          }
        ],
        can_fix?: true
      })

      assert html =~ ~s(data-testid="translation-validation-fix")
      refute html =~ ~r/data-testid="translation-validation-fix"[^>]*disabled/
    end

    test "shows content-in-database issue type" do
      html = render_translation_validation(%{
        invalid_database_rows: [
          %{
            "translation_for" => "post-4",
            "issue" => "content-in-database",
            "canonical_language" => "en",
            "translation_language" => "fr",
            "title" => "Published Translation",
            "file_path" => "posts/published.fr.md"
          }
        ],
        can_fix?: true
      })

      assert html =~ "Published translation has content stuck in DB instead of filesystem"
    end

    test "revalidate button is always present" do
      html = render_translation_validation(%{
        can_fix?: false
      })

      assert html =~ ~s(data-testid="translation-validation-revalidate")
    end

    test "database issues section shows empty state when none found" do
      html = render_translation_validation(%{
        invalid_database_rows: [],
        invalid_filesystem_files: [],
        can_fix?: false
      })

      assert html =~ "translation-validation-empty"
    end

    test "all four issue types are rendered with correct labels" do
      html = render_translation_validation(%{
        invalid_database_rows: [
          %{"translation_for" => "p1", "issue" => "missing_source_post", "canonical_language" => "en", "translation_language" => "de"},
          %{"translation_for" => "p2", "issue" => "same-language-as-canonical", "canonical_language" => "en", "translation_language" => "en"},
          %{"translation_for" => "p3", "issue" => "do-not-translate-has-translations", "canonical_language" => "en", "translation_language" => "de"},
          %{"translation_for" => "p4", "issue" => "content-in-database", "canonical_language" => "en", "translation_language" => "fr"}
        ],
        can_fix?: true
      })

      assert html =~ "Translation points to a missing source post"
      assert html =~ "Translation language matches canonical post language"
      assert html =~ "Post is marked as do-not-translate but has translations"
      assert html =~ "Published translation has content stuck in DB instead of filesystem"
    end

    test "language display shows canonical and translation" do
      html = render_translation_validation(%{
        invalid_database_rows: [
          %{
            "translation_for" => "p1",
            "issue" => "same-language-as-canonical",
            "canonical_language" => "en",
            "translation_language" => "en"
          }
        ],
        can_fix?: true
      })

      assert html =~ "en = en"
    end
  end

  describe "find_duplicates rendering" do
    test "renders pair rows with similarity badges" do
      html = render_duplicates([
        %{"post_id_a" => "a1", "post_id_b" => "b1", "title_a" => "Post Alpha",
          "title_b" => "Post Beta", "similarity" => 0.95, "exact_match" => false},
        %{"post_id_a" => "a2", "post_id_b" => "b2", "title_a" => "Post Gamma",
          "title_b" => "Post Delta", "similarity" => 1.0, "exact_match" => true}
      ])

      assert html =~ "Post Alpha"
      assert html =~ "Post Beta"
      assert html =~ "Post Gamma"
      assert html =~ "Post Delta"
      assert html =~ "95.0%"
      assert html =~ "Exact Match"
    end

    test "renders checkbox, dismiss buttons, and clickable titles" do
      html = render_duplicates([
        %{"post_id_a" => "a1", "post_id_b" => "b1", "title_a" => "Post A",
          "title_b" => "Post B", "similarity" => 0.92, "exact_match" => false}
      ])

      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(phx-click="toggle_duplicate_pair")
      assert html =~ ~s(phx-click="dismiss_duplicate_pair")
      assert html =~ ~s(phx-click="open_duplicate_post")
    end

    test "renders Dismiss Checked button disabled when nothing selected" do
      html = render_duplicates([
        %{"post_id_a" => "a1", "post_id_b" => "b1", "title_a" => "Post A",
          "title_b" => "Post B", "similarity" => 0.92, "exact_match" => false}
      ], MapSet.new())

      assert html =~ ~s(phx-click="dismiss_selected_duplicates")
      assert html =~ ~r/phx-click="dismiss_selected_duplicates"[^>]*disabled/
    end

    test "renders clickable post title buttons with correct phx-value attributes" do
      html = render_duplicates([
        %{"post_id_a" => "post-123", "post_id_b" => "post-456",
          "title_a" => "Clickable A", "title_b" => "Clickable B",
          "similarity" => 0.98, "exact_match" => false}
      ])

      assert html =~ ~s(phx-value-id="post-123")
      assert html =~ ~s(phx-value-id="post-456")
      assert html =~ ~s(phx-value-title="Clickable A")
      assert html =~ ~s(phx-value-title="Clickable B")
    end

    test "arrow separator between post titles" do
      html = render_duplicates([
        %{"post_id_a" => "a1", "post_id_b" => "b1", "title_a" => "Left",
          "title_b" => "Right", "similarity" => 0.95, "exact_match" => false}
      ])

      assert html =~ "Left"
      assert html =~ "→"
      assert html =~ "Right"
    end
  end

  describe "git_diff rendering" do
    test "shows empty state when no files are changed" do
      html = render_git_diff(%{
        files: [],
        empty_message: "No unstaged changes"
      })

      assert html =~ "No unstaged changes"
      assert html =~ "git-diff-empty"
    end

    test "renders file select dropdown with changed files" do
      html = render_git_diff(%{
        files: ["posts/hello.md", "media/photo.jpg"],
        selected_file_path: "posts/hello.md",
        active_diff: %{
          file_path: "posts/hello.md", original: "Hello World",
          modified: "Hello Universe", error: nil, language: "markdown"
        }
      })

      assert html =~ ~s(data-testid="git-diff-file-select")
      assert html =~ ~s(<option value="posts/hello.md")
      assert html =~ ~s(<option value="media/photo.jpg")
      refute html =~ "No unstaged changes"
    end

    test "renders Monaco editor hook with correct attributes" do
      html = render_git_diff(%{
        files: ["posts/hello.md"],
        selected_file_path: "posts/hello.md",
        active_diff: %{
          file_path: "posts/hello.md", original: "Hello World",
          modified: "Hello Universe", error: nil, language: "markdown"
        },
        preferences: %{view_style: "side_by_side", word_wrap: true, hide_unchanged_regions: false}
      })

      assert html =~ ~s(phx-hook="MonacoDiffEditor")
      assert html =~ ~s(data-monaco-diff-language="markdown")
      assert html =~ ~s(data-monaco-diff-view-style="side_by_side")
      assert html =~ ~s(data-monaco-diff-word-wrap="on")
      assert html =~ ~s(data-monaco-diff-hide-unchanged="false")
      assert html =~ ~s(<textarea class="monaco-diff-original")
      assert html =~ ~s(<textarea class="monaco-diff-modified")
    end

    test "no edit buttons in read-only git diff view" do
      html = render_git_diff(%{
        files: ["test.txt"],
        selected_file_path: "test.txt",
        active_diff: %{
          file_path: "test.txt", original: "old",
          modified: "new", error: nil, language: "plaintext"
        }
      })

      refute html =~ ~s(phx-click="save)
      refute html =~ ~s(phx-click="edit)
      refute html =~ ~s(phx-click="commit)
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp render_translation_validation(overrides) do
    defaults = %{
      kind: :translation_validation,
      title: "Translation Validation",
      subtitle: "",
      summary: %{},
      summary_text: "Checked DB rows: 0 · Checked files: 0 · Invalid DB rows: 0 · Invalid files: 0",
      invalid_database_rows: [],
      invalid_filesystem_files: [],
      can_fix?: false
    }

    assigns = %{myself: nil, misc_editor: Map.merge(defaults, overrides)}
    render_component(&MiscEditor.render/1, assigns)
  end

  defp render_duplicates(pairs, selected_pairs \\ MapSet.new()) do
    defaults = %{
      kind: :find_duplicates,
      title: "Find Duplicates",
      subtitle: "",
      summary: %{total_pairs: length(pairs)},
      pairs: pairs,
      selected_pairs: selected_pairs
    }

    assigns = %{myself: nil, misc_editor: defaults}
    render_component(&MiscEditor.render/1, assigns)
  end

  defp render_git_diff(overrides) do
    defaults = %{
      kind: :git_diff,
      title: "Git Diff",
      subtitle: "",
      summary: %{},
      files: [],
      selected_file_path: nil,
      active_diff: %{file_path: nil, original: "", modified: "", error: nil, language: "plaintext"},
      preferences: %{view_style: "inline", word_wrap: false, hide_unchanged_regions: false},
      empty_message: "No unstaged changes"
    }

    assigns = %{myself: nil, misc_editor: Map.merge(defaults, overrides)}
    render_component(&MiscEditor.render/1, assigns)
  end
end
