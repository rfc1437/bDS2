defmodule BDS.MacBundle.Dylibs do
  @moduledoc """
  Makes the bundled Elixir release **fully self-contained** on macOS: after
  `bundle/3` runs, no Mach-O binary in the `.app` references a Homebrew/local
  (`/opt/homebrew`, `/usr/local`) path, so the app launches on a clean Mac with
  no Homebrew installed.

  Erlang NIFs (`wxe_driver.so`, `crypto.so`, …) are built against whatever
  produced the host OTP install — typically Homebrew. We walk every Mach-O in
  the release, copy the transitive closure of external dylibs into
  `Contents/Frameworks/`, and rewrite every external install name to a
  `@loader_path`-relative one.

  Two robustness points the previous (per-NIF, exact-path) version missed:

    * **Spelling-independent rewriting.** The same physical dylib is referenced
      under different absolute spellings — a NIF links the symlink name
      (`.../opt/wxwidgets@3.2/lib/libwx_..._core-3.2.dylib`) while inter-library
      deps link the versioned name (`.../Cellar/.../libwx_..._core-3.2.0.4.3.dylib`).
      We rewrite by *basename* (`relink_changes/2`), so every spelling of an
      external dep is caught regardless of how it was written.

    * **Inode dedup via symlinks.** Those two names are one file. We copy the
      real bytes once and make the other name a symlink to it, so dyld loads a
      single image — otherwise both copies load and you get duplicate
      Objective-C class / wx event-table registrations.

  The `otool`/`install_name_tool` parsing and argument building are pure so they
  can be unit-tested; `bundle/3` performs the actual filesystem + tool work.
  """

  # Homebrew prefixes whose libraries must be copied into the bundle. Anything
  # under /usr/lib or /System is part of macOS and stays referenced in place;
  # @rpath/@executable_path/@loader_path are already relocatable.
  @external_prefixes ["/opt/homebrew", "/usr/local"]

  @doc "Parse `otool -L` output into the ordered list of dependency paths."
  @spec parse_otool(String.t()) :: [String.t()]
  def parse_otool(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    # The first line is the inspected file ("path:"), not a dependency.
    |> Enum.filter(&String.starts_with?(&1, "\t"))
    |> Enum.map(fn line ->
      line
      |> String.trim()
      |> String.replace(~r/\s+\(compatibility version.*\)$/, "")
      |> String.trim()
    end)
  end

  @doc "True when a dylib path must be copied into the bundle (Homebrew/local)."
  @spec external?(String.t()) :: boolean()
  def external?(path) when is_binary(path) do
    Enum.any?(@external_prefixes, &String.starts_with?(path, &1))
  end

  @doc "install_name_tool args to set a dylib's own id."
  @spec id_args(String.t(), String.t()) :: [String.t()]
  def id_args(dylib_path, new_id), do: ["-id", new_id, dylib_path]

  @doc """
  install_name_tool args to rewrite zero or more dependency install names on a
  binary. Returns `[]` when there are no changes so callers can skip the tool.
  """
  @spec change_args(String.t(), [{String.t(), String.t()}]) :: [String.t()]
  def change_args(_binary, []), do: []

  def change_args(binary, changes) when is_list(changes) do
    Enum.flat_map(changes, fn {old, new} -> ["-change", old, new] end) ++ [binary]
  end

  @doc """
  Extract the `LC_RPATH` search paths from `otool -l` output. Used to find and
  strip Homebrew/local rpaths — an `@rpath` dep would otherwise resolve outside
  the bundle, breaking standalone even though `otool -L` looks clean.
  """
  @spec parse_rpaths(String.t()) :: [String.t()]
  def parse_rpaths(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {in_rpath?, acc} ->
      line = String.trim(line)

      cond do
        line == "cmd LC_RPATH" ->
          {true, acc}

        in_rpath? and String.starts_with?(line, "path ") ->
          path =
            line
            |> String.replace_prefix("path ", "")
            |> String.replace(~r/\s+\(offset \d+\)$/, "")

          {false, [path | acc]}

        true ->
          {in_rpath?, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  Resolve an `@rpath/<name>` dependency to absolute candidate paths using the
  referencing binary's `LC_RPATH` list, the way dyld would: each rpath entry is
  tried in order with `@loader_path` expanded to the binary's own directory.
  `@executable_path` rpaths are skipped (not resolvable from a library), and
  non-`@rpath` deps yield no candidates. Homebrew links keg siblings this way
  (`@rpath/libsharpyuv.0.dylib` + rpath `@loader_path/../lib` in libwebp), so
  these deps are just as external as absolute `/opt/homebrew` ones.
  """
  @spec resolve_rpath_dep(String.t(), [String.t()], String.t()) :: [String.t()]
  def resolve_rpath_dep("@rpath/" <> name, rpaths, loader_dir) when is_list(rpaths) do
    rpaths
    |> Enum.map(fn
      "@loader_path" <> rest -> Path.expand(loader_dir <> rest)
      "@executable_path" <> _rest -> nil
      absolute -> absolute
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join(&1, name))
  end

  def resolve_rpath_dep(_dep, _rpaths, _loader_dir), do: []

  @doc """
  Build `{old, new}` rewrites for a binary's `otool -L` dependency list: every
  external dep becomes `<prefix>/<basename>`, and every `@rpath/<name>` dep
  whose basename is in `bundled` (it was copied into Frameworks) is rewritten
  the same way. System (`/usr/lib`, `/System`) and other already-relocatable
  deps are dropped. Rewriting by basename — not by the exact source path — is
  what makes this catch every absolute spelling of the same library.
  """
  @spec relink_changes([String.t()], String.t(), [String.t()]) :: [{String.t(), String.t()}]
  def relink_changes(deps, prefix, bundled \\ []) when is_list(deps) do
    deps
    |> Enum.filter(fn
      "@rpath/" <> name -> name in bundled
      dep -> external?(dep)
    end)
    |> Enum.map(fn dep -> {dep, prefix <> "/" <> Path.basename(dep)} end)
  end

  @doc """
  Relocate every external dylib reachable from `nifs` into `frameworks_dir` and
  rewrite all install names so the bundle is self-contained.

  `nifs` is the list of Mach-O binaries in the release that may link external
  libs (NIFs, `beam.smp`, …). `prefix_for` maps a NIF to its `@loader_path`-based
  prefix to `frameworks_dir` (the NIF runs from `beam.smp`, so references are
  `@loader_path`-relative to the NIF's own location, independent of `DYLD_*`).

  Copied dylibs share `frameworks_dir`, so they reference each other (and their
  own id) as `@loader_path/<basename>`. Returns `{:ok, real_copies}`.
  """
  @spec bundle([String.t()], String.t(), (String.t() -> String.t())) ::
          {:ok, [String.t()]} | {:error, term()}
  def bundle(nifs, frameworks_dir, prefix_for) when is_function(prefix_for, 1) do
    File.mkdir_p!(frameworks_dir)

    with {:ok, externals} <- collect(nifs, %{}) do
      reals = materialize(externals, frameworks_dir)
      bundled = Map.keys(externals)

      with :ok <- relink_each(reals, fn _real -> "@loader_path" end, bundled, set_id: true),
           :ok <- relink_each(nifs, prefix_for, bundled, set_id: false) do
        {:ok, reals}
      end
    end
  end

  # Transitive closure of external deps, keyed by basename (one source path per
  # basename — different absolute spellings of the same leaf collapse here).
  defp collect(binaries, acc) do
    Enum.reduce_while(binaries, {:ok, acc}, fn bin, {:ok, acc} ->
      case external_deps(bin) do
        {:ok, deps} ->
          deps
          |> Enum.reduce_while({:ok, acc}, fn dep, {:ok, acc} ->
            base = Path.basename(dep)

            if Map.has_key?(acc, base) do
              {:cont, {:ok, acc}}
            else
              case collect([dep], Map.put(acc, base, dep)) do
                {:ok, _} = ok -> {:cont, ok}
                error -> {:halt, error}
              end
            end
          end)
          |> case do
            {:ok, _} = ok -> {:cont, ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  # A binary's external deps: absolute Homebrew/local references, plus any
  # @rpath/ reference that resolves (via the binary's own LC_RPATHs) to an
  # existing Homebrew/local file. @rpath deps resolving inside the release tree
  # (vix/exla-style precompiled NIFs) are relocatable as-is and stay untouched.
  defp external_deps(bin) do
    with {:ok, deps} <- otool(bin) do
      direct = Enum.filter(deps, &external?/1)

      case resolve_external_rpath_deps(bin, deps) do
        {:ok, resolved} -> {:ok, direct ++ resolved}
        error -> error
      end
    end
  end

  defp resolve_external_rpath_deps(bin, deps) do
    case Enum.filter(deps, &String.starts_with?(&1, "@rpath/")) do
      [] ->
        {:ok, []}

      rpath_deps ->
        with {:ok, search_paths} <- rpaths(bin) do
          resolved =
            rpath_deps
            |> Enum.map(fn dep ->
              dep
              |> resolve_rpath_dep(search_paths, Path.dirname(bin))
              |> Enum.find(fn candidate -> external?(candidate) and File.exists?(candidate) end)
            end)
            |> Enum.reject(&is_nil/1)

          {:ok, resolved}
        end
    end
  end

  # Copy each external once (deduped by device+inode, which follows symlinks to
  # the real file); additional basenames for the same file become symlinks so
  # dyld loads a single image. Returns the real (non-symlink) copies.
  # ponytail: basename collisions between *different* libraries would clobber;
  # never happens for our deps — add content hashing if it ever does.
  defp materialize(externals, frameworks_dir) do
    {_seen, reals} =
      Enum.reduce(externals, {%{}, []}, fn {base, src}, {seen, reals} ->
        dest = Path.join(frameworks_dir, base)
        inode = file_inode(src)

        case Map.get(seen, inode) do
          nil ->
            File.cp!(src, dest)
            File.chmod!(dest, 0o644)
            {Map.put(seen, inode, base), [dest | reals]}

          canonical ->
            _ = File.rm(dest)
            File.ln_s!(canonical, dest)
            {seen, reals}
        end
      end)

    Enum.reverse(reals)
  end

  defp file_inode(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.inode}
  end

  defp relink_each(binaries, prefix_for, bundled, opts) do
    set_id? = Keyword.fetch!(opts, :set_id)

    Enum.reduce_while(binaries, :ok, fn binary, :ok ->
      with :ok <- maybe_set_id(binary, set_id?),
           :ok <- relink(binary, prefix_for.(binary), bundled) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp maybe_set_id(_binary, false), do: :ok

  defp maybe_set_id(binary, true) do
    run("install_name_tool", id_args(binary, "@loader_path/" <> Path.basename(binary)))
  end

  defp relink(binary, prefix, bundled) do
    with {:ok, deps} <- otool(binary),
         :ok <- apply_changes(binary, change_args(binary, relink_changes(deps, prefix, bundled))) do
      strip_external_rpaths(binary)
    end
  end

  defp apply_changes(_binary, []), do: :ok
  defp apply_changes(_binary, args), do: run("install_name_tool", args)

  # Drop any LC_RPATH pointing at Homebrew/local. Such an rpath lets an
  # @rpath/ dep resolve outside the bundle, so leaving it would break standalone.
  defp strip_external_rpaths(binary) do
    case rpaths(binary) do
      {:ok, paths} ->
        paths
        |> Enum.filter(&external?/1)
        |> Enum.reduce_while(:ok, fn rpath, :ok ->
          case run("install_name_tool", ["-delete_rpath", rpath, binary]) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      error ->
        error
    end
  end

  defp rpaths(path) do
    case System.cmd("otool", ["-l", path], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse_rpaths(out)}
      {out, status} -> {:error, {:otool_failed, status, out}}
    end
  end

  defp otool(path) do
    case System.cmd("otool", ["-L", path], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse_otool(out)}
      {out, status} -> {:error, {:otool_failed, status, out}}
    end
  end

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:command_failed, cmd, status, out}}
    end
  end
end
