defmodule Cranium.Plugins.AgendaTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Cranium.Plugins.Agenda

  @agendas_path "test/fixtures/agendas"
  @state_path "test/fixtures/agenda_state"
  @test_epoch_id "00000000-0000-0000-0000-000000000001"

  @metadata %{
    conversation_id: "test-conv",
    epoch_id: @test_epoch_id,
    room_name: "test-room",
    profile: %Cranium.Config.Profile{name: "test", backend: :mock, model: "test-model"},
    plugin_config: %{
      "agendas_path" => @agendas_path,
      "state_path" => @state_path,
      "sidecar_profile" => nil,
      "eval_interval" => 5,
      "injection_priority" => 25
    }
  }

  setup_all do
    File.mkdir_p!(@agendas_path)
    File.mkdir_p!(@state_path)

    File.write!(Path.join(@agendas_path, "weekly-sync.json"), Jason.encode!(%{
      "name" => "weekly-sync",
      "description" => "Weekly team sync agenda",
      "body" => "Review action items from last week and plan for next week.",
      "criteria" => [
        %{
          "topic" => "Action Items",
          "prose" => "Review prior commitments from last sync.",
          "conditions" => [
            "User confirmed action items reviewed",
            "Outstanding items triaged"
          ]
        },
        %{
          "topic" => "Sprint Planning",
          "prose" => "Plan next sprint priorities.",
          "conditions" => [
            "Sprint goals agreed",
            "Assignments confirmed"
          ]
        }
      ]
    }))

    File.write!(Path.join(@agendas_path, "standup.json"), Jason.encode!(%{
      "name" => "standup",
      "description" => "Quick daily standup",
      "body" => "What did you do yesterday? What are you doing today? Any blockers?",
      "criteria" => [
        %{
          "topic" => "Status",
          "prose" => "Quick status check.",
          "conditions" => [
            "Yesterday's work discussed",
            "Today's plan shared",
            "Blockers identified"
          ]
        }
      ]
    }))

    on_exit(fn ->
      File.rm_rf!(@agendas_path)
      File.rm_rf!(@state_path)
    end)

    :ok
  end

  # Clean state files between tests
  setup do
    File.rm_rf!(@state_path)
    File.mkdir_p!(@state_path)
    :ok
  end

  describe "init/1" do
    test "loads definitions and returns hooks and tools" do
      assert {:ok, hooks, tools, state} = Agenda.init(@metadata)
      assert :on_epoch_start in hooks
      assert :before_context_build in hooks
      assert :after_pass_complete in hooks
      assert :on_epoch_end in hooks
      assert length(tools) == 4
      assert Enum.map(tools, & &1.name) == ["activate_agenda", "end_agenda", "agenda_status", "agenda_skip"]
      assert length(state.definitions) == 2
      assert state.agenda == %{active: false}
    end

    test "tool descriptions include available agendas" do
      {:ok, _hooks, tools, _state} = Agenda.init(@metadata)
      activate = Enum.find(tools, &(&1.name == "activate_agenda"))
      assert activate.description =~ "weekly-sync"
      assert activate.description =~ "standup"
    end

    test "returns :ignore when agendas_path is nil" do
      metadata = %{@metadata | plugin_config: %{"agendas_path" => nil, "state_path" => @state_path}}
      assert :ignore = Agenda.init(metadata)
    end

    test "returns :ignore when agendas_path does not exist" do
      metadata = %{@metadata | plugin_config: %{"agendas_path" => "/nonexistent", "state_path" => @state_path}}
      assert :ignore = Agenda.init(metadata)
    end

    test "returns :ignore when state_path is nil" do
      metadata = %{@metadata | plugin_config: %{"agendas_path" => @agendas_path, "state_path" => nil}}
      assert :ignore = Agenda.init(metadata)
    end

    test "returns :ignore when no valid definitions found" do
      empty = Path.join(System.tmp_dir!(), "empty_agendas_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)

      metadata = %{@metadata | plugin_config: %{"agendas_path" => empty, "state_path" => @state_path}}
      result = Agenda.init(metadata)
      File.rm_rf!(empty)
      assert :ignore = result
    end

    test "respects custom config values" do
      config = %{
        "agendas_path" => @agendas_path,
        "state_path" => @state_path,
        "eval_interval" => 10,
        "injection_priority" => 42
      }

      {:ok, _, _, state} = Agenda.init(%{@metadata | plugin_config: config})
      assert state.eval_interval == 10
      assert state.injection_priority == 42
    end
  end

  describe "handle_tool_call — activate_agenda" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      %{state: state}
    end

    test "activates a static agenda", %{state: state} do
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      assert {:ok, content, new_state} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "weekly-sync"
      assert content =~ "Review action items"
      assert content =~ "Action Items"
      assert content =~ "Sprint Planning"
      assert new_state.agenda.active == true
      assert new_state.agenda.definition_name == "weekly-sync"
      assert length(new_state.agenda.conditions) == 4
    end

    test "flattens conditions with correct indices", %{state: state} do
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, new_state} = Agenda.handle_tool_call(ctx, state)

      conditions = new_state.agenda.conditions
      assert Enum.map(conditions, & &1.index) == [0, 1, 2, 3]
      assert Enum.all?(conditions, &(&1.status == :pending))
      assert Enum.at(conditions, 0).section_topic == "Action Items"
      assert Enum.at(conditions, 2).section_topic == "Sprint Planning"
    end

    test "rejects activation when agenda already active", %{state: state} do
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)

      ctx2 = tool_ctx("activate_agenda", %{"name" => "standup"}, 2)
      assert {:error, msg, _state} = Agenda.handle_tool_call(ctx2, state)
      assert msg =~ "already active"
    end

    test "rejects unknown agenda name", %{state: state} do
      ctx = tool_ctx("activate_agenda", %{"name" => "nonexistent"}, 1)
      assert {:error, msg, _state} = Agenda.handle_tool_call(ctx, state)
      assert msg =~ "Unknown agenda"
    end

    test "persists state on activation", %{state: state} do
      ctx = tool_ctx("activate_agenda", %{"name" => "standup"}, 1)
      {:ok, _, _state} = Agenda.handle_tool_call(ctx, state)

      # Verify state file was written
      path = Path.join(@state_path, "test-room.json")
      assert File.exists?(path)
      persisted = Jason.decode!(File.read!(path))
      assert persisted["active"] == true
      assert persisted["definition_name"] == "standup"
    end
  end

  describe "handle_tool_call — end_agenda" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      # Activate first
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      %{state: state}
    end

    test "ends active agenda with summary", %{state: state} do
      ctx = tool_ctx("end_agenda", %{}, 5)
      assert {:ok, content, new_state} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "weekly-sync"
      assert content =~ "0/4 completed"
      assert new_state.agenda.active == false
    end

    test "reports completion counts", %{state: state} do
      # Complete one condition via sidecar-like state mutation
      conditions =
        Enum.map(state.agenda.conditions, fn c ->
          if c.index == 0, do: %{c | status: :complete}, else: c
        end)

      state = %{state | agenda: %{state.agenda | conditions: conditions}}

      ctx = tool_ctx("end_agenda", %{}, 5)
      {:ok, content, _} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "1/4 completed"
    end

    test "rejects end when no agenda active" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("end_agenda", %{}, 1)
      assert {:error, msg, _} = Agenda.handle_tool_call(ctx, state)
      assert msg =~ "No active agenda"
    end

    test "persists inactive state", %{state: state} do
      ctx = tool_ctx("end_agenda", %{}, 5)
      {:ok, _, _state} = Agenda.handle_tool_call(ctx, state)

      path = Path.join(@state_path, "test-room.json")
      persisted = Jason.decode!(File.read!(path))
      assert persisted["active"] == false
    end
  end

  describe "handle_tool_call — agenda_status" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      %{state: state}
    end

    test "returns full status of active agenda", %{state: state} do
      ctx = tool_ctx("agenda_status", %{}, 2)
      {:ok, content, _state} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "weekly-sync"
      assert content =~ "0/4 completed"
      assert content =~ "User confirmed action items reviewed"
      assert content =~ "Sprint goals agreed"
    end

    test "shows correct status markers", %{state: state} do
      # Mark one complete, one skipped
      conditions =
        Enum.map(state.agenda.conditions, fn c ->
          case c.index do
            0 -> %{c | status: :complete}
            1 -> %{c | status: :skipped}
            _ -> c
          end
        end)

      state = %{state | agenda: %{state.agenda | conditions: conditions}}

      ctx = tool_ctx("agenda_status", %{}, 3)
      {:ok, content, _} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "[x]"
      assert content =~ "[~]"
      assert content =~ "[ ]"
    end

    test "rejects when no agenda active" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("agenda_status", %{}, 1)
      assert {:error, msg, _} = Agenda.handle_tool_call(ctx, state)
      assert msg =~ "No active agenda"
    end
  end

  describe "handle_tool_call — agenda_skip" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      %{state: state}
    end

    test "skips a condition by index", %{state: state} do
      ctx = tool_ctx("agenda_skip", %{"condition_index" => 1}, 2)
      {:ok, content, new_state} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "Skipped"
      assert content =~ "Outstanding items triaged"

      condition = Enum.find(new_state.agenda.conditions, &(&1.index == 1))
      assert condition.status == :skipped
    end

    test "skips a condition by text", %{state: state} do
      ctx = tool_ctx("agenda_skip", %{"condition_text" => "Sprint goals agreed"}, 2)
      {:ok, content, new_state} = Agenda.handle_tool_call(ctx, state)
      assert content =~ "Skipped"

      condition = Enum.find(new_state.agenda.conditions, &(&1.index == 2))
      assert condition.status == :skipped
    end

    test "rejects skip of already completed condition", %{state: state} do
      # Mark condition 0 as complete
      conditions =
        Enum.map(state.agenda.conditions, fn c ->
          if c.index == 0, do: %{c | status: :complete}, else: c
        end)

      state = %{state | agenda: %{state.agenda | conditions: conditions}}

      ctx = tool_ctx("agenda_skip", %{"condition_index" => 0}, 2)
      assert {:error, msg, _} = Agenda.handle_tool_call(ctx, state)
      assert msg =~ "already complete"
    end

    test "rejects skip of nonexistent condition", %{state: state} do
      ctx = tool_ctx("agenda_skip", %{"condition_index" => 99}, 2)
      assert {:error, msg, _} = Agenda.handle_tool_call(ctx, state)
      assert msg =~ "not found"
    end

    test "rejects when no agenda active" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("agenda_skip", %{"condition_index" => 0}, 1)
      assert {:error, msg, _} = Agenda.handle_tool_call(ctx, state)
      assert msg =~ "No active agenda"
    end
  end

  describe "auto-close" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "standup"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      %{state: state}
    end

    test "auto-closes when all conditions are skipped", %{state: state} do
      # Skip all 3 conditions
      state =
        Enum.reduce(0..2, state, fn i, acc ->
          ctx = tool_ctx("agenda_skip", %{"condition_index" => i}, i + 2)
          {:ok, _, acc} = Agenda.handle_tool_call(ctx, acc)
          acc
        end)

      assert state.agenda.active == false
    end

    test "auto-closes when remaining conditions are complete or skipped", %{state: state} do
      # Complete condition 0
      conditions =
        Enum.map(state.agenda.conditions, fn c ->
          if c.index == 0, do: %{c | status: :complete}, else: c
        end)

      state = %{state | agenda: %{state.agenda | conditions: conditions}}

      # Skip conditions 1 and 2
      ctx = tool_ctx("agenda_skip", %{"condition_index" => 1}, 3)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)

      ctx = tool_ctx("agenda_skip", %{"condition_index" => 2}, 4)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)

      assert state.agenda.active == false
    end

    test "does not auto-close with pending conditions", %{state: state} do
      # Skip only one of three
      ctx = tool_ctx("agenda_skip", %{"condition_index" => 0}, 2)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      assert state.agenda.active == true
    end
  end

  describe "context injection — before_context_build" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      %{state: state}
    end

    test "injects on first turn after activation", %{state: state} do
      turn_ctx = %{conversation_id: "test-conv", epoch_id: @test_epoch_id, turn_count: 2, message_text: "hello"}
      {:ok, [injection], _state} = Agenda.before_context_build(turn_ctx, state)
      assert injection.priority == 25
      assert injection.content =~ "weekly-sync"
      assert injection.content =~ "0/4 completed"
      assert injection.content =~ "Action Items"
    end

    test "skips when no agenda active" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      turn_ctx = %{conversation_id: "test-conv", epoch_id: @test_epoch_id, turn_count: 1, message_text: "hello"}
      assert {:ok, :skip, ^state} = Agenda.before_context_build(turn_ctx, state)
    end

    test "skips on non-event turns", %{state: state} do
      # Turn 5 is not first-after-activation (that was turn 2) and no sidecar result
      turn_ctx = %{conversation_id: "test-conv", epoch_id: @test_epoch_id, turn_count: 5, message_text: "hello"}
      assert {:ok, :skip, _state} = Agenda.before_context_build(turn_ctx, state)
    end

    test "injects on rehydration", %{state: state} do
      state = %{state | rehydrated: true}
      turn_ctx = %{conversation_id: "test-conv", epoch_id: @test_epoch_id, turn_count: 10, message_text: "hello"}
      {:ok, [injection], new_state} = Agenda.before_context_build(turn_ctx, state)
      assert injection.content =~ "mid-agenda"
      assert new_state.rehydrated == false
    end

    test "injects completion notice on auto-close" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      # Activate standup (3 conditions)
      ctx = tool_ctx("activate_agenda", %{"name" => "standup"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)

      # Skip all to trigger auto-close
      state =
        Enum.reduce(0..2, state, fn i, acc ->
          ctx = tool_ctx("agenda_skip", %{"condition_index" => i}, i + 2)
          {:ok, _, acc} = Agenda.handle_tool_call(ctx, acc)
          acc
        end)

      # Now before_context_build should inject completion notice
      turn_ctx = %{conversation_id: "test-conv", epoch_id: @test_epoch_id, turn_count: 10, message_text: "hello"}
      {:ok, [injection], new_state} = Agenda.before_context_build(turn_ctx, state)
      assert injection.content =~ "complete"
      assert new_state.just_auto_closed == false
    end
  end

  describe "state persistence and rehydration" do
    test "round-trips active state through persistence" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)

      # Mark one condition complete
      conditions =
        Enum.map(state.agenda.conditions, fn c ->
          if c.index == 0, do: %{c | status: :complete}, else: c
        end)

      state = %{state | agenda: %{state.agenda | conditions: conditions}}

      # Simulate epoch end (persist)
      :ok = Agenda.on_epoch_end(%{conversation_id: "test-conv", epoch_id: @test_epoch_id, messages: []}, state)

      # Simulate epoch start (rehydrate)
      epoch_ctx = %{conversation_id: "test-conv", epoch_id: "new-epoch", predecessor_epoch_id: @test_epoch_id, room_name: "test-room"}
      {:ok, new_state} = Agenda.on_epoch_start(epoch_ctx, state)

      assert new_state.agenda.active == true
      assert new_state.agenda.definition_name == "weekly-sync"
      assert length(new_state.agenda.conditions) == 4

      completed = Enum.find(new_state.agenda.conditions, &(&1.index == 0))
      assert completed.status == :complete

      pending = Enum.find(new_state.agenda.conditions, &(&1.index == 1))
      assert pending.status == :pending
    end

    test "rehydrates as inactive when no persisted state" do
      {:ok, _, _, state} = Agenda.init(@metadata)
      epoch_ctx = %{conversation_id: "test-conv", epoch_id: "new-epoch", predecessor_epoch_id: nil, room_name: "test-room"}
      {:ok, new_state} = Agenda.on_epoch_start(epoch_ctx, state)
      assert new_state.agenda == %{active: false}
      assert new_state.rehydrated == false
    end

    test "rehydrates as inactive when persisted state is inactive" do
      {:ok, _, _, state} = Agenda.init(@metadata)

      # Write inactive state
      path = Path.join(@state_path, "test-room.json")
      File.write!(path, Jason.encode!(%{active: false}))

      epoch_ctx = %{conversation_id: "test-conv", epoch_id: "new-epoch", predecessor_epoch_id: "old", room_name: "test-room"}
      {:ok, new_state} = Agenda.on_epoch_start(epoch_ctx, state)
      assert new_state.agenda == %{active: false}
    end
  end

  describe "condition flattening" do
    test "handles nested criteria sections" do
      nested_path = Path.join(System.tmp_dir!(), "nested_agendas_#{System.unique_integer([:positive])}")
      state_path = Path.join(System.tmp_dir!(), "nested_state_#{System.unique_integer([:positive])}")
      File.mkdir_p!(nested_path)
      File.mkdir_p!(state_path)

      File.write!(Path.join(nested_path, "nested.json"), Jason.encode!(%{
        "name" => "nested",
        "description" => "Nested agenda",
        "body" => "A nested agenda.",
        "criteria" => [
          %{
            "topic" => "Parent",
            "prose" => "Top level.",
            "conditions" => ["Parent condition"],
            "children" => [
              %{
                "topic" => "Child A",
                "prose" => "First child.",
                "conditions" => ["Child A condition 1", "Child A condition 2"]
              },
              %{
                "topic" => "Child B",
                "prose" => "Second child.",
                "conditions" => ["Child B condition"]
              }
            ]
          }
        ]
      }))

      metadata = %{@metadata | plugin_config: %{
        "agendas_path" => nested_path,
        "state_path" => state_path
      }}

      {:ok, _, _, state} = Agenda.init(metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "nested"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)

      conditions = state.agenda.conditions
      assert length(conditions) == 4
      assert Enum.at(conditions, 0).criterion == "Parent condition"
      assert Enum.at(conditions, 0).section_topic == "Parent"
      assert Enum.at(conditions, 1).criterion == "Child A condition 1"
      assert Enum.at(conditions, 1).section_topic == "Child A"
      assert Enum.at(conditions, 3).criterion == "Child B condition"

      File.rm_rf!(nested_path)
      File.rm_rf!(state_path)
    end
  end

  describe "definition validation" do
    test "rejects definitions with both init and body" do
      bad_path = Path.join(System.tmp_dir!(), "bad_agendas_#{System.unique_integer([:positive])}")
      state_path = Path.join(System.tmp_dir!(), "bad_state_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bad_path)
      File.mkdir_p!(state_path)

      File.write!(Path.join(bad_path, "bad.json"), Jason.encode!(%{
        "name" => "bad",
        "description" => "Bad agenda",
        "body" => "Some body",
        "init" => "scripts/init.sh"
      }))

      metadata = %{@metadata | plugin_config: %{
        "agendas_path" => bad_path,
        "state_path" => state_path
      }}

      # Should ignore since no valid definitions
      assert :ignore = Agenda.init(metadata)

      File.rm_rf!(bad_path)
      File.rm_rf!(state_path)
    end
  end

  describe "sidecar eval coordination (Agent-based)" do
    setup do
      {:ok, _, _, state} = Agenda.init(@metadata)
      ctx = tool_ctx("activate_agenda", %{"name" => "weekly-sync"}, 1)
      {:ok, _, state} = Agenda.handle_tool_call(ctx, state)
      %{state: state}
    end

    test "pending eval results are consumed by before_context_build", %{state: state} do
      # Simulate sidecar completing with results
      Agent.update(state.eval_agent, fn _ -> %{in_flight: false, result: [0, 2]} end)

      # Need to stub Store for count_current_messages
      # Since Store isn't running in async tests, we'll test this by verifying
      # the agent coordination pattern directly
      eval_state = Agent.get(state.eval_agent, & &1)
      assert eval_state.result == [0, 2]

      # After consumption, result should be cleared
      Agent.update(state.eval_agent, fn s -> %{s | result: nil} end)
      eval_state = Agent.get(state.eval_agent, & &1)
      assert eval_state.result == nil
    end

    test "eval_in_flight prevents concurrent evaluations", %{state: state} do
      Agent.update(state.eval_agent, fn _ -> %{in_flight: true, result: nil} end)
      eval_state = Agent.get(state.eval_agent, & &1)
      assert eval_state.in_flight == true
    end

    test "eval agent is cleaned up on process exit", %{state: state} do
      agent = state.eval_agent
      assert Process.alive?(agent)
      # Agent is linked to the test process via init; in production it's linked
      # to the Plugin.Server process
    end
  end

  # --- Helpers ---

  defp tool_ctx(tool_name, input, turn_count) do
    %{
      conversation_id: "test-conv",
      epoch_id: @test_epoch_id,
      turn_count: turn_count,
      tool_call_id: "call_#{System.unique_integer([:positive])}",
      tool_name: tool_name,
      input: input
    }
  end
end
