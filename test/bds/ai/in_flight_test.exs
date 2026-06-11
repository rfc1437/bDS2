defmodule BDS.AI.InFlightTest do
  use ExUnit.Case, async: true

  alias BDS.AI.InFlight

  test "registrations survive the death of the registering process" do
    conversation_id = unique_conversation_id()
    target = self()

    {pid, ref} =
      spawn_monitor(fn ->
        InFlight.register(conversation_id, self())
        send(target, :registered)
      end)

    assert_receive :registered
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert InFlight.lookup(conversation_id) == pid

    assert InFlight.unregister(conversation_id) == :ok
    assert InFlight.lookup(conversation_id) == nil
  end

  test "lookup returns nil for unknown conversations" do
    assert InFlight.lookup(unique_conversation_id()) == nil
  end

  test "the named table is owned by the supervised InFlight process" do
    owner = :ets.info(:bds_ai_in_flight, :owner)

    assert is_pid(owner)
    assert owner == Process.whereis(InFlight)
  end

  defp unique_conversation_id do
    "in-flight-test-" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
