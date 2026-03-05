defmodule Cranium.StageTest do
  use ExUnit.Case, async: true

  alias Cranium.Stage

  describe "new_stream_id/0" do
    test "generates unique IDs" do
      id1 = Stage.new_stream_id()
      id2 = Stage.new_stream_id()

      assert is_binary(id1)
      assert is_binary(id2)
      assert id1 != id2
      assert String.length(id1) == 16
    end
  end

  describe "buffer_chunk/3" do
    test "creates new buffer for first chunk" do
      buffers = Stage.buffer_chunk(%{}, "stream-1", "hello")
      assert buffers == %{"stream-1" => ["hello"]}
    end

    test "prepends subsequent chunks" do
      buffers =
        %{}
        |> Stage.buffer_chunk("stream-1", "hello")
        |> Stage.buffer_chunk("stream-1", " world")

      assert buffers == %{"stream-1" => [" world", "hello"]}
    end

    test "maintains separate buffers per stream" do
      buffers =
        %{}
        |> Stage.buffer_chunk("stream-1", "hello")
        |> Stage.buffer_chunk("stream-2", "goodbye")

      assert Map.keys(buffers) |> Enum.sort() == ["stream-1", "stream-2"]
    end
  end

  describe "flush_buffer/2" do
    test "returns concatenated data in order" do
      buffers =
        %{}
        |> Stage.buffer_chunk("s1", "hello")
        |> Stage.buffer_chunk("s1", " world")

      {data, remaining} = Stage.flush_buffer(buffers, "s1")
      assert data == "hello world"
      assert remaining == %{}
    end

    test "returns empty binary for missing stream" do
      {data, buffers} = Stage.flush_buffer(%{}, "nonexistent")
      assert data == ""
      assert buffers == %{}
    end

    test "preserves other buffers" do
      buffers =
        %{}
        |> Stage.buffer_chunk("s1", "hello")
        |> Stage.buffer_chunk("s2", "goodbye")

      {_data, remaining} = Stage.flush_buffer(buffers, "s1")
      assert Map.has_key?(remaining, "s2")
      refute Map.has_key?(remaining, "s1")
    end
  end
end
