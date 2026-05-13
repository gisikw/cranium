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

  describe "info/1" do
    test "returns module and hooks" do
      {:ok, pid} = Server.start_link(module: Cranium.TestPlugins.Echo, session_metadata: @metadata)
      assert {:ok, %{module: Cranium.TestPlugins.Echo, hooks: [:before_context_build]}} = Server.info(pid)
    end
  end
end
