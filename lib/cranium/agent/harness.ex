defmodule Cranium.Agent.Harness do
  @moduledoc """
  Core agent inference loop.

  Manages the send-receive-tool_call cycle:

  1. Send assembled context (system + messages) to LLM backend
  2. Stream response via SSE
  3. Forward text chunks to Egress for delivery
  4. On tool_use stop reason:
     a. Route through ToolRouter (real tool or marker?)
     b. Execute or intercept accordingly
     c. Append tool_result to messages
     d. Loop back to step 1
  5. On end_turn stop reason: signal completion

  ## Streaming

  The Harness receives SSE events from the LLM backend and must:
  - Parse content_block_delta events for text chunks
  - Detect content_block_start for tool_use blocks
  - Accumulate tool input JSON across deltas
  - Detect message_stop for turn completion
  - Track token usage from message_delta events

  ## Token Tracking

  Each response includes input_tokens, output_tokens, and cache metrics.
  These are accumulated across tool-call loops and reported to the Session
  for saturation tracking.
  """

  require Logger

  @type inference_result :: %{
          text: String.t(),
          tool_calls: [map()],
          stop_reason: String.t(),
          usage: map()
        }

  @doc """
  Run a single inference turn (no tool-call looping).

  Returns the parsed response. The Agent GenServer handles the loop.
  """
  @spec run_turn(module(), map(), keyword()) :: {:ok, inference_result()} | {:error, term()}
  def run_turn(backend, context, opts \\ []) do
    system = context[:system_prompt] || ""
    messages = context[:messages] || []

    case backend.stream_chat(messages, Keyword.merge(opts, system: system)) do
      {:ok, stream_pid} ->
        collect_response(stream_pid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private ---

  defp collect_response(stream_pid) do
    ref = Process.monitor(stream_pid)
    do_collect(ref, %{text: "", tool_calls: [], stop_reason: nil, usage: %{}})
  end

  defp do_collect(ref, acc) do
    receive do
      {:llm_text, text} ->
        do_collect(ref, %{acc | text: acc.text <> text})

      {:llm_tool_use, tool_call} ->
        do_collect(ref, %{acc | tool_calls: [tool_call | acc.tool_calls]})

      {:llm_usage, usage} ->
        do_collect(ref, %{acc | usage: Map.merge(acc.usage, usage)})

      {:llm_stop, reason} ->
        Process.demonitor(ref, [:flush])
        {:ok, %{acc | stop_reason: reason, tool_calls: Enum.reverse(acc.tool_calls)}}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, {:stream_died, reason}}
    end
  end
end
