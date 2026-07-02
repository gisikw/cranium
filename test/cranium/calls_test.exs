defmodule Cranium.CallsTest do
  use CraniumTest.DataCase, async: false

  @moduletag :capture_log

  alias Cranium.Calls

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

    caller = "test-caller-#{System.unique_integer([:positive])}"
    target = "test-target-#{System.unique_integer([:positive])}"
    {:ok, target_ctx} = Cranium.Store.get_or_create_epoch(target)

    %{caller: caller, target: target, target_epoch: target_ctx.epoch_id}
  end

  defp place_async(caller, input) do
    Task.async(fn -> Calls.place(caller, input) end)
  end

  defp await_delivery do
    assert_receive {:call_delivered, request, stream_id}, 2_000
    [_, correlation_id] = Regex.run(~r/correlation_id="([^"]+)"/, request.text)
    {request, stream_id, correlation_id}
  end

  defp receiver_turn_ended(room, stream_id) do
    send(Process.whereis(Calls), {:pass_complete, room, stream_id, %{reason: :complete}})
    GenServer.call(Calls, :flush)
  end

  describe "wait disposition" do
    test "round-trips a respond payload", %{caller: caller, target: target} do
      task =
        place_async(caller, %{
          "room" => target,
          "message" => "what is X?",
          "disposition" => "wait"
        })

      {request, _stream_id, correlation_id} = await_delivery()

      assert request.target_room == target
      assert request.origin == "call:" <> caller
      assert request.text =~ "what is X?"
      assert request.depth == 1

      assert {:ok, :delivered} = Calls.respond(target, correlation_id, "X is 42")

      assert {:ok, %{status: :responded, correlation_id: ^correlation_id, payload: "X is 42"}} =
               Task.await(task)
    end

    test "receiver turn ending without respond yields no_reply_designated — never a transcript",
         %{caller: caller, target: target} do
      task =
        place_async(caller, %{
          "room" => target,
          "message" => "anyone home?",
          "disposition" => "wait"
        })

      {_request, stream_id, correlation_id} = await_delivery()

      receiver_turn_ended(target, stream_id)

      assert {:ok, %{status: :no_reply_designated, correlation_id: ^correlation_id} = result} =
               Task.await(task)

      refute Map.has_key?(result, :payload)
    end

    test "timeout degrades to notify semantics — late respond arrives as injection",
         %{caller: caller, target: target} do
      task =
        place_async(caller, %{
          "room" => target,
          "message" => "slow question",
          "disposition" => "wait",
          # Clamped up to the 1s minimum
          "timeout_ms" => 1
        })

      {_request, _stream_id, correlation_id} = await_delivery()

      assert {:ok, %{status: :timed_out, correlation_id: ^correlation_id}} =
               Task.await(task, 5_000)

      assert {:ok, :recorded} = Calls.respond(target, correlation_id, "late answer")

      assert [injection] = Calls.drain_injections(caller)
      assert injection =~ "late answer"
      assert injection =~ correlation_id
    end

    test "further responds after the waiter is unblocked queue as injections",
         %{caller: caller, target: target} do
      task =
        place_async(caller, %{"room" => target, "message" => "q", "disposition" => "wait"})

      {_request, _stream_id, correlation_id} = await_delivery()

      assert {:ok, :delivered} = Calls.respond(target, correlation_id, "first")
      assert {:ok, %{payload: "first"}} = Task.await(task)

      assert {:ok, :recorded} = Calls.respond(target, correlation_id, "second")
      assert {:ok, :recorded} = Calls.respond(target, correlation_id, "third")

      assert [second, third] = Calls.drain_injections(caller)
      assert second =~ "second"
      assert third =~ "third"
    end
  end

  describe "notify disposition" do
    test "returns immediately; respond payloads inject in order with correlation id",
         %{caller: caller, target: target} do
      assert {:ok, %{status: :sent, correlation_id: correlation_id}} =
               Calls.place(caller, %{
                 "room" => target,
                 "message" => "async question",
                 "disposition" => "notify"
               })

      assert_receive {:call_delivered, request, _stream_id}, 2_000
      assert request.text =~ correlation_id

      assert {:ok, :recorded} = Calls.respond(target, correlation_id, "part one")
      assert {:ok, :recorded} = Calls.respond(target, correlation_id, "part two")

      assert [one, two] = Calls.drain_injections(caller)
      assert one =~ "part one"
      assert one =~ correlation_id
      assert two =~ "part two"

      # Drained means drained
      assert Calls.drain_injections(caller) == []
    end
  end

  describe "mute disposition" do
    test "responds are recorded but never delivered", %{caller: caller, target: target} do
      assert {:ok, %{status: :sent, correlation_id: correlation_id}} =
               Calls.place(caller, %{
                 "room" => target,
                 "message" => "fire and forget",
                 "disposition" => "mute"
               })

      assert_receive {:call_delivered, _request, _stream_id}, 2_000

      assert {:ok, :recorded} = Calls.respond(target, correlation_id, "into the void")
      assert Calls.drain_injections(caller) == []
    end
  end

  describe "saturation gate" do
    test "critically saturated receiver returns receiver_saturated without delivery",
         %{caller: caller, target: target, target_epoch: epoch_id} do
      :ok = Cranium.Store.update_epoch(epoch_id, %{saturation: 0.95})

      assert {:ok, %{status: :receiver_saturated, correlation_id: correlation_id} = result} =
               Calls.place(caller, %{
                 "room" => target,
                 "message" => "one more thing...",
                 "disposition" => "wait"
               })

      assert result.saturation == 0.95
      refute_receive {:call_delivered, _, _}, 100

      # The receiver never saw the call, so its correlation id is unknown
      assert {:error, :unknown_correlation_id} =
               Calls.respond(target, correlation_id, "ghost reply")
    end
  end

  describe "validation and addressing" do
    test "unknown target room errors without delivering", %{caller: caller} do
      assert {:error, message} =
               Calls.place(caller, %{
                 "room" => "no-such-room-#{System.unique_integer([:positive])}",
                 "message" => "hello?",
                 "disposition" => "notify"
               })

      assert message =~ "unknown room"
      refute_receive {:call_delivered, _, _}, 100
    end

    test "self-calls are rejected", %{caller: caller} do
      {:ok, _} = Cranium.Store.get_or_create_epoch(caller)

      assert {:error, message} =
               Calls.place(caller, %{
                 "room" => caller,
                 "message" => "note to self",
                 "disposition" => "notify"
               })

      assert message =~ "own room"
    end

    test "respond with a foreign correlation id errors", %{caller: caller, target: target} do
      assert {:ok, %{correlation_id: correlation_id}} =
               Calls.place(caller, %{
                 "room" => target,
                 "message" => "for target only",
                 "disposition" => "notify"
               })

      assert {:error, :foreign_correlation_id} =
               Calls.respond("some-other-room", correlation_id, "not mine")
    end

    test "respond with an unknown correlation id errors" do
      assert {:error, :unknown_correlation_id} =
               Calls.respond("anywhere", "call_nonexistent", "hello")
    end
  end
end
