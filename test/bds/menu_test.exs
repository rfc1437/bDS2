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

  test "update_menu normalizes Home first, writes meta/menu.opml, and load returns nested items",
       %{project: project, temp_dir: temp_dir} do
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
    assert contents =~ ~s(<outline text="Home" type="home" pageSlug="home")
    assert contents =~ ~s(<outline text="About" type="page" pageSlug="about")
    assert contents =~ ~s(<outline text="Sections" type="submenu")
    assert contents =~ ~s(<outline text="Notes" type="category-archive" categoryName="notes")

    assert {:ok, loaded} = BDS.Menu.get_menu(project.id)
    assert loaded == menu
  end

  test "sync_menu_from_filesystem loads canonical bDS OPML and preserves a prepended Home entry",
       %{
         project: project,
         temp_dir: temp_dir
       } do
    meta_dir = Path.join(temp_dir, "meta")
    File.mkdir_p!(meta_dir)

    File.write!(
      Path.join(meta_dir, "menu.opml"),
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<opml version="2.0">),
        ~s(  <head>),
        ~s(    <title>Blog Menu</title>),
        ~s(  </head>),
        ~s(  <body>),
        ~s(    <outline id="menu-home" text="Home" type="home" pageSlug="home"/>),
        ~s(    <outline id="menu-topics" text="Topics" type="submenu">),
        ~s(      <outline id="menu-page" text="Blog" type="page" pageId="page-1" pageSlug="blog"/>),
        ~s(      <outline id="menu-cat" text="Elixir" type="category-archive" categoryName="elixir"/>),
        ~s(    </outline>),
        ~s(  </body>),
        ~s(</opml>)
      ]
      |> Enum.join("\n")
    )

    assert {:ok, menu} = BDS.Menu.sync_menu_from_filesystem(project.id)

    assert menu.items == [
             %{kind: :home, label: "Home", slug: nil},
             %{
               kind: :submenu,
               label: "Topics",
               slug: nil,
               children: [
                 %{kind: :page, label: "Blog", slug: "blog"},
                 %{kind: :category_archive, label: "Elixir", slug: "elixir"}
               ]
             }
           ]
  end

  test "get_menu parses legacy kind/slug attributes and drops children of non-submenu items",
       %{project: project, temp_dir: temp_dir} do
    write_menu_opml(temp_dir, [
      ~s(    <outline text="About" kind="page" slug="about">),
      ~s(      <outline text="Nested" kind="page" slug="nested"/>),
      ~s(    </outline>),
      ~s(    <outline text="Notes" kind="category-archive" slug="notes"/>)
    ])

    assert {:ok, menu} = BDS.Menu.get_menu(project.id)

    assert menu.items == [
             %{kind: :home, label: "Home", slug: nil},
             %{kind: :page, label: "About", slug: "about"},
             %{kind: :category_archive, label: "Notes", slug: "notes"}
           ]
  end

  test "get_menu ignores outlines outside /opml/body and decodes XML entities",
       %{project: project, temp_dir: temp_dir} do
    File.mkdir_p!(Path.join(temp_dir, "meta"))

    File.write!(
      Path.join([temp_dir, "meta", "menu.opml"]),
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<opml version="2.0">),
        ~s(  <head>),
        ~s(    <outline text="Stray" type="page" pageSlug="stray"/>),
        ~s(  </head>),
        ~s(  <body>),
        ~s(    <outline text="Q &amp; A" type="page" pageSlug="q-and-a"/>),
        ~s(  </body>),
        ~s(</opml>)
      ]
      |> Enum.join("\n")
    )

    assert {:ok, menu} = BDS.Menu.get_menu(project.id)

    assert menu.items == [
             %{kind: :home, label: "Home", slug: nil},
             %{kind: :page, label: "Q & A", slug: "q-and-a"}
           ]
  end

  test "get_menu raises on malformed OPML", %{project: project, temp_dir: temp_dir} do
    File.mkdir_p!(Path.join(temp_dir, "meta"))
    File.write!(Path.join([temp_dir, "meta", "menu.opml"]), "<opml><body><outline")

    assert_raise RuntimeError, fn ->
      BDS.Menu.get_menu(project.id)
    end
  end

  test "get_menu does not intern OPML element or attribute names as atoms",
       %{project: project, temp_dir: temp_dir} do
    unique_element = "untrusted_element_#{System.unique_integer([:positive])}"
    unique_attr = "untrusted_attr_#{System.unique_integer([:positive])}"

    write_menu_opml(temp_dir, [
      ~s(    <#{unique_element}>ignored</#{unique_element}>),
      ~s(    <outline text="About" type="page" pageSlug="about" #{unique_attr}="x"/>)
    ])

    assert {:ok, menu} = BDS.Menu.get_menu(project.id)
    assert Enum.at(menu.items, 1) == %{kind: :page, label: "About", slug: "about"}

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_element) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique_attr) end
  end

  test "get_menu keeps atom growth bounded for many unique attribute names",
       %{project: project, temp_dir: temp_dir} do
    unique_attrs =
      Enum.map(1..250, fn index ->
        "untrusted_bulk_attr_#{System.unique_integer([:positive])}_#{index}"
      end)

    outlines =
      Enum.map(unique_attrs, fn attr ->
        ~s(    <outline text="Item" type="page" pageSlug="item" #{attr}="x"/>)
      end)

    write_menu_opml(temp_dir, outlines)
    assert {:ok, _warmup} = BDS.Menu.get_menu(project.id)

    atom_count_before = :erlang.system_info(:atom_count)
    assert {:ok, menu} = BDS.Menu.get_menu(project.id)
    atom_count_after = :erlang.system_info(:atom_count)

    assert length(menu.items) == 251
    assert atom_count_after - atom_count_before < 20

    Enum.each(unique_attrs, fn attr ->
      assert_raise ArgumentError, fn -> String.to_existing_atom(attr) end
    end)
  end

  defp write_menu_opml(temp_dir, body_lines) do
    File.mkdir_p!(Path.join(temp_dir, "meta"))

    File.write!(
      Path.join([temp_dir, "meta", "menu.opml"]),
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<opml version="2.0">),
        ~s(  <head><title>Menu</title></head>),
        ~s(  <body>)
      ]
      |> Enum.concat(body_lines)
      |> Enum.concat([~s(  </body>), ~s(</opml>)])
      |> Enum.join("\n")
    )
  end
end
