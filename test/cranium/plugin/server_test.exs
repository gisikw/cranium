defmodule Cranium.Plugin.ServerTest do
  use ExUnit.Case, async: true

  alias Cranium.Plugin.Server

  @metadata %{
    conversation_id: "test-conv",
    epoch_id: "test-epoch",
    room_name: "test-room",
    profile: %Cranium.Config.Profile{name: "test", backend: :mock, model: "test-model"},
    plugin_config: nil
  }

  @turn_context %{
    conversation_id: "test-conv",
    epoch_id: "test-epoch",
    turn_count: 1,
    message_text: "hello"
  }

  describe "start_link/1" do
    test "starts a plugin server" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert Process.alive?(pid)
    end

    test "returns :ignore for plugins that decline" do
      assert :ignore = Server.start_link(module: Cranium.TestPlugins.Ignorer, session_metadata: @metadata)
    end
  end

  describe "call_hook/3" do
    test "returns injections from plugin" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert {:ok, [%{priority: 25, content: "<echo>echo-1</echo>"}]} = Server.call_hook(pid, :before_context_build, @turn_context)
    end

    test "returns :skip from skipper plugin" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Skipper, session_metadata: @metadata)
      assert {:ok, :skip} = Server.call_hook(pid, :before_context_build, @turn_context)
    end

    test "returns :skip for unsubscribed hooks" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      # Echo only subscribes to :before_context_build, not :after_pass_complete
      assert {:ok, :skip} = Server.call_hook(pid, :after_pass_complete, @turn_context)
    end

    test "handles crash in callback gracefully" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Crasher, session_metadata: @metadata)
      assert {:error, {:raised, %RuntimeError{}}} = Server.call_hook(pid, :before_context_build, @turn_context)
      # Server should still be alive
      assert Process.alive?(pid)
    end

    test "maintains state across calls" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert {:ok, [%{content: "<echo>echo-1</echo>"}]} = Server.call_hook(pid, :before_context_build, @turn_context)
      assert {:ok, [%{content: "<echo>echo-2</echo>"}]} = Server.call_hook(pid, :before_context_build, @turn_context)
    end
  end

  describe "on_epoch_end hook" do
    test "dispatches epoch_end to subscribed plugin" do
      metadata = %{@metadata | plugin_config: %{"test_pid" => self()}}
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.EpochEndTracker, session_metadata: metadata)

      epoch_end_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        messages: [%{role: "user", content: "hello"}]
      }

      assert {:ok, :ok} = Server.call_hook(pid, :on_epoch_end, epoch_end_context)
      assert_receive {:epoch_end_called, ^epoch_end_context}
    end

    test "handles crash in on_epoch_end gracefully" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.EpochEndCrasher, session_metadata: @metadata)

      epoch_end_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        messages: []
      }

      assert {:error, {:raised, %RuntimeError{}}} = Server.call_hook(pid, :on_epoch_end, epoch_end_context)
      assert Process.alive?(pid)
    end

    test "returns :skip for plugins not subscribed to on_epoch_end" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)

      epoch_end_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        messages: []
      }

      assert {:ok, :skip} = Server.call_hook(pid, :on_epoch_end, epoch_end_context)
    end
  end

  describe "after_resolve_profile hook" do
    @profile_context %{
      conversation_id: "test-conv",
      epoch_id: "test-epoch",
      turn_count: 3,
      profile_name: "exo",
      backend: :anthropic,
      backend_module: Cranium.Backend.LLM.Mock,
      model: "claude-opus-4-6",
      identity: "I am exo",
      thinking: nil,
      context_window: 200_000,
      saturation_warn: nil,
      saturation_critical: nil
    }

    test "returns modified context from swapper plugin" do
      metadata = %{@metadata | plugin_config: %{model: "gemma4-cranium", backend: :mock, backend_module: Cranium.Backend.LLM.Mock}}
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ProfileSwapper, session_metadata: metadata)

      assert {:ok, result} = Server.call_hook(pid, :after_resolve_profile, @profile_context)
      assert result.model == "gemma4-cranium"
      assert result.backend == :mock
      assert result.backend_module == Cranium.Backend.LLM.Mock
      # Unmodified fields preserved
      assert result.conversation_id == "test-conv"
      assert result.identity == "I am exo"
    end

    test "returns context unchanged from passthrough plugin" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ProfilePassthrough, session_metadata: @metadata)

      assert {:ok, result} = Server.call_hook(pid, :after_resolve_profile, @profile_context)
      assert result == @profile_context
    end

    test "handles crash gracefully" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ProfileCrasher, session_metadata: @metadata)

      assert {:error, {:raised, %RuntimeError{}}} = Server.call_hook(pid, :after_resolve_profile, @profile_context)
      assert Process.alive?(pid)
    end

    test "returns :skip for plugins not subscribed to after_resolve_profile" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert {:ok, :skip} = Server.call_hook(pid, :after_resolve_profile, @profile_context)
    end
  end

  describe "info/1" do
    test "returns module, hooks, and empty tool_definitions" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)

      assert {:ok,
              %{module: Cranium.TestPlugins.Echo, hooks: [:before_context_build], tool_definitions: []}} =
               Server.info(pid)
    end

    test "returns tool_definitions when plugin declares tools" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolProvider, session_metadata: @metadata)
      assert {:ok, %{tool_definitions: tools}} = Server.info(pid)
      assert length(tools) == 2
      assert Enum.any?(tools, &(&1.name == "greet"))
      assert Enum.any?(tools, &(&1.name == "farewell"))
    end
  end

  describe "tool_definitions/1" do
    test "returns tool definitions from plugin" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolProvider, session_metadata: @metadata)
      defs = Server.tool_definitions(pid)
      assert length(defs) == 2
      names = Enum.map(defs, & &1.name)
      assert "greet" in names
      assert "farewell" in names
    end

    test "returns empty list for plugin without tools" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert [] = Server.tool_definitions(pid)
    end
  end

  describe "call_tool/2" do
    test "dispatches tool call to plugin handle_tool_call" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolProvider, session_metadata: @metadata)

      tool_call_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        turn_count: 1,
        tool_call_id: "call-1",
        tool_name: "greet",
        input: %{"name" => "Kevin"}
      }

      assert {:ok, result} = Server.call_tool(pid, tool_call_context)
      assert result =~ "Hello, Kevin!"
    end

    test "returns error from plugin" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolProvider, session_metadata: @metadata)

      tool_call_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        turn_count: 1,
        tool_call_id: "call-2",
        tool_name: "nonexistent",
        input: %{}
      }

      assert {:error, "unknown tool: nonexistent"} = Server.call_tool(pid, tool_call_context)
    end

    test "handles crash in handle_tool_call gracefully" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolCrasher, session_metadata: @metadata)

      tool_call_context = %{
        conversation_id: "test-conv",
        epoch_id: "test-epoch",
        turn_count: 1,
        tool_call_id: "call-3",
        tool_name: "boom",
        input: %{}
      }

      assert {:error, "intentional tool crash"} = Server.call_tool(pid, tool_call_context)
      assert Process.alive?(pid)
    end

    test "maintains state across tool calls" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolProvider, session_metadata: @metadata)

      for name <- ["Alice", "Bob"] do
        ctx = %{
          conversation_id: "test-conv",
          epoch_id: "test-epoch",
          turn_count: 1,
          tool_call_id: "call-#{name}",
          tool_name: "greet",
          input: %{"name" => name}
        }

        assert {:ok, _} = Server.call_tool(pid, ctx)
      end

      assert {:ok, result} =
               Server.call_tool(pid, %{
                 conversation_id: "test-conv",
                 epoch_id: "test-epoch",
                 turn_count: 1,
                 tool_call_id: "call-3",
                 tool_name: "farewell",
                 input: %{}
               })

      assert result =~ "Goodbye!"
    end
  end

  describe "on_epoch_start hook" do
    test "dispatches epoch_start to subscribed plugin" do
      metadata = %{@metadata | plugin_config: %{"test_pid" => self()}}
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.EpochStartTracker, session_metadata: metadata)

      epoch_start_context = %{
        conversation_id: "test-conv",
        epoch_id: "new-epoch",
        predecessor_epoch_id: "old-epoch",
        room_name: "test-room"
      }

      assert {:ok, :ok} = Server.call_hook(pid, :on_epoch_start, epoch_start_context)
      assert_receive {:epoch_start_called, ^epoch_start_context}
    end

    test "returns :skip for plugins not subscribed to on_epoch_start" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)

      assert {:ok, :skip} =
               Server.call_hook(pid, :on_epoch_start, %{
                 conversation_id: "test-conv",
                 epoch_id: "new-epoch",
                 predecessor_epoch_id: nil,
                 room_name: "test-room"
               })
    end
  end

  describe "init with tool definitions" do
    test "stores tool definitions from 4-tuple init return" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.ToolProvider, session_metadata: @metadata)
      assert {:ok, %{tool_definitions: tools}} = Server.info(pid)
      assert length(tools) == 2
    end

    test "stores empty tool definitions from 3-tuple init return" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert {:ok, %{tool_definitions: []}} = Server.info(pid)
    end
  end
end
