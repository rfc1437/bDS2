defmodule BDS.MacBundle.Dylibs do
  @moduledoc """
  Makes the bundled Elixir release self-contained on macOS by relocating the
  non-system dynamic libraries the wxWidgets NIF (`wxe_driver.so`) links against.

  Erlang's `:wx` driver is built against the wxWidgets dylibs of whatever host
  produced the OTP install (typically Homebrew under `/opt/homebrew`), so a
  release copied to a clean Mac would fail to load `:wx`. We copy every external
  dylib (and its transitive deps) into `Contents/Frameworks/`, then rewrite the
  install names with `install_name_tool` to `@executable_path/../Frameworks/...`.

  The `otool`/`install_name_tool` parsing and argument building are pure so they
  can be unit-tested; `bundle/2` performs the actual filesystem + tool work.
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
  Copy every external dylib reachable from `nif_path` into `frameworks_dir` and
  rewrite all install names (in the NIF and the copied dylibs) to point inside
  the bundle. Returns `{:ok, copied_paths}`.

  References are made `@loader_path`-relative so they resolve against the binary
  that triggers the load — independent of where the host process executable
  lives (the release runs `beam.smp`, not the bundle launcher) and without any
  `DYLD_*` env reliance:

    * the NIF references each dylib as `<nif_loader_prefix>/<basename>`, where
      `nif_loader_prefix` is the `@loader_path/../…/Frameworks` path from the
      NIF's directory to `frameworks_dir`;
    * the copied dylibs live together, so they reference each other (and their
      own id) as `@loader_path/<basename>`.
  """
  @spec bundle(String.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def bundle(nif_path, frameworks_dir, nif_loader_prefix) do
    File.mkdir_p!(frameworks_dir)

    with {:ok, {_seen, externals}} <- collect(nif_path, %{}, []) do
      externals = Enum.reverse(externals)

      {physical, logical_entries, _inode_map} =
        externals
        |> Enum.reduce({[], [], %{}}, fn src, {phys_acc, log_acc, inode_map} ->
          dest = Path.join(frameworks_dir, Path.basename(src))

          if File.exists?(dest) do
            {phys_acc, [{src, dest} | log_acc], inode_map}
          else
            ino = file_inode(src)

            case Map.get(inode_map, ino) do
              nil ->
                File.cp!(src, dest)
                File.chmod!(dest, 0o644)
                {[{src, dest} | phys_acc], [{src, dest} | log_acc],
                 Map.put(inode_map, ino, dest)}

              existing_dest ->
                # Same inode already copied under a different name.
                # Point this logical entry to the physical copy.
                {phys_acc, [{src, existing_dest} | log_acc], inode_map}
            end
          end
        end)

      copied = Enum.reverse(logical_entries)
      physical = Enum.reverse(physical)

      with :ok <- rewrite(nif_path, copied, nif_loader_prefix),
           :ok <- rewrite_each(physical) do
        {:ok, Enum.map(physical, &elem(&1, 1))}
      end
    end
  end

  defp file_inode(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.inode}
  end

  # Depth-first transitive collection of external dependency paths. Returns
  # `{:ok, {seen, acc}}` where `seen` is a plain map used as a set (a MapSet's
  # opaque internals trip dialyzer when threaded through the recursion) and
  # `acc` is the reverse-discovery-order path list.
  defp collect(binary, seen, acc) do
    case otool(binary) do
      {:ok, deps} ->
        deps
        |> Enum.filter(&external?/1)
        |> Enum.reduce_while({:ok, {seen, acc}}, fn dep, {:ok, {seen_acc, list_acc}} ->
          if Map.has_key?(seen_acc, dep) do
            {:cont, {:ok, {seen_acc, list_acc}}}
          else
            seen_acc = Map.put(seen_acc, dep, true)
            case collect(dep, seen_acc, [dep | list_acc]) do
              {:ok, _} = ok -> {:cont, ok}
              error -> {:halt, error}
            end
          end
        end)
      error ->
        error
    end
  end

  defp rewrite(binary, copied, prefix) do
    changes =
      Enum.map(copied, fn {src, dest} ->
        {src, prefix <> "/" <> Path.basename(dest)}
      end)

    case change_args(binary, changes) do
      [] -> :ok
      args -> run("install_name_tool", args)
    end
  end

  # Copied dylibs share Frameworks/, so they reference each other (and their own
  # id) relative to their own location with @loader_path.
  defp rewrite_each(copied) do
    Enum.reduce_while(copied, :ok, fn {_src, dest}, _acc ->
      base = Path.basename(dest)

      with :ok <- run("install_name_tool", id_args(dest, "@loader_path/" <> base)),
           :ok <- rewrite(dest, copied, "@loader_path") do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
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
