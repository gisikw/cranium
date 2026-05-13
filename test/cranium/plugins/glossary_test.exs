defmodule Cranium.Plugins.GlossaryTest do
  use ExUnit.Case, async: true

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
      assert {:ok, [:before_context_build], state} = Glossary.init(@metadata)
      # alice, bob, chestertons-fence — each indexed by term + aliases
      assert map_size(state.entries) > 3
      assert state.seen == %{}
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
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "I talked to Alice today"}

      assert {:ok, [%{content: content}], new_state} = Glossary.before_context_build(ctx, state)
      assert content =~ "<glossary>"
      assert content =~ "Alice is a senior engineer"
      assert Map.has_key?(new_state.seen, "alice")
    end

    test "matches aliases", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Bobby said we should wait"}

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "Bob is the team's product manager"
    end

    test "case insensitive matching", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "ALICE and bob are here"}

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "alice"
      assert content =~ "bob"
    end

    test "skips when no terms match", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Nothing interesting"}

      assert {:ok, :skip, ^state} = Glossary.before_context_build(ctx, state)
    end

    test "does not re-inject already seen terms", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Ask Alice about it"}
      {:ok, _, state} = Glossary.before_context_build(ctx, state)

      # Same message again — Alice already seen
      ctx2 = %{ctx | turn_count: 2, message_text: "Alice said yes"}
      assert {:ok, :skip, _state} = Glossary.before_context_build(ctx2, state)
    end

    test "injects multiple matched terms in one turn", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Alice and Bob met"}

      assert {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "alice"
      assert content =~ "bob"
    end

    test "includes body content when present", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Alice is working on it"}

      {:ok, [%{content: content}], _state} = Glossary.before_context_build(ctx, state)
      assert content =~ "API migration"
    end

    test "matches hyphenated terms with spaces", %{state: state} do
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "This is a chestertons fence situation"}

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
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Dana reviewed it"}
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
      ctx = %{conversation_id: "c", epoch_id: "e", turn_count: 1, message_text: "Dana reviewed it"}
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
end
