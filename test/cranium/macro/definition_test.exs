defmodule Cranium.Macro.DefinitionTest do
  use ExUnit.Case, async: true

  alias Cranium.Macro.Definition

  @fixtures_path Path.join(File.cwd!(), "test/fixtures/macros")

  defp load_fixture(filename) do
    @fixtures_path
    |> Path.join(filename)
    |> File.read!()
    |> Jason.decode!()
  end

  # --- Prompt body type ---

  describe "parse/1 prompt body" do
    test "parses a simple skill (explicit/listed/turn)" do
      json = load_fixture("greeting-skill.json")
      assert {:ok, def} = Definition.parse(json)

      assert def.name == "greeting"
      assert def.description == "A simple greeting skill for testing"
      assert def.version == 1
      assert def.trigger == :explicit
      assert def.advertising == :listed
      assert def.lifecycle == :turn
      assert def.learning == :none
      assert def.revision == :never
      assert def.disposition == :foreground
      assert def.body_type == :prompt
      assert def.prompt_body.text =~ "friendly greeter"
      assert def.prompt_body.tag == "skill"
      assert def.prompt_body.priority == 50
      assert def.tags == ["test", "skill"]
    end

    test "parses a glossary entry (match/hidden/session)" do
      json = load_fixture("kubernetes-glossary.json")
      assert {:ok, def} = Definition.parse(json)

      assert def.trigger == :match
      assert def.match_config.patterns == ["kubernetes", "k8s", "/kube[-\\s]?cluster/"]
      assert def.match_config.once == true
      assert def.advertising == :hidden
      assert def.lifecycle == :session
      assert def.revision == :session_end
      assert def.revision_config.prompt =~ "Review this glossary"
      assert def.body_type == :prompt
      assert def.prompt_body.tag == "glossary"
    end

    test "parses an agenda with conditions and children" do
      json = load_fixture("standup-agenda.json")
      assert {:ok, def} = Definition.parse(json)

      assert def.trigger == :explicit
      assert def.lifecycle == :condition
      assert def.learning == :sidecar
      assert def.sidecar_config.model == "exo-local"
      assert def.sidecar_config.interval == 3
      assert def.sidecar_config.prompt =~ "%{conditions}"

      assert length(def.conditions) == 3
      assert hd(def.conditions).description == "Yesterday's work discussed"
      assert hd(def.conditions).section == "Updates"

      assert length(def.children) == 1
      child = hd(def.children)
      assert child.name == "end_standup"
      assert child.trigger == :explicit
      assert child.lifecycle == :parent

      assert def.state_schema["type"] == "object"
    end
  end

  # --- Script body type ---

  describe "parse/1 script body" do
    test "parses a script macro with discoverable advertising" do
      json = load_fixture("deploy-script.json")
      assert {:ok, def} = Definition.parse(json)

      assert def.trigger == :explicit
      assert def.advertising == :discoverable
      assert def.discoverable_config.keywords == ["deploy", "deployment", "ship it"]
      assert def.body_type == :script
      assert def.script_body.command == "echo deploying $MACRO_NAME"
      assert def.script_body.timeout_seconds == 60
      assert def.script_body.sandbox == true
    end
  end

  # --- Sequence body type ---

  describe "parse/1 sequence body" do
    test "parses a sequence with named ref and inline step" do
      json = load_fixture("pipeline.json")
      assert {:ok, def} = Definition.parse(json)

      assert def.body_type == :sequence
      assert length(def.sequence_body.steps) == 2
      assert def.sequence_body.on_failure == :halt

      [step1, step2] = def.sequence_body.steps
      assert step1.name == "deploy"
      assert step1.inline == nil

      assert step2.name == nil
      assert step2.inline.name == "verify-step"
      assert step2.inline.body_type == :script
    end
  end

  # --- Validation errors ---

  describe "parse/1 validation" do
    test "rejects missing name" do
      json = %{"description" => "x", "trigger" => "explicit"}
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "name"
    end

    test "rejects missing description" do
      json = %{"name" => "x", "trigger" => "explicit"}
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "description"
    end

    test "rejects invalid trigger value" do
      json = minimal_json() |> Map.put("trigger", "invalid")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "trigger"
      assert msg =~ "must be one of"
    end

    test "rejects match trigger without match_config" do
      json = minimal_json() |> Map.put("trigger", "match")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "match_config is required"
    end

    test "rejects match_config with empty patterns" do
      json =
        minimal_json()
        |> Map.put("trigger", "match")
        |> Map.put("match_config", %{"patterns" => []})

      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "match_config.patterns"
    end

    test "rejects discoverable without discoverable_config" do
      json = minimal_json() |> Map.put("advertising", "discoverable")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "discoverable_config is required"
    end

    test "rejects sidecar learning without sidecar_config" do
      json = minimal_json() |> Map.put("learning", "sidecar")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "sidecar_config is required"
    end

    test "rejects session_end revision without revision_config" do
      json = minimal_json() |> Map.put("revision", "session_end")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "revision_config is required"
    end

    test "rejects prompt body_type without prompt_body" do
      json = minimal_json() |> Map.delete("prompt_body")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "prompt_body is required"
    end

    test "rejects script body_type without script_body" do
      json = minimal_json() |> Map.put("body_type", "script") |> Map.delete("prompt_body")
      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "script_body is required"
    end

    test "rejects non-map input" do
      assert {:error, _} = Definition.parse("not a map")
      assert {:error, _} = Definition.parse(nil)
    end

    test "rejects invalid step in sequence" do
      json =
        minimal_json()
        |> Map.put("body_type", "sequence")
        |> Map.delete("prompt_body")
        |> Map.put("sequence_body", %{
          "steps" => [%{"neither" => "name nor inline"}],
          "on_failure" => "halt"
        })

      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "step[0]"
    end
  end

  # --- Inline JSON builder for minimal valid definitions ---

  describe "parse/1 minimal" do
    test "parses minimal valid definition" do
      json = minimal_json()
      assert {:ok, def} = Definition.parse(json)
      assert def.name == "test"
      assert def.tools == []
      assert def.children == []
      assert def.conditions == []
      assert def.tags == []
      assert def.version == nil
      assert def.source == nil
    end
  end

  # --- Tools parsing ---

  describe "parse/1 tools" do
    test "parses tools with all fields" do
      json =
        minimal_json()
        |> Map.put("tools", [
          %{
            "name" => "do_thing",
            "description" => "Does a thing",
            "input_schema" => %{"type" => "object"},
            "handler" => "script"
          }
        ])

      assert {:ok, def} = Definition.parse(json)
      assert length(def.tools) == 1
      tool = hd(def.tools)
      assert tool.name == "do_thing"
      assert tool.handler == :script
    end

    test "rejects tool missing name" do
      json =
        minimal_json()
        |> Map.put("tools", [%{"description" => "x", "handler" => "script"}])

      assert {:error, msg} = Definition.parse(json)
      assert msg =~ "tools[0].name"
    end
  end

  defp minimal_json do
    %{
      "name" => "test",
      "description" => "A test macro",
      "trigger" => "explicit",
      "advertising" => "listed",
      "lifecycle" => "turn",
      "learning" => "none",
      "revision" => "never",
      "disposition" => "foreground",
      "body_type" => "prompt",
      "prompt_body" => %{"text" => "test prompt text"}
    }
  end
end
