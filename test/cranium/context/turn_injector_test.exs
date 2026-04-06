defmodule Cranium.Context.TurnInjectorTest do
  use ExUnit.Case, async: true

  alias Cranium.Context.TurnInjector

  # Stub Landscape.build to return nil by default (no cross-room data).
  # Landscape-specific tests use Mox or dedicated test module.

  describe "build_injections/2" do
    test "returns empty list when no injections are needed" do
      message = %{text: "hello"}
      context = %{}
      assert {[], false, nil} = TurnInjector.build_injections(message, context)
    end

    test "injects time-gap reminder after 30+ minutes" do
      now = ~U[2026-03-05 10:45:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}
      context = %{epoch: %{last_invoked_at: last}, now: now}

      {injections, _landscape, _bucket} = TurnInjector.build_injections(message, context)
      assert length(injections) >= 1
      assert Enum.any?(injections, &(&1 =~ "45 minutes"))
      assert Enum.any?(injections, &(&1 =~ "<system-reminder>"))
    end

    test "no time-gap reminder under 30 minutes" do
      now = ~U[2026-03-05 10:20:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}
      context = %{epoch: %{last_invoked_at: last}, now: now}

      {injections, _landscape, _bucket} = TurnInjector.build_injections(message, context)
      refute Enum.any?(injections, &(&1 =~ "minutes"))
    end

    test "injects saturation warning on rising edge" do
      message = %{text: "hello"}

      context = %{
        epoch: %{saturation: 55.0, last_reminder_bucket: 45}
      }

      {injections, _landscape, bucket} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "55%"))
      assert Enum.any?(injections, &(&1 =~ "past halfway"))
      assert bucket == 55
    end

    test "no saturation warning when in same bucket" do
      message = %{text: "hello"}

      context = %{
        epoch: %{saturation: 53.0, last_reminder_bucket: 50}
      }

      {injections, _landscape, bucket} = TurnInjector.build_injections(message, context)
      refute Enum.any?(injections, &(&1 =~ "%"))
      assert bucket == nil
    end

    test "saturation warning fires when last_reminder_bucket has not been advanced" do
      # Regression: last_reminder_bucket must only advance when a warning fires.
      # If it advances every turn, the warning can never fire because the
      # pre-inference saturation and last_reminder_bucket are always in the
      # same bucket.
      message = %{text: "hello"}

      # Simulates: saturation grew past 50% but last_reminder_bucket stayed at 0
      # because no warning was previously injected
      context = %{
        epoch: %{saturation: 52.0, last_reminder_bucket: 0}
      }

      {injections, _landscape, bucket} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "52%"))
      assert bucket == 50
    end

    test "injects interrupted context breadcrumb" do
      message = %{text: "hello"}

      context = %{
        epoch: %{interrupted_context: "Was working on deploying the new service"}
      }

      {injections, _landscape, _bucket} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "interrupted"))
      assert Enum.any?(injections, &(&1 =~ "deploying the new service"))
    end

    test "respects custom saturation_warn threshold from context" do
      message = %{text: "hello"}

      # With default warn=50, a saturation of 45% wouldn't fire.
      # With custom warn=40, it should fire.
      context = %{
        epoch: %{saturation: 45.0, last_reminder_bucket: 0},
        saturation_warn: 40,
        saturation_critical: 70
      }

      {injections, _landscape, bucket} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "45%"))
      assert bucket == 45
    end

    test "respects custom saturation_critical for advice text" do
      message = %{text: "hello"}

      # With critical=65, saturation at 66% should trigger "wrap up" advice
      context = %{
        epoch: %{saturation: 66.0, last_reminder_bucket: 60},
        saturation_warn: 40,
        saturation_critical: 65
      }

      {injections, _landscape, _bucket} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "getting full"))
    end

    test "multiple injections can fire simultaneously" do
      now = ~U[2026-03-05 11:00:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}

      context = %{
        epoch: %{
          last_invoked_at: last,
          saturation: 72.0,
          last_reminder_bucket: 65
        },
        now: now
      }

      {injections, _landscape, _bucket} = TurnInjector.build_injections(message, context)
      assert length(injections) >= 2
    end
  end

  describe "process/2" do
    test "prepends injections to message text" do
      message = %{text: "hello"}

      context = %{
        epoch: %{interrupted_context: "fixing a bug"}
      }

      {:ok, result} = TurnInjector.process(message, context)
      assert result.text =~ "interrupted"
      assert result.text =~ "hello"
    end

    test "returns message unchanged when no injections" do
      message = %{text: "hello"}
      {:ok, result} = TurnInjector.process(message, %{})
      assert result.text == "hello"
      refute Map.has_key?(result, :saturation_warned_bucket)
    end

    test "sets saturation_warned_bucket when warning fires" do
      message = %{text: "hello"}

      context = %{
        epoch: %{saturation: 72.0, last_reminder_bucket: 65}
      }

      {:ok, result} = TurnInjector.process(message, context)
      assert result[:saturation_warned_bucket] == 70
      assert result.text =~ "72%"
    end

    test "sets landscape_injected flag on fresh epoch with landscape data" do
      # Push a summary into the Landscape GenServer cache
      now = DateTime.utc_now()
      Cranium.Inference.Landscape.summary_updated("other-room", "They were discussing tests.", now)
      # Ensure the cast is processed before we read
      :sys.get_state(Cranium.Inference.Landscape)

      on_exit(fn ->
        # Clean up: remove the test entry so it doesn't leak to other tests.
        # Push an empty entry then let it be excluded by the empty-summary guard.
        # Simplest: just restart the Landscape to clear its cache.
        if pid = Process.whereis(Cranium.Inference.Landscape) do
          :sys.replace_state(pid, fn state ->
            entries = Map.delete(state.entries, "other-room")
            %{state | entries: entries}
          end)
        end
      end)

      message = %{text: "hello", is_fresh: true, conversation_id: "test-room"}
      context = %{now: now}

      {:ok, result} = TurnInjector.process(message, context)

      assert result[:landscape_injected] == true
      assert result.text =~ "<cross-room-context>"
      assert result.text =~ "hello"
    end

    test "no landscape on non-fresh epoch without time gap" do
      message = %{text: "hello", is_fresh: false, conversation_id: "test-room"}

      context = %{
        epoch: %{last_invoked_at: DateTime.utc_now()},
        now: DateTime.utc_now()
      }

      {:ok, result} = TurnInjector.process(message, context)
      refute Map.has_key?(result, :landscape_injected)
      refute result.text =~ "<cross-room-context>"
    end
  end
end
