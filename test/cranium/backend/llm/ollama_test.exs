defmodule Cranium.Backend.LLM.OllamaTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.Ollama

  describe "manages_tool_loop?/0" do
    test "returns false" do
      refute Ollama.manages_tool_loop?()
    end
  end

  # Message building is tested indirectly through stream_chat integration.
  # NDJSON parsing and dispatch are internal — tested via the tagged message protocol.
end
