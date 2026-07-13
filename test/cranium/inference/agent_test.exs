defmodule Cranium.Inference.AgentTest do
  use CraniumTest.DataCase, async: false

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)
    :ok
  end

  # Subscribe the test process to events via Cranium.Events.
  # Must be called before Agent.infer so the test process receives broadcasts.
  defp subscribe_stream(stream_id) do
    Cranium.Events.subscribe({:stream_raw, stream_id})
  end

  defp subscribe_conversation(conversation_id) do
    Cranium.Events.subscribe({:conversation, conversation_id})
  end

  defp subscribe_global do
    Cranium.Events.subscribe()
  end

  defp start_agent do
    {:ok, pid} = Cranium.Inference.Agent.start_link(conversation_id: "test-agent")
    pid
  end

  describe "tool execution loop" do
    test "executes a real tool and re-enters inference" do
      test_pid = self()

      # Register a test tool
      tools_before = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, tools_before) end)
      Cranium.Inference.Agent.ToolRouter.register("echo", Cranium.Inference.AgentTest.EchoTool)

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
      subscribe_stream("s1")
      {:ok, result} = Cranium.Inference.Agent.infer(agent, context)

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

    test "preserves native assistant content blocks while executing tool calls" do
      test_pid = self()

      tools_before = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, tools_before) end)
      Cranium.Inference.Agent.ToolRouter.register("echo", Cranium.Inference.AgentTest.EchoTool)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_assistant_content,
               [
                 %{"type" => "thinking", "text" => "I should use the echo tool."},
                 %{"type" => "text", "text" => "Let me check"},
                 %{
                   "type" => "tool_use",
                   "tool_use_id" => "tc_native",
                   "tool_name" => "echo",
                   "tool_input" => %{"msg" => "hi"}
                 }
               ]}
            )

            send(caller, {:llm_text, "Let me check"})

            send(
              caller,
              {:llm_tool_use, %{id: "tc_native", name: "echo", input: %{"msg" => "hi"}}}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:native_second_call_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Done!"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s-native"}
      subscribe_stream("s-native")
      {:ok, result} = Cranium.Inference.Agent.infer(agent, context)

      assert result.output == "Done!"
      assert_receive {:native_second_call_messages, messages}
      [_user, assistant, tool_result] = messages

      assert assistant.role == "assistant"

      assert assistant.content == [
               %{type: "thinking", text: "I should use the echo tool."},
               %{type: "text", text: "Let me check"},
               %{type: "tool_use", id: "tc_native", name: "echo", input: %{"msg" => "hi"}}
             ]

      assert tool_result.role == "user"
      [%{type: "tool_result", tool_use_id: "tc_native", content: content}] = tool_result.content
      assert content =~ "hi"
    end

    test "handles marker tools with fake success" do
      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Here's an image"})

            send(
              caller,
              {:llm_tool_use, %{id: "tc_m", name: "show", input: %{"url" => "img.png"}}}
            )

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

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "There you go"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "show me"}], stream_id: "s2"}
      subscribe_stream("s2")
      {:ok, result} = Cranium.Inference.Agent.infer(agent, context)
      assert result.output == "There you go"

      # Should have received the marker on the egress channel
      assert_receive {:chunk, "s2",
                      {:marker, %{type: :marker, marker: :show, payload: %{"url" => "img.png"}}}}
    end

    test "handles unknown tools with error result" do
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

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "Sorry, I cannot do that"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "use magic"}], stream_id: "s3"}
      subscribe_stream("s3")
      {:ok, result} = Cranium.Inference.Agent.infer(agent, context)
      assert result.output == "Sorry, I cannot do that"
    end

    test "passes tool definitions to LLM backend" do
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
      subscribe_stream("s5")
      {:ok, _result} = Cranium.Inference.Agent.infer(agent, context)

      assert_receive {:opts_received, opts}
      tools = Keyword.get(opts, :tools)
      assert is_list(tools)
      assert length(tools) > 0
      names = Enum.map(tools, & &1.name)
      assert "clear_context" in names
    end

    test "cancel terminates LLM process mid-inference" do
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
      subscribe_stream("s-cancel")

      # Run infer in a separate process so we can send cancel
      task =
        Task.async(fn ->
          Cranium.Inference.Agent.infer(agent, context)
        end)

      # Wait for LLM to start streaming, then cancel
      assert_receive :llm_streaming, 2000
      GenServer.cast(agent, :cancel)

      # Should return with cancelled error and partial output
      result = Task.await(task, 5000)
      assert {:error, :cancelled, partial} = result
      assert partial.output == "Starting..."
      assert partial.interrupted_context == "Starting..."
    end

    test "cancel captures pending tool calls as interrupted context even without text" do
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use, %{id: "tc_1", name: "bash", input: %{"command" => "hostname"}}}
            )

            send(test_pid, :tool_seen)
            Process.sleep(:infinity)
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s-cancel-tool"}
      subscribe_stream("s-cancel-tool")

      task = Task.async(fn -> Cranium.Inference.Agent.infer(agent, context) end)

      assert_receive :tool_seen, 2000
      GenServer.cast(agent, :cancel)

      result = Task.await(task, 5000)
      assert {:error, :cancelled, partial} = result
      assert partial.output == ""
      assert partial.interrupted_context =~ "**bash**"
      assert partial.interrupted_context =~ "hostname"
    end

    test "cancel captures completed tool messages as interrupted context" do
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:cc_tool_use, %{id: "toolu_1", name: "bash", input: %{"command" => "pwd"}}}
            )

            send(caller, {:cc_tool_result, %{tool_use_id: "toolu_1", content: "/tmp"}})
            send(test_pid, :tool_result_seen)
            Process.sleep(:infinity)
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s-cancel-tool-result"}
      subscribe_stream("s-cancel-tool-result")

      task = Task.async(fn -> Cranium.Inference.Agent.infer(agent, context) end)

      assert_receive :tool_result_seen, 2000
      GenServer.cast(agent, :cancel)

      result = Task.await(task, 5000)
      assert {:error, :cancelled, partial} = result
      assert length(partial.intermediate_messages) == 2
      [assistant_msg, user_msg] = partial.intermediate_messages
      assert assistant_msg["role"] || assistant_msg[:role] == "assistant"
      assert user_msg["role"] || user_msg[:role] == "user"
    end

    test "keeps last usage snapshot across tool use rounds" do
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
      subscribe_stream("s4")
      {:ok, result} = Cranium.Inference.Agent.infer(agent, context)

      # Last snapshot wins — reflects actual context window state
      assert result.usage.input_tokens == 150
      assert result.usage.output_tokens == 30
    end

    test "single_pass async tool returns ack then injects result before completion" do
      test_pid = self()

      tools_before = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, tools_before) end)
      Cranium.Inference.Agent.ToolRouter.register("echo", Cranium.Inference.AgentTest.EchoTool)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_async",
                 name: "echo",
                 input: %{"msg" => "hi", "cranium_async_mode" => "single_pass"}
               }}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:ack_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "I'll keep going."})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:result_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "The background echo finished."})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s-async"}
      subscribe_stream("s-async")

      {:ok, result} = Cranium.Inference.Agent.infer(agent, context)
      assert result.output == "The background echo finished."

      assert_receive {:ack_messages, ack_messages}
      ack_tool_result = List.last(ack_messages)
      [%{type: "tool_result", tool_use_id: "tc_async", content: ack}] = ack_tool_result.content
      assert ack =~ "async_task_id"
      assert ack =~ "single_pass"

      assert_receive {:result_messages, result_messages}
      injected = List.last(result_messages)
      assert injected.role == "user"
      assert injected.content =~ "<async-tool-result"
      assert injected.content =~ "\"msg\":\"hi\""
      refute injected.content =~ "cranium_async_mode"

      assert_received {:chunk, "s-async", {:async_task, %{event_type: :started}}}

      assert_received {:chunk, "s-async",
                       {:async_task, %{event_type: :completed, preview: preview}}}

      assert preview =~ "hi"
    end

    test "unsupported async mode returns a tool error" do
      test_pid = self()

      tools_before = Application.get_env(:cranium, :tools, [])
      on_exit(fn -> Application.put_env(:cranium, :tools, tools_before) end)
      Cranium.Inference.Agent.ToolRouter.register("echo", Cranium.Inference.AgentTest.EchoTool)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{id: "tc_bad_mode", name: "echo", input: %{"cranium_async_mode" => "later"}}}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:bad_mode_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "handled"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      subscribe_stream("s-async-bad-mode")

      {:ok, result} =
        Cranium.Inference.Agent.infer(agent, %{messages: [], stream_id: "s-async-bad-mode"})

      assert result.output == "handled"

      assert_receive {:bad_mode_messages, messages}
      [%{type: "tool_result", content: content}] = List.last(messages).content
      assert content =~ "unsupported cranium_async_mode: later"
    end

    test "async mode on ineligible tools returns a tool error" do
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_marker_async",
                 name: "show",
                 input: %{"cranium_async_mode" => "single_pass"}
               }}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:ineligible_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "handled"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      subscribe_stream("s-async-ineligible")

      {:ok, result} =
        Cranium.Inference.Agent.infer(agent, %{messages: [], stream_id: "s-async-ineligible"})

      assert result.output == "handled"

      assert_receive {:ineligible_messages, messages}
      [%{type: "tool_result", content: content}] = List.last(messages).content
      assert content =~ "tool does not support cranium_async_mode"
    end

    test "async mode on clear_context returns a tool error instead of clearing" do
      test_pid = self()

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_clear_async",
                 name: "clear_context",
                 input: %{"cranium_async_mode" => "single_pass"}
               }}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:clear_async_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "not cleared"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      subscribe_stream("s-async-clear")

      {:ok, result} =
        Cranium.Inference.Agent.infer(agent, %{messages: [], stream_id: "s-async-clear"})

      assert result.output == "not cleared"

      assert_receive {:clear_async_messages, messages}
      [%{type: "tool_result", content: content}] = List.last(messages).content
      assert content =~ "tool does not support cranium_async_mode"
    end

    test "clear_context cancels async work already accepted in the same batch" do
      test_pid = self()

      tools_before = Application.get_env(:cranium, :tools, [])
      cancel_before = Application.get_env(:cranium, :async_cancel_grace_ms)
      kill_before = Application.get_env(:cranium, :async_kill_grace_ms)

      on_exit(fn ->
        Application.put_env(:cranium, :tools, tools_before)

        if cancel_before == nil,
          do: Application.delete_env(:cranium, :async_cancel_grace_ms),
          else: Application.put_env(:cranium, :async_cancel_grace_ms, cancel_before)

        if kill_before == nil,
          do: Application.delete_env(:cranium, :async_kill_grace_ms),
          else: Application.put_env(:cranium, :async_kill_grace_ms, kill_before)
      end)

      Application.put_env(:cranium, :async_cancel_grace_ms, 50)
      Application.put_env(:cranium, :async_kill_grace_ms, 50)

      Cranium.Inference.Agent.ToolRouter.register(
        "blocking",
        Cranium.Inference.AgentTest.BlockingTool
      )

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_clear_blocking",
                 name: "blocking",
                 input: %{"test_pid" => test_pid, "cranium_async_mode" => "single_pass"}
               }}
            )

            send(caller, {:llm_tool_use, %{id: "tc_clear", name: "clear_context", input: %{}}})
            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      subscribe_stream("s-async-clear-cancel")

      assert {:ok, %{status: :cleared}} =
               Cranium.Inference.Agent.infer(agent, %{
                 messages: [],
                 stream_id: "s-async-clear-cancel"
               })

      assert_received {:chunk, "s-async-clear-cancel", {:async_task, %{event_type: :started}}}

      assert_received {:chunk, "s-async-clear-cancel",
                       {:tool_result,
                        %{
                          tool_use_id: "tc_clear_blocking",
                          content: async_ack
                        }}}

      assert async_ack =~ "async_task_id"
      assert async_ack =~ "accepted"

      assert_received {:chunk, "s-async-clear-cancel", {:async_task, %{event_type: :cancelled}}}

      refute_received {:chunk, "s-async-clear-cancel", {:async_task, %{event_type: :completed}}}
    end

    test "enforces per-pass async fan-out limit" do
      test_pid = self()

      tools_before = Application.get_env(:cranium, :tools, [])
      limit_before = Application.get_env(:cranium, :max_async_tasks_per_pass)

      on_exit(fn ->
        Application.put_env(:cranium, :tools, tools_before)

        if limit_before == nil,
          do: Application.delete_env(:cranium, :max_async_tasks_per_pass),
          else: Application.put_env(:cranium, :max_async_tasks_per_pass, limit_before)
      end)

      Application.put_env(:cranium, :max_async_tasks_per_pass, 1)
      Cranium.Inference.Agent.ToolRouter.register("echo", Cranium.Inference.AgentTest.EchoTool)

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_async_1",
                 name: "echo",
                 input: %{"n" => 1, "cranium_async_mode" => "single_pass"}
               }}
            )

            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_async_2",
                 name: "echo",
                 input: %{"n" => 2, "cranium_async_mode" => "single_pass"}
               }}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:limit_ack_messages, messages})
        caller = self()
        pid = spawn(fn -> send(caller, {:llm_stop, "end_turn"}) end)
        {:ok, pid}
      end)
      |> expect(:stream_chat, fn messages, _opts ->
        send(test_pid, {:limit_result_messages, messages})
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "done"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      subscribe_stream("s-async-limit")

      {:ok, result} =
        Cranium.Inference.Agent.infer(agent, %{messages: [], stream_id: "s-async-limit"})

      assert result.output == "done"

      assert_receive {:limit_ack_messages, messages}
      [first_result, second_result] = Enum.take(messages, -2)
      [%{content: first_content}] = first_result.content
      [%{content: second_content}] = second_result.content
      assert first_content =~ "async_task_id"
      assert second_content =~ "async task limit reached for this pass"

      assert_receive {:limit_result_messages, messages}
      assert List.last(messages).content =~ "<async-tool-result"
    end

    test "cancel while awaiting async work emits terminal cue and does not inject late result" do
      test_pid = self()

      tools_before = Application.get_env(:cranium, :tools, [])
      cancel_before = Application.get_env(:cranium, :async_cancel_grace_ms)
      kill_before = Application.get_env(:cranium, :async_kill_grace_ms)

      on_exit(fn ->
        Application.put_env(:cranium, :tools, tools_before)

        if cancel_before == nil,
          do: Application.delete_env(:cranium, :async_cancel_grace_ms),
          else: Application.put_env(:cranium, :async_cancel_grace_ms, cancel_before)

        if kill_before == nil,
          do: Application.delete_env(:cranium, :async_kill_grace_ms),
          else: Application.put_env(:cranium, :async_kill_grace_ms, kill_before)
      end)

      Application.put_env(:cranium, :async_cancel_grace_ms, 50)
      Application.put_env(:cranium, :async_kill_grace_ms, 50)

      Cranium.Inference.Agent.ToolRouter.register(
        "blocking",
        Cranium.Inference.AgentTest.BlockingTool
      )

      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(
              caller,
              {:llm_tool_use,
               %{
                 id: "tc_blocking",
                 name: "blocking",
                 input: %{"test_pid" => test_pid, "cranium_async_mode" => "single_pass"}
               }}
            )

            send(caller, {:llm_stop, "tool_use"})
          end)

        {:ok, pid}
      end)
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()
        pid = spawn(fn -> send(caller, {:llm_stop, "end_turn"}) end)
        {:ok, pid}
      end)

      agent = start_agent()
      subscribe_stream("s-async-cancel")

      task =
        Task.async(fn ->
          Cranium.Inference.Agent.infer(agent, %{messages: [], stream_id: "s-async-cancel"})
        end)

      assert_receive :blocking_tool_started, 2_000
      GenServer.cast(agent, :cancel)

      assert {:error, :cancelled, _partial} = Task.await(task, 5_000)
      assert_received {:chunk, "s-async-cancel", {:async_task, %{event_type: :started}}}
      assert_received {:chunk, "s-async-cancel", {:async_task, %{event_type: :cancelled}}}
      refute_received {:result_messages, _}
    end
  end

  describe "conversation and global dispatch" do
    test "events are broadcast on conversation and global topics" do
      Cranium.Backend.LLM.Mock
      |> expect(:stream_chat, fn _messages, _opts ->
        caller = self()

        pid =
          spawn(fn ->
            send(caller, {:llm_text, "hello"})
            send(caller, {:llm_stop, "end_turn"})
          end)

        {:ok, pid}
      end)

      agent = start_agent()
      context = %{messages: [%{role: "user", content: "test"}], stream_id: "s-conv"}

      # Subscribe on all three topics
      subscribe_stream("s-conv")
      subscribe_conversation("test-agent")
      subscribe_global()

      {:ok, _result} = Cranium.Inference.Agent.infer(agent, context)

      # Per-stream topic (existing behavior)
      assert_received {:stream_start, "s-conv", _}
      assert_received {:chunk, "s-conv", "hello"}
      assert_received {:stream_end, "s-conv"}

      # Conversation topic
      assert_received {:stream_start, "s-conv", %{conversation_id: "test-agent"}}
      assert_received {:chunk, "s-conv", "hello"}
      assert_received {:stream_end, "s-conv"}

      # Global topic
      assert_received {:stream_start, "s-conv", %{conversation_id: "test-agent"}}
      assert_received {:chunk, "s-conv", "hello"}
      assert_received {:stream_end, "s-conv"}
    end
  end
end

defmodule Cranium.Inference.AgentTest.EchoTool do
  @behaviour Cranium.Inference.Agent.Tool

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

defmodule Cranium.Inference.AgentTest.BlockingTool do
  @behaviour Cranium.Inference.Agent.Tool

  @impl true
  def execute(%{"test_pid" => test_pid}, _opts) when is_pid(test_pid) do
    send(test_pid, :blocking_tool_started)
    Process.sleep(:infinity)
    {:ok, "unreachable"}
  end

  @impl true
  def name, do: "blocking"

  @impl true
  def schema do
    %{
      name: "blocking",
      description: "Blocks until killed",
      input_schema: %{type: "object", properties: %{}}
    }
  end
end
