defmodule Cranium.Calls.LogicTest do
  use ExUnit.Case, async: true

  alias Cranium.Calls.Logic

  describe "validate/1" do
    test "accepts a minimal wait call with default timeout" do
      assert {:ok, params} =
               Logic.validate(%{
                 "room" => "fort-nix",
                 "message" => "investigate X",
                 "disposition" => "wait"
               })

      assert params.room == "fort-nix"
      assert params.message == "investigate X"
      assert params.disposition == :wait
      assert params.timeout_ms == 600_000
      assert params.depth == 0
    end

    test "clamps timeout_ms into 1s..30min for wait" do
      base = %{"room" => "r", "message" => "m", "disposition" => "wait"}

      assert {:ok, %{timeout_ms: 1_000}} = Logic.validate(Map.put(base, "timeout_ms", 5))

      assert {:ok, %{timeout_ms: 1_800_000}} =
               Logic.validate(Map.put(base, "timeout_ms", 99_999_999))

      assert {:ok, %{timeout_ms: 30_000}} = Logic.validate(Map.put(base, "timeout_ms", 30_000))
    end

    test "ignores timeout_ms for notify and mute" do
      for disposition <- ["notify", "mute"] do
        assert {:ok, %{timeout_ms: nil}} =
                 Logic.validate(%{
                   "room" => "r",
                   "message" => "m",
                   "disposition" => disposition,
                   "timeout_ms" => 5_000
                 })
      end
    end

    test "rejects missing room, message, or bad disposition" do
      assert {:error, msg} = Logic.validate(%{"message" => "m", "disposition" => "wait"})
      assert msg =~ "room"

      assert {:error, msg} = Logic.validate(%{"room" => "r", "disposition" => "wait"})
      assert msg =~ "message"

      assert {:error, msg} =
               Logic.validate(%{"room" => "r", "message" => "m", "disposition" => "block"})

      assert msg =~ "disposition"

      assert {:error, _} = Logic.validate(%{"room" => "r", "message" => "m"})
    end

    test "normalizes depth" do
      base = %{"room" => "r", "message" => "m", "disposition" => "mute"}

      assert {:ok, %{depth: 3}} = Logic.validate(Map.put(base, "depth", 3))
      assert {:ok, %{depth: 0}} = Logic.validate(Map.put(base, "depth", nil))
      assert {:ok, %{depth: 0}} = Logic.validate(Map.put(base, "depth", -2))
    end
  end

  describe "saturated?/2" do
    test "true at or above threshold, false below or unknown" do
      assert Logic.saturated?(0.95, 0.9)
      assert Logic.saturated?(0.9, 0.9)
      refute Logic.saturated?(0.89, 0.9)
      refute Logic.saturated?(nil, 0.9)
    end
  end

  describe "respond_route/2" do
    defp call_record(overrides) do
      Map.merge(
        %{
          correlation_id: "call_x",
          caller_room: "alpha",
          target_room: "beta",
          disposition: :notify,
          status: :pending,
          waiter: nil,
          responses: []
        },
        overrides
      )
    end

    test "foreign room is rejected" do
      assert {:error, :foreign_correlation_id} =
               Logic.respond_route(call_record(%{}), "gamma")
    end

    test "mute records only, even from the right room" do
      assert :record_only = Logic.respond_route(call_record(%{disposition: :mute}), "beta")
    end

    test "wait with a blocked waiter delivers to the waiter" do
      record = call_record(%{disposition: :wait, waiter: {self(), make_ref()}})
      assert :deliver_to_waiter = Logic.respond_route(record, "beta")
    end

    test "notify — and wait after timeout/answer — queue injections" do
      assert :queue_injection = Logic.respond_route(call_record(%{}), "beta")

      timed_out = call_record(%{disposition: :wait, status: :timed_out})
      assert :queue_injection = Logic.respond_route(timed_out, "beta")
    end
  end

  describe "formatting" do
    test "incoming_call_text carries attribution, correlation id, and respond note" do
      text = Logic.incoming_call_text("alpha", "call_abc", "please check X", :wait)

      assert text =~ ~s(from_room="alpha")
      assert text =~ ~s(correlation_id="call_abc")
      assert text =~ ~s(disposition="wait")
      assert text =~ "please check X"
      assert text =~ "`respond` tool"
      assert text =~ "blocked waiting"
    end

    test "non-wait dispositions omit the blocked-caller note" do
      refute Logic.incoming_call_text("alpha", "call_abc", "hi", :notify) =~ "blocked waiting"
    end

    test "injection_content tags payload with room and correlation id" do
      content = Logic.injection_content("beta", "call_abc", "the answer")

      assert content =~ ~s(from_room="beta")
      assert content =~ "correlation_id: call_abc"
      assert content =~ "the answer"
      assert content =~ "<system-reminder>"
    end
  end

  describe "push_injection/3" do
    test "appends in order under the cap" do
      {pending, 0} = Logic.push_injection(["a"], "b", 5)
      assert pending == ["a", "b"]
    end

    test "drops oldest entries beyond the cap" do
      {pending, dropped} = Logic.push_injection(["a", "b", "c"], "d", 3)
      assert pending == ["b", "c", "d"]
      assert dropped == 1
    end
  end
end
