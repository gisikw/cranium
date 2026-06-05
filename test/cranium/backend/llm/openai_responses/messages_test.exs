defmodule Cranium.Backend.LLM.OpenAIResponses.MessagesTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.OpenAIResponses.Messages

  describe "translate/2" do
    test "passes system prompt as instructions" do
      {instructions, _input} = Messages.translate([], "You are helpful")
      assert instructions == "You are helpful"
    end

    test "nil system prompt" do
      {instructions, _input} = Messages.translate([], nil)
      assert instructions == nil
    end

    test "translates simple user text message" do
      messages = [%{role: "user", content: "hello"}]
      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [%{role: "user", content: "hello"}]
    end

    test "translates user message with text content blocks" do
      messages = [%{role: "user", content: [%{type: "text", text: "hello"}]}]
      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [%{role: "user", content: "hello"}]
    end

    test "translates simple assistant text message" do
      messages = [%{role: "assistant", content: "I'll help"}]
      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [
               %{type: "message", role: "assistant", content: [%{type: "output_text", text: "I'll help"}]}
             ]
    end

    test "translates assistant message with text blocks" do
      messages = [
        %{role: "assistant", content: [%{type: "text", text: "checking..."}]}
      ]

      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [
               %{type: "message", role: "assistant", content: [%{type: "output_text", text: "checking..."}]}
             ]
    end

    test "translates assistant message with tool_use blocks" do
      messages = [
        %{
          role: "assistant",
          content: [
            %{type: "text", text: "Let me search"},
            %{type: "tool_use", id: "toolu_abc", name: "read", input: %{"path" => "/foo"}}
          ]
        }
      ]

      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [
               %{
                 type: "message",
                 role: "assistant",
                 content: [%{type: "output_text", text: "Let me search"}]
               },
               %{
                 type: "function_call",
                 call_id: "toolu_abc",
                 name: "read",
                 arguments: ~s({"path":"/foo"})
               }
             ]
    end

    test "translates tool result user message" do
      messages = [
        %{
          role: "user",
          content: [
            %{type: "tool_result", tool_use_id: "toolu_abc", content: "file contents here"}
          ]
        }
      ]

      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [
               %{type: "function_call_output", call_id: "toolu_abc", output: "file contents here"}
             ]
    end

    test "translates mixed user message with tool results and text" do
      messages = [
        %{
          role: "user",
          content: [
            %{type: "tool_result", tool_use_id: "toolu_abc", content: "result"},
            %{type: "text", text: "now do this"}
          ]
        }
      ]

      {_instructions, input} = Messages.translate(messages, nil)

      assert input == [
               %{type: "function_call_output", call_id: "toolu_abc", output: "result"},
               %{role: "user", content: "now do this"}
             ]
    end

    test "handles string-keyed message maps" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "hi"},
            %{"type" => "tool_use", "id" => "t1", "name" => "bash", "input" => %{"cmd" => "ls"}}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "output"}
          ]
        }
      ]

      {_instructions, input} = Messages.translate(messages, nil)

      assert length(input) == 4
      assert Enum.at(input, 0) == %{role: "user", content: "hello"}
      assert %{type: "function_call", call_id: "t1"} = Enum.at(input, 2)
      assert %{type: "function_call_output", call_id: "t1"} = Enum.at(input, 3)
    end

    test "full conversation round-trip" do
      messages = [
        %{role: "user", content: "read /etc/hostname"},
        %{
          role: "assistant",
          content: [
            %{type: "text", text: "Let me read that file."},
            %{type: "tool_use", id: "tc_1", name: "read", input: %{"path" => "/etc/hostname"}}
          ]
        },
        %{
          role: "user",
          content: [
            %{type: "tool_result", tool_use_id: "tc_1", content: "ratched\n"}
          ]
        },
        %{role: "assistant", content: "Your hostname is ratched."}
      ]

      {instructions, input} = Messages.translate(messages, "Be concise")

      assert instructions == "Be concise"
      assert length(input) == 5

      assert Enum.at(input, 0) == %{role: "user", content: "read /etc/hostname"}

      assert %{type: "message", role: "assistant", content: [%{type: "output_text"}]} =
               Enum.at(input, 1)

      assert %{type: "function_call", call_id: "tc_1", name: "read"} = Enum.at(input, 2)
      assert %{type: "function_call_output", call_id: "tc_1", output: "ratched\n"} = Enum.at(input, 3)

      assert %{type: "message", role: "assistant", content: [%{type: "output_text", text: "Your hostname is ratched."}]} =
               Enum.at(input, 4)
    end
  end

  describe "translate_tools/1" do
    test "translates tool definitions" do
      tools = [
        %{name: "read", description: "Read a file", input_schema: %{type: "object", properties: %{path: %{type: "string"}}}}
      ]

      result = Messages.translate_tools(tools)

      assert result == [
               %{
                 type: "function",
                 name: "read",
                 description: "Read a file",
                 parameters: %{type: "object", properties: %{path: %{type: "string"}}}
               }
             ]
    end

    test "handles string-keyed tool definitions" do
      tools = [
        %{"name" => "bash", "description" => "Run a command", "input_schema" => %{"type" => "object"}}
      ]

      result = Messages.translate_tools(tools)
      assert [%{type: "function", name: "bash"}] = result
    end

    test "returns empty list for non-list input" do
      assert Messages.translate_tools(nil) == []
    end
  end
end
