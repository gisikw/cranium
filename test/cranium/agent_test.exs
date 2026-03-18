defmodule Cranium.AgentTest do
  use ExUnit.Case, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)
    egress = self()
    {:ok, egress: egress}
  end

  defp start_agent do
    {:ok, pid} = Cranium.Agent.start_link(conversation_id: "test-agent")
    pid
  end

  describe "tool execution loop" do
    test "executes a real tool and re-enters inference", %{egress: egress} do
      test_pid = self()

      # Register a test tool
      tools_before = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, tools_before) end)
      Cranium.Agent.ToolRouter.register("echo", Cranium.AgentTest.EchoTool)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Let me check"})
            send(caller, {:llm_tool_use, %{id: "tc_1", name: "echo", input: %{"msg" => "hi"}}})
            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        # Second call — verify tool_result is in the messages
        send(test_pid, {:second_call_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Done!"})
            send(caller, {:llm_usage, %{input_tokens: 50, output_tokens: 10}})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s1"}
      {:ok, result} = Cranium.Agent.infer(agent, context, egress)

      # Final output is from the second inference call
      assert result.output == "Done!"

      # Verify the second call got the tool result
      assert_receive {:second_call_messages, messages}

      # Should have: user msg, assistant (with tool_use), tool_result
      assert length(messages) == 3
      [_user, assistant, tool_result] = messages
      assert assistant.role == "assistant"
      assert tool_result.role == "user"
      [%{type: "tool_result", tool_use_id: "tc_1", content: content}] = tool_result.content
      assert content =~ "hi"
    end

    test "handles marker tools with fake success", %{egress: egress} do
      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Here's an image"})
            send(caller, {:llm_tool_use, %{id: "tc_m", name: "show", input: %{"url" => "img.png"}}})
            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        # Verify marker got fake success
        tool_result = List.last(messages)
        [%{content: content}] = tool_result.content
        assert content == ~s({"success": true})

        caller = self()
        pid = spawn(fn ->
          send(caller, {:llm_text, "There you go"})
          send(caller, {:llm_stop, "end_turn"})
        end)
        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "show me"}], stream_id: "s2"}
      {:ok, result} = Cranium.Agent.infer(agent, context, egress)
      assert result.output == "There you go"

      # Should have received the marker on the egress channel
      assert_receive {:chunk, "s2", {:marker, %{type: :marker, marker: :show, payload: %{"url" => "img.png"}}}}
    end

    test "handles unknown tools with error result", %{egress: egress} do
      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_tool_use, %{id: "tc_u", name: "nonexistent", input: %{}}})
            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        tool_result = List.last(messages)
        [%{content: content}] = tool_result.content
        assert content =~ "unknown tool"

        caller = self()
        pid = spawn(fn ->
          send(caller, {:llm_text, "Sorry, I cannot do that"})
          send(caller, {:llm_stop, "end_turn"})
        end)
        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "use magic"}], stream_id: "s3"}
      {:ok, result} = Cranium.Agent.infer(agent, context, egress)
      assert result.output == "Sorry, I cannot do that"
    end

    test "passes tool definitions to LLM backend", %{egress: egress} do
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, opts ->
        send(test_pid, {:opts_received, opts})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "hi"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s5"}
      {:ok, _result} = Cranium.Agent.infer(agent, context, egress)

      assert_receive {:opts_received, opts}
      tools = Keyword.get(opts, :tools)
      assert is_list(tools)
      assert length(tools) > 0
      names = Enum.map(tools, & &1.name)
      assert "show" in names
    end

    test "cancel terminates LLM process mid-inference", %{egress: egress} do
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Starting..."})
            # Notify test that streaming has begun so it can send cancel
            send(test_pid, :llm_streaming)
            # Block indefinitely — cancel should terminate us
            Process.sleep(:infinity)
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s-cancel"}

      # Run infer in a separate process so we can send cancel
      task =
        Task.async(fn ->
          Cranium.Agent.infer(agent, context, egress)
        end)

      # Wait for LLM to start streaming, then cancel
      assert_receive :llm_streaming, 2000
      GenServer.cast(agent, :cancel)

      # Should return with cancelled error
      result = Task.await(task, 5000)
      assert {:error, :cancelled} = result
    end

    test "keeps last usage snapshot across tool use rounds", %{egress: egress} do
      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_usage, %{input_tokens: 100, output_tokens: 20}})
            send(caller, {:llm_tool_use, %{id: "tc_x", name: "nonexistent", input: %{}}})
            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_usage, %{input_tokens: 150, output_tokens: 30}})
            send(caller, {:llm_text, "done"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s4"}
      {:ok, result} = Cranium.Agent.infer(agent, context, egress)

      # Last snapshot wins — reflects actual context window state
      assert result.usage.input_tokens == 150
      assert result.usage.output_tokens == 30
    end
  end
end

defmodule Cranium.AgentTest.EchoTool do
  @behaviour Cranium.Agent.Tool

  @impl true
  def execute(input, _opts), do: {:ok, Jason.encode!(input)}

  @impl true
  def name, do: "echo"

  @impl true
  def schema do
    %{
      name: "echo",
      description: "Echoes the input back as JSON",
      input_schema: %{type: "object", properties: %{msg: %{type: "string"}}}
    }
  end
end
