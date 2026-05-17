defmodule Cranium.Backend.LLM.CCStreamParserTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.CCStreamParser

  describe "parse_line/2 — system init" do
    test "extracts session_id from init event" do
      line = ~s({"type":"system","subtype":"init","session_id":"abc-123","tools":[]})
      assert {:ok, [{:cc_session, "abc-123"}]} = CCStreamParser.parse_line(line)
    end

    test "skips init event without session_id" do
      line = ~s({"type":"system","subtype":"init"})
      assert :skip = CCStreamParser.parse_line(line)
    end
  end

  describe "parse_line/2 — assistant content" do
    test "extracts text from text block" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{content: [%{type: "text", text: "Hello world"}]}
        })

      assert {:ok, [{:llm_text, "Hello world"}]} = CCStreamParser.parse_line(line)
    end

    test "extracts usage from assistant message" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [%{type: "text", text: "Hi"}],
            usage: %{
              input_tokens: 5,
              output_tokens: 10,
              cache_creation_input_tokens: 100,
              cache_read_input_tokens: 20_000
            }
          }
        })

      assert {:ok, messages} = CCStreamParser.parse_line(line)
      assert {:llm_text, "Hi"} = Enum.at(messages, 0)
      assert {:llm_usage, usage} = Enum.at(messages, 1)
      assert usage.input_tokens == 5
      assert usage.output_tokens == 10
      assert usage.cache_read_input_tokens == 20_000
    end

    test "skips empty text blocks" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{content: [%{type: "text", text: ""}]}
        })

      assert :skip = CCStreamParser.parse_line(line)
    end

    test "extracts MCP marker tool calls" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [
              %{
                type: "tool_use",
                id: "tool_1",
                name: "mcp__cranium-markers__show",
                input: %{url: "img.png"}
              }
            ]
          }
        })

      assert {:ok, [{:llm_tool_use, %{id: "tool_1", name: "show", input: %{"url" => "img.png"}}}]} =
               CCStreamParser.parse_line(line)
    end

    test "extracts MCP switch_room marker tool call" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [
              %{
                type: "tool_use",
                id: "tool_sr",
                name: "mcp__cranium-markers__switch_room",
                input: %{room_id: "fort-nix"}
              }
            ]
          }
        })

      assert {:ok,
              [{:llm_tool_use, %{id: "tool_sr", name: "switch_room", input: %{"room_id" => "fort-nix"}}}]} =
               CCStreamParser.parse_line(line)
    end

    test "emits cc_tool_use for native CC tool calls" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [
              %{
                type: "tool_use",
                id: "tool_2",
                name: "Read",
                input: %{file_path: "/tmp/test"}
              }
            ]
          }
        })

      assert {:ok,
              [
                {:cc_tool_use,
                 %{id: "tool_2", name: "Read", input: %{"file_path" => "/tmp/test"}}}
              ]} =
               CCStreamParser.parse_line(line)
    end

    test "skips unrecognized MCP tools" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [
              %{
                type: "tool_use",
                id: "tool_3",
                name: "mcp__cranium-markers__unknown_tool",
                input: %{}
              }
            ]
          }
        })

      assert :skip = CCStreamParser.parse_line(line)
    end

    test "handles mixed text and marker blocks" do
      line =
        Jason.encode!(%{
          type: "assistant",
          message: %{
            content: [
              %{type: "text", text: "Here's an image:"},
              %{
                type: "tool_use",
                id: "t1",
                name: "mcp__cranium-markers__show",
                input: %{url: "pic.png"}
              },
              %{type: "text", text: " and some code:"},
              %{
                type: "tool_use",
                id: "t2",
                name: "mcp__cranium-markers__show_code",
                input: %{code: "x = 1"}
              }
            ]
          }
        })

      assert {:ok, messages} = CCStreamParser.parse_line(line)
      assert length(messages) == 4

      assert {:llm_text, "Here's an image:"} = Enum.at(messages, 0)
      assert {:llm_tool_use, %{name: "show"}} = Enum.at(messages, 1)
      assert {:llm_text, " and some code:"} = Enum.at(messages, 2)
      assert {:llm_tool_use, %{name: "show_code"}} = Enum.at(messages, 3)
    end
  end

  describe "parse_line/2 — result" do
    test "emits stop without usage (cumulative usage is ignored)" do
      line =
        Jason.encode!(%{
          type: "result",
          subtype: "success",
          result: "Some response text",
          usage: %{
            input_tokens: 1500,
            output_tokens: 300,
            cache_creation_input_tokens: 100,
            cache_read_input_tokens: 50
          }
        })

      assert {:ok, [{:llm_stop, "end_turn"}]} = CCStreamParser.parse_line(line)
    end

    test "handles error result" do
      line =
        Jason.encode!(%{
          type: "result",
          subtype: "error",
          error: %{message: "context window exceeded"}
        })

      assert {:ok, [{:llm_stop, {:error, "context window exceeded"}}]} =
               CCStreamParser.parse_line(line)
    end
  end

  describe "parse_line/2 — CC tool results" do
    test "extracts tool result with file info" do
      line =
        Jason.encode!(%{
          type: "user",
          message: %{
            role: "user",
            content: [%{tool_use_id: "toolu_abc", type: "tool_result", content: "ratched\n"}]
          },
          tool_use_result: %{
            type: "text",
            file: %{filePath: "/etc/hostname", content: "ratched\n"}
          }
        })

      assert {:ok,
              [{:cc_tool_result, %{tool_use_id: "toolu_abc", content: "Read /etc/hostname"}}]} =
               CCStreamParser.parse_line(line)
    end

    test "extracts tool result with plain text content" do
      line =
        Jason.encode!(%{
          type: "user",
          message: %{
            role: "user",
            content: [%{tool_use_id: "toolu_def", type: "tool_result", content: "ok"}]
          },
          tool_use_result: %{type: "text", content: "command output here"}
        })

      assert {:ok,
              [{:cc_tool_result, %{tool_use_id: "toolu_def", content: "command output here"}}]} =
               CCStreamParser.parse_line(line)
    end
  end

  describe "parse_line/2 — edge cases" do
    test "skips empty lines" do
      assert :skip = CCStreamParser.parse_line("")
      assert :skip = CCStreamParser.parse_line("   ")
    end

    test "skips malformed JSON" do
      assert :skip = CCStreamParser.parse_line("{not json")
    end

    test "skips user events without tool_use_result" do
      line = Jason.encode!(%{type: "user", message: %{content: "plain text"}})
      assert :skip = CCStreamParser.parse_line(line)
    end

    test "skips unknown event types" do
      line = Jason.encode!(%{type: "ping"})
      assert :skip = CCStreamParser.parse_line(line)
    end
  end

  describe "demangle_mcp_name/1" do
    test "demanges cranium-markers prefix" do
      assert {:ok, "show"} = CCStreamParser.demangle_mcp_name("mcp__cranium-markers__show")

      assert {:ok, "play_audio"} =
               CCStreamParser.demangle_mcp_name("mcp__cranium-markers__play_audio")
    end

    test "returns :not_mcp for non-MCP names" do
      assert :not_mcp = CCStreamParser.demangle_mcp_name("Read")
      assert :not_mcp = CCStreamParser.demangle_mcp_name("Bash")
    end

    test "returns :not_mcp for other MCP servers" do
      assert :not_mcp = CCStreamParser.demangle_mcp_name("mcp__other-server__tool")
    end
  end
end
