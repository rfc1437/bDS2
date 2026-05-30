defmodule BDS.Desktop.DeepLinkTest do
  use ExUnit.Case, async: false

  alias BDS.Desktop.DeepLink

  setup do
    topic = "deep-link-test:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(BDS.PubSub, topic)

    {:ok, pid} = DeepLink.start_link(name: nil, pubsub: BDS.PubSub, topic: topic)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{pid: pid, topic: topic}
  end

  test "broadcasts a bds2:// open_url event to the shell topic", %{pid: pid} do
    url = "bds2://new-post?title=Hello&url=https://example.com"
    send(pid, {:open_url, [url]})

    assert_receive {:blogmark_deep_link, ^url}, 500
  end

  test "ignores non-bds2 open_url events", %{pid: pid} do
    send(pid, {:open_url, ["https://example.com"]})

    refute_receive {:blogmark_deep_link, _url}, 200
  end

  test "ignores unrelated messages", %{pid: pid} do
    send(pid, {:open_file, ["/tmp/x"]})

    refute_receive {:blogmark_deep_link, _url}, 200
  end
end
