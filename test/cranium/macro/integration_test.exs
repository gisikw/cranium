defmodule Cranium.Macro.IntegrationTest do
  @moduledoc """
  Integration tests verifying macro engine wiring into TurnInjector and ToolRouter.
  """
  use ExUnit.Case, async: false

  alias Cranium.Macro.{Definition, Registry, State}
  alias Cranium.Context.TurnInjector
  alias Cranium.Inference.Agent.ToolRouter

  # --- Helpers ---

  defp make_macro(overrides \\ %{}) do
    base = %Definition{
      name: "test-macro",
      description: "Test macro",
      trigger: :match,
      match_config: %{patterns: ["kubernetes"], once: false},
      advertising: :hidden,
      lifecycle: :turn,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "K8s context", tag: "system-reminder", priority: 50}
    }

    struct!(base, Map.to_list(overrides))
  end

  defp insert_macro(macro) do
    :ets.insert(Registry, {{:macro, macro.name}, macro})
    rebuild_registry_indices()
  end

  defp rebuild_registry_indices do
    macros =
      :ets.match_object(Registry, {{:macro, :_}, :_})
      |> Enum.map(fn {_key, definition} -> definition end)

    trigger_groups = Enum.group_by(macros, & &1.trigger)

    for trigger <- [:explicit, :match, :ambient, :passive] do
      names = trigger_groups |> Map.get(trigger, []) |> Enum.map(& &1.name)
      :ets.insert(Registry, {{:trigger_index, trigger}, names})
    end

    ad_groups = Enum.group_by(macros, & &1.advertising)

    for advertising <- [:listed, :discoverable, :searchable, :hidden] do
      names = ad_groups |> Map.get(advertising, []) |> Enum.map(& &1.name)
      :ets.insert(Registry, {{:advertising_index, advertising}, names})
    end

    unique_count = :ets.match(Registry, {{:macro, :_}, :_}) |> length()
    :ets.insert(Registry, {:count, unique_count})
  end

  defp clear_registry do
    :ets.match_delete(Registry, {{:macro, :_}, :_})
    rebuild_registry_indices()
  end

  setup do
    clear_registry()
    State.clear_session("test-room")
    :ok
  end

  # --- TurnInjector integration ---

  describe "TurnInjector with macro injections" do
    test "macro injection appears in turn prefix at correct priority" do
      insert_macro(make_macro())

      # Simulate what TurnAssembler does: evaluate macros, then pass to TurnInjector
      turn_context = %{
        conversation_id: "test-room",
        epoch_id: "epoch-1",
        turn_count: 1,
        message_text: "tell me about kubernetes",
        room_name: "test-room"
      }

      {macro_injections, macro_announcements} = Cranium.Macro.Engine.evaluate_turn(turn_context)
      all_injections = macro_injections ++ macro_announcements

      message = %{text: "tell me about kubernetes", conversation_id: "test-room"}

      context = %{
        now: DateTime.utc_now(),
        epoch: %{
          last_invoked_at: nil,
          saturation: 0,
          last_reminder_bucket: 0,
          last_landscape_at: nil,
          interrupted_context: nil
        }
      }

      {:ok, injected} = TurnInjector.process(message, context, all_injections)
      assert injected.text =~ "K8s context"
    end

    test "macro injection respects priority ordering" do
      # Low priority macro
      insert_macro(make_macro(%{
        name: "low-priority",
        prompt_body: %{text: "LOW", tag: nil, priority: 5}
      }))

      # High priority macro
      insert_macro(make_macro(%{
        name: "high-priority",
        match_config: %{patterns: ["kubernetes"], once: false},
        prompt_body: %{text: "HIGH", tag: nil, priority: 60}
      }))

      turn_context = %{
        conversation_id: "test-room",
        epoch_id: "epoch-1",
        turn_count: 1,
        message_text: "kubernetes",
        room_name: "test-room"
      }

      {macro_injections, _} = Cranium.Macro.Engine.evaluate_turn(turn_context)

      message = %{text: "kubernetes"}

      context = %{
        now: DateTime.utc_now(),
        epoch: %{
          last_invoked_at: nil,
          saturation: 0,
          last_reminder_bucket: 0,
          last_landscape_at: nil,
          interrupted_context: nil
        }
      }

      {:ok, injected} = TurnInjector.process(message, context, macro_injections)
      text = injected.text

      # LOW (priority 5) should appear before HIGH (priority 60)
      low_pos = :binary.match(text, "LOW") |> elem(0)
      high_pos = :binary.match(text, "HIGH") |> elem(0)
      assert low_pos < high_pos
    end
  end

  # --- ToolRouter integration ---

  describe "ToolRouter with macro tools" do
    test "explicit listed macro appears in tool definitions" do
      insert_macro(make_macro(%{
        name: "deploy",
        trigger: :explicit,
        match_config: nil,
        advertising: :listed,
        description: "Deploy to production"
      }))

      defs = ToolRouter.tool_definitions("test-room")
      names = Enum.map(defs, & &1.name)
      assert "macro_deploy" in names
    end

    test "macro tool call routes to :macro" do
      insert_macro(make_macro(%{
        name: "deploy",
        trigger: :explicit,
        match_config: nil,
        advertising: :listed
      }))

      tool_call = %{name: "macro_deploy", input: %{"target" => "staging"}}
      result = ToolRouter.route(tool_call, "test-room")

      assert {:macro, "macro_deploy", %{"target" => "staging"}} = result
    end

    test "search_macros tool appears when searchable macros exist" do
      insert_macro(make_macro(%{
        name: "searchable-macro",
        advertising: :searchable
      }))

      defs = ToolRouter.tool_definitions("test-room")
      names = Enum.map(defs, & &1.name)
      assert "search_macros" in names
    end

    test "search_macros tool does not appear when no searchable macros" do
      insert_macro(make_macro(%{advertising: :hidden}))

      defs = ToolRouter.tool_definitions("test-room")
      names = Enum.map(defs, & &1.name)
      refute "search_macros" in names
    end

    test "search_macros routes to :macro" do
      tool_call = %{name: "search_macros", input: %{"query" => "deploy"}}
      result = ToolRouter.route(tool_call, "test-room")

      assert {:macro, "search_macros", %{"query" => "deploy"}} = result
    end

    test "non-macro tool does not route to :macro" do
      tool_call = %{name: "clear_context", input: %{}}
      result = ToolRouter.route(tool_call, "test-room")

      assert {:clear, _} = result
    end
  end
end
