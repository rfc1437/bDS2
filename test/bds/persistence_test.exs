defmodule BDS.PersistenceTest do
  use ExUnit.Case, async: true

  alias BDS.Persistence
  alias BDS.Posts.TranslationValidation

  test "atomic_write keeps concurrent writers intact" do
    temp_dir = Path.join(System.tmp_dir!(), "bds-persistence-#{System.unique_integer([:positive])}")
    path = Path.join(temp_dir, "shared.txt")
    payload_a = String.duplicate("alpha", 200_000)
    payload_b = String.duplicate("bravo", 200_000)

    on_exit(fn -> File.rm_rf(temp_dir) end)

    parent = self()

    tasks =
      for index <- 1..12 do
        payload = if rem(index, 2) == 0, do: payload_a, else: payload_b

        Task.async(fn ->
          send(parent, :ready)

          receive do
            :go -> Persistence.atomic_write(path, payload)
          end
        end)
      end

    for _ <- tasks do
      assert_receive :ready
    end

    Enum.each(tasks, fn task -> send(task.pid, :go) end)

    assert Enum.map(tasks, &Task.await(&1, 15_000)) == List.duplicate(:ok, length(tasks))
    assert File.read!(path) in [payload_a, payload_b]
  end

  test "post rebuild globs ignore atomic temp files" do
    temp_dir = Path.join(System.tmp_dir!(), "bds-persistence-glob-#{System.unique_integer([:positive])}")
    posts_dir = Path.join(temp_dir, "posts")

    File.mkdir_p!(posts_dir)
    File.write!(Path.join(posts_dir, "entry.md"), "---\ntitle: Entry\n---\n")
    File.write!(Path.join(posts_dir, "entry.md.tmp.123"), "temp")

    on_exit(fn -> File.rm_rf(temp_dir) end)

    assert TranslationValidation.list_matching_files(posts_dir, "*.md") ==
             [Path.join(posts_dir, "entry.md")]
  end
end