defmodule Cranium.Inference.SuppressedThoughtTest do
  use ExUnit.Case, async: true

  alias Cranium.Inference.SuppressedThought

  describe "strip/1" do
    test "text without spans passes through untouched" do
      texts = [
        "Hello world.\n",
        "a < b, and 4 <sup>2</sup> = 16\n\nnext paragraph\n",
        "an orphan close tag </suppressed> stays put",
        "trailing whitespace survives  \n\n"
      ]

      for text <- texts do
        assert SuppressedThought.strip(text) == {text, []}
      end
    end

    test "removes a single inline span" do
      assert SuppressedThought.strip("Hello <suppressed>x</suppressed>world") ==
               {"Hello world", ["x"]}

      assert SuppressedThought.strip("Hello <suppressed>x</suppressed> world") ==
               {"Hello world", ["x"]}

      assert SuppressedThought.strip("AB<suppressed>x</suppressed>CD") == {"ABCD", ["x"]}
    end

    test "removes multiple spans" do
      {clean, spans} =
        SuppressedThought.strip(
          "One <suppressed>a</suppressed>two <suppressed>b</suppressed>three"
        )

      assert clean == "One two three"
      assert spans == ["a", "b"]
    end

    test "removes a multiline span" do
      {clean, spans} =
        SuppressedThought.strip(
          "Before.\n\n<suppressed>line one\nline two\n\nline four</suppressed>\n\nAfter."
        )

      assert clean == "Before.\n\nAfter."
      assert spans == ["line one\nline two\n\nline four"]
    end

    test "unclosed span strips from the tag to end of message" do
      assert SuppressedThought.strip("Public<suppressed>secret to the end") ==
               {"Public", ["secret to the end"]}

      assert SuppressedThought.strip("Public.\n\n<suppressed>secret\nmore") ==
               {"Public.", ["secret\nmore"]}
    end

    test "collapses whitespace cleanly around removed spans" do
      # blank line stays a single blank line, no dangling gaps
      assert SuppressedThought.strip("Para1.\n\n<suppressed>hidden</suppressed>\n\nPara2.") ==
               {"Para1.\n\nPara2.", ["hidden"]}

      # single newlines stay single newlines
      assert SuppressedThought.strip("A\n<suppressed>x</suppressed>\nB") == {"A\nB", ["x"]}

      # leading span leaves no leading whitespace
      assert SuppressedThought.strip("<suppressed>x</suppressed>\n\nHello") == {"Hello", ["x"]}

      # trailing span leaves no dangling whitespace
      assert SuppressedThought.strip("Hello\n\n<suppressed>x</suppressed>") == {"Hello", ["x"]}

      # consecutive spans collapse to one seam
      assert SuppressedThought.strip(
               "A\n\n<suppressed>x</suppressed>\n\n<suppressed>y</suppressed>\n\nB"
             ) == {"A\n\nB", ["x", "y"]}
    end

    test "a message that is entirely one span strips to empty" do
      assert SuppressedThought.strip("<suppressed>all of it</suppressed>") ==
               {"", ["all of it"]}
    end

    test "empty spans are removed but not reported" do
      assert SuppressedThought.strip("a <suppressed></suppressed> b") == {"a b", []}
    end

    test "duplicate span content is reported once" do
      {clean, spans} =
        SuppressedThought.strip("A <suppressed>x</suppressed> B <suppressed>x</suppressed> C")

      assert clean == "A B C"
      assert spans == ["x"]
    end
  end

  describe "streaming (push/finish)" do
    defp run_stream(chunks) do
      {visible, spans, t} =
        Enum.reduce(chunks, {"", [], SuppressedThought.new()}, fn chunk, {out, spans, t} ->
          {visible, new_spans, t} = SuppressedThought.push(t, chunk)
          {out <> visible, spans ++ new_spans, t}
        end)

      {tail, tail_spans, _t} = SuppressedThought.finish(t)
      {visible <> tail, spans ++ tail_spans}
    end

    test "strips a span whose tags are split across chunk boundaries" do
      chunks = ["Hello <supp", "ressed>sec", "ret</suppr", "essed> world"]
      assert run_stream(chunks) == {"Hello world", ["secret"]}
    end

    test "chunking does not change the result" do
      text = "Para1.\n\n<suppressed>hidden\nthought</suppressed>\n\nPara2 with a < sign.\n"
      expected = SuppressedThought.strip(text)

      for size <- [1, 2, 3, 5, 11] do
        chunks =
          text
          |> String.graphemes()
          |> Enum.chunk_every(size)
          |> Enum.map(&Enum.join/1)

        assert run_stream(chunks) == expected, "chunk size #{size} diverged"
      end
    end

    test "a false-positive tag prefix is released once disproven" do
      assert run_stream(["a <b", "old> c"]) == {"a <bold> c", []}
    end

    test "a partial tag prefix held at end of message is literal text" do
      assert run_stream(["tail <supp"]) == {"tail <supp", []}
    end

    test "an unclosed span across chunks is reported at finish" do
      assert run_stream(["ok <suppressed>one", " two"]) == {"ok", ["one two"]}
    end
  end

  describe "strip_blocks/2" do
    test "strips text blocks, leaves other block types untouched" do
      blocks = [
        %{type: "thinking", text: "keep <suppressed>even here</suppressed>"},
        %{type: "text", text: "Say <suppressed>quietly</suppressed>this"},
        %{type: "tool_use", id: "t1", name: "echo", input: %{}}
      ]

      {stripped, spans, _t} = SuppressedThought.strip_blocks(blocks, SuppressedThought.new())

      assert stripped == [
               %{type: "thinking", text: "keep <suppressed>even here</suppressed>"},
               %{type: "text", text: "Say this"},
               %{type: "tool_use", id: "t1", name: "echo", input: %{}}
             ]

      assert spans == ["quietly"]
    end

    test "drops text blocks emptied by stripping" do
      blocks = [%{type: "text", text: "<suppressed>gone</suppressed>"}]
      {stripped, spans, _t} = SuppressedThought.strip_blocks(blocks, SuppressedThought.new())
      assert stripped == []
      assert spans == ["gone"]
    end

    test "does not re-report spans the stream already saw" do
      {_visible, ["x"], t} =
        SuppressedThought.push(SuppressedThought.new(), "hi <suppressed>x</suppressed>there")

      blocks = [%{type: "text", text: "hi <suppressed>x</suppressed>there"}]
      {stripped, new_spans, _t} = SuppressedThought.strip_blocks(blocks, t)

      assert stripped == [%{type: "text", text: "hi there"}]
      assert new_spans == []
    end

    test "handles string-keyed blocks" do
      blocks = [%{"type" => "text", "text" => "a <suppressed>b</suppressed> c"}]
      {stripped, spans, _t} = SuppressedThought.strip_blocks(blocks, SuppressedThought.new())
      assert stripped == [%{"type" => "text", "text" => "a c"}]
      assert spans == ["b"]
    end
  end
end
