defmodule BDS.CSM035ProcessDictTest do
  use ExUnit.Case, async: true

  alias BDS.Desktop.UILocale

  describe "source-level: no raw Process.put/get for :bds_ui_locale outside ui_locale.ex" do
    test "no direct Process.put(:bds_ui_locale, ...) outside ui_locale.ex" do
      elixir_files =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&(&1 == "lib/bds/desktop/ui_locale.ex"))

      violations =
        Enum.filter(elixir_files, fn path ->
          source = File.read!(path)
          source =~ "Process.put(:bds_ui_locale" or source =~ "Process.put(@key"
        end)

      assert violations == [],
             "Raw Process.put(:bds_ui_locale) found outside ui_locale.ex: #{inspect(violations)}"
    end

    test "no direct Process.get(:bds_ui_locale, ...) outside ui_locale.ex" do
      elixir_files =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&(&1 == "lib/bds/desktop/ui_locale.ex"))

      violations =
        Enum.filter(elixir_files, fn path ->
          source = File.read!(path)
          source =~ "Process.get(:bds_ui_locale" or source =~ "Process.delete(:bds_ui_locale"
        end)

      assert violations == [],
             "Raw Process.get/delete(:bds_ui_locale) found outside ui_locale.ex: #{inspect(violations)}"
    end
  end

  describe "source-level: render boundaries call UILocale.put before template evaluation" do
    test "ShellLive.render/1 calls UILocale.put before index(assigns)" do
      source = File.read!("lib/bds/desktop/shell_live.ex")
      render_match = Regex.run(~r/def render\(assigns\).*?\n(.*?)\n(.*?)\n/s, source)
      assert render_match, "could not find render/1 in shell_live.ex"
      [_, first_line | _] = render_match
      assert first_line =~ "UILocale.put", "render/1 must call UILocale.put on its first line"
    end

    test "sidebar_content/1 calls UILocale.put before HEEx" do
      source = File.read!("lib/bds/desktop/shell_live/sidebar_components.ex")
      match = Regex.run(~r/def sidebar_content\(assigns\).*?\n(.*?)\n/s, source)
      assert match, "could not find sidebar_content/1"
      [_, first_line | _] = match
      assert first_line =~ "UILocale.put", "sidebar_content/1 must call UILocale.put on its first line"
    end

    test "MenuBar.mount/1 calls UILocale.put" do
      source = File.read!("lib/bds/desktop/menu_bar.ex")
      match = Regex.run(~r/def mount\(menu\).*?\n(.*?)\n/s, source)
      assert match, "could not find mount/1 in menu_bar.ex"
      [_, first_line | _] = match
      assert first_line =~ "UILocale.put", "MenuBar.mount/1 must call UILocale.put on its first line"
    end
  end

  describe "UILocale functional behavior" do
    test "put/1 sets locale readable by current/0" do
      UILocale.put("de")
      assert UILocale.current() == "de"
    end

    test "with_locale/2 restores previous locale after block" do
      UILocale.put("en")
      UILocale.with_locale("fr", fn -> assert UILocale.current() == "fr" end)
      assert UILocale.current() == "en"
    end

    test "with_locale/2 restores nil when no prior locale was set" do
      Process.delete(:bds_ui_locale)
      UILocale.with_locale("it", fn -> assert UILocale.current() == "it" end)
      assert UILocale.current() == nil
    end

    test "put/1 returns :ok" do
      assert UILocale.put("en") == :ok
    end
  end
end
