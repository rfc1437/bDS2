defmodule BDS.MacBundleTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias BDS.MacBundle
  alias BDS.MacBundle.Dylibs
  alias BDS.MacBundle.Icon

  # Give a copied keg dylib a controlled id so verify_standalone only sees the
  # reference under test, not the keg's absolute LC_ID_DYLIB.
  defp fix_id!(dylib, id \\ nil) do
    {_out, 0} =
      System.cmd(
        "install_name_tool",
        Dylibs.id_args(dylib, id || "@loader_path/" <> Path.basename(dylib)),
        stderr_to_stdout: true
      )

    :ok
  end

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

  describe "Dylibs.relink_changes/2" do
    test "rewrites every external dep to <prefix>/<basename>, independent of source spelling" do
      deps = [
        # opt/symlink spelling (as a NIF references it)
        "/opt/homebrew/opt/wxwidgets@3.2/lib/libwx_osx_cocoau_core-3.2.dylib",
        # Cellar/versioned spelling (as inter-lib deps reference the same file)
        "/opt/homebrew/Cellar/wxwidgets@3.2/3.2.10/lib/libwx_baseu-3.2.0.4.3.dylib",
        "/usr/local/lib/libpcre2-32.0.dylib",
        # left untouched: macOS-provided and already-relocatable
        "/usr/lib/libSystem.B.dylib",
        "@rpath/libalready.dylib"
      ]

      assert Dylibs.relink_changes(deps, "@loader_path") == [
               {"/opt/homebrew/opt/wxwidgets@3.2/lib/libwx_osx_cocoau_core-3.2.dylib",
                "@loader_path/libwx_osx_cocoau_core-3.2.dylib"},
               {"/opt/homebrew/Cellar/wxwidgets@3.2/3.2.10/lib/libwx_baseu-3.2.0.4.3.dylib",
                "@loader_path/libwx_baseu-3.2.0.4.3.dylib"},
               {"/usr/local/lib/libpcre2-32.0.dylib", "@loader_path/libpcre2-32.0.dylib"}
             ]
    end

    test "honors a NIF-relative loader prefix" do
      assert Dylibs.relink_changes(
               ["/opt/homebrew/lib/libfoo.dylib"],
               "@loader_path/../../Frameworks"
             ) ==
               [{"/opt/homebrew/lib/libfoo.dylib", "@loader_path/../../Frameworks/libfoo.dylib"}]
    end
  end

  describe "Dylibs.resolve_rpath_dep/3" do
    test "expands @loader_path rpaths against the referencing binary's directory" do
      assert Dylibs.resolve_rpath_dep(
               "@rpath/libsharpyuv.0.dylib",
               ["@loader_path/../lib", "/opt/homebrew/lib"],
               "/opt/homebrew/opt/webp/lib"
             ) == [
               "/opt/homebrew/opt/webp/lib/libsharpyuv.0.dylib",
               "/opt/homebrew/lib/libsharpyuv.0.dylib"
             ]
    end

    test "resolves in-tree loader-relative rpaths (vix/exla precompiled layout)" do
      assert Dylibs.resolve_rpath_dep(
               "@rpath/libvips.42.dylib",
               ["@loader_path/precompiled_libvips/lib"],
               "/app/rel/lib/vix-0.38.0/priv"
             ) == ["/app/rel/lib/vix-0.38.0/priv/precompiled_libvips/lib/libvips.42.dylib"]
    end

    test "skips @executable_path rpaths (not resolvable from a library) and non-@rpath deps" do
      assert Dylibs.resolve_rpath_dep(
               "@rpath/libfoo.dylib",
               ["@executable_path/../Frameworks"],
               "/any/dir"
             ) == []

      assert Dylibs.resolve_rpath_dep("/usr/lib/libSystem.B.dylib", ["@loader_path"], "/d") == []
    end
  end

  describe "Dylibs.relink_changes/3 (@rpath deps)" do
    test "rewrites @rpath deps whose basename was bundled, leaves the rest" do
      deps = [
        "/opt/homebrew/opt/webp/lib/libwebp.7.dylib",
        "@rpath/libsharpyuv.0.dylib",
        "@rpath/libvips.42.dylib",
        "/usr/lib/libSystem.B.dylib"
      ]

      assert Dylibs.relink_changes(deps, "@loader_path", ["libsharpyuv.0.dylib"]) == [
               {"/opt/homebrew/opt/webp/lib/libwebp.7.dylib", "@loader_path/libwebp.7.dylib"},
               {"@rpath/libsharpyuv.0.dylib", "@loader_path/libsharpyuv.0.dylib"}
             ]
    end
  end

  describe "MacBundle.verify_standalone/1 (@rpath resolution gate)" do
    @describetag :macos_tools

    # Regression for the July 2026 crash: Homebrew's libwebp references its
    # sibling as @rpath/libsharpyuv.0.dylib (rpath @loader_path/../lib). A copy
    # in Frameworks without the sibling must fail verification; a copy whose
    # rpath resolves inside the tree must pass.
    test "fails on an @rpath dep that does not resolve inside the bundle and passes when it does" do
      keg_webp = "/opt/homebrew/opt/webp/lib/libwebp.7.dylib"
      keg_sharpyuv = "/opt/homebrew/opt/webp/lib/libsharpyuv.0.dylib"

      if File.exists?(keg_webp) and File.exists?(keg_sharpyuv) do
        tmp = Path.join(System.tmp_dir!(), "bds-rpath-#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf!(tmp) end)

        # Broken layout: libwebp in Frameworks, libsharpyuv missing entirely.
        broken = Path.join(tmp, "broken/Contents/Frameworks")
        File.mkdir_p!(broken)
        File.cp!(keg_webp, Path.join(broken, "libwebp.7.dylib"))
        File.chmod!(Path.join(broken, "libwebp.7.dylib"), 0o644)
        fix_id!(Path.join(broken, "libwebp.7.dylib"))

        assert {:error, {:external_refs, offenders}} =
                 MacBundle.verify_standalone(Path.join(tmp, "broken"))

        assert Enum.any?(offenders, fn {_file, ref} -> ref == "@rpath/libsharpyuv.0.dylib" end)

        # Healthy layout: @loader_path/../lib resolves next to the library, so
        # placing the sibling there satisfies the reference (vix-style in-tree
        # resolution must not be flagged). libsharpyuv keeps an @rpath/ self id
        # — precompiled NIF deps (hnswlib, libvips, libmlx) ship exactly that,
        # and a library's own LC_ID_DYLIB must never count as unresolved.
        healthy = Path.join(tmp, "healthy/Contents/pkg/lib")
        File.mkdir_p!(healthy)
        File.cp!(keg_webp, Path.join(healthy, "libwebp.7.dylib"))
        File.cp!(keg_sharpyuv, Path.join(healthy, "libsharpyuv.0.dylib"))
        Enum.each(["libwebp.7.dylib", "libsharpyuv.0.dylib"], fn base ->
          File.chmod!(Path.join(healthy, base), 0o644)
        end)

        fix_id!(Path.join(healthy, "libwebp.7.dylib"))
        fix_id!(Path.join(healthy, "libsharpyuv.0.dylib"), "@rpath/libsharpyuv.0.dylib")

        # Match the precompiled-NIF shape exactly: @rpath/ self id with NO
        # LC_RPATH left to resolve it (hnswlib_nif.so ships like this).
        sharpyuv = Path.join(healthy, "libsharpyuv.0.dylib")

        {rpath_out, 0} = System.cmd("otool", ["-l", sharpyuv], stderr_to_stdout: true)

        Enum.each(Dylibs.parse_rpaths(rpath_out), fn rpath ->
          {_out, 0} =
            System.cmd("install_name_tool", ["-delete_rpath", rpath, sharpyuv],
              stderr_to_stdout: true
            )
        end)

        assert MacBundle.verify_standalone(Path.join(tmp, "healthy")) == :ok
      else
        :ok
      end
    end
  end

  describe "Dylibs.parse_rpaths/1" do
    test "extracts LC_RPATH paths from otool -l output, ignoring other load commands" do
      output = """
      Load command 12
                cmd LC_LOAD_DYLIB
            cmdsize 56
               name /usr/lib/libSystem.B.dylib (offset 24)
      Load command 13
                cmd LC_RPATH
            cmdsize 48
               path /opt/homebrew/Cellar/jpeg-turbo/3.1.4.1/lib (offset 12)
      Load command 14
                cmd LC_RPATH
            cmdsize 32
               path @loader_path/../lib (offset 12)
      """

      assert Dylibs.parse_rpaths(output) == [
               "/opt/homebrew/Cellar/jpeg-turbo/3.1.4.1/lib",
               "@loader_path/../lib"
             ]
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

  describe "Dylibs.bundle/3 + MacBundle.verify_standalone/1 (real otool/install_name_tool)" do
    @describetag :macos_tools

    test "relocates the wx NIF's dylibs and leaves zero Homebrew/local references" do
      src_nif = Path.join(to_string(:code.priv_dir(:wx)), "wxe_driver.so")

      # Only meaningful when the host's wx NIF links Homebrew dylibs (the normal
      # macOS+Homebrew dev setup). Skip otherwise so a non-Homebrew host passes.
      {out, 0} = System.cmd("otool", ["-L", src_nif])
      external = out |> Dylibs.parse_otool() |> Enum.filter(&Dylibs.external?/1)

      if external == [] do
        :ok
      else
        tmp = Path.join(System.tmp_dir!(), "bds-relink-#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf!(tmp) end)

        nif_dir = Path.join(tmp, "rel/lib/wx-2.4/priv")
        File.mkdir_p!(nif_dir)
        File.cp!(src_nif, Path.join(nif_dir, "wxe_driver.so"))

        frameworks = Path.join(tmp, "Frameworks")
        nifs = MacBundle.macho_files(Path.join(tmp, "rel"))

        prefix_for = fn nif ->
          "@loader_path/" <> MacBundle.relative_up(Path.dirname(nif), frameworks)
        end

        assert {:ok, reals} = Dylibs.bundle(nifs, frameworks, prefix_for)
        assert reals != []

        # Hard requirement: nothing in the tree still points at Homebrew/local.
        assert MacBundle.verify_standalone(tmp) == :ok

        # Same physical lib referenced under two names (e.g. core-3.2.dylib and
        # core-3.2.0.4.3.dylib) collapses to one real file + a symlink, so dyld
        # loads a single image — no duplicate Objective-C classes.
        symlinks =
          frameworks
          |> File.ls!()
          |> Enum.filter(&(File.lstat!(Path.join(frameworks, &1)).type == :symlink))

        assert symlinks != [], "expected symlink dedup for versioned dylib names"
      end
    end
  end

  describe "MacBundle.macho_files/1" do
    test "finds Mach-O binaries anywhere in the tree by magic number, ignoring other files" do
      tmp = Path.join(System.tmp_dir!(), "bds-macho-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(tmp) end)

      # Little-endian 64-bit Mach-O magic (0xFEEDFACF) as stored on disk.
      macho = <<0xCF, 0xFA, 0xED, 0xFE>>

      beam = Path.join(tmp, "Contents/Resources/rel/erts-16/bin/beam.smp")
      nif = Path.join(tmp, "Contents/Resources/rel/lib/foo-1.0/priv/foo.so")
      dylib = Path.join(tmp, "Contents/Frameworks/libbar.dylib")

      for path <- [beam, nif, dylib] do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, macho <> "machine code")
      end

      # Non-Mach-O files (plist, shell scripts) must be excluded.
      File.write!(Path.join(tmp, "Contents/Info.plist"), ~s(<?xml version="1.0"?>))
      File.write!(Path.join(tmp, "Contents/Resources/rel/erts-16/bin/erl"), "#!/bin/sh\n")

      assert Enum.sort(MacBundle.macho_files(tmp)) == Enum.sort([beam, nif, dylib])
    end
  end

  describe "MacBundle.assemble/1" do
    # assemble/1 compiles the native arm64 launcher with `cc -arch arm64`, so it
    # needs the macOS toolchain (the only platform that builds the .app anyway).
    @describetag :macos_tools

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

    test "installs an executable, arm64-only Mach-O launcher", %{app: app} do
      launcher = Path.join(app, "Contents/MacOS/bds2")
      assert File.exists?(launcher)
      %File.Stat{mode: mode} = File.stat!(launcher)
      assert (mode &&& 0o111) != 0, "launcher must be executable"
      # Must be a native arm64 Mach-O, not a script — a script has no Mach-O
      # slices so LaunchServices advertises x86_64 and offers Rosetta.
      {archs, 0} = System.cmd("lipo", ["-archs", launcher])
      assert String.trim(archs) == "arm64"
    end

    test "copies the release tree and the icon into Resources", %{app: app} do
      assert File.exists?(Path.join(app, "Contents/Resources/rel/bin/bds"))
      assert File.exists?(Path.join(app, "Contents/Resources/AppIcon.icns"))
    end
  end
end
