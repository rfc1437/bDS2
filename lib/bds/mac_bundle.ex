defmodule BDS.MacBundle do
  @moduledoc """
  Assembles a self-contained, ad-hoc-signed macOS `.app` bundle for bDS2.

  The bundle wraps the `:bds` Elixir release (which already embeds ERTS), a
  red-pen `AppIcon.icns` (`BDS.MacBundle.Icon`), and the wxWidgets dylibs the
  `:wx` NIF needs, relocated to run on a clean Mac (`BDS.MacBundle.Dylibs`). Its
  `Info.plist` registers the `bds2://` URL scheme so the OS forwards blogmark
  deep links to the running app (`Desktop.Env` → `BDS.Desktop.DeepLink`).

  Layout:

      BDS2.app/Contents/
        Info.plist  PkgInfo
        MacOS/bds2                 # native arm64 launcher (execs the release)
        Resources/AppIcon.icns
        Resources/rel/             # the mix release (ERTS bundled)
        Frameworks/                # relocated wx + transitive dylibs
  """

  alias BDS.MacBundle.Dylibs

  @identifier "de.rfc1437.bds2"
  @display_name "Blogging Desktop Server"
  @executable "bds2"
  @icon_name "AppIcon"
  @scheme "bds2"
  @min_system "13.0"
  @release_name "bds"
  @app_dir_name "BDS2.app"

  @doc "Render the `Info.plist` XML for the bundle."
  @spec info_plist(keyword()) :: String.t()
  def info_plist(opts \\ []) do
    assigns = [
      identifier: Keyword.get(opts, :identifier, @identifier),
      name: Keyword.get(opts, :name, @display_name),
      executable: Keyword.get(opts, :executable, @executable),
      icon: Keyword.get(opts, :icon, @icon_name),
      scheme: Keyword.get(opts, :scheme, @scheme),
      min_system: Keyword.get(opts, :min_system, @min_system),
      version: Keyword.get(opts, :version, "0.0.0")
    ]

    EEx.eval_file(template_path("Info.plist.eex"), assigns)
  end

  @doc """
  Assemble the `.app` from a built release directory.

  Options:
    * `:release_dir`  — path to the `:bds` release (required)
    * `:output_dir`   — where to place `BDS2.app` (required)
    * `:icns_path`    — path to `AppIcon.icns` (required)
    * `:version`      — version string for `Info.plist` (default "0.0.0")
    * `:skip_dylibs`  — skip wx dylib relocation (tests; default false)
    * `:skip_codesign`— skip ad-hoc codesign (tests; default false)
  """
  @spec assemble(keyword()) :: {:ok, String.t()} | {:error, term()}
  def assemble(opts) do
    release_dir = Keyword.fetch!(opts, :release_dir)
    output_dir = Keyword.fetch!(opts, :output_dir)
    icns_path = Keyword.fetch!(opts, :icns_path)
    version = Keyword.get(opts, :version, "0.0.0")

    app = Path.join(output_dir, @app_dir_name)
    contents = Path.join(app, "Contents")
    macos = Path.join(contents, "MacOS")
    resources = Path.join(contents, "Resources")
    frameworks = Path.join(contents, "Frameworks")
    rel = Path.join(resources, "rel")

    File.rm_rf!(app)
    Enum.each([macos, resources, frameworks], &File.mkdir_p!/1)

    with {:ok, _} <- File.cp_r(release_dir, rel),
         :ok <- File.cp(icns_path, Path.join(resources, "#{@icon_name}.icns")),
         :ok <- File.write(Path.join(contents, "Info.plist"), info_plist(version: version)),
         :ok <- File.write(Path.join(contents, "PkgInfo"), "APPL????"),
         :ok <- write_launcher(Path.join(macos, @executable)),
         :ok <- maybe_relocate_dylibs(rel, frameworks, opts),
         :ok <- maybe_codesign(app, opts) do
      {:ok, app}
    end
  end

  # The main executable must be a real arm64 Mach-O, not a shell script — a
  # script has no Mach-O slices, so LaunchServices advertises x86_64 and offers
  # Rosetta. Compile the native stub (launcher.c) in its place.
  defp write_launcher(path) do
    src = template_path("launcher.c")

    case System.cmd(
           "cc",
           ["-arch", "arm64", "-O2", ~s(-DBDS_RELEASE_NAME="#{@release_name}"), "-o", path, src],
           stderr_to_stdout: true
         ) do
      {_, 0} -> File.chmod(path, 0o755)
      {out, code} -> {:error, "launcher compile failed (#{code}): #{out}"}
    end
  end

  defp maybe_relocate_dylibs(_rel, _frameworks, opts) do
    if Keyword.get(opts, :skip_dylibs, false) do
      :ok
    else
      relocate_dylibs(opts[:release_dir], opts)
    end
  end

  defp relocate_dylibs(release_dir, opts) do
    app = Path.join(opts[:output_dir], @app_dir_name)
    frameworks = Path.join(app, "Contents/Frameworks")
    rel = Path.join(app, "Contents/Resources/rel")

    # Every loose Mach-O in the release (NIFs, beam.smp, …) may link a Homebrew
    # dylib, so relocate the closure reachable from all of them — not just wx.
    case macho_files(rel) do
      [] ->
        {:error, {:no_release_binaries, release_dir}}

      nifs ->
        prefix_for = fn nif -> "@loader_path/" <> relative_up(Path.dirname(nif), frameworks) end

        with {:ok, _copied} <- Dylibs.bundle(nifs, frameworks, prefix_for) do
          verify_standalone(app)
        end
    end
  end

  @doc """
  Fail the build unless the bundle is self-contained: no Mach-O under the `.app`
  may reference a Homebrew/local (`/opt/homebrew`, `/usr/local`) path, and every
  `@rpath/` dependency must resolve — via the binary's own `LC_RPATH`s — to a
  file inside the bundle. This is a hard requirement — the app must run on a
  Mac without Homebrew installed.
  """
  @spec verify_standalone(String.t()) ::
          :ok | {:error, {:external_refs, [{String.t(), String.t()}]}}
  def verify_standalone(app) do
    offenders =
      app
      |> macho_files()
      |> Enum.flat_map(fn file ->
        external_refs(file, ["-L"], &Dylibs.parse_otool/1) ++
          external_refs(file, ["-l"], &Dylibs.parse_rpaths/1) ++
          unresolved_rpath_refs(file, app)
      end)

    if offenders == [], do: :ok, else: {:error, {:external_refs, offenders}}
  end

  defp external_refs(file, otool_args, parse) do
    case System.cmd("otool", otool_args ++ [file], stderr_to_stdout: true) do
      {out, 0} -> out |> parse.() |> Enum.filter(&Dylibs.external?/1) |> Enum.map(&{file, &1})
      _ -> []
    end
  end

  # An @rpath/ dep is an offender unless one of its rpath-resolved candidates
  # exists inside the app — a dangling one (Homebrew's libwebp referencing
  # @rpath/libsharpyuv.0.dylib with no copied sibling) crashes only at runtime
  # on the user's machine, so it must fail the build here. A dylib's own
  # LC_ID_DYLIB shows up in `otool -L` like a dep (precompiled NIFs such as
  # hnswlib_nif.so ship an @rpath/ self id with no rpaths at all); dyld never
  # resolves a file's id when loading that file, so self references are skipped.
  defp unresolved_rpath_refs(file, app) do
    root = Path.expand(app)

    case otool_parse(file, ["-L"], &Dylibs.parse_otool/1) do
      {:ok, deps} ->
        deps
        |> Enum.filter(&String.starts_with?(&1, "@rpath/"))
        |> Enum.reject(&(Path.basename(&1) == Path.basename(file)))
        |> Enum.reject(&rpath_dep_resolves?(file, &1, root))
        |> Enum.map(&{file, &1})

      _error ->
        []
    end
  end

  defp rpath_dep_resolves?(file, dep, root) do
    case otool_parse(file, ["-l"], &Dylibs.parse_rpaths/1) do
      {:ok, rpaths} ->
        dep
        |> Dylibs.resolve_rpath_dep(rpaths, Path.dirname(file))
        |> Enum.any?(fn candidate ->
          String.starts_with?(candidate, root <> "/") and File.exists?(candidate)
        end)

      _error ->
        false
    end
  end

  defp otool_parse(file, args, parse) do
    case System.cmd("otool", args ++ [file], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse.(out)}
      {out, status} -> {:error, {:otool_failed, status, out}}
    end
  end

  @doc """
  Compute a `../`-style relative path from `from_dir` to `to` (both absolute),
  e.g. the path from the wx NIF's directory up to `Contents/Frameworks`.
  """
  @spec relative_up(String.t(), String.t()) :: String.t()
  def relative_up(from_dir, to) do
    from = Path.split(Path.expand(from_dir))
    target = Path.split(Path.expand(to))
    {rest_from, rest_to} = drop_common(from, target)
    (List.duplicate("..", length(rest_from)) ++ rest_to) |> Path.join()
  end

  defp drop_common([h | from], [h | to]), do: drop_common(from, to)
  defp drop_common(from, to), do: {from, to}

  defp maybe_codesign(app, opts) do
    if Keyword.get(opts, :skip_codesign, false), do: :ok, else: codesign(app)
  end

  # Mach-O magic numbers (thin 32/64-bit, both endiannesses, and fat) as the
  # first four bytes appear on disk.
  @macho_magics [
    <<0xCF, 0xFA, 0xED, 0xFE>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xCA, 0xFE, 0xBA, 0xBE>>,
    <<0xBE, 0xBA, 0xFE, 0xCA>>
  ]

  @doc """
  Ad-hoc codesign the bundle.

  `codesign --deep` only recurses into nested *bundles* and the main executable;
  it ignores the loose Mach-O files the release ships — `beam.smp`, `erlexec`,
  and every NIF `.so`/`.dylib` under `Resources/rel/…`. Those keep their original
  *linker-signed* ad-hoc signatures, which the macOS code-signing monitor rejects
  once the files are copied into a new bundle (the process is SIGKILLed with
  "Code Signature Invalid" the moment it `dlopen`s such a NIF).

  So we sign every Mach-O explicitly with a fresh ad-hoc signature (inside-out),
  then seal the outer bundle and verify it.
  """
  @spec codesign(String.t()) :: :ok | {:error, term()}
  def codesign(app) do
    with :ok <- sign_machos(macho_files(app)),
         :ok <- run("codesign", ["--force", "--sign", "-", "--timestamp=none", app]) do
      run("codesign", ["--verify", "--strict", app])
    end
  end

  @doc """
  List every Mach-O file under `root`, detected by magic number. These are the
  loose binaries `codesign --deep` skips and that must be signed individually.
  """
  @spec macho_files(String.t()) :: [String.t()]
  def macho_files(root) do
    root |> regular_files() |> Enum.filter(&macho?/1)
  end

  defp regular_files(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(path, entry)

          case File.lstat(full) do
            {:ok, %File.Stat{type: :directory}} -> regular_files(full)
            {:ok, %File.Stat{type: :regular}} -> [full]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp macho?(file) do
    case File.open(file, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, magic} when magic in @macho_magics -> true
      _ -> false
    end
  end

  defp sign_machos(files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case run("codesign", ["--force", "--sign", "-", "--timestamp=none", file]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:command_failed, cmd, status, out}}
    end
  end

  defp template_path(name), do: Path.join(:code.priv_dir(:bds), "desktop/macos/#{name}")
end
