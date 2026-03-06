defmodule Cranium.Egress.ChunkerTest do
  use ExUnit.Case, async: true

  alias Cranium.Egress.Chunker

  # Helper to build a paragraph of N words
  defp para(n), do: Enum.map_join(1..n, " ", fn _ -> "word" end)

  describe "process/2 voice mode — paragraph-boundary chunking" do
    test "single paragraph under 30 words emitted as one chunk (remainder flush)" do
      text = para(20)
      {:ok, chunks} = Chunker.process(text, %{mode: :voice})
      assert chunks == [text]
    end

    test "single paragraph at exactly 30 words is emitted as first batch" do
      text = para(30)
      {:ok, chunks} = Chunker.process(text, %{mode: :voice})
      assert chunks == [text]
    end

    test "two paragraphs crossing 30-word threshold: first batch emitted, remainder flushed" do
      p1 = para(20)
      p2 = para(15)
      text = p1 <> "\n\n" <> p2
      {:ok, chunks} = Chunker.process(text, %{mode: :voice})
      # p1 alone is 20 words (< 30), p1+p2 combined = 35 words (>= 30), so both go in first batch
      assert chunks == [p1 <> "\n\n" <> p2]
    end

    test "paragraphs crossing 30 words first batch, then remainder flushed" do
      # p1=20 words, p2=15 words → combined 35 >= 30 → emit as first chunk
      # p3=10 words → remainder, flushed as second chunk
      p1 = para(20)
      p2 = para(15)
      p3 = para(10)
      text = Enum.join([p1, p2, p3], "\n\n")
      {:ok, chunks} = Chunker.process(text, %{mode: :voice})
      assert length(chunks) == 2
      assert Enum.at(chunks, 0) == p1 <> "\n\n" <> p2
      assert Enum.at(chunks, 1) == p3
    end

    test "enough paragraphs to cross 30 (first) then 100 (rest)" do
      # First chunk: accumulate until >= 30 words
      # p1=20, p2=15 → 35 >= 30 → emit chunk 1
      # Rest chunk: accumulate until >= 100 words
      # p3=50, p4=55 → 105 >= 100 → emit chunk 2
      # p5=10 → remainder flushed as chunk 3
      p1 = para(20)
      p2 = para(15)
      p3 = para(50)
      p4 = para(55)
      p5 = para(10)
      text = Enum.join([p1, p2, p3, p4, p5], "\n\n")
      {:ok, chunks} = Chunker.process(text, %{mode: :voice})
      assert length(chunks) == 3
      assert Enum.at(chunks, 0) == p1 <> "\n\n" <> p2
      assert Enum.at(chunks, 1) == p3 <> "\n\n" <> p4
      assert Enum.at(chunks, 2) == p5
    end

    test "empty paragraphs are filtered" do
      text = para(10) <> "\n\n\n\n" <> para(25)
      {:ok, chunks} = Chunker.process(text, %{mode: :voice})
      # 35 words total >= 30 → single chunk, no empty paragraphs
      assert length(chunks) == 1
    end

    test "text with only blank paragraphs returns empty list" do
      {:ok, chunks} = Chunker.process("\n\n  \n\n", %{mode: :voice})
      assert chunks == []
    end
  end

  describe "process/2 text mode — paragraph splitting" do
    test "splits on double newlines" do
      text = "Para one.\n\nPara two.\n\nPara three."
      {:ok, chunks} = Chunker.process(text, %{mode: :text})
      assert chunks == ["Para one.", "Para two.", "Para three."]
    end

    test "filters blank paragraphs" do
      text = "Para one.\n\n\n\nPara two."
      {:ok, chunks} = Chunker.process(text, %{mode: :text})
      assert chunks == ["Para one.", "Para two."]
    end

    test "single paragraph with no newlines returned as one chunk" do
      text = "Just one paragraph."
      {:ok, chunks} = Chunker.process(text, %{mode: :text})
      assert chunks == ["Just one paragraph."]
    end
  end

  describe "process/2 markers" do
    test "markers pass through unchanged" do
      marker = %{type: :marker, id: "abc"}
      {:ok, [result]} = Chunker.process(marker, %{mode: :voice})
      assert result == marker
    end
  end
end
