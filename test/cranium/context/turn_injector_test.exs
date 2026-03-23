defmodule Cranium.Context.TurnInjectorTest do
  use ExUnit.Case, async: true

  alias Cranium.Context.TurnInjector

  # Stub Landscape.build to return nil by default (no cross-room data).
  # Landscape-specific tests use Mox or dedicated test module.

  describe "build_injections/2" do
    test "returns empty list when no injections are needed" do
      message = %{text: "hello"}
      context = %{}
      assert {[], false} = TurnInjector.build_injections(message, context)
    end

    test "injects time-gap reminder after 30+ minutes" do
      now = ~U[2026-03-05 10:45:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}
      context = %{epoch: %{last_invoked_at: last}, now: now}

      {injections, _landscape} = TurnInjector.build_injections(message, context)
      assert length(injections) >= 1
      assert Enum.any?(injections, &(&1 =~ "45 minutes"))
      assert Enum.any?(injections, &(&1 =~ "<system-reminder>"))
    end

    test "no time-gap reminder under 30 minutes" do
      now = ~U[2026-03-05 10:20:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}
      context = %{epoch: %{last_invoked_at: last}, now: now}

      {injections, _landscape} = TurnInjector.build_injections(message, context)
      refute Enum.any?(injections, &(&1 =~ "minutes"))
    end

    test "injects saturation warning on rising edge" do
      message = %{text: "hello"}

      context = %{
        epoch: %{saturation: 55.0, last_reminder_bucket: 45}
      }

      {injections, _landscape} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "55%"))
      assert Enum.any?(injections, &(&1 =~ "past halfway"))
    end

    test "no saturation warning when in same bucket" do
      message = %{text: "hello"}

      context = %{
        epoch: %{saturation: 53.0, last_reminder_bucket: 50}
      }

      {injections, _landscape} = TurnInjector.build_injections(message, context)
      refute Enum.any?(injections, &(&1 =~ "%"))
    end

    test "injects interrupted context breadcrumb" do
      message = %{text: "hello"}

      context = %{
        epoch: %{interrupted_context: "Was working on deploying the new service"}
      }

      {injections, _landscape} = TurnInjector.build_injections(message, context)
      assert Enum.any?(injections, &(&1 =~ "interrupted"))
      assert Enum.any?(injections, &(&1 =~ "deploying the new service"))
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

      {injections, _landscape} = TurnInjector.build_injections(message, context)
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
    end

    test "sets landscape_injected flag on fresh epoch with landscape data" do
      # Create a temp summary file so landscape has data regardless of env
      summaries_dir = Application.get_env(:cranium, :paths)[:summaries]
      summary_file = Path.join(summaries_dir, "other-room.json")

      File.write!(
        summary_file,
        Jason.encode!(%{
          "room_name" => "other-room",
          "summary" => "They were discussing tests.",
          "last_message_ts" => DateTime.to_unix(DateTime.utc_now())
        })
      )

      on_exit(fn -> File.rm(summary_file) end)

      message = %{text: "hello", is_fresh: true, conversation_id: "test-room"}
      context = %{now: DateTime.utc_now()}

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
