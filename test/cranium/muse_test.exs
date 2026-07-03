defmodule Cranium.MuseTest do
  use ExUnit.Case, async: true

  alias Cranium.Inference.ToolResultEnvelope
  alias Cranium.Muse

  describe "unwrap_exec_output/1" do
    test "unwraps a content envelope so the cross-repo discriminant matches" do
      envelope = %{
        "type" => "content",
        "content" => [
          %{"type" => "text", "text" => "screenshot captured"},
          %{"type" => "image", "grotto_ref" => "grotto://blob/abc123"}
        ]
      }

      wrapped = Jason.encode!(%{"output" => envelope})

      refute ToolResultEnvelope.envelope?(wrapped)

      unwrapped = Muse.unwrap_exec_output(wrapped)

      assert ToolResultEnvelope.envelope?(unwrapped)
      assert {:ok, blocks} = ToolResultEnvelope.parse(unwrapped)

      assert [%{"type" => "text"}, %{"type" => "image", "grotto_ref" => "grotto://blob/abc123"}] =
               blocks
    end

    test "unwraps pretty-printed ExecResult (muse uses MarshalIndent)" do
      wrapped = """
      {
        "output": {
          "type": "content",
          "content": [
            {
              "type": "text",
              "text": "hi"
            }
          ]
        }
      }
      """

      assert ToolResultEnvelope.envelope?(Muse.unwrap_exec_output(wrapped))
    end

    test "returns string output as-is without JSON quoting" do
      assert Muse.unwrap_exec_output(~s({"output": "plain text result"})) ==
               "plain text result"
    end

    test "re-encodes structured non-envelope output as JSON" do
      wrapped = Jason.encode!(%{"output" => %{"stdout" => "hi", "exit_code" => 0}})

      unwrapped = Muse.unwrap_exec_output(wrapped)

      assert Jason.decode!(unwrapped) == %{"stdout" => "hi", "exit_code" => 0}
    end

    test "passes non-JSON output through verbatim" do
      assert Muse.unwrap_exec_output("not json at all") == "not json at all"
    end

    test "passes JSON without an output key through verbatim" do
      assert Muse.unwrap_exec_output("{}") == "{}"
      assert Muse.unwrap_exec_output(~s({"stdout": "raw"})) == ~s({"stdout": "raw"})
    end

    test "passes a bare (already unwrapped) envelope through verbatim" do
      bare = Jason.encode!(%{"type" => "content", "content" => []})

      assert Muse.unwrap_exec_output(bare) == bare
      assert ToolResultEnvelope.envelope?(Muse.unwrap_exec_output(bare))
    end
  end
end
