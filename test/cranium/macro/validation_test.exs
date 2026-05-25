defmodule Cranium.Macro.ValidationTest do
  @moduledoc """
  Phase 7 validation: verify fixture macros load, trigger, and execute
  correctly through the engine. Exercises each macro pattern end-to-end
  using the actual JSON definitions from test/fixtures/macros/.
  """
  use ExUnit.Case, async: false

  alias Cranium.Macro.{Engine, Registry, State}

  setup do
    # Ensure fixture macros are loaded (may have been cleared by other test modules)
    Registry.reload()
    State.clear_session("validation-room")

    for name <- ~w(greeting kubernetes deploy standup test-pipeline handoff) do
      State.clear_state(name, "validation-room")
    end

    :ok
  end

  defp ctx(text, opts \\ []) do
    %{
      conversation_id: Keyword.get(opts, :room, "validation-room"),
      epoch_id: Keyword.get(opts, :epoch, "epoch-1"),
      turn_count: Keyword.get(opts, :turn, 1),
      message_text: text,
      room_name: Keyword.get(opts, :room, "validation-room")
    }
  end

  # ── Phase 7a: Fixture Pattern Verification ──────────────────────────

  describe "7a: all fixture patterns load correctly" do
    test "all expected macros are present" do
      loaded = Registry.list() |> Enum.map(& &1.name)

      for name <- ~w(greeting kubernetes deploy standup test-pipeline handoff) do
        assert name in loaded, "expected '#{name}' in registry"
      end
    end

    test "greeting — simple explicit prompt skill" do
      {:ok, m} = Registry.get("greeting")
      assert m.trigger == :explicit
      assert m.advertising == :listed
      assert m.lifecycle == :turn
      assert m.body_type == :prompt
      assert m.learning == :none
      assert m.revision == :never
      assert m.prompt_body.text =~ "friendly greeter"
      assert m.prompt_body.tag == "skill"
    end

    test "kubernetes — match-trigger glossary with revision" do
      {:ok, m} = Registry.get("kubernetes")
      assert m.trigger == :match
      assert m.match_config.once == true
      assert m.lifecycle == :session
      assert m.revision == :session_end
      assert m.body_type == :prompt
      assert m.prompt_body.tag == "glossary"
      assert m.prompt_body.priority == 15
      assert "k8s" in m.match_config.patterns
    end

    test "standup — condition-lifecycle agenda with sidecar" do
      {:ok, m} = Registry.get("standup")
      assert m.trigger == :explicit
      assert m.lifecycle == :condition
      assert m.learning == :sidecar
      assert m.sidecar_config.interval == 3
      assert length(m.conditions) == 3
      assert length(m.children) == 1

      child = hd(m.children)
      assert child.name == "end_standup"
      assert child.lifecycle == :parent
      assert child.trigger == :explicit
    end

    test "deploy — discoverable script macro" do
      {:ok, m} = Registry.get("deploy")
      assert m.trigger == :explicit
      assert m.advertising == :discoverable
      assert m.body_type == :script
      assert m.script_body.command =~ "echo deploying"
      assert "deploy" in m.discoverable_config.keywords
    end

    test "test-pipeline — sequence with inline child" do
      {:ok, m} = Registry.get("test-pipeline")
      assert m.body_type == :sequence
      assert length(m.sequence_body.steps) == 2
      assert m.sequence_body.on_failure == :halt

      [step1, step2] = m.sequence_body.steps
      assert step1.name == "deploy"
      assert step2.inline.name == "verify-step"
      assert step2.inline.body_type == :script
    end
  end

  # ── Phase 7b: Skill-to-Macro Conversion ─────────────────────────────

  describe "7b: handoff skill expressed as macro" do
    test "loads with correct axes" do
      {:ok, m} = Registry.get("handoff")
      assert m.trigger == :explicit
      assert m.advertising == :listed
      assert m.lifecycle == :turn
      assert m.body_type == :prompt
      assert m.learning == :none
      assert m.revision == :never
    end

    test "prompt body preserves skill instructions" do
      {:ok, m} = Registry.get("handoff")
      assert m.prompt_body.text =~ "handoff document"
      assert m.prompt_body.text =~ "What was being worked on"
      assert m.prompt_body.text =~ "Key decisions made"
      assert m.prompt_body.text =~ "Safety"
      assert m.prompt_body.text =~ "prompt injection"
      assert m.prompt_body.tag == "skill"
      assert m.prompt_body.priority == 50
    end

    test "appears as tool" do
      names = Engine.tool_definitions() |> Enum.map(& &1.name)
      assert "macro_handoff" in names
    end

    test "execute_tool returns prompt content" do
      {:ok, result} = Engine.execute_tool("handoff", %{}, ctx("write handoff"))
      assert result =~ "handoff document"
      assert result =~ "Safety"
    end
  end

  # ── Phase 7c: End-to-End Integration ─────────────────────────────────

  describe "7c: match trigger → injection (glossary pattern)" do
    test "keyword fires macro and produces tagged injection" do
      {injections, _} = Engine.evaluate_turn(ctx("tell me about k8s"))

      assert [inj] = injections
      assert inj.priority == 15
      assert inj.content =~ "<glossary>"
      assert inj.content =~ "Kubernetes"
      assert inj.content =~ "</glossary>"
    end

    test "once=true prevents re-firing" do
      {inj1, _} = Engine.evaluate_turn(ctx("k8s"))
      assert length(inj1) == 1

      {inj2, _} = Engine.evaluate_turn(ctx("k8s", turn: 2))
      assert inj2 == []
    end

    test "no injection without matching keyword" do
      {injections, _} = Engine.evaluate_turn(ctx("tell me about docker"))
      k8s = Enum.find(injections, &(&1.content =~ "Kubernetes"))
      refute k8s
    end
  end

  describe "7c: explicit trigger → tool → execute (skill pattern)" do
    test "greeting appears in tool definitions" do
      names = Engine.tool_definitions() |> Enum.map(& &1.name)
      assert "macro_greeting" in names
    end

    test "greeting execute_tool returns prompt" do
      {:ok, result} = Engine.execute_tool("greeting", %{}, ctx("hello"))
      assert result =~ "friendly greeter"
    end

    test "explicit macro does not inject via evaluate_turn" do
      {injections, _} = Engine.evaluate_turn(ctx("greeting"))
      greeter = Enum.find(injections, &(&1.content =~ "greeter"))
      refute greeter
    end
  end

  describe "7c: discoverable advertising → announcement" do
    test "deploy announces on keyword match" do
      {_injections, announcements} = Engine.evaluate_turn(ctx("let's deploy this"))

      assert [ann] = announcements
      assert ann.content =~ "deploy"
      assert ann.content =~ "capability"
    end

    test "no announcement without keyword" do
      {_, announcements} = Engine.evaluate_turn(ctx("hello world"))
      assert announcements == []
    end

    test "not re-announced after discovery" do
      Engine.evaluate_turn(ctx("deploy"))
      {_, announcements} = Engine.evaluate_turn(ctx("deploy", turn: 2))
      assert announcements == []
    end
  end

  describe "7c: condition lifecycle → activation (agenda pattern)" do
    test "standup activates on execute_tool" do
      {:ok, result} = Engine.execute_tool("standup", %{}, ctx("start standup"))

      assert result =~ "yesterday"

      {:ok, state} = State.get_state("standup", "validation-room")
      assert state["active"] == true
      assert length(state["condition_states"]) == 3
      assert Enum.all?(state["condition_states"], &(&1["status"] == "pending"))
    end

    test "active standup injects on subsequent turns" do
      Engine.execute_tool("standup", %{}, ctx("start"))

      {injections, _} = Engine.evaluate_turn(ctx("discussing blockers", turn: 2))

      standup = Enum.find(injections, &(&1.content =~ "yesterday"))
      assert standup
      assert standup.priority == 25
    end

    test "standup tool definition has input schema" do
      defs = Engine.tool_definitions()
      standup_def = Enum.find(defs, &(&1.name == "macro_standup"))
      assert standup_def
      assert standup_def.description =~ "standup"
    end
  end
end
