defmodule Cranium.Backend.LLM.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Cranium.Backend.LLM.ClaudeCode

  describe "manages_tool_loop?/0" do
    test "returns true" do
      assert ClaudeCode.manages_tool_loop?() == true
    end
  end

  describe "stream_chat/2 — port-based streaming" do
    test "parses stream-json from a subprocess" do
      # Simulate CC output by echoing stream-json lines
      init_line = Jason.encode!(%{type: "system", subtype: "init", session_id: "test-sess-001", tools: []})
      text_line = Jason.encode!(%{type: "assistant", message: %{content: [%{type: "text", text: "Hello from CC"}]}})
      result_line = Jason.encode!(%{type: "result", subtype: "success", result: %{usage: %{input_tokens: 100, output_tokens: 25}}})

      # We'll use a script that echoes these lines instead of actual claude
      script = "echo '#{init_line}'\necho '#{text_line}'\necho '#{result_line}'"
      script_path = write_temp_script(script)

      # Override claude path to our test script
      backends = Application.get_env(:cranium, :backends, [])
      Application.put_env(:cranium, :backends, Keyword.put(backends, :claude_code_path, script_path))
      on_exit(fn ->
        Application.put_env(:cranium, :backends, backends)
        File.rm(script_path)
      end)

      {:ok, _pid} = ClaudeCode.stream_chat(
        [%{role: "user", content: "hello"}],
        [system: "be helpful", bypass_permissions: false]
      )

      assert_receive {:cc_session, "test-sess-001"}, 5000
      assert_receive {:llm_text, "Hello from CC"}, 5000
      assert_receive {:llm_usage, %{input_tokens: 100, output_tokens: 25}}, 5000
      assert_receive {:llm_stop, "end_turn"}, 5000
    end

    test "handles MCP marker tool calls in stream" do
      marker_line = Jason.encode!(%{
        type: "assistant",
        message: %{content: [
          %{type: "text", text: "Check this out:"},
          %{type: "tool_use", id: "m1", name: "mcp__cranium-markers__show", input: %{url: "img.png"}}
        ]}
      })
      result_line = Jason.encode!(%{type: "result", subtype: "success", result: %{usage: %{input_tokens: 50, output_tokens: 10}}})

      script = "echo '#{marker_line}'\necho '#{result_line}'"
      script_path = write_temp_script(script)

      backends = Application.get_env(:cranium, :backends, [])
      Application.put_env(:cranium, :backends, Keyword.put(backends, :claude_code_path, script_path))
      on_exit(fn ->
        Application.put_env(:cranium, :backends, backends)
        File.rm(script_path)
      end)

      {:ok, _pid} = ClaudeCode.stream_chat(
        [%{role: "user", content: "show me"}],
        [bypass_permissions: false]
      )

      assert_receive {:llm_text, "Check this out:"}, 5000
      assert_receive {:llm_tool_use, %{id: "m1", name: "show", input: %{"url" => "img.png"}}}, 5000
      assert_receive {:llm_stop, "end_turn"}, 5000
    end

    test "handles non-zero exit status" do
      script_path = write_temp_script("exit 1")

      backends = Application.get_env(:cranium, :backends, [])
      Application.put_env(:cranium, :backends, Keyword.put(backends, :claude_code_path, script_path))
      on_exit(fn ->
        Application.put_env(:cranium, :backends, backends)
        File.rm(script_path)
      end)

      {:ok, _pid} = ClaudeCode.stream_chat(
        [%{role: "user", content: "fail"}],
        [bypass_permissions: false]
      )

      assert_receive {:llm_stop, {:error, {:exit_status, _}}}, 5000
    end

    test "cleans up temp files after streaming" do
      result_line = Jason.encode!(%{type: "result", subtype: "success", result: %{usage: %{input_tokens: 0, output_tokens: 0}}})
      script_path = write_temp_script("echo '#{result_line}'")

      backends = Application.get_env(:cranium, :backends, [])
      Application.put_env(:cranium, :backends, Keyword.put(backends, :claude_code_path, script_path))
      on_exit(fn ->
        Application.put_env(:cranium, :backends, backends)
        File.rm(script_path)
      end)

      {:ok, pid} = ClaudeCode.stream_chat(
        [%{role: "user", content: "test"}],
        [system: "system prompt here", bypass_permissions: false]
      )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 5000

      # Temp files should be cleaned up (we can't easily inspect them,
      # but verify no crash from cleanup)
    end
  end

  defp write_temp_script(content) do
    path = Path.join(System.tmp_dir!(), "cc_test_#{:rand.uniform(999999)}.sh")
    File.write!(path, "#!/bin/sh\n#{content}")
    File.chmod!(path, 0o755)
    path
  end
end
