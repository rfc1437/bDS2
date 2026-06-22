defmodule Mix.Tasks.Bds.Bundle.Macos do
  @moduledoc """
  Build a self-contained, ad-hoc-signed `BDS2.app` macOS bundle.

      mix bds.bundle.macos [--app-release PATH] [--output DIR] [--version V]
                           [--regen-icon] [--register] [--no-codesign]

  Assumes the `:bds` release has been built (`MIX_ENV=prod mix release bds`); pass
  `--app-release` to point elsewhere. Generates the red-pen icon on first run (or
  with `--regen-icon`), assembles the bundle, relocates the wxWidgets dylibs so it
  runs on a clean Mac, ad-hoc codesigns it, and (with `--register`) registers the
  `bds2://` URL scheme via LaunchServices.

  ## Standalone is a hard requirement

  The produced `.app` MUST be fully self-contained: no Mach-O inside it may
  reference a Homebrew/local path (`/opt/homebrew`, `/usr/local`). Every external
  dylib reachable from the release's NIFs is copied into `Contents/Frameworks`
  and rewritten to `@loader_path`-relative install names. The build runs
  `BDS.MacBundle.verify_standalone/1` after relocation and **fails** if any
  external reference survives — so a bundle that would break on a Mac without
  Homebrew never ships.
  """

  use Mix.Task

  alias BDS.MacBundle
  alias BDS.MacBundle.Icon

  @shortdoc "Builds a self-contained macOS .app bundle (BDS2.app)"

  @lsregister "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  @impl Mix.Task
  def run(args) do
    unless match?({:unix, :darwin}, :os.type()) do
      Mix.raise("mix bds.bundle.macos only runs on macOS")
    end

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          app_release: :string,
          output: :string,
          version: :string,
          regen_icon: :boolean,
          register: :boolean,
          codesign: :boolean
        ]
      )

    Mix.Task.run("app.config")

    version = opts[:version] || Mix.Project.config()[:version]
    # ponytail: bundle always ships the prod release; ignore Mix.env() so a stale
    # dev release can't be bundled by forgetting MIX_ENV=prod. Override with --app-release.
    release_dir = opts[:app_release] || Path.expand("_build/prod/rel/bds", File.cwd!())
    output_dir = opts[:output] || Path.expand("dist/macos", File.cwd!())

    unless File.dir?(release_dir) do
      Mix.raise("Release not found at #{release_dir}. Run `MIX_ENV=prod mix release bds` first.")
    end

    icns = ensure_icon(opts[:regen_icon] == true)

    Mix.shell().info("Assembling BDS2.app (version #{version})…")

    case MacBundle.assemble(
           release_dir: release_dir,
           output_dir: output_dir,
           icns_path: icns,
           version: version,
           skip_codesign: opts[:codesign] == false
         ) do
      {:ok, app} ->
        maybe_register(app, opts[:register] == true)
        Mix.shell().info("Built #{app}")

      {:error, reason} ->
        Mix.raise("Bundle failed: #{inspect(reason)}")
    end
  end

  defp ensure_icon(regen?) do
    icns = Icon.icns_path()

    if regen? or not File.exists?(icns) do
      Mix.shell().info("Generating AppIcon.icns (blue→red)…")

      case Icon.generate() do
        {:ok, path} -> path
        {:error, reason} -> Mix.raise("Icon generation failed: #{inspect(reason)}")
      end
    else
      icns
    end
  end

  defp maybe_register(_app, false), do: :ok

  defp maybe_register(app, true) do
    if File.exists?(@lsregister) do
      System.cmd(@lsregister, ["-f", app])
      Mix.shell().info("Registered bds2:// scheme via LaunchServices")
    else
      Mix.shell().info("lsregister not found; skip scheme registration")
    end
  end
end
