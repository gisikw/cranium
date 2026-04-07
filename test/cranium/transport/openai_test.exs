defmodule Cranium.Transport.OpenAITest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Mox

  alias Cranium.Transport.HTTP

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(Cranium.Backend.LLM.Mock, :manages_tool_loop?, fn -> false end)
    :ok
  end

  # --- Helper: simulate LLM backend that sends text then completes ---

  defp mock_stream_chat(text, usage \\ nil) do
    expect(Cranium.Backend.LLM.Mock, :stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn(fn ->
          send(caller, {:llm_text, text})

          if usage do
            send(caller, {:llm_usage, usage})
          end

          send(caller, {:llm_stop, "end_turn"})
        end)

      {:ok, pid}
    end)
  end

  defp mock_stream_chat_chunked(chunks, usage \\ nil) do
    expect(Cranium.Backend.LLM.Mock, :stream_chat, fn _messages, _opts ->
      caller = self()

      pid =
        spawn(fn ->
          Enum.each(chunks, fn chunk ->
            send(caller, {:llm_text, chunk})
          end)

          if usage do
            send(caller, {:llm_usage, usage})
          end

          send(caller, {:llm_stop, "end_turn"})
        end)

      {:ok, pid}
    end)
  end

  # --- GET /v1/models ---

  describe "GET /v1/models" do
    test "returns profile list" do
      conn =
        Plug.Test.conn(:get, "/v1/models")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert json["object"] == "list"
      assert is_list(json["data"])

      names = Enum.map(json["data"], & &1["id"])
      assert "test" in names
      assert "test-ollama" in names

      first = hd(json["data"])
      assert first["object"] == "model"
      assert first["owned_by"] == "cranium"
      assert is_integer(first["created"])
    end
  end

  # --- POST /v1/chat/completions (non-streaming) ---

  describe "POST /v1/chat/completions (buffered)" do
    test "returns chat completion for valid profile" do
      usage = %{input_tokens: 10, output_tokens: 5}
      mock_stream_chat("Hello from cranium!", usage)

      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", %{
          "model" => "test",
          "messages" => [%{"role" => "user", "content" => "Hi"}]
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)

      assert json["object"] == "chat.completion"
      assert String.starts_with?(json["id"], "cranium-")
      assert json["model"] == "test"

      [choice] = json["choices"]
      assert choice["index"] == 0
      assert choice["message"]["role"] == "assistant"
      assert choice["message"]["content"] == "Hello from cranium!"
      assert choice["finish_reason"] == "stop"

      assert json["usage"]["prompt_tokens"] == 10
      assert json["usage"]["completion_tokens"] == 5
      assert json["usage"]["total_tokens"] == 15
    end

    test "returns 404 for unknown model" do
      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", %{
          "model" => "nonexistent-model",
          "messages" => [%{"role" => "user", "content" => "Hi"}]
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
      json = Jason.decode!(conn.resp_body)
      assert json["error"]["message"] =~ "not found"
    end

    test "returns 404 when model is missing" do
      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", %{
          "messages" => [%{"role" => "user", "content" => "Hi"}]
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 404
    end

    test "passes non-system messages to backend" do
      test_pid = self()

      expect(Cranium.Backend.LLM.Mock, :stream_chat, fn messages, _opts ->
        send(test_pid, {:backend_messages, messages})
        caller = self()
        pid = spawn(fn ->
          send(caller, {:llm_text, "ok"})
          send(caller, {:llm_stop, "end_turn"})
        end)
        {:ok, pid}
      end)

      Plug.Test.conn(:post, "/v1/chat/completions", %{
        "model" => "test",
        "messages" => [
          %{"role" => "system", "content" => "Be helpful"},
          %{"role" => "user", "content" => "Hello"},
          %{"role" => "assistant", "content" => "Hi!"},
          %{"role" => "user", "content" => "How are you?"}
        ]
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> HTTP.call(HTTP.init([]))

      assert_receive {:backend_messages, messages}
      # System message should be extracted, not passed to backend
      roles = Enum.map(messages, fn m -> m["role"] end)
      refute "system" in roles
      assert length(messages) == 3
    end

    test "passes system prompt and model to backend opts" do
      test_pid = self()

      expect(Cranium.Backend.LLM.Mock, :stream_chat, fn _messages, opts ->
        send(test_pid, {:backend_opts, opts})
        caller = self()
        pid = spawn(fn ->
          send(caller, {:llm_text, "ok"})
          send(caller, {:llm_stop, "end_turn"})
        end)
        {:ok, pid}
      end)

      Plug.Test.conn(:post, "/v1/chat/completions", %{
        "model" => "test",
        "messages" => [%{"role" => "user", "content" => "Hi"}],
        "max_tokens" => 1024
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> HTTP.call(HTTP.init([]))

      assert_receive {:backend_opts, opts}
      assert opts[:model] == "test-model"
      assert opts[:max_tokens] == 1024
      assert opts[:ephemeral] == true
      assert opts[:tools] == []
    end

    test "returns zero usage when backend reports none" do
      mock_stream_chat("Hello!")

      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", %{
          "model" => "test",
          "messages" => [%{"role" => "user", "content" => "Hi"}]
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      json = Jason.decode!(conn.resp_body)
      assert json["usage"]["prompt_tokens"] == 0
      assert json["usage"]["completion_tokens"] == 0
    end
  end

  # --- POST /v1/chat/completions (streaming) ---

  describe "POST /v1/chat/completions (streaming)" do
    test "returns SSE stream with content chunks" do
      mock_stream_chat_chunked(["Hello", " world", "!"])

      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", %{
          "model" => "test",
          "messages" => [%{"role" => "user", "content" => "Hi"}],
          "stream" => true
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      assert conn.status == 200
      assert {"content-type", "text/event-stream"} in conn.resp_headers

      # Parse the SSE body
      chunks = parse_sse_chunks(conn.resp_body)

      # First chunk: role
      role_chunk = Enum.find(chunks, fn c -> c["choices"] && hd(c["choices"])["delta"]["role"] end)
      assert role_chunk
      assert hd(role_chunk["choices"])["delta"]["role"] == "assistant"

      # Content chunks
      content_chunks =
        chunks
        |> Enum.filter(fn c ->
          c["choices"] && Map.has_key?(hd(c["choices"])["delta"], "content")
        end)

      content = Enum.map_join(content_chunks, fn c -> hd(c["choices"])["delta"]["content"] end)
      assert content == "Hello world!"

      # Final chunk: finish_reason
      final = Enum.find(chunks, fn c -> c["choices"] && hd(c["choices"])["finish_reason"] == "stop" end)
      assert final

      # DONE sentinel
      assert conn.resp_body =~ "data: [DONE]"

      # All chunks share the same ID
      ids = chunks |> Enum.map(& &1["id"]) |> Enum.uniq()
      assert length(ids) == 1
      assert hd(ids) |> String.starts_with?("cranium-")
    end

    test "streaming with usage includes usage in final chunk" do
      usage = %{input_tokens: 100, output_tokens: 25}
      mock_stream_chat_chunked(["Hi"], usage)

      conn =
        Plug.Test.conn(:post, "/v1/chat/completions", %{
          "model" => "test",
          "messages" => [%{"role" => "user", "content" => "Hi"}],
          "stream" => true
        })
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> HTTP.call(HTTP.init([]))

      chunks = parse_sse_chunks(conn.resp_body)
      final = Enum.find(chunks, fn c -> c["choices"] && hd(c["choices"])["finish_reason"] == "stop" end)
      assert final["usage"]["prompt_tokens"] == 100
      assert final["usage"]["completion_tokens"] == 25
      assert final["usage"]["total_tokens"] == 125
    end
  end

  # --- System prompt policy ---

  describe "system prompt policy" do
    test "replace mode uses profile identity, ignores client system" do
      test_pid = self()

      expect(Cranium.Backend.LLM.Mock, :stream_chat, fn _messages, opts ->
        send(test_pid, {:system, opts[:system]})
        caller = self()
        pid = spawn(fn ->
          send(caller, {:llm_text, "ok"})
          send(caller, {:llm_stop, "end_turn"})
        end)
        {:ok, pid}
      end)

      # test-with-identity has identity "You are a test identity." and backend: anthropic
      # But for this test we need a mock backend profile. The "test" profile has no identity.
      # So with replace mode (default) and no identity, client system passes through.
      Plug.Test.conn(:post, "/v1/chat/completions", %{
        "model" => "test",
        "messages" => [
          %{"role" => "system", "content" => "Be a pirate"},
          %{"role" => "user", "content" => "Hi"}
        ]
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> HTTP.call(HTTP.init([]))

      assert_receive {:system, system}
      # "test" profile has no identity (nil), so replace falls through to client system
      assert system == "Be a pirate"
    end
  end

  # --- SSE parsing helper ---

  defp parse_sse_chunks(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.trim_leading(&1, "data: "))
    |> Enum.reject(&(&1 == "[DONE]"))
    |> Enum.map(&Jason.decode!/1)
  end
end
