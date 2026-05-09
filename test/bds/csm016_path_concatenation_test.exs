defmodule BDS.CSM016PathConcatenationTest do
  use ExUnit.Case, async: false

  alias BDS.Rendering.FileSystem, as: TemplateFileSystem
  alias BDS.Rendering.LinksAndLanguages
  alias BDS.Rendering.Metadata

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)

    temp_dir = Path.join(System.tmp_dir!(), "bds-csm016-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    %{temp_dir: temp_dir}
  end

  describe "FileSystem.full_path/2 extension handling" do
    test "adds .liquid extension to bare template name", %{temp_dir: temp_dir} do
      File.write!(Path.join(temp_dir, "header.liquid"), "")
      fs = TemplateFileSystem.new(temp_dir)
      assert String.ends_with?(TemplateFileSystem.full_path(fs, "header"), ".liquid")
    end

    test "does not double .liquid extension", %{temp_dir: temp_dir} do
      File.write!(Path.join(temp_dir, "header.liquid"), "")
      fs = TemplateFileSystem.new(temp_dir)
      path = TemplateFileSystem.full_path(fs, "header.liquid")
      refute String.ends_with?(path, ".liquid.liquid")
      assert String.ends_with?(path, ".liquid")
    end

    test "handles nested template paths", %{temp_dir: temp_dir} do
      nested_dir = Path.join(temp_dir, "partials")
      File.mkdir_p!(nested_dir)
      File.write!(Path.join(nested_dir, "footer.liquid"), "")
      fs = TemplateFileSystem.new(temp_dir)
      path = TemplateFileSystem.full_path(fs, "partials/footer")
      assert String.ends_with?(path, "partials/footer.liquid")
    end
  end

  describe "Metadata.href_for_language/1" do
    test "empty prefix returns root" do
      assert Metadata.href_for_language("") == "/"
    end

    test "prefix without trailing slash gets one" do
      assert Metadata.href_for_language("/de") == "/de/"
    end

    test "prefix with trailing slash does not get double slash" do
      assert Metadata.href_for_language("/de/") == "/de/"
    end
  end

  describe "Metadata menu_item_href via to_template_menu_item" do
    test "page slug with special characters is encoded" do
      items = Metadata.menu_items_from_raw([%{kind: :page, slug: "über uns", children: []}])
      [item] = items
      assert item.href == "/%C3%BCber%20uns/"
    end

    test "page slug without special chars is unchanged" do
      items = Metadata.menu_items_from_raw([%{kind: :page, slug: "about", children: []}])
      [item] = items
      assert item.href == "/about/"
    end

    test "category archive slug is encoded" do
      items =
        Metadata.menu_items_from_raw([
          %{kind: :category_archive, slug: "café", children: []}
        ])

      [item] = items
      assert item.href == "/category/caf%C3%A9/"
    end
  end

  describe "LinksAndLanguages.post_path/2 construction" do
    test "produces correct path with leading slash and trailing slash" do
      post = %{
        slug: "hello-world",
        created_at: 1_746_792_000_000
      }

      path = LinksAndLanguages.post_path(post, nil)
      assert String.starts_with?(path, "/")
      assert String.ends_with?(path, "/")
      refute String.contains?(path, "//")
    end

    test "language prefix path has no double slashes" do
      post = %{
        slug: "hello-world",
        created_at: 1_746_792_000_000
      }

      path = LinksAndLanguages.post_path(post, "/de")
      assert String.starts_with?(path, "/de/")
      refute String.contains?(path, "//")
    end
  end

  describe "LinksAndLanguages.language_prefix/2" do
    test "same language returns empty string" do
      assert LinksAndLanguages.language_prefix("en", "en") == ""
    end

    test "nil language returns empty string" do
      assert LinksAndLanguages.language_prefix(nil, "en") == ""
    end

    test "different language returns prefix with leading slash" do
      prefix = LinksAndLanguages.language_prefix("de", "en")
      assert prefix == "/de"
      assert String.starts_with?(prefix, "/")
      refute String.ends_with?(prefix, "/")
    end
  end

  describe "publishing ensure_trailing_slash" do
    test "path without trailing slash gets one" do
      assert BDS.Publishing.ensure_trailing_slash("/var/www") == "/var/www/"
    end

    test "path with trailing slash keeps exactly one" do
      assert BDS.Publishing.ensure_trailing_slash("/var/www/") == "/var/www/"
    end

    test "empty string gets a slash" do
      assert BDS.Publishing.ensure_trailing_slash("") == "/"
    end
  end
end
