defmodule Cranium.Backend.LLM.TiamatTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.Tiamat

  test "completed responses emit text, usage, and end_turn" do
    response = %{
      "status" => "completed",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 4},
      "transcript_delta" => [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "hello "},
            %{"type" => "text", "text" => "world"}
          ]
        }
      ]
    }

    assert :ok = Tiamat.dispatch_response(self(), response)
    assert_receive {:llm_text, "hello "}
    assert_receive {:llm_text, "world"}
    assert_receive {:llm_usage, %{input_tokens: 10, output_tokens: 4}}
    assert_receive {:llm_stop, "end_turn"}
  end

  test "tool_call responses emit tool calls and tool_use stop" do
    response = %{
      "status" => "tool_call",
      "transcript_delta" => [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "I'll check."},
            %{
              "type" => "tool_use",
              "tool_use_id" => "toolu_1",
              "tool_name" => "bash",
              "tool_input" => %{"command" => "printf hello"}
            }
          ]
        }
      ]
    }

    assert :ok = Tiamat.dispatch_response(self(), response)
    assert_receive {:llm_text, "I'll check."}

    assert_receive {:llm_tool_use,
                    %{id: "toolu_1", name: "bash", input: %{"command" => "printf hello"}}}

    assert_receive {:llm_stop, "tool_use"}
  end

  test "error responses emit backend error stop" do
    response = %{
      "status" => "error",
      "error_code" => "invalid_request",
      "errors" => [%{"code" => "invalid_request", "message" => "bad", "recoverable" => false}]
    }

    assert :ok = Tiamat.dispatch_response(self(), response)

    assert_receive {:llm_stop,
                    {:error,
                     %{
                       error_code: "invalid_request",
                       errors: [
                         %{
                           "code" => "invalid_request",
                           "message" => "bad",
                           "recoverable" => false
                         }
                       ]
                     }}}
  end
end
