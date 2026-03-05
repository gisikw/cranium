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

  describe "init_stream/3" do
    test "creates structured buffer with metadata" do
      metadata = %{conversation_id: "conv-1", mode: :text, content_type: :llm_response}
      buffers = Stage.init_stream(%{}, "s1", metadata)

      assert %{"s1" => %{chunks: [], metadata: ^metadata}} = buffers
    end

    test "maintains separate streams" do
      meta1 = %{mode: :text}
      meta2 = %{mode: :voice}

      buffers =
        %{}
        |> Stage.init_stream("s1", meta1)
        |> Stage.init_stream("s2", meta2)

      assert Map.keys(buffers) |> Enum.sort() == ["s1", "s2"]
      assert buffers["s1"].metadata == meta1
      assert buffers["s2"].metadata == meta2
    end
  end

  describe "buffer_chunk/3" do
    test "creates new buffer for first chunk (legacy)" do
      buffers = Stage.buffer_chunk(%{}, "stream-1", "hello")
      assert buffers == %{"stream-1" => ["hello"]}
    end

    test "prepends subsequent chunks (legacy)" do
      buffers =
        %{}
        |> Stage.buffer_chunk("stream-1", "hello")
        |> Stage.buffer_chunk("stream-1", " world")

      assert buffers == %{"stream-1" => [" world", "hello"]}
    end

    test "appends to structured buffer from init_stream" do
      buffers =
        %{}
        |> Stage.init_stream("s1", %{mode: :text})
        |> Stage.buffer_chunk("s1", "hello")
        |> Stage.buffer_chunk("s1", " world")

      assert buffers["s1"].chunks == [" world", "hello"]
      assert buffers["s1"].metadata == %{mode: :text}
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
    test "returns concatenated data in order (legacy)" do
      buffers =
        %{}
        |> Stage.buffer_chunk("s1", "hello")
        |> Stage.buffer_chunk("s1", " world")

      {data, remaining} = Stage.flush_buffer(buffers, "s1")
      assert data == "hello world"
      assert remaining == %{}
    end

    test "returns data and metadata for structured buffers" do
      metadata = %{conversation_id: "conv-1", mode: :voice}

      buffers =
        %{}
        |> Stage.init_stream("s1", metadata)
        |> Stage.buffer_chunk("s1", "hello")
        |> Stage.buffer_chunk("s1", " world")

      {data, returned_metadata, remaining} = Stage.flush_buffer(buffers, "s1")
      assert data == "hello world"
      assert returned_metadata == metadata
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
