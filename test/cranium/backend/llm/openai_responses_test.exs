defmodule Cranium.Backend.LLM.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.OpenAIResponses

  describe "manages_tool_loop?/0" do
    test "returns false" do
      refute OpenAIResponses.manages_tool_loop?()
    end
  end
end
