defmodule Cranium.Inference.Agent.Tools.CallTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.Inference.Agent.Tools.Call

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

  test "errors in-band without an originating room" do
    assert {:ok, result} =
             Call.execute(%{"room" => "r", "message" => "m", "disposition" => "notify"}, [])

    assert %{"error" => error} = Jason.decode!(result)
    assert error =~ "no originating room"
  end

  test "places a notify call and returns correlation id, threading depth" do
    caller = "test-tool-caller-#{System.unique_integer([:positive])}"
    target = "test-tool-target-#{System.unique_integer([:positive])}"
    {:ok, _} = Cranium.Store.get_or_create_epoch(target)

    assert {:ok, result} =
             Call.execute(
               %{"room" => target, "message" => "ping", "disposition" => "notify"},
               conversation_id: caller,
               depth: 2
             )

    assert %{"status" => "sent", "correlation_id" => "call_" <> _} = Jason.decode!(result)

    assert_receive {:call_delivered, request, _stream_id}, 2_000
    assert request.depth == 3
  end

  test "surfaces validation errors in-band" do
    caller = "test-tool-caller-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             Call.execute(%{"room" => "r", "disposition" => "notify"}, conversation_id: caller)

    assert %{"error" => error} = Jason.decode!(result)
    assert error =~ "message"
  end

  test "executor backstop timeout sits above the max wait timeout" do
    assert Call.timeout() > Cranium.Calls.Logic.max_timeout_ms()
  end
end
