defmodule Cranium.Plugin.ConversationSupervisorTest do
  use ExUnit.Case

  alias Cranium.Plugin.ConversationSupervisor

  @conversation_id "plugin-sup-test-#{System.unique_integer([:positive])}"

  setup do
    # Start a conversation supervisor (normally done by Conversation)
    conversation_id = "#{@conversation_id}-#{System.unique_integer([:positive])}"
    {:ok, _pid} = ConversationSupervisor.start_link(conversation_id: conversation_id)

    profile = %Cranium.Config.Profile{
      name: "test",
      backend: :mock,
      model: "test-model",
      plugins: [
        %{module: Cranium.TestPlugins.Echo, config: nil},
        %{module: Cranium.TestPlugins.Skipper, config: nil}
      ]
    }

    metadata = %{
      conversation_id: conversation_id,
      epoch_id: "test-epoch",
      room_name: conversation_id,
      profile: profile,
      plugin_config: nil
    }

    %{conversation_id: conversation_id, metadata: metadata}
  end

  describe "start_plugins/2" do
    test "starts plugins from profile declarations", %{conversation_id: cid, metadata: meta} do
      assert :ok = ConversationSupervisor.start_plugins(cid, meta)

      # Both Echo and Skipper should be running
      registry = Cranium.Inference.ConversationRegistry
      [{sup_pid, _}] = Registry.lookup(registry, {cid, :plugins})
      children = DynamicSupervisor.which_children(sup_pid)
      assert length(children) == 2
    end

    test "skips plugins that return :ignore", %{conversation_id: cid} do
      profile = %Cranium.Config.Profile{
        name: "test",
        backend: :mock,
        model: "test-model",
        plugins: [
          %{module: Cranium.TestPlugins.Ignorer, config: nil},
          %{module: Cranium.TestPlugins.Echo, config: nil}
        ]
      }

      metadata = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        room_name: cid,
        profile: profile,
        plugin_config: nil
      }

      assert :ok = ConversationSupervisor.start_plugins(cid, metadata)

      registry = Cranium.Inference.ConversationRegistry
      [{sup_pid, _}] = Registry.lookup(registry, {cid, :plugins})
      children = DynamicSupervisor.which_children(sup_pid)
      # Only Echo should be running — Ignorer returned :ignore
      assert length(children) == 1
    end

    test "handles empty plugins list", %{conversation_id: cid} do
      profile = %Cranium.Config.Profile{
        name: "test",
        backend: :mock,
        model: "test-model",
        plugins: []
      }

      metadata = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        room_name: cid,
        profile: profile,
        plugin_config: nil
      }

      assert :ok = ConversationSupervisor.start_plugins(cid, metadata)
    end
  end

  describe "dispatch_hook/3" do
    test "collects injections from plugins", %{conversation_id: cid, metadata: meta} do
      ConversationSupervisor.start_plugins(cid, meta)

      turn_context = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        turn_count: 1,
        message_text: "hello"
      }

      injections = ConversationSupervisor.dispatch_hook(cid, :before_context_build, turn_context)
      # Echo returns one injection, Skipper returns :skip
      assert length(injections) == 1
      assert [%{priority: 25, content: "<echo>echo-1</echo>"}] = injections
    end

    test "returns empty list when no plugins are running" do
      fake_cid = "no-plugins-#{System.unique_integer([:positive])}"
      assert [] = ConversationSupervisor.dispatch_hook(fake_cid, :before_context_build, %{})
    end

    test "returns empty list for unsubscribed hooks", %{conversation_id: cid, metadata: meta} do
      ConversationSupervisor.start_plugins(cid, meta)

      # Echo only subscribes to before_context_build, not on_epoch_end
      epoch_end_context = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        messages: []
      }

      # dispatch_hook returns empty since no plugins subscribe to on_epoch_end
      assert [] = ConversationSupervisor.dispatch_hook(cid, :on_epoch_end, epoch_end_context)
    end

    test "handles plugin crash during dispatch", %{conversation_id: cid} do
      profile = %Cranium.Config.Profile{
        name: "test",
        backend: :mock,
        model: "test-model",
        plugins: [
          %{module: Cranium.TestPlugins.Crasher, config: nil},
          %{module: Cranium.TestPlugins.Echo, config: nil}
        ]
      }

      metadata = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        room_name: cid,
        profile: profile,
        plugin_config: nil
      }

      ConversationSupervisor.start_plugins(cid, metadata)

      turn_context = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        turn_count: 1,
        message_text: "hello"
      }

      # Should still get Echo's injection despite Crasher failing
      injections = ConversationSupervisor.dispatch_hook(cid, :before_context_build, turn_context)
      assert length(injections) == 1
      assert [%{priority: 25}] = injections
    end
  end

  describe "dispatch_epoch_end/2" do
    test "dispatches to subscribed plugins", %{conversation_id: cid} do
      profile = %Cranium.Config.Profile{
        name: "test",
        backend: :mock,
        model: "test-model",
        plugins: [
          %{module: Cranium.TestPlugins.EpochEndTracker, config: %{"test_pid" => self()}}
        ]
      }

      metadata = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        room_name: cid,
        profile: profile,
        plugin_config: nil
      }

      ConversationSupervisor.start_plugins(cid, metadata)

      epoch_end_context = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        messages: [%{role: "user", content: "hello"}]
      }

      assert :ok = ConversationSupervisor.dispatch_epoch_end(cid, epoch_end_context)
      assert_receive {:epoch_end_called, ^epoch_end_context}
    end

    test "handles crash during epoch end gracefully", %{conversation_id: cid} do
      profile = %Cranium.Config.Profile{
        name: "test",
        backend: :mock,
        model: "test-model",
        plugins: [
          %{module: Cranium.TestPlugins.EpochEndCrasher, config: nil},
          %{module: Cranium.TestPlugins.EpochEndTracker, config: %{"test_pid" => self()}}
        ]
      }

      metadata = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        room_name: cid,
        profile: profile,
        plugin_config: nil
      }

      ConversationSupervisor.start_plugins(cid, metadata)

      epoch_end_context = %{
        conversation_id: cid,
        epoch_id: "test-epoch",
        messages: []
      }

      # Should complete despite crasher, and tracker should still fire
      assert :ok = ConversationSupervisor.dispatch_epoch_end(cid, epoch_end_context)
      assert_receive {:epoch_end_called, ^epoch_end_context}
    end

    test "returns :ok when no plugins are running" do
      fake_cid = "no-plugins-epoch-end-#{System.unique_integer([:positive])}"
      assert :ok = ConversationSupervisor.dispatch_epoch_end(fake_cid, %{})
    end
  end
end
