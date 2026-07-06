defmodule BDS.Git.StreamTest do
  use ExUnit.Case, async: true

  alias BDS.Git.Stream

  setup do
    dir = Path.join(System.tmp_dir!(), "bds-git-stream-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write_script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  test "streams stdout and stderr separately and reports the exit status", %{dir: dir} do
    script =
      write_script(
        dir,
        "emit",
        ~s(printf 'OUT:%s\\n' "$1"; printf 'ERR:%s\\n' "$1" 1>&2\nexit 3\n)
      )

    {:ok, _pid, ref} = Stream.start(self(), dir, ["hello"], command: script)

    assert_receive {:git_output, ^ref, :stdout, out}, 2_000
    assert out =~ "OUT:hello"

    assert_receive {:git_output, ^ref, :stderr, err}, 2_000
    assert err =~ "ERR:hello"

    assert_receive {:git_done, ^ref, 3}, 2_000
  end

  test "cancel kills a hanging process and still reports done", %{dir: dir} do
    script = write_script(dir, "hang", "exec sleep 30\n")

    {:ok, pid, ref} = Stream.start(self(), dir, [], command: script)
    Stream.cancel(pid)

    assert_receive {:git_done, ^ref, status}, 2_000
    refute status == 0
  end

  test "reports a failure when the command is missing", %{dir: dir} do
    {:ok, _pid, ref} = Stream.start(self(), dir, [], command: "definitely-not-a-real-binary-xyz")

    assert_receive {:git_output, ^ref, :stderr, msg}, 2_000
    assert msg =~ "definitely-not-a-real-binary-xyz"
    assert_receive {:git_done, ^ref, status}, 2_000
    refute status == 0
  end
end
