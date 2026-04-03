defmodule Cranium.Context.RouterTest do
  use ExUnit.Case, async: true

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
      result = Router.resolve_project_dir("Cranium V2", dir)
      assert result == Path.join(dir, "cranium-v2")
    end
  end
end
