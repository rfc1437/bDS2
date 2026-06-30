defmodule BDS.Desktop.DeepLinkTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.DeepLink

  setup do
    {:ok, pid} = DeepLink.start_link(name: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{pid: pid}
  end

  test "delivers a bds2:// link (wx charlist payload) to an attached shell", %{pid: pid} do
    :ok = DeepLink.attach(self(), pid)

    url = "bds2://new-post?title=Hello&url=https://example.com"
    # This is the exact shape erlang :wx sends on macOS: {:open_url, charlist}.
    send(pid, {:open_url, ~c"bds2://new-post?title=Hello&url=https://example.com"})

    assert_receive {:blogmark_deep_link, ^url}, 500
  end

  test "also accepts a binary payload", %{pid: pid} do
    :ok = DeepLink.attach(self(), pid)

    url = "bds2://new-post?title=Bin"
    send(pid, {:open_url, url})

    assert_receive {:blogmark_deep_link, ^url}, 500
  end

  test "queues a link that arrives before a shell attaches, then replays it", %{pid: pid} do
    url = "bds2://new-post?title=Cold&url=https://example.com"
    send(pid, {:open_url, String.to_charlist(url)})

    # Nothing is connected yet, so nothing is delivered.
    refute_receive {:blogmark_deep_link, _}, 100

    :ok = DeepLink.attach(self(), pid)
    assert_receive {:blogmark_deep_link, ^url}, 500
  end

  test "replays multiple cold-start links in arrival order", %{pid: pid} do
    send(pid, {:open_url, ~c"bds2://new-post?title=One"})
    send(pid, {:open_url, ~c"bds2://new-post?title=Two"})

    :ok = DeepLink.attach(self(), pid)

    assert_receive {:blogmark_deep_link, "bds2://new-post?title=One"}, 500
    assert_receive {:blogmark_deep_link, "bds2://new-post?title=Two"}, 500
  end

  test "queues again after the attached shell dies", %{pid: pid} do
    task = Task.async(fn -> DeepLink.attach(self(), pid) end)
    Task.await(task)
    # task process is now dead; DeepLink should observe the DOWN and re-queue.
    Process.sleep(50)

    url = "bds2://new-post?title=After&url=https://example.com"
    send(pid, {:open_url, String.to_charlist(url)})

    :ok = DeepLink.attach(self(), pid)
    assert_receive {:blogmark_deep_link, ^url}, 500
  end

  test "ignores non-bds2 open_url events", %{pid: pid} do
    :ok = DeepLink.attach(self(), pid)
    send(pid, {:open_url, ~c"https://example.com"})

    refute_receive {:blogmark_deep_link, _url}, 200
  end

  test "ignores unrelated messages", %{pid: pid} do
    :ok = DeepLink.attach(self(), pid)
    send(pid, {:open_file, ["/tmp/x"]})

    refute_receive {:blogmark_deep_link, _url}, 200
  end
end
