defmodule Cranium.Macro.EngineTest do
  use ExUnit.Case, async: false

  alias Cranium.Macro.{Engine, Definition, Registry, State}

  # --- Helpers ---

  defp make_prompt_macro(overrides \\ %{}) do
    base = %Definition{
      name: "test-prompt",
      description: "A test prompt macro",
      trigger: :match,
      match_config: %{patterns: ["kubernetes"], once: false},
      advertising: :hidden,
      lifecycle: :turn,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "K8s context here", tag: "system-reminder", priority: 50}
    }

    struct!(base, Map.to_list(overrides))
  end

  defp make_explicit_macro(overrides \\ %{}) do
    base = %Definition{
      name: "deploy",
      description: "Deploy to production",
      trigger: :explicit,
      advertising: :listed,
      lifecycle: :turn,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "Deploying %{target}", tag: nil, priority: nil}
    }

    struct!(base, Map.to_list(overrides))
  end

  defp turn_context(text, room \\ "test-room") do
    %{
      conversation_id: room,
      epoch_id: "epoch-1",
      turn_count: 1,
      message_text: text,
      room_name: room
    }
  end

  defp insert_macro(macro) do
    :ets.insert(Registry, {{:macro, macro.name}, macro})
    # Rebuild indices
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
    # Clear macros and session state between tests
    clear_registry()
    State.clear_session("test-room")
    # Clear persistent state for test macros
    for name <- ~w(test-prompt deploy k8s-helper secret-deploy secret-deploy-trigger
                    always-on condition-macro sidecar-condition) do
      State.clear_state(name, "test-room")
    end

    # Restore the fixture-loaded registry after each test so other modules
    # (RegistryTest) that depend on app-level fixtures aren't broken
    on_exit(fn ->
      try do
        Registry.reload()
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # --- evaluate_turn/1 ---

  describe "evaluate_turn/1" do
    test "returns empty when no macros loaded" do
      {injections, announcements} = Engine.evaluate_turn(turn_context("hello"))
      assert injections == []
      assert announcements == []
    end

    test "fires match-trigger macro on keyword" do
      insert_macro(make_prompt_macro())
      {injections, _} = Engine.evaluate_turn(turn_context("tell me about kubernetes"))

      assert [%{priority: 50, content: content}] = injections
      assert content =~ "K8s context here"
    end

    test "does not fire match-trigger macro without keyword" do
      insert_macro(make_prompt_macro())
      {injections, _} = Engine.evaluate_turn(turn_context("tell me about docker"))
      assert injections == []
    end

    test "fires ambient macro every turn" do
      macro =
        make_prompt_macro(%{
          name: "always-on",
          trigger: :ambient,
          match_config: nil,
          prompt_body: %{text: "Always present", tag: nil, priority: 10}
        })

      insert_macro(macro)

      {injections, _} = Engine.evaluate_turn(turn_context("anything"))
      assert [%{priority: 10, content: "Always present"}] = injections
    end

    test "skips explicit trigger macros" do
      insert_macro(make_explicit_macro())
      {injections, _} = Engine.evaluate_turn(turn_context("deploy"))
      assert injections == []
    end

    test "respects once flag" do
      macro =
        make_prompt_macro(%{
          match_config: %{patterns: ["kubernetes"], once: true}
        })

      insert_macro(macro)

      # First hit: fires
      {injections1, _} = Engine.evaluate_turn(turn_context("kubernetes"))
      assert length(injections1) == 1

      # Second hit: skipped (already seen)
      {injections2, _} = Engine.evaluate_turn(turn_context("kubernetes"))
      assert injections2 == []
    end

    test "updates session state with seen-set" do
      macro =
        make_prompt_macro(%{
          match_config: %{patterns: ["kubernetes"], once: true}
        })

      insert_macro(macro)

      Engine.evaluate_turn(turn_context("kubernetes"))

      session = State.get_session("test-room")
      assert MapSet.member?(session.seen, "test-prompt")
    end

    test "generates discovery announcements" do
      macro =
        make_prompt_macro(%{
          name: "k8s-helper",
          advertising: :discoverable,
          discoverable_config: %{keywords: ["kubernetes"]}
        })

      insert_macro(macro)

      {_injections, announcements} = Engine.evaluate_turn(turn_context("kubernetes"))

      assert [%{priority: 45, content: content}] = announcements
      assert content =~ "k8s-helper"
      assert content =~ "system-reminder"
    end

    test "does not re-announce already discovered macros" do
      macro =
        make_prompt_macro(%{
          name: "k8s-helper",
          advertising: :discoverable,
          discoverable_config: %{keywords: ["kubernetes"]}
        })

      insert_macro(macro)

      # First: discovers
      {_, announcements1} = Engine.evaluate_turn(turn_context("kubernetes"))
      assert length(announcements1) == 1

      # Second: already discovered
      {_, announcements2} = Engine.evaluate_turn(turn_context("kubernetes"))
      assert announcements2 == []
    end

    test "template variables resolved from context" do
      macro =
        make_prompt_macro(%{
          prompt_body: %{
            text: "Turn %{turn_count} in room %{room_name}",
            tag: nil,
            priority: 50
          }
        })

      insert_macro(macro)

      {injections, _} = Engine.evaluate_turn(turn_context("kubernetes"))
      assert [%{content: "Turn 1 in room test-room"}] = injections
    end
  end

  # --- execute_tool/3 ---

  describe "execute_tool/3" do
    test "executes explicit macro as tool" do
      insert_macro(make_explicit_macro())

      context = turn_context("deploy")
      result = Engine.execute_tool("deploy", %{"target" => "staging"}, context)

      assert {:ok, "Deploying staging"} = result
    end

    test "returns error for unknown macro" do
      result = Engine.execute_tool("nonexistent", %{}, turn_context(""))
      assert {:error, "macro 'nonexistent' not found"} = result
    end
  end

  # --- tool_definitions/0 ---

  describe "tool_definitions/0" do
    test "returns tool defs for explicit listed macros" do
      insert_macro(make_explicit_macro())

      defs = Engine.tool_definitions()
      assert [%{name: "macro_deploy", description: "Deploy to production"} | _] = defs
    end

    test "excludes hidden macros" do
      insert_macro(make_explicit_macro(%{advertising: :hidden}))

      defs = Engine.tool_definitions()
      assert defs == []
    end

    test "excludes non-explicit trigger macros" do
      insert_macro(make_prompt_macro(%{advertising: :listed}))

      defs = Engine.tool_definitions()
      assert defs == []
    end

    test "includes declared child tools" do
      macro =
        make_explicit_macro(%{
          tools: [
            %{
              name: "status",
              description: "Check deploy status",
              input_schema: %{},
              handler: :script
            }
          ]
        })

      insert_macro(macro)

      defs = Engine.tool_definitions()
      names = Enum.map(defs, & &1.name)
      assert "macro_deploy" in names
      assert "macro_deploy_status" in names
    end

    test "extracts template variables as input schema properties" do
      macro =
        make_explicit_macro(%{
          prompt_body: %{text: "Deploy %{target} to %{environment}", tag: nil, priority: nil}
        })

      insert_macro(macro)

      [main_def | _] = Engine.tool_definitions()
      props = main_def.input_schema.properties
      assert Map.has_key?(props, "target")
      assert Map.has_key?(props, "environment")
    end
  end

  # --- tool_definitions_for_room/1 ---

  describe "tool_definitions_for_room/1" do
    test "always includes listed macros" do
      insert_macro(make_explicit_macro())

      defs = Engine.tool_definitions_for_room("test-room")
      assert length(defs) > 0
    end

    test "includes discoverable macros only after discovery" do
      macro =
        make_explicit_macro(%{
          name: "secret-deploy",
          advertising: :discoverable,
          discoverable_config: %{keywords: ["deploy"]}
        })

      insert_macro(macro)

      # Before discovery
      defs_before = Engine.tool_definitions_for_room("test-room")
      assert defs_before == []

      # Discover it via trigger evaluation
      match_macro =
        make_prompt_macro(%{
          name: "secret-deploy-trigger",
          trigger: :match,
          match_config: %{patterns: ["deploy"], once: false},
          advertising: :discoverable,
          discoverable_config: %{keywords: ["deploy"]}
        })

      insert_macro(match_macro)
      Engine.evaluate_turn(turn_context("deploy"))

      # After discovery — the explicit one should now appear
      # (We need to put the discovered name in the session)
      session = State.get_session("test-room")
      updated_session = %{session | discovered: MapSet.put(session.discovered, "secret-deploy")}
      State.put_session("test-room", updated_session)

      defs_after = Engine.tool_definitions_for_room("test-room")
      names = Enum.map(defs_after, & &1.name)
      assert "macro_secret_deploy" in names
    end
  end

  # --- macro_tool?/1 ---

  describe "macro_tool?/1" do
    test "returns true for registered macro tool" do
      insert_macro(make_explicit_macro())
      assert Engine.macro_tool?("macro_deploy")
    end

    test "returns false for non-macro tool" do
      refute Engine.macro_tool?("clear_context")
    end

    test "returns false for macro_ prefix with no matching macro" do
      refute Engine.macro_tool?("macro_nonexistent")
    end
  end

  # --- Phase 6: Activation ---

  defp make_condition_macro(overrides \\ %{}) do
    base = %Definition{
      name: "condition-macro",
      description: "A condition-lifecycle macro",
      trigger: :match,
      match_config: %{patterns: ["activate"], once: false},
      advertising: :hidden,
      lifecycle: :condition,
      learning: :none,
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "Condition macro active", tag: nil, priority: 30},
      conditions: [
        %{description: "User did A", section: nil},
        %{description: "User did B", section: nil}
      ]
    }

    struct!(base, Map.to_list(overrides))
  end

  defp make_sidecar_condition_macro(overrides \\ %{}) do
    base = %Definition{
      name: "sidecar-condition",
      description: "A condition macro with sidecar learning",
      trigger: :match,
      match_config: %{patterns: ["learn"], once: false},
      advertising: :hidden,
      lifecycle: :condition,
      learning: :sidecar,
      sidecar_config: %{model: nil, interval: 2, prompt: "Check: %{conditions}\n%{lookback}"},
      revision: :never,
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "Learning macro active", tag: nil, priority: 30},
      conditions: [
        %{description: "Condition X", section: nil},
        %{description: "Condition Y", section: nil}
      ]
    }

    struct!(base, Map.to_list(overrides))
  end

  describe "condition macro activation" do
    setup do
      State.clear_session("test-room")
      Cranium.Macro.Sidecar.reset("condition-macro", "test-room")
      Cranium.Macro.Sidecar.reset("sidecar-condition", "test-room")
      :ok
    end

    test "activates condition macro on first trigger match" do
      insert_macro(make_condition_macro())

      {injections, _} = Engine.evaluate_turn(turn_context("let's activate"))

      # Should inject the body
      assert [%{priority: 30, content: "Condition macro active"}] = injections

      # Should be active in state
      {:ok, state} = State.get_state("condition-macro", "test-room")
      assert state["active"] == true
      assert state["activated_at_turn"] == 1
      assert length(state["condition_states"]) == 2
      assert Enum.all?(state["condition_states"], &(&1["status"] == "pending"))
    end

    test "active condition macro injects on every turn" do
      insert_macro(make_condition_macro())

      # Activate
      Engine.evaluate_turn(turn_context("activate"))

      # Subsequent turn without trigger keyword — still injects because active
      {injections, _} =
        Engine.evaluate_turn(%{
          conversation_id: "test-room",
          epoch_id: "epoch-1",
          turn_count: 2,
          message_text: "something else entirely",
          room_name: "test-room"
        })

      assert [%{priority: 30, content: "Condition macro active"}] = injections
    end

    test "does not re-activate already active macro" do
      insert_macro(make_condition_macro())

      # Activate
      Engine.evaluate_turn(turn_context("activate"))

      # Trigger again — should not reset condition states
      State.put_state("condition-macro", "test-room", %{
        "active" => true,
        "activated_at_turn" => 1,
        "condition_states" => [
          %{"index" => 0, "status" => "complete"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      Engine.evaluate_turn(%{
        conversation_id: "test-room",
        epoch_id: "epoch-1",
        turn_count: 5,
        message_text: "activate again",
        room_name: "test-room"
      })

      # Condition states should NOT be reset
      {:ok, state} = State.get_state("condition-macro", "test-room")
      assert Enum.find(state["condition_states"], &(&1["index"] == 0))["status"] == "complete"
    end
  end

  # --- Phase 6: Auto-Close ---

  describe "auto-close" do
    setup do
      State.clear_session("test-room")
      Cranium.Macro.Sidecar.reset("sidecar-condition", "test-room")
      :ok
    end

    test "auto-closes when all conditions complete via sidecar" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      # Set up active state
      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "pending"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      # Simulate sidecar completing both conditions
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{"test-room", "sidecar-condition"}, %{in_flight: false, result: [0, 1]}}
      )

      # evaluate_turn should consume results and auto-close
      {injections, _} =
        Engine.evaluate_turn(%{
          conversation_id: "test-room",
          epoch_id: "epoch-1",
          turn_count: 5,
          message_text: "anything",
          room_name: "test-room"
        })

      # Should have completion injection
      completion = Enum.find(injections, &(&1.content =~ "completed"))
      assert completion
      assert completion.content =~ "sidecar-condition"
      assert completion.content =~ "2 completed"

      # Macro should be deactivated
      {:ok, state} = State.get_state("sidecar-condition", "test-room")
      refute state["active"]
    end

    test "does not auto-close when pending conditions remain" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      # Active with one complete, one pending
      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "complete"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      {injections, _} =
        Engine.evaluate_turn(%{
          conversation_id: "test-room",
          epoch_id: "epoch-1",
          turn_count: 5,
          message_text: "anything",
          room_name: "test-room"
        })

      # No completion injection
      completion = Enum.find(injections, &(Map.get(&1, :content, "") =~ "completed"))
      refute completion

      # Still active
      {:ok, state} = State.get_state("sidecar-condition", "test-room")
      assert state["active"]
    end

    test "auto-closes when all conditions are skipped" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "skipped"},
          %{"index" => 1, "status" => "skipped"}
        ]
      })

      {injections, _} =
        Engine.evaluate_turn(%{
          conversation_id: "test-room",
          epoch_id: "epoch-1",
          turn_count: 5,
          message_text: "anything",
          room_name: "test-room"
        })

      completion = Enum.find(injections, &(Map.get(&1, :content, "") =~ "completed"))
      assert completion
      assert completion.content =~ "2 skipped"

      {:ok, state} = State.get_state("sidecar-condition", "test-room")
      refute state["active"]
    end

    test "auto-closes on mix of complete and skipped" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "complete"},
          %{"index" => 1, "status" => "skipped"}
        ]
      })

      {injections, _} =
        Engine.evaluate_turn(%{
          conversation_id: "test-room",
          epoch_id: "epoch-1",
          turn_count: 5,
          message_text: "anything",
          room_name: "test-room"
        })

      completion = Enum.find(injections, &(Map.get(&1, :content, "") =~ "completed"))
      assert completion
      assert completion.content =~ "1 completed"
      assert completion.content =~ "1 skipped"
    end
  end

  # --- Phase 6: Sidecar Result Consumption ---

  describe "sidecar result consumption" do
    setup do
      State.clear_session("test-room")
      Cranium.Macro.Sidecar.reset("sidecar-condition", "test-room")
      :ok
    end

    test "applies sidecar completions to condition states" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "pending"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      # Sidecar completed index 0
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{"test-room", "sidecar-condition"}, %{in_flight: false, result: [0]}}
      )

      Engine.evaluate_turn(%{
        conversation_id: "test-room",
        epoch_id: "epoch-1",
        turn_count: 5,
        message_text: "anything",
        room_name: "test-room"
      })

      {:ok, state} = State.get_state("sidecar-condition", "test-room")
      cs = state["condition_states"]
      assert Enum.find(cs, &(&1["index"] == 0))["status"] == "complete"
      assert Enum.find(cs, &(&1["index"] == 1))["status"] == "pending"
    end

    test "updates eval tracking after consumption" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "pending"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      :ets.insert(
        Cranium.Macro.Sidecar,
        {{"test-room", "sidecar-condition"}, %{in_flight: false, result: []}}
      )

      Engine.evaluate_turn(%{
        conversation_id: "test-room",
        epoch_id: "epoch-1",
        turn_count: 7,
        message_text: "anything",
        room_name: "test-room"
      })

      {:ok, state} = State.get_state("sidecar-condition", "test-room")
      assert state["last_eval_turn"] == 7
    end

    test "sidecar can promote skipped conditions to complete" do
      macro = make_sidecar_condition_macro()
      insert_macro(macro)

      State.put_state("sidecar-condition", "test-room", %{
        "active" => true,
        "activated_at_turn" => 0,
        "condition_states" => [
          %{"index" => 0, "status" => "skipped"},
          %{"index" => 1, "status" => "pending"}
        ]
      })

      # Sidecar completes the skipped condition
      :ets.insert(
        Cranium.Macro.Sidecar,
        {{"test-room", "sidecar-condition"}, %{in_flight: false, result: [0]}}
      )

      Engine.evaluate_turn(%{
        conversation_id: "test-room",
        epoch_id: "epoch-1",
        turn_count: 5,
        message_text: "anything",
        room_name: "test-room"
      })

      {:ok, state} = State.get_state("sidecar-condition", "test-room")
      assert Enum.find(state["condition_states"], &(&1["index"] == 0))["status"] == "complete"
    end
  end

  # --- Phase 6: after_pass ---

  describe "after_pass/1" do
    setup do
      Cranium.Macro.Sidecar.reset("sidecar-condition", "test-room")
      :ok
    end

    test "does not crash when no macros loaded" do
      assert :ok = Engine.after_pass(turn_context("test"))
    end

    test "skips non-sidecar macros" do
      insert_macro(make_condition_macro())
      assert :ok = Engine.after_pass(turn_context("test"))
    end

    test "skips inactive sidecar macros" do
      insert_macro(make_sidecar_condition_macro())

      # Not active — no dispatch
      assert :ok = Engine.after_pass(turn_context("test"))
      refute Cranium.Macro.Sidecar.in_flight?("sidecar-condition", "test-room")
    end
  end

  # --- Phase 6: on_epoch_end ---

  describe "on_epoch_end/1" do
    test "does not crash when no macros loaded" do
      assert :ok =
               Engine.on_epoch_end(%{
                 conversation_id: "test-room",
                 epoch_id: "epoch-1",
                 messages: []
               })
    end

    test "skips non-revision macros" do
      insert_macro(make_condition_macro())

      assert :ok =
               Engine.on_epoch_end(%{
                 conversation_id: "test-room",
                 epoch_id: "epoch-1",
                 messages: []
               })
    end
  end
end
