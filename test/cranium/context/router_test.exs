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
    setup do
      tmp = Path.join(System.tmp_dir!(), "router_test_#{:erlang.unique_integer([:positive])}")
      project = Path.join(tmp, "cranium-v2")
      File.mkdir_p!(project)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{projects_dir: tmp}
    end

    test "returns path when directory exists", %{projects_dir: dir} do
      result = Router.resolve_project_dir("cranium-v2", dir)
      assert result == Path.join(dir, "cranium-v2")
      assert File.dir?(result)
    end

    test "returns nil when directory does not exist", %{projects_dir: dir} do
      result = Router.resolve_project_dir("nonexistent-project-abc123", dir)
      assert result == nil
    end

    test "handles conversation_id slugification", %{projects_dir: dir} do
      # "Cranium V2" slugifies to "cranium-v2" which exists in our temp dir
      result = Router.resolve_project_dir("Cranium V2", dir)
      assert result == Path.join(dir, "cranium-v2")
    end
  end

  describe "process/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "router_test_#{:erlang.unique_integer([:positive])}")
      project = Path.join(tmp, "cranium-v2")
      File.mkdir_p!(project)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{projects_dir: tmp}
    end

    test "sets working_dir for a known project", %{projects_dir: dir} do
      message = %{conversation_id: "cranium-v2", text: "hello", attachments: []}
      context = %{projects_dir: dir}

      {:ok, enriched} = Router.process(message, context)

      assert enriched.working_dir == Path.join(dir, "cranium-v2")
      assert Map.has_key?(enriched, :is_fresh)
    end

    test "sets working_dir to nil for unknown project", %{projects_dir: dir} do
      message = %{conversation_id: "nonexistent-xyz", text: "hello", attachments: []}
      context = %{projects_dir: dir}

      {:ok, enriched} = Router.process(message, context)

      assert enriched.working_dir == nil
    end

    test "preserves original message fields", %{projects_dir: dir} do
      message = %{conversation_id: "cranium-v2", text: "hello", attachments: [], custom: "data"}
      context = %{projects_dir: dir}

      {:ok, enriched} = Router.process(message, context)

      assert enriched.text == "hello"
      assert enriched.custom == "data"
      assert enriched.conversation_id == "cranium-v2"
    end
  end
end
