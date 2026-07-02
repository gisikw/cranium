defmodule Cranium.Inference.Agent.Tools.RespondTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.Inference.Agent.Tools.Respond

  setup do
    original = Application.get_env(:cranium, :call_delivery)
    Application.put_env(:cranium, :call_delivery, Cranium.Test.CallDeliveryStub)
    Application.put_env(:cranium, :call_delivery_test_pid, self())

    on_exit(fn ->
      if original,
        do: Application.put_env(:cranium, :call_delivery, original),
        else: Application.delete_env(:cranium, :call_delivery)

      Application.delete_env(:cranium, :call_delivery_test_pid)
    end)

    :ok
  end

  test "records a respond for an incoming notify call" do
    caller = "test-respond-caller-#{System.unique_integer([:positive])}"
    target = "test-respond-target-#{System.unique_integer([:positive])}"
    {:ok, _} = Cranium.Store.get_or_create_epoch(target)

    {:ok, %{correlation_id: correlation_id}} =
      Cranium.Calls.place(caller, %{
        "room" => target,
        "message" => "question",
        "disposition" => "notify"
      })

    assert {:ok, result} =
             Respond.execute(
               %{"correlation_id" => correlation_id, "payload" => "answer"},
               conversation_id: target
             )

    assert %{"status" => "recorded", "correlation_id" => ^correlation_id} =
             Jason.decode!(result)

    assert [injection] = Cranium.Calls.drain_injections(caller)
    assert injection =~ "answer"
  end

  test "unknown correlation id errors in-band" do
    assert {:ok, result} =
             Respond.execute(
               %{"correlation_id" => "call_missing", "payload" => "p"},
               conversation_id: "some-room"
             )

    assert %{"error" => error} = Jason.decode!(result)
    assert error =~ "unknown correlation_id"
  end

  test "foreign correlation id errors in-band" do
    caller = "test-respond-caller-#{System.unique_integer([:positive])}"
    target = "test-respond-target-#{System.unique_integer([:positive])}"
    {:ok, _} = Cranium.Store.get_or_create_epoch(target)

    {:ok, %{correlation_id: correlation_id}} =
      Cranium.Calls.place(caller, %{
        "room" => target,
        "message" => "question",
        "disposition" => "notify"
      })

    assert {:ok, result} =
             Respond.execute(
               %{"correlation_id" => correlation_id, "payload" => "p"},
               conversation_id: "intruder-room"
             )

    assert %{"error" => error} = Jason.decode!(result)
    assert error =~ "not addressed to this room"
  end

  test "missing fields error in-band" do
    assert {:ok, result} = Respond.execute(%{"payload" => "p"}, conversation_id: "room")
    assert %{"error" => error} = Jason.decode!(result)
    assert error =~ "correlation_id"

    assert {:ok, result} =
             Respond.execute(%{"correlation_id" => "call_x"}, conversation_id: "room")

    assert %{"error" => error} = Jason.decode!(result)
    assert error =~ "payload"
  end
end
