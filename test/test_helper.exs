cache_root = Path.join(System.tmp_dir!(), "bds-test-cache-#{System.unique_integer([:positive])}")
File.mkdir_p!(cache_root)
Application.put_env(:bds, :project_cache_root, cache_root)

# Public, user-owned default project content lives under a per-user default
# content location — never the repo or the private app dir. Tests redirect it
# to a throwaway temp dir so first-launch defaults never touch the developer's
# home directory.
content_root =
  Path.join(System.tmp_dir!(), "bds-test-content-#{System.unique_integer([:positive])}")

File.mkdir_p!(content_root)
Application.put_env(:bds, :default_content_root, content_root)

Enum.each(["LC_ALL", "LC_MESSAGES", "LANG"], fn variable ->
  System.put_env(variable, "en_US.UTF-8")
end)

# The test suite spins up long-lived LiveView, Bandit, and desktop automation
# processes against a single SQLite database. Running files concurrently causes
# intermittent `Database busy` failures in otherwise passing tests, so the
# default suite runs serially.
ExUnit.start(max_cases: 1)

ExUnit.after_suite(fn _results ->
  File.rm_rf(cache_root)
  File.rm_rf(content_root)
end)

Ecto.Adapters.SQL.Sandbox.mode(BDS.Repo, :manual)
