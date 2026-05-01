cache_root = Path.join(System.tmp_dir!(), "bds-test-cache-#{System.unique_integer([:positive])}")
File.mkdir_p!(cache_root)
Application.put_env(:bds, :project_cache_root, cache_root)

ExUnit.start()

ExUnit.after_suite(fn _results ->
  File.rm_rf(cache_root)
end)

Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual)
