defmodule BDS.MenuTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BDS.Repo)
    temp_dir = Path.join(System.tmp_dir!(), "bds-menu-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    {:ok, project} = BDS.Projects.create_project(%{name: "Menu", data_path: temp_dir})
    %{project: project, temp_dir: temp_dir}
  end

  test "update_menu normalizes Home first, writes meta/menu.opml, and load returns nested items", %{project: project, temp_dir: temp_dir} do
    assert {:ok, menu} =
             BDS.Menu.update_menu(project.id, [
               %{kind: :page, label: "About", slug: "about"},
               %{
                 kind: :submenu,
                 label: "Sections",
                 children: [
                   %{kind: :category_archive, label: "Notes", slug: "notes"},
                   %{kind: :page, label: "Contact", slug: "contact"}
                 ]
               },
               %{kind: :home, label: "Ignored Home"}
             ])

    assert hd(menu.items) == %{kind: :home, label: "Home", slug: nil}
    assert Enum.at(menu.items, 1) == %{kind: :page, label: "About", slug: "about"}

    assert Enum.at(menu.items, 2) == %{
             kind: :submenu,
             label: "Sections",
             slug: nil,
             children: [
               %{kind: :category_archive, label: "Notes", slug: "notes"},
               %{kind: :page, label: "Contact", slug: "contact"}
             ]
           }

    opml_path = Path.join([temp_dir, "meta", "menu.opml"])
    assert File.exists?(opml_path)

    contents = File.read!(opml_path)
    assert contents =~ ~s(<outline kind="home" text="Home")
    assert contents =~ ~s(<outline kind="page" text="About" slug="about")
    assert contents =~ ~s(<outline kind="submenu" text="Sections")
    assert contents =~ ~s(<outline kind="category_archive" text="Notes" slug="notes")

    assert {:ok, loaded} = BDS.Menu.get_menu(project.id)
    assert loaded == menu
  end

  test "sync_menu_from_filesystem loads canonical OPML and preserves a prepended Home entry", %{project: project, temp_dir: temp_dir} do
    meta_dir = Path.join(temp_dir, "meta")
    File.mkdir_p!(meta_dir)

    File.write!(
      Path.join(meta_dir, "menu.opml"),
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<opml version="2.0">),
        ~s(  <body>),
        ~s(    <outline kind="page" text="Blog" slug="blog" />),
        ~s(    <outline kind="submenu" text="Topics">),
        ~s(      <outline kind="category_archive" text="Elixir" slug="elixir" />),
        ~s(    </outline>),
        ~s(  </body>),
        ~s(</opml>)
      ]
      |> Enum.join("\n")
    )

    assert {:ok, menu} = BDS.Menu.sync_menu_from_filesystem(project.id)

    assert menu.items == [
             %{kind: :home, label: "Home", slug: nil},
             %{kind: :page, label: "Blog", slug: "blog"},
             %{
               kind: :submenu,
               label: "Topics",
               slug: nil,
               children: [
                 %{kind: :category_archive, label: "Elixir", slug: "elixir"}
               ]
             }
           ]
  end
end
