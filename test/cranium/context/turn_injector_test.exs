defmodule Cranium.Context.TurnInjectorTest do
  use ExUnit.Case, async: true

  alias Cranium.Context.TurnInjector

  describe "build_injections/2" do
    test "returns empty list when no injections are needed" do
      message = %{text: "hello"}
      context = %{}
      assert TurnInjector.build_injections(message, context) == []
    end

    test "injects time-gap reminder after 30+ minutes" do
      now = ~U[2026-03-05 10:45:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}
      context = %{session: %{last_invoked_at: last}, now: now}

      injections = TurnInjector.build_injections(message, context)
      assert length(injections) == 1
      assert hd(injections) =~ "45 minutes"
      assert hd(injections) =~ "<system-reminder>"
    end

    test "no time-gap reminder under 30 minutes" do
      now = ~U[2026-03-05 10:20:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}
      context = %{session: %{last_invoked_at: last}, now: now}

      assert TurnInjector.build_injections(message, context) == []
    end

    test "injects saturation warning on rising edge" do
      message = %{text: "hello"}

      context = %{
        session: %{saturation: 55.0, last_reminder_bucket: 45}
      }

      injections = TurnInjector.build_injections(message, context)
      assert length(injections) == 1
      assert hd(injections) =~ "55%"
      assert hd(injections) =~ "past halfway"
    end

    test "no saturation warning when in same bucket" do
      message = %{text: "hello"}

      context = %{
        session: %{saturation: 53.0, last_reminder_bucket: 50}
      }

      assert TurnInjector.build_injections(message, context) == []
    end

    test "injects interrupted context breadcrumb" do
      message = %{text: "hello"}

      context = %{
        session: %{interrupted_context: "Was working on deploying the new service"}
      }

      injections = TurnInjector.build_injections(message, context)
      assert length(injections) == 1
      assert hd(injections) =~ "interrupted"
      assert hd(injections) =~ "deploying the new service"
    end

    test "multiple injections can fire simultaneously" do
      now = ~U[2026-03-05 11:00:00Z]
      last = ~U[2026-03-05 10:00:00Z]

      message = %{text: "hello"}

      context = %{
        session: %{
          last_invoked_at: last,
          saturation: 72.0,
          last_reminder_bucket: 65
        },
        now: now
      }

      injections = TurnInjector.build_injections(message, context)
      assert length(injections) == 2
    end
  end

  describe "process/2" do
    test "prepends injections to message text" do
      message = %{text: "hello"}

      context = %{
        session: %{interrupted_context: "fixing a bug"}
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
  end
end
