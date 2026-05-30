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
        MacOS/bds2                 # launcher script (execs the release)
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

  @doc "Render the `Contents/MacOS` launcher shell script."
  @spec launcher(keyword()) :: String.t()
  def launcher(opts \\ []) do
    assigns = [
      identifier: Keyword.get(opts, :identifier, @identifier),
      name: Keyword.get(opts, :name, @display_name),
      release_name: Keyword.get(opts, :release_name, @release_name)
    ]

    EEx.eval_file(template_path("launcher.sh.eex"), assigns)
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

  @doc "Locate the wxWidgets NIF (`wxe_driver.so`) inside a release tree."
  @spec wx_nif_path(String.t()) :: String.t() | nil
  def wx_nif_path(release_dir) do
    release_dir
    |> Path.join("lib/wx-*/priv/wxe_driver.so")
    |> Path.wildcard()
    |> List.first()
  end

  defp write_launcher(path) do
    with :ok <- File.write(path, launcher()) do
      File.chmod(path, 0o755)
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

    case wx_nif_path(Path.join(app, "Contents/Resources/rel")) do
      nil ->
        {:error, {:wx_nif_not_found, release_dir}}

      nif ->
        prefix = "@loader_path/" <> relative_up(Path.dirname(nif), frameworks)

        case Dylibs.bundle(nif, frameworks, prefix) do
          {:ok, _copied} -> :ok
          error -> error
        end
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

  @doc """
  Ad-hoc codesign the whole bundle recursively. `--deep` signs every nested
  Mach-O (the relocated dylibs and the release's `beam.smp`/`erlexec`/escripts),
  then we verify with `--deep --strict`.
  """
  @spec codesign(String.t()) :: :ok | {:error, term()}
  def codesign(app) do
    with :ok <- run("codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", app]) do
      run("codesign", ["--verify", "--deep", "--strict", app])
    end
  end

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:command_failed, cmd, status, out}}
    end
  end

  defp template_path(name), do: Path.join(:code.priv_dir(:bds), "desktop/macos/#{name}")
end
