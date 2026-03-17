defmodule Cranium.Context.RouterTest do
  use CraniumTest.DataCase, async: true

  alias Cranium.Context.Router

  describe "slugify/1" do
    test "lowercases and replaces non-alphanumeric chars" do
      assert Router.slugify("Fort-Nix") == "fort-nix"
      assert Router.slugify("cranium_v2") == "cranium-v2"
      assert Router.slugify("My Project!") == "my-project"
    end

    test "collapses consecutive hyphens" do
      assert Router.slugify("a--b---c") == "a-b-c"
    end

    test "trims leading and trailing hyphens" do
      assert Router.slugify("-foo-") == "foo"
    end
  end

  describe "resolve_project_dir/2" do
    test "returns path when directory exists" do
      # cranium-v2 itself is a real project directory
      result = Router.resolve_project_dir("cranium-v2", "~/Projects")
      expanded = Path.expand("~/Projects/cranium-v2")
      assert result == expanded
      assert File.dir?(result)
    end

    test "returns nil when directory does not exist" do
      result = Router.resolve_project_dir("nonexistent-project-abc123", "~/Projects")
      assert result == nil
    end

    test "handles conversation_id slugification" do
      # "Cranium V2" slugifies to "cranium-v2" which exists
      result = Router.resolve_project_dir("Cranium V2", "~/Projects")
      expanded = Path.expand("~/Projects/cranium-v2")
      assert result == expanded
    end
  end

  describe "process/2" do
    test "sets working_dir for a known project" do
      message = %{conversation_id: "cranium-v2", text: "hello", attachments: []}
      context = %{projects_dir: "~/Projects"}

      {:ok, enriched} = Router.process(message, context)

      assert enriched.working_dir == Path.expand("~/Projects/cranium-v2")
      assert Map.has_key?(enriched, :is_fresh)
    end

    test "sets working_dir to nil for unknown project" do
      message = %{conversation_id: "nonexistent-xyz", text: "hello", attachments: []}
      context = %{projects_dir: "~/Projects"}

      {:ok, enriched} = Router.process(message, context)

      assert enriched.working_dir == nil
    end

    test "preserves original message fields" do
      message = %{conversation_id: "cranium-v2", text: "hello", attachments: [], custom: "data"}
      context = %{projects_dir: "~/Projects"}

      {:ok, enriched} = Router.process(message, context)

      assert enriched.text == "hello"
      assert enriched.custom == "data"
      assert enriched.conversation_id == "cranium-v2"
    end
  end
end
