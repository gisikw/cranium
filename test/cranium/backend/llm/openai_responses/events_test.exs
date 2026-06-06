defmodule Cranium.Backend.LLM.OpenAIResponses.EventsTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.OpenAIResponses.Events

  describe "dispatch_event/3 — text" do
    test "sends llm_text on output_text.delta" do
      event = %{
        event: "response.output_text.delta",
        data: Jason.encode!(%{"delta" => "Hello"})
      }

      Events.dispatch_event(self(), event, %{})
      assert_received {:llm_text, "Hello"}
    end

    test "ignores malformed text delta" do
      event = %{event: "response.output_text.delta", data: "not json"}
      Events.dispatch_event(self(), event, %{})
      refute_received {:llm_text, _}
    end
  end

  describe "dispatch_event/3 — tool calls" do
    test "initializes accumulator on output_item.added for function_call" do
      event = %{
        event: "response.output_item.added",
        data:
          Jason.encode!(%{
            "output_index" => 0,
            "item" => %{
              "type" => "function_call",
              "call_id" => "call_abc",
              "name" => "read"
            }
          })
      }

      acc = Events.dispatch_event(self(), event, %{})
      assert acc == %{0 => %{call_id: "call_abc", name: "read", arguments: ""}}
    end

    test "accumulates function_call_arguments.delta" do
      acc = %{0 => %{call_id: "call_abc", name: "read", arguments: "{\"pa"}}

      event = %{
        event: "response.function_call_arguments.delta",
        data: Jason.encode!(%{"output_index" => 0, "delta" => "th\":\"/foo\"}"})
      }

      acc = Events.dispatch_event(self(), event, acc)
      assert acc[0].arguments == "{\"path\":\"/foo\"}"
    end

    test "ignores delta for unknown output_index" do
      event = %{
        event: "response.function_call_arguments.delta",
        data: Jason.encode!(%{"output_index" => 5, "delta" => "x"})
      }

      acc = Events.dispatch_event(self(), event, %{})
      assert acc == %{}
    end

    test "sends llm_tool_use on output_item.done for function_call" do
      acc = %{0 => %{call_id: "call_abc", name: "read", arguments: ~s({"path":"/foo"})}}

      event = %{
        event: "response.output_item.done",
        data:
          Jason.encode!(%{
            "output_index" => 0,
            "item" => %{"type" => "function_call"}
          })
      }

      new_acc = Events.dispatch_event(self(), event, acc)
      assert_received {:llm_tool_use, %{id: "call_abc", name: "read", input: %{"path" => "/foo"}}}
      assert new_acc == %{_had_tool_calls: true}
    end

    test "handles malformed arguments JSON gracefully" do
      acc = %{0 => %{call_id: "call_abc", name: "read", arguments: "not json"}}

      event = %{
        event: "response.output_item.done",
        data: Jason.encode!(%{"output_index" => 0, "item" => %{"type" => "function_call"}})
      }

      Events.dispatch_event(self(), event, acc)
      assert_received {:llm_tool_use, %{id: "call_abc", name: "read", input: %{}}}
    end

    test "ignores output_item.done for non-function_call" do
      event = %{
        event: "response.output_item.done",
        data: Jason.encode!(%{"output_index" => 0, "item" => %{"type" => "message"}})
      }

      acc = Events.dispatch_event(self(), event, %{})
      assert acc == %{}
      refute_received {:llm_tool_use, _}
    end
  end

  describe "dispatch_event/3 — completion" do
    test "sends usage and end_turn on response.completed (text only)" do
      event = %{
        event: "response.completed",
        data:
          Jason.encode!(%{
            "response" => %{
              "output" => [%{"type" => "message"}],
              "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
            }
          })
      }

      Events.dispatch_event(self(), event, %{})
      assert_received {:llm_usage, %{input_tokens: 100, output_tokens: 50}}
      assert_received {:llm_stop, "end_turn"}
    end

    test "sends tool_use stop reason when output has function_call" do
      event = %{
        event: "response.completed",
        data:
          Jason.encode!(%{
            "response" => %{
              "output" => [
                %{"type" => "message"},
                %{"type" => "function_call"}
              ],
              "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
            }
          })
      }

      Events.dispatch_event(self(), event, %{})
      assert_received {:llm_stop, "tool_use"}
    end

    test "handles response.completed with missing usage" do
      event = %{
        event: "response.completed",
        data: Jason.encode!(%{"response" => %{"output" => []}})
      }

      Events.dispatch_event(self(), event, %{})
      assert_received {:llm_stop, "end_turn"}
      refute_received {:llm_usage, _}
    end
  end

  describe "dispatch_event/3 — errors" do
    test "sends error on response.failed" do
      event = %{
        event: "response.failed",
        data:
          Jason.encode!(%{
            "response" => %{
              "error" => %{"code" => "rate_limit_exceeded", "message" => "slow down"}
            }
          })
      }

      Events.dispatch_event(self(), event, %{})

      assert_received {:llm_stop,
                       {:error, :response_failed,
                        %{"code" => "rate_limit_exceeded", "message" => "slow down"}}}
    end

    test "sends error on response.incomplete" do
      event = %{event: "response.incomplete", data: "{}"}
      Events.dispatch_event(self(), event, %{})
      assert_received {:llm_stop, {:error, :incomplete}}
    end
  end

  describe "dispatch_event/3 — ignored events" do
    test "ignores unknown event types" do
      event = %{event: "response.reasoning_text.delta", data: "{}"}
      acc = Events.dispatch_event(self(), event, %{some: :state})
      assert acc == %{some: :state}
      refute_received _
    end
  end

  describe "dispatch_events/3" do
    test "processes multiple events in order" do
      events = [
        %{event: "response.output_text.delta", data: Jason.encode!(%{"delta" => "Hi"})},
        %{event: "response.output_text.delta", data: Jason.encode!(%{"delta" => " there"})},
        %{
          event: "response.completed",
          data:
            Jason.encode!(%{
              "response" => %{
                "output" => [],
                "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
              }
            })
        }
      ]

      Events.dispatch_events(self(), events, %{})

      assert_received {:llm_text, "Hi"}
      assert_received {:llm_text, " there"}
      assert_received {:llm_usage, %{input_tokens: 10, output_tokens: 5}}
      assert_received {:llm_stop, "end_turn"}
    end
  end
end
