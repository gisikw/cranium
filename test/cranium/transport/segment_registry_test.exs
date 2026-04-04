defmodule Cranium.Transport.SegmentRegistryTest do
  use ExUnit.Case, async: true

  alias Cranium.Transport.SegmentRegistry

  setup do
    name = :"segment_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = SegmentRegistry.start_link(name: name)
    %{name: name}
  end

  describe "open/5" do
    test "registers a take", %{name: name} do
      assert :ok = SegmentRegistry.open("t1", "s1", "conv1", ["text"], name: name)
    end

    test "returns conflict on duplicate take_id", %{name: name} do
      :ok = SegmentRegistry.open("t1", "s1", "conv1", ["text"], name: name)
      assert {:error, :conflict} = SegmentRegistry.open("t1", "s2", "conv1", ["text"], name: name)
    end
  end

  describe "put_chunk/4" do
    test "buffers chunk for open take", %{name: name} do
      :ok = SegmentRegistry.open("t1", "s1", "conv1", ["text"], name: name)
      assert {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 0, "audio0", name: name)
    end

    test "returns not_found for unknown take", %{name: name} do
      assert {:error, :not_found} = SegmentRegistry.put_chunk("nope", 0, "data", name: name)
    end
  end

  describe "seal/3" do
    test "returns complete when all chunks present", %{name: name} do
      :ok = SegmentRegistry.open("t1", "s1", "conv1", ["audio"], name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 0, "a", name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 1, "b", name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 2, "c", name: name)

      assert {:ok, :complete, result} = SegmentRegistry.seal("t1", 2, name: name)
      assert result.audio == "abc"
      assert result.stream_id == "s1"
      assert result.conversation_id == "conv1"
    end

    test "returns incomplete with missing chunks", %{name: name} do
      :ok = SegmentRegistry.open("t1", "s1", "conv1", ["audio"], name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 0, "a", name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 1, "b", name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 3, "d", name: name)

      assert {:ok, :incomplete, [2]} = SegmentRegistry.seal("t1", 3, name: name)
    end

    test "returns not_found for unknown take", %{name: name} do
      assert {:error, :not_found} = SegmentRegistry.seal("nope", 0, name: name)
    end
  end

  describe "backfill" do
    test "put_chunk on sealed take completes when last gap filled", %{name: name} do
      :ok = SegmentRegistry.open("t1", "s1", "conv1", ["audio"], name: name)
      {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 0, "a", name: name)
      {:ok, :incomplete, [1]} = SegmentRegistry.seal("t1", 1, name: name)

      assert {:ok, :complete, result} = SegmentRegistry.put_chunk("t1", 1, "b", name: name)
      assert result.audio == "ab"
    end

    test "put_chunk on sealed take with remaining gaps returns buffered", %{name: name} do
      :ok = SegmentRegistry.open("t1", "s1", "conv1", ["audio"], name: name)
      {:ok, :incomplete, [0, 1, 2]} = SegmentRegistry.seal("t1", 2, name: name)

      assert {:ok, :buffered} = SegmentRegistry.put_chunk("t1", 0, "a", name: name)
    end
  end
end
