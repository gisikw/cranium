defmodule Cranium.Macro.RegistryTest do
  use ExUnit.Case

  alias Cranium.Macro.Registry

  # The app-level Registry is already running with test/fixtures/macros
  # (configured in test.exs). For tests needing a custom path, use with_registry/2.

  # Ensure fixtures are loaded — other async:false test modules may have
  # cleared the registry and not yet restored it depending on run order.
  setup do
    Registry.reload()
    :ok
  end

  describe "loading" do
    test "loads all valid fixtures" do
      assert Registry.count() >= 6
    end

    test "get returns a loaded definition" do
      assert {:ok, def} = Registry.get("greeting")
      assert def.name == "greeting"
      assert def.body_type == :prompt
    end

    test "get returns :error for unknown name" do
      assert :error = Registry.get("nonexistent")
    end
  end

  describe "list" do
    test "returns all definitions sorted by name" do
      macros = Registry.list()
      names = Enum.map(macros, & &1.name)
      assert "greeting" in names
      assert "kubernetes" in names
      assert "deploy" in names
      assert names == Enum.sort(names)
    end
  end

  describe "list_by_trigger" do
    test "returns explicit-trigger macros" do
      macros = Registry.list_by_trigger(:explicit)
      names = Enum.map(macros, & &1.name)
      assert "greeting" in names
      assert "deploy" in names
      refute "kubernetes" in names
    end

    test "returns match-trigger macros" do
      macros = Registry.list_by_trigger(:match)
      names = Enum.map(macros, & &1.name)
      assert "kubernetes" in names
      refute "greeting" in names
    end

    test "returns empty list for unused trigger" do
      assert [] = Registry.list_by_trigger(:ambient)
    end
  end

  describe "list_by_advertising" do
    test "returns listed macros" do
      macros = Registry.list_by_advertising(:listed)
      names = Enum.map(macros, & &1.name)
      assert "greeting" in names
      assert "standup" in names
    end

    test "returns discoverable macros" do
      macros = Registry.list_by_advertising(:discoverable)
      names = Enum.map(macros, & &1.name)
      assert "deploy" in names
    end

    test "returns hidden macros" do
      macros = Registry.list_by_advertising(:hidden)
      names = Enum.map(macros, & &1.name)
      assert "kubernetes" in names
    end
  end

  describe "search" do
    test "matches by name substring" do
      results = Registry.search("greet")
      assert length(results) == 1
      assert hd(results).name == "greeting"
    end

    test "matches by description substring" do
      results = Registry.search("deployment")
      assert Enum.any?(results, &(&1.name == "deploy"))
    end

    test "matches by tag" do
      results = Registry.search("pipeline")
      assert Enum.any?(results, &(&1.name == "test-pipeline"))
    end

    test "case-insensitive search" do
      results = Registry.search("KUBERNETES")
      assert Enum.any?(results, &(&1.name == "kubernetes"))
    end

    test "no results for non-matching query" do
      assert [] = Registry.search("zzz_nonexistent_zzz")
    end
  end

  describe "reload" do
    test "reload returns :ok" do
      assert :ok = Registry.reload()
      assert Registry.count() >= 6
    end
  end

  describe "custom directories" do
    test "name collision: last-writer-wins on duplicate names" do
      tmp = make_tmp_dir("collision")

      macro1 = minimal_json("dupe") |> Map.put("description", "first")
      macro2 = minimal_json("dupe") |> Map.put("description", "second")

      File.write!(Path.join(tmp, "dupe1.json"), Jason.encode!(macro1))
      File.write!(Path.join(tmp, "dupe2.json"), Jason.encode!(macro2))

      with_registry(tmp, fn ->
        assert {:ok, def} = Registry.get("dupe")
        assert def.name == "dupe"
        assert Registry.count() == 1
      end)
    end

    test "starts empty when directory does not exist" do
      bogus = "/tmp/nonexistent_macro_dir_#{System.unique_integer([:positive])}"

      with_registry(bogus, fn ->
        assert Registry.count() == 0
        assert [] = Registry.list()
      end)
    end

    test "skips invalid JSON files" do
      tmp = make_tmp_dir("invalid")

      valid = minimal_json("valid")
      File.write!(Path.join(tmp, "valid.json"), Jason.encode!(valid))
      File.write!(Path.join(tmp, "bad_json.json"), "not json at all {{{")
      File.write!(Path.join(tmp, "bad_schema.json"), Jason.encode!(%{"name" => 123}))

      with_registry(tmp, fn ->
        assert Registry.count() == 1
        assert {:ok, _} = Registry.get("valid")
      end)
    end
  end

  # --- Helpers ---

  defp with_registry(path, fun) do
    # Stop the app-level registry, run with a custom path, then restore
    Supervisor.terminate_child(Cranium.Supervisor, Registry)
    Supervisor.delete_child(Cranium.Supervisor, Registry)

    try do
      {:ok, _pid} = Registry.start_link(path: path)
      fun.()
    after
      GenServer.stop(Registry)
      Supervisor.start_child(Cranium.Supervisor, {Registry, []})
    end
  end

  defp make_tmp_dir(label) do
    tmp = Path.join(System.tmp_dir!(), "macro_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp minimal_json(name) do
    %{
      "name" => name,
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
