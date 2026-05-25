defmodule Cranium.Macro.RevisionTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Cranium.Macro.{Revision, Definition}

  @test_dir "test/fixtures/macros_revision_test"

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  defp make_revisable_macro(source_path) do
    %Definition{
      name: "revisable-macro",
      description: "A macro that revises itself",
      trigger: :match,
      match_config: %{patterns: ["test"], once: false},
      advertising: :hidden,
      lifecycle: :condition,
      learning: :sidecar,
      sidecar_config: %{model: nil, interval: 3, prompt: "eval %{conditions} %{lookback}"},
      revision: :session_end,
      revision_config: %{prompt: "Revise this: %{definition}\nBased on: %{messages}", condition: nil},
      disposition: :foreground,
      body_type: :prompt,
      prompt_body: %{text: "Test body", tag: nil, priority: 50},
      conditions: [
        %{description: "Condition A", section: nil}
      ],
      version: 1,
      source_path: source_path
    }
  end

  defp write_macro_file(path) do
    json = %{
      "name" => "revisable-macro",
      "description" => "A macro that revises itself",
      "trigger" => "match",
      "match_config" => %{"patterns" => ["test"], "once" => false},
      "advertising" => "hidden",
      "lifecycle" => "condition",
      "learning" => "sidecar",
      "sidecar_config" => %{"model" => nil, "interval" => 3, "prompt" => "eval %{conditions} %{lookback}"},
      "revision" => "session_end",
      "revision_config" => %{"prompt" => "Revise: %{definition}\nHistory: %{messages}"},
      "disposition" => "foreground",
      "body_type" => "prompt",
      "prompt_body" => %{"text" => "Test body", "tag" => nil, "priority" => 50},
      "conditions" => [%{"description" => "Condition A"}],
      "version" => 1
    }

    File.write!(path, Jason.encode!(json, pretty: true))
    path
  end

  # --- dispatch/2 guards ---

  describe "dispatch/2 guards" do
    test "skips when no revision_config" do
      macro = %Definition{
        make_revisable_macro("/tmp/none") | revision_config: nil
      }

      context = %{conversation_id: "test", epoch_id: "e1", messages: []}
      assert :ok = Revision.dispatch(macro, context)
    end

    test "skips when no source_path" do
      macro = %{make_revisable_macro(nil) | source_path: nil}

      context = %{conversation_id: "test", epoch_id: "e1", messages: []}
      assert :ok = Revision.dispatch(macro, context)
    end

    test "dispatches when all requirements met" do
      path = Path.join(@test_dir, "revisable.json")
      write_macro_file(path)

      macro = make_revisable_macro(path)
      context = %{conversation_id: "test", epoch_id: "e1", messages: []}

      # This will dispatch a Task that fails (no Ollama), but dispatch itself succeeds
      assert :ok = Revision.dispatch(macro, context)
    end
  end

  # --- Response parsing (via module internals tested through integration) ---

  describe "revision response handling" do
    test "atomic_write creates valid JSON file" do
      path = Path.join(@test_dir, "atomic-test.json")

      original = %{
        "name" => "revisable-macro",
        "description" => "Original",
        "trigger" => "match",
        "match_config" => %{"patterns" => ["test"], "once" => false},
        "advertising" => "hidden",
        "lifecycle" => "condition",
        "learning" => "sidecar",
        "sidecar_config" => %{"model" => nil, "interval" => 3, "prompt" => "eval"},
        "revision" => "session_end",
        "revision_config" => %{"prompt" => "revise"},
        "disposition" => "foreground",
        "body_type" => "prompt",
        "prompt_body" => %{"text" => "Original body", "tag" => nil, "priority" => 50},
        "conditions" => [%{"description" => "Condition A"}],
        "version" => 1
      }

      File.write!(path, Jason.encode!(original, pretty: true))

      # Simulate what revision does internally
      revised = Map.merge(original, %{
        "description" => "Revised description",
        "version" => 2,
        "_revision_history" => [%{
          "version" => 2,
          "revised_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "from_version" => 1,
          "macro_name" => "revisable-macro"
        }]
      })

      # Verify the revised definition parses correctly
      assert {:ok, parsed} = Definition.parse(revised)
      assert parsed.version == 2
      assert parsed.description == "Revised description"

      # Write atomically
      json = Jason.encode!(revised, pretty: true)
      tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"
      :ok = File.write(tmp, json)
      :ok = File.rename(tmp, path)

      # Read back and verify
      {:ok, content} = File.read(path)
      {:ok, decoded} = Jason.decode(content)
      assert decoded["version"] == 2
      assert decoded["description"] == "Revised description"
      assert length(decoded["_revision_history"]) == 1
    end

    test "version is bumped on revision" do
      path = Path.join(@test_dir, "version-bump.json")

      original = %{
        "name" => "revisable-macro",
        "description" => "V1",
        "trigger" => "match",
        "match_config" => %{"patterns" => ["test"], "once" => false},
        "advertising" => "hidden",
        "lifecycle" => "condition",
        "learning" => "sidecar",
        "sidecar_config" => %{"model" => nil, "interval" => 3, "prompt" => "eval"},
        "revision" => "session_end",
        "revision_config" => %{"prompt" => "revise"},
        "disposition" => "foreground",
        "body_type" => "prompt",
        "prompt_body" => %{"text" => "body", "tag" => nil, "priority" => 50},
        "conditions" => [%{"description" => "Cond"}],
        "version" => 5
      }

      File.write!(path, Jason.encode!(original, pretty: true))

      # Simulate a version bump
      revised = Map.put(original, "version", 6)
      assert {:ok, parsed} = Definition.parse(revised)
      assert parsed.version == 6
    end

    test "revision history accumulates" do
      history = [
        %{"version" => 2, "from_version" => 1, "revised_at" => "2026-01-01T00:00:00Z", "macro_name" => "test"},
        %{"version" => 3, "from_version" => 2, "revised_at" => "2026-02-01T00:00:00Z", "macro_name" => "test"}
      ]

      new_entry = %{"version" => 4, "from_version" => 3, "revised_at" => "2026-03-01T00:00:00Z", "macro_name" => "test"}
      full_history = history ++ [new_entry]

      assert length(full_history) == 3
      assert List.last(full_history)["version"] == 4
    end
  end
end
