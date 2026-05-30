defmodule BDS.MacBundleTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias BDS.MacBundle
  alias BDS.MacBundle.Dylibs
  alias BDS.MacBundle.Icon

  # Parse "#RRGGBB" into {r, g, b} for property assertions in tests.
  defp rgb("#" <> hex) do
    {r, g, b} = {String.slice(hex, 0, 2), String.slice(hex, 2, 2), String.slice(hex, 4, 2)}
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  describe "Icon.recolor_color/1" do
    test "turns the saturated blue pen colors red (red channel becomes dominant)" do
      for blue <- ~w(#1D4294 #214A9D #2B61CE #6FA3FF #7FB0FF #9FC2FF) do
        recolored = Icon.recolor_color(blue)
        {ir, _ig, ib} = rgb(blue)
        {r, _g, b} = rgb(recolored)

        assert ib > ir, "expected #{blue} to start blue-dominant"
        assert r > b, "expected #{blue} -> #{recolored} to become red-dominant"
      end
    end

    test "leaves gold / warm colors unchanged" do
      for gold <- ~w(#FCE9A4 #E8C96A #C59A33 #9B741F #6E4E14 #FFF4C8) do
        assert Icon.recolor_color(gold) == gold
      end
    end

    test "leaves pure white and near-black unchanged" do
      assert Icon.recolor_color("#FFFFFF") == "#FFFFFF"
      assert Icon.recolor_color("#0D0D0D") == "#0D0D0D"
    end

    test "is case-insensitive on input and returns uppercase hex" do
      assert Icon.recolor_color("#2b61ce") == Icon.recolor_color("#2B61CE")
      assert Icon.recolor_color("#2b61ce") =~ ~r/^#[0-9A-F]{6}$/
    end
  end

  describe "Icon.recolor_svg/1" do
    test "replaces every blue hex in the source SVG and keeps gold stops" do
      svg = File.read!(Icon.source_svg_path())
      recolored = Icon.recolor_svg(svg)

      refute recolored =~ "#2B61CE"
      refute recolored =~ "#1D4294"
      refute recolored =~ "#9FC2FF"
      # gold base gradient stops survive untouched
      assert recolored =~ "#E8C96A"
      assert recolored =~ "#C59A33"
    end
  end

  describe "Icon.generate/1 (real libvips + sips + iconutil pipeline)" do
    @describetag :macos_tools

    test "renders the recoloured SVG and packs a valid .icns" do
      tmp = Path.join(System.tmp_dir!(), "bds-icon-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      icns = Path.join(tmp, "AppIcon.icns")
      png = Path.join(tmp, "AppIcon-1024.png")

      assert {:ok, ^icns} = Icon.generate(icns_path: icns, png_path: png)
      assert File.exists?(icns)
      # .icns files begin with the "icns" magic.
      assert File.read!(icns) |> binary_part(0, 4) == "icns"
      # 1024² master PNG was produced.
      assert {:ok, img} = Image.open(png)
      assert Image.width(img) == 1024
    end
  end

  describe "MacBundle.info_plist/1" do
    setup do
      %{plist: MacBundle.info_plist(version: "1.2.3")}
    end

    test "registers the bds2 URL scheme", %{plist: plist} do
      assert plist =~ "CFBundleURLSchemes"
      assert plist =~ "<string>bds2</string>"
    end

    test "carries the confirmed bundle identity", %{plist: plist} do
      assert plist =~ "<string>de.rfc1437.bds2</string>"
      assert plist =~ "<key>CFBundleExecutable</key>"
      assert plist =~ "<string>bds2</string>"
      assert plist =~ "<string>AppIcon</string>"
      assert plist =~ "<string>1.2.3</string>"
    end

    test "is well-formed XML/plist" do
      assert plist = MacBundle.info_plist(version: "0.0.1")
      assert String.starts_with?(plist, "<?xml")
      assert plist =~ "<!DOCTYPE plist"
      assert plist =~ "</plist>"
    end
  end

  describe "MacBundle.relative_up/2" do
    test "computes the ../-style hop from the wx NIF dir up to Frameworks" do
      nif_dir = "/x/BDS2.app/Contents/Resources/rel/lib/wx-2.5/priv"
      frameworks = "/x/BDS2.app/Contents/Frameworks"
      assert MacBundle.relative_up(nif_dir, frameworks) == "../../../../../Frameworks"
    end

    test "siblings resolve with a single hop" do
      assert MacBundle.relative_up("/a/b/c", "/a/b/d") == "../d"
    end
  end

  describe "Dylibs.parse_otool/1 and external?/1" do
    test "extracts the dependency paths, dropping the header line" do
      output =
        Enum.join(
          [
            "/abs/path/wxe_driver.so:",
            "\t/opt/homebrew/opt/wxwidgets/lib/libwx_baseu-3.2.dylib (compatibility version 0.0.0, current version 0.0.0)",
            "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)",
            "\t@rpath/libwx_osx_cocoau_core-3.2.dylib (compatibility version 0.0.0, current version 0.0.0)"
          ],
          "\n"
        )

      assert Dylibs.parse_otool(output) == [
               "/opt/homebrew/opt/wxwidgets/lib/libwx_baseu-3.2.dylib",
               "/usr/lib/libSystem.B.dylib",
               "@rpath/libwx_osx_cocoau_core-3.2.dylib"
             ]
    end

    test "treats Homebrew prefixes as external and system/rpath as internal" do
      assert Dylibs.external?("/opt/homebrew/opt/wxwidgets/lib/libwx_baseu-3.2.dylib")
      assert Dylibs.external?("/usr/local/lib/libpng16.dylib")
      refute Dylibs.external?("/usr/lib/libSystem.B.dylib")
      refute Dylibs.external?("/System/Library/Frameworks/Cocoa.framework/Cocoa")
      refute Dylibs.external?("@rpath/libwx_osx_cocoau_core-3.2.dylib")
      refute Dylibs.external?("@executable_path/../Frameworks/libfoo.dylib")
    end
  end

  describe "Dylibs install_name_tool arg builders" do
    test "id_args/2" do
      assert Dylibs.id_args("/Frameworks/libfoo.dylib", "@rpath/libfoo.dylib") ==
               ["-id", "@rpath/libfoo.dylib", "/Frameworks/libfoo.dylib"]
    end

    test "change_args/2 batches multiple -change pairs before the target binary" do
      changes = [
        {"/opt/homebrew/lib/a.dylib", "@executable_path/../Frameworks/a.dylib"},
        {"/opt/homebrew/lib/b.dylib", "@executable_path/../Frameworks/b.dylib"}
      ]

      assert Dylibs.change_args("/app/MacOS/bds2", changes) ==
               [
                 "-change",
                 "/opt/homebrew/lib/a.dylib",
                 "@executable_path/../Frameworks/a.dylib",
                 "-change",
                 "/opt/homebrew/lib/b.dylib",
                 "@executable_path/../Frameworks/b.dylib",
                 "/app/MacOS/bds2"
               ]
    end

    test "change_args/2 with no changes is an empty list (no-op, do not invoke the tool)" do
      assert Dylibs.change_args("/app/MacOS/bds2", []) == []
    end
  end

  describe "MacBundle.assemble/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "bds-macbundle-#{System.unique_integer([:positive])}")
      release = Path.join(tmp, "rel")
      File.mkdir_p!(Path.join(release, "bin"))
      File.write!(Path.join(release, "bin/bds"), "#!/bin/sh\necho fake release\n")
      File.mkdir_p!(Path.join(release, "lib/wx-2.4/priv"))
      File.write!(Path.join(release, "lib/wx-2.4/priv/wxe_driver.so"), "fake-nif")

      icns = Path.join(tmp, "AppIcon.icns")
      File.write!(icns, "fake-icns")

      output = Path.join(tmp, "dist")

      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, app} =
        MacBundle.assemble(
          release_dir: release,
          output_dir: output,
          icns_path: icns,
          version: "0.1.0",
          skip_dylibs: true,
          skip_codesign: true
        )

      %{app: app}
    end

    test "produces a BDS2.app with the standard Contents layout", %{app: app} do
      assert Path.basename(app) == "BDS2.app"
      assert File.dir?(Path.join(app, "Contents/MacOS"))
      assert File.dir?(Path.join(app, "Contents/Resources"))
      assert File.dir?(Path.join(app, "Contents/Frameworks"))
    end

    test "writes Info.plist with the bds2 scheme", %{app: app} do
      plist = File.read!(Path.join(app, "Contents/Info.plist"))
      assert plist =~ "<string>bds2</string>"
      assert plist =~ "<string>de.rfc1437.bds2</string>"
    end

    test "writes the PkgInfo file", %{app: app} do
      assert File.read!(Path.join(app, "Contents/PkgInfo")) == "APPL????"
    end

    test "installs an executable launcher that execs the release", %{app: app} do
      launcher = Path.join(app, "Contents/MacOS/bds2")
      assert File.exists?(launcher)
      %File.Stat{mode: mode} = File.stat!(launcher)
      assert (mode &&& 0o111) != 0, "launcher must be executable"
      script = File.read!(launcher)
      assert script =~ "Resources/rel"
      assert script =~ "bin/bds"
    end

    test "copies the release tree and the icon into Resources", %{app: app} do
      assert File.exists?(Path.join(app, "Contents/Resources/rel/bin/bds"))
      assert File.exists?(Path.join(app, "Contents/Resources/AppIcon.icns"))
    end
  end
end
