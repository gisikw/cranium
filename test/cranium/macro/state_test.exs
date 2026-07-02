defmodule Cranium.Macro.StateTest do
  use ExUnit.Case, async: false

  alias Cranium.Macro.State

  @test_state_path Path.join(
                     System.tmp_dir!(),
                     "cranium_macro_state_test_#{System.unique_integer([:positive])}"
                   )

  setup do
    # Clean up any prior test state
    File.rm_rf!(@test_state_path)
    File.mkdir_p!(@test_state_path)

    # Override the config for this test
    original = Application.get_env(:cranium, :paths)
    paths = Keyword.put(original || [], :macros_state, @test_state_path)
    Application.put_env(:cranium, :paths, paths)

    on_exit(fn ->
      File.rm_rf!(@test_state_path)
      if original, do: Application.put_env(:cranium, :paths, original)
    end)

    :ok
  end

  # --- Persistent state ---

  describe "persistent state get/put" do
    test "put_state and get_state roundtrip" do
      assert :ok = State.put_state("test-macro", "room-1", %{"count" => 42})
      assert {:ok, %{"count" => 42}} = State.get_state("test-macro", "room-1")
    end

    test "get_state returns :error for missing state" do
      assert :error = State.get_state("nonexistent", "room-1")
    end

    test "put_state overwrites existing state" do
      State.put_state("test-macro", "room-1", %{"v" => 1})
      State.put_state("test-macro", "room-1", %{"v" => 2})
      assert {:ok, %{"v" => 2}} = State.get_state("test-macro", "room-1")
    end

    test "state is isolated between rooms" do
      State.put_state("test-macro", "room-1", %{"room" => "one"})
      State.put_state("test-macro", "room-2", %{"room" => "two"})

      assert {:ok, %{"room" => "one"}} = State.get_state("test-macro", "room-1")
      assert {:ok, %{"room" => "two"}} = State.get_state("test-macro", "room-2")
    end

    test "state is isolated between macros" do
      State.put_state("macro-a", "room-1", %{"who" => "a"})
      State.put_state("macro-b", "room-1", %{"who" => "b"})

      assert {:ok, %{"who" => "a"}} = State.get_state("macro-a", "room-1")
      assert {:ok, %{"who" => "b"}} = State.get_state("macro-b", "room-1")
    end
  end

  describe "persistent state disk storage" do
    test "state is written to disk as JSON" do
      State.put_state("disk-test", "room-1", %{"persisted" => true})

      path = Path.join([@test_state_path, "room-1", "disk-test.json"])
      assert File.exists?(path)

      content = File.read!(path) |> Jason.decode!()
      assert content == %{"persisted" => true}
    end

    test "state survives ETS eviction (loads from disk)" do
      State.put_state("reload-test", "room-1", %{"value" => "from-disk"})

      # Evict from ETS to simulate cold cache
      :ets.delete(Cranium.Macro.State, {"reload-test", "room-1"})

      # Should load from disk
      assert {:ok, %{"value" => "from-disk"}} = State.get_state("reload-test", "room-1")
    end

    test "sanitizes room and macro names for filesystem safety" do
      State.put_state("my/macro", "room with spaces", %{"safe" => true})

      # Should use sanitized path
      path = Path.join([@test_state_path, "room_with_spaces", "my_macro.json"])
      assert File.exists?(path)
    end
  end

  describe "init_state/3" do
    test "initializes with defaults when no state exists" do
      assert :ok = State.init_state("fresh", "room-1", %{"initialized" => true})
      assert {:ok, %{"initialized" => true}} = State.get_state("fresh", "room-1")
    end

    test "does not overwrite existing state" do
      State.put_state("existing", "room-1", %{"original" => true})
      assert :ok = State.init_state("existing", "room-1", %{"replaced" => true})
      assert {:ok, %{"original" => true}} = State.get_state("existing", "room-1")
    end

    test "defaults to empty map" do
      assert :ok = State.init_state("empty-default", "room-1")
      assert {:ok, %{}} = State.get_state("empty-default", "room-1")
    end
  end

  # --- Session state ---

  describe "session state" do
    test "get_session returns empty map for unknown room" do
      assert %{} = State.get_session("unknown-room-#{System.unique_integer()}")
    end

    test "put_session and get_session roundtrip" do
      room = "session-test-#{System.unique_integer()}"
      session = %{seen: MapSet.new(["k8s"]), discovered: MapSet.new(["deploy"])}

      assert :ok = State.put_session(room, session)
      assert ^session = State.get_session(room)
    end

    test "put_session overwrites previous session" do
      room = "overwrite-test-#{System.unique_integer()}"
      State.put_session(room, %{seen: MapSet.new(["a"])})
      State.put_session(room, %{seen: MapSet.new(["b"])})

      assert %{seen: seen} = State.get_session(room)
      assert MapSet.member?(seen, "b")
      refute MapSet.member?(seen, "a")
    end

    test "clear_session removes session state" do
      room = "clear-test-#{System.unique_integer()}"
      State.put_session(room, %{seen: MapSet.new(["x"])})
      assert :ok = State.clear_session(room)
      assert %{} = State.get_session(room)
    end

    test "session state is not persisted to disk" do
      room = "no-disk-#{System.unique_integer()}"
      State.put_session(room, %{seen: MapSet.new(["test"])})

      # No file should exist for session state
      refute File.exists?(Path.join([@test_state_path, room]))
    end
  end
end
