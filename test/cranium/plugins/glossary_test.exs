defmodule Cranium.Plugins.GlossaryTest do
  use ExUnit.Case, async: false

  import Mox

  alias Cranium.Plugins.Glossary

  @glossary_path "test/fixtures/glossary"

  @metadata %{
    conversation_id: "test-conv",
    epoch_id: "test-epoch",
    room_name: "test-room",
    profile: %Cranium.Config.Profile{name: "test", backend: :mock, model: "test-model"},
    plugin_config: %{"path" => @glossary_path}
  }

  setup_all do
    # Create test glossary entries
    File.mkdir_p!(@glossary_path)

    File.write!(Path.join(@glossary_path, "alice.md"), """
    ---
    aliases: [al]
    summary: "Alice is a senior engineer on the platform team"
    ---

    Alice joined in 2023 and leads the API migration effort.
    """)

    File.write!(Path.join(@glossary_path, "bob.md"), """
    ---
    aliases: [bobby]
    summary: "Bob is the team's product manager"
    ---
    """)

    File.write!(Path.join(@glossary_path, "chestertons-fence.md"), """
    ---
    aliases: [chesterton's fence]
    summary: "Don't remove a rule until you understand why it was put there"
    ---
    """)

    on_exit(fn ->
      File.rm_rf!(@glossary_path)
    end)

    :ok
  end

  describe "init/1" do
    test "loads glossary from configured path" do
      assert {:ok, hooks, state} = Glossary.init(@metadata)
      assert :before_context_build in hooks
      assert :after_pass_complete in hooks
      # alice, bob, chestertons-fence — each indexed by term + aliases
      assert map_size(state.entries) > 3
      assert state.seen == %{}
      assert state.mentions == %{}
    end

    test "subscribes to on_epoch_end when update_model configured" do
      metadata = %{
        @metadata
        | plugin_config: %{
            "path" => @glossary_path,
            "update_model" => "gemma4:27b"
          }
      }

      assert {:ok, hooks, state} = Glossary.init(metadata)
      assert :before_context_build in hooks
      assert :after_pass_complete in hooks
      assert :on_epoch_end in hooks
      assert state.update_model == "gemma4:27b"
    end

    test "does not subscribe to on_epoch_end without update_model" do
      assert {:ok, hooks, _state} = Glossary.init(@metadata)
      assert :before_context_build in hooks
      assert :after_pass_complete in hooks
      refute :on_epoch_end in hooks
    end

    test "returns :ignore when no path configured" do
      metadata = %{@metadata | plugin_config: nil}
      assert :ignore = Glossary.init(metadata)
    end

    test "returns :ignore when path doesn't exist" do
      metadata = %{@metadata | plugin_config: %{"path" => "/nonexistent/glossary"}}
      assert :ignore = Glossary.init(metadata)
    end

    test "respects custom priority" do
      metadata = %{@metadata | plugin_config: %{"path" => @glossary_path, "priority" => 42}}
      {:ok, _, state} = Glossary.init(metadata)
      assert state.priority == 42
    end
  end

  describe "before_context_build/2" do
    setup do
      {:ok, _, state} = Glossary.init(@metadata)
      %{state: state}
    end

    test "injects gloss tag for mentioned term", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "I talked to Alice today"
      }

      assert {:ok, [%{content: content}], new_state} = Glossary.before_context_build(ctx, state)
      assert content =~ "<glossary>"
      assert content =~ "Alice is a senior engineer"
      assert Map.has_key?(new_state.seen, "alice")
    end

    test "matches aliases", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Bobby said we should wait"
      }

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "Bob is the team's product manager"
    end

    test "case insensitive matching", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "ALICE and bob are here"
      }

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "alice"
      assert content =~ "bob"
    end

    test "skips when no terms match", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Nothing interesting"
      }

      assert {:ok, :skip, ^state} = Glossary.before_context_build(ctx, state)
    end

    test "does not re-inject already seen terms", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Ask Alice about it"
      }

      {:ok, _, state} = Glossary.before_context_build(ctx, state)

      # Same message again — Alice already seen
      ctx2 = %{ctx | turn_count: 2, message_text: "Alice said yes"}
      assert {:ok, :skip, _state} = Glossary.before_context_build(ctx2, state)
    end

    test "injects multiple matched terms in one turn", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Alice and Bob met"
      }

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "alice"
      assert content =~ "bob"
    end

    test "includes body content when present", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Alice is working on it"
      }

      {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "API migration"
    end

    test "matches hyphenated terms with spaces", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "This is a chestertons fence situation"
      }

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "Don't remove a rule"
    end
  end

  describe "live reload" do
    setup do
      dir = Path.join(System.tmp_dir!(), "glossary_reload_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "dana.md"), """
      ---
      aliases: []
      summary: "Dana is a backend engineer"
      ---
      """)

      metadata = %{@metadata | plugin_config: %{"path" => dir}}
      {:ok, _, state} = Glossary.init(metadata)

      on_exit(fn -> File.rm_rf!(dir) end)

      %{state: state, dir: dir}
    end

    test "picks up new files on next turn", %{state: state, dir: dir} do
      # Initially, "eve" is unknown
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Ask Eve"}
      assert {:ok, :skip, state} = Glossary.before_context_build(ctx, state)

      # Add a new glossary entry
      # Ensure mtime differs (touch with 1s future to guarantee change)
      File.write!(Path.join(dir, "eve.md"), """
      ---
      aliases: []
      summary: "Eve is a frontend engineer"
      ---
      """)

      # Next turn should pick up the new entry
      ctx2 = %{ctx | turn_count: 2, message_text: "Ask Eve about the UI"}
      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx2, state)
      assert content =~ "Eve is a frontend engineer"
    end

    test "picks up edits to existing files", %{state: state, dir: dir} do
      # First turn — see Dana
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Dana reviewed it"
      }

      {:ok, [%{content: content}], state} = Glossary.before_context_build(ctx, state)
      assert content =~ "backend engineer"

      # Edit Dana's entry — need mtime to change
      :timer.sleep(1100)

      File.write!(Path.join(dir, "dana.md"), """
      ---
      aliases: []
      summary: "Dana is now a staff engineer"
      ---
      """)

      # Dana was already seen, but the file changed so re-injection is eligible
      ctx2 = %{ctx | turn_count: 2, message_text: "Dana approved the RFC"}
      {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx2, state)
      assert content =~ "staff engineer"
    end

    test "handles deleted files gracefully", %{state: state, dir: dir} do
      # First turn — see Dana
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Dana reviewed it"
      }

      {:ok, _, state} = Glossary.before_context_build(ctx, state)

      # Delete the file
      File.rm!(Path.join(dir, "dana.md"))

      # Next turn — Dana no longer matches
      ctx2 = %{ctx | turn_count: 2, message_text: "Dana reviewed it again"}
      assert {:ok, :skip, _state} = Glossary.before_context_build(ctx2, state)
    end

    test "does not reload when files are unchanged", %{state: state} do
      # Two turns, no file changes — state.entries should be the same reference
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Nothing"}
      {:ok, :skip, state2} = Glossary.before_context_build(ctx, state)

      ctx2 = %{ctx | turn_count: 2, message_text: "Still nothing"}
      {:ok, :skip, state3} = Glossary.before_context_build(ctx2, state2)

      # entries map identity preserved (no reload happened)
      assert state.entries === state3.entries
    end
  end

  describe "mention tracking" do
    setup do
      {:ok, _, state} = Glossary.init(@metadata)
      %{state: state}
    end

    test "tracks turn indices for all matching terms", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Alice reviewed it"
      }

      {:ok, _, state} = Glossary.before_context_build(ctx, state)

      assert state.mentions["alice"] == [1]
    end

    test "accumulates turn indices across multiple mentions", %{state: state} do
      ctx1 = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Alice reviewed it"
      }

      {:ok, _, state} = Glossary.before_context_build(ctx1, state)

      ctx2 = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 5,
        message_text: "Alice approved it"
      }

      {:ok, :skip, state} = Glossary.before_context_build(ctx2, state)

      assert Enum.sort(state.mentions["alice"]) == [1, 5]
    end

    test "tracks already-seen terms without re-injecting", %{state: state} do
      # First mention — injected
      ctx1 = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Ask Alice"}
      {:ok, [_injection], state} = Glossary.before_context_build(ctx1, state)

      # Second mention — not injected but still tracked
      ctx2 = %{conversation_id: "c", epoch_id: "e", turn_count: 3, message_text: "Alice said no"}
      {:ok, :skip, state} = Glossary.before_context_build(ctx2, state)

      assert Enum.sort(state.mentions["alice"]) == [1, 3]
      # Only injected once
      assert Map.has_key?(state.seen, "alice")
    end

    test "tracks multiple terms independently", %{state: state} do
      ctx1 = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Alice and Bob met"
      }

      {:ok, _, state} = Glossary.before_context_build(ctx1, state)

      ctx2 = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 3,
        message_text: "Alice called Bob"
      }

      {:ok, :skip, state} = Glossary.before_context_build(ctx2, state)

      assert Enum.sort(state.mentions["alice"]) == [1, 3]
      assert Enum.sort(state.mentions["bob"]) == [1, 3]
    end
  end

  describe "after_pass_complete (assistant mention tracking)" do
    setup do
      {:ok, _, state} = Glossary.init(@metadata)
      %{state: state}
    end

    test "tracks mentions in assistant output", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        output: "Alice is a great engineer",
        turn_count: 2
      }

      {:ok, state} = Glossary.after_pass_complete(ctx, state)

      assert state.mentions["alice"] == [2]
    end

    test "accumulates with existing user-side mentions", %{state: state} do
      # User mentions Alice on turn 1
      user_ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 1,
        message_text: "Tell me about Alice"
      }

      {:ok, _, state} = Glossary.before_context_build(user_ctx, state)
      assert state.mentions["alice"] == [1]

      # Assistant mentions Alice in response (same turn)
      pass_ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        output: "Alice is a senior engineer on the platform team.",
        turn_count: 1
      }

      {:ok, state} = Glossary.after_pass_complete(pass_ctx, state)

      assert Enum.sort(state.mentions["alice"]) == [1, 1]
    end

    test "catches assistant-only mentions not in user message", %{state: state} do
      # User doesn't mention Bob
      user_ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        turn_count: 3,
        message_text: "Who's on the team?"
      }

      {:ok, :skip, state} = Glossary.before_context_build(user_ctx, state)
      assert state.mentions == %{}

      # But assistant names Bob in the response
      pass_ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        output: "Bob is the product manager for this team.",
        turn_count: 4
      }

      {:ok, state} = Glossary.after_pass_complete(pass_ctx, state)

      assert state.mentions["bob"] == [4]
    end

    test "skips when no terms match in assistant output", %{state: state} do
      ctx = %{
        conversation_id: "c",
        epoch_id: "e",
        output: "Sure, I'll help with that.",
        turn_count: 1
      }

      {:ok, state} = Glossary.after_pass_complete(ctx, state)

      assert state.mentions == %{}
    end
  end

  describe "on_epoch_end auto-update" do
    setup do
      Mox.set_mox_global()

      dir = Path.join(System.tmp_dir!(), "glossary_update_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "frank.md"), """
      ---
      aliases: []
      summary: "Frank is a backend engineer"
      ---

      Frank joined in 2022.
      """)

      metadata = %{
        @metadata
        | plugin_config: %{
            "path" => dir,
            "update_model" => "test-model",
            "async" => false
          }
      }

      {:ok, _, state} = Glossary.init(metadata)

      on_exit(fn -> File.rm_rf!(dir) end)

      %{state: state, dir: dir}
    end

    test "updates glossary file when model proposes update", %{state: state, dir: dir} do
      state = %{state | mentions: %{"frank" => [1, 3]}}

      stub_sidecar_response(
        Jason.encode!(%{
          "update" => true,
          "summary" => "Frank is now a staff engineer on the platform team",
          "rationale" => "User corrected Frank's role"
        })
      )

      messages = [
        %{"role" => "user", "content" => "Frank got promoted"},
        %{"role" => "assistant", "content" => "That's great!"},
        %{"role" => "user", "content" => "Yeah he's a staff engineer now"},
        %{"role" => "assistant", "content" => "Congrats to Frank!"},
        %{"role" => "user", "content" => "On the platform team"}
      ]

      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}
      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)

      updated = File.read!(Path.join(dir, "frank.md"))
      assert updated =~ "Frank is now a staff engineer on the platform team"
      assert updated =~ "<!-- updated"
      assert updated =~ "User corrected Frank's role"
      assert updated =~ "Frank joined in 2022."
    end

    test "does not modify file when model says no update", %{state: state, dir: dir} do
      state = %{state | mentions: %{"frank" => [1]}}

      original = File.read!(Path.join(dir, "frank.md"))

      stub_sidecar_response(Jason.encode!(%{"update" => false}))

      messages = [
        %{"role" => "user", "content" => "Frank reviewed the PR"},
        %{"role" => "assistant", "content" => "Got it"}
      ]

      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}
      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)

      assert File.read!(Path.join(dir, "frank.md")) == original
    end

    test "survives sidecar being unreachable", %{state: state} do
      state = %{state | mentions: %{"frank" => [1]}}

      stub(Cranium.Backend.LLM.Mock, :stream_chat, fn _messages, _opts ->
        {:error, :connection_refused}
      end)

      messages = [%{"role" => "user", "content" => "Frank is here"}]
      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}

      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)
    end

    test "no-ops when update_model is nil", %{state: state} do
      state = %{state | update_model: nil, mentions: %{"frank" => [1]}}

      # No stub needed — if it tries to call Ollama, the test will fail
      messages = [%{"role" => "user", "content" => "Frank is here"}]
      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}

      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)
    end

    test "no-ops when no terms were mentioned", %{state: state} do
      messages = [%{"role" => "user", "content" => "Hello"}]
      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}

      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)
    end

    test "includes windowed conversation excerpts in prompt", %{state: state} do
      state = %{state | mentions: %{"frank" => [2]}}

      stub_sidecar_response(Jason.encode!(%{"update" => false}))

      messages = [
        %{"role" => "user", "content" => "Before Frank stuff"},
        %{"role" => "assistant", "content" => "Okay"},
        %{"role" => "user", "content" => "Frank got promoted"},
        %{"role" => "assistant", "content" => "Nice!"},
        %{"role" => "user", "content" => "After Frank stuff"}
      ]

      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}
      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)
    end

    test "merges overlapping windows from close mentions", %{state: state} do
      state = %{state | mentions: %{"frank" => [1, 3]}}

      stub_sidecar_response(Jason.encode!(%{"update" => false}))

      messages =
        for i <- 0..8 do
          %{"role" => if(rem(i, 2) == 0, do: "user", else: "assistant"), "content" => "msg-#{i}"}
        end

      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}
      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)
    end

    test "atomic write preserves body content", %{state: state, dir: dir} do
      state = %{state | mentions: %{"frank" => [0]}}

      stub_sidecar_response(
        Jason.encode!(%{
          "update" => true,
          "summary" => "Frank is a principal engineer",
          "rationale" => "Role updated"
        })
      )

      messages = [%{"role" => "user", "content" => "Frank is now principal"}]
      epoch_ctx = %{conversation_id: "c", epoch_id: "e", messages: messages}
      assert :ok = Glossary.on_epoch_end(epoch_ctx, state)

      updated = File.read!(Path.join(dir, "frank.md"))
      assert updated =~ "Frank is a principal engineer"
      assert updated =~ "Frank joined in 2022."
      refute File.exists?(Path.join(dir, "frank.md.tmp"))
    end
  end

  defp stub_sidecar_response(json_text) do
    stub(Cranium.Backend.LLM.Mock, :stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn_link(fn ->
          send(caller, {:llm_text, json_text})
          send(caller, {:llm_stop, "end_turn"})
        end)

      {:ok, pid}
    end)

    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)
  end
end
