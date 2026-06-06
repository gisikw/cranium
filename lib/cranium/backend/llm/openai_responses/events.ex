defmodule Cranium.Backend.LLM.OpenAIResponses.Events do
  @moduledoc """
  Dispatches OpenAI Responses API SSE events into tagged messages
  for the Agent's receive loop.

  The Responses API uses named event types (like Anthropic) rather than
  the Chat Completions delta-only format. Tool call arguments are
  streamed incrementally and accumulated until `output_item.done`.

  ## Handled Events

  - `response.output_text.delta` → `{:llm_text, delta}`
  - `response.output_item.added` → init tool accumulator (function_call items)
  - `response.function_call_arguments.delta` → append to tool accumulator
  - `response.output_item.done` → `{:llm_tool_use, ...}` (function_call items)
  - `response.completed` → `{:llm_usage, ...}` + `{:llm_stop, ...}`
  - `response.failed` → `{:llm_stop, {:error, ...}}`
  - `response.incomplete` → `{:llm_stop, {:error, :incomplete}}`
  """

  require Logger

  @doc """
  Process a list of parsed SSE events, returning updated tool accumulator.
  """
  @spec dispatch_events(pid(), [map()], map()) :: map()
  def dispatch_events(caller, events, tool_acc) do
    Enum.reduce(events, tool_acc, fn event, acc ->
      dispatch_event(caller, event, acc)
    end)
  end

  @doc """
  Process a single SSE event. Returns updated tool accumulator.
  """
  @spec dispatch_event(pid(), map(), map()) :: map()

  # Text content delta
  def dispatch_event(caller, %{event: "response.output_text.delta", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"delta" => delta}} when is_binary(delta) ->
        send(caller, {:llm_text, delta})

      _ ->
        :ok
    end

    tool_acc
  end

  # New output item — initialize tool accumulator for function_call items
  def dispatch_event(_caller, %{event: "response.output_item.added", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"output_index" => idx, "item" => %{"type" => "function_call", "call_id" => call_id, "name" => name}}} ->
        Map.put(tool_acc, idx, %{call_id: call_id, name: name, arguments: ""})

      _ ->
        tool_acc
    end
  end

  # Function call arguments streaming delta
  def dispatch_event(_caller, %{event: "response.function_call_arguments.delta", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"output_index" => idx, "delta" => delta}} when is_binary(delta) ->
        case Map.get(tool_acc, idx) do
          %{arguments: existing} = entry ->
            Map.put(tool_acc, idx, %{entry | arguments: existing <> delta})

          nil ->
            tool_acc
        end

      _ ->
        tool_acc
    end
  end

  # Output item complete — emit tool_use for function_call items
  def dispatch_event(caller, %{event: "response.output_item.done", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"output_index" => idx, "item" => %{"type" => "function_call"}}} ->
        case Map.pop(tool_acc, idx) do
          {%{call_id: call_id, name: name, arguments: args_json}, new_acc} ->
            input =
              case Jason.decode(args_json) do
                {:ok, parsed} -> parsed
                _ -> %{}
              end

            send(caller, {:llm_tool_use, %{id: call_id, name: name, input: input}})
            new_acc

          {nil, _} ->
            tool_acc
        end

      _ ->
        tool_acc
    end
  end

  # Response complete — extract usage and determine stop reason
  def dispatch_event(caller, %{event: "response.completed", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"response" => response}} ->
        # Send usage if present
        case response["usage"] do
          %{"input_tokens" => input, "output_tokens" => output} ->
            send(caller, {:llm_usage, %{input_tokens: input, output_tokens: output}})

          _ ->
            :ok
        end

        # Determine stop reason from output items
        output = response["output"] || []
        status = response["status"]

        Logger.info(
          "OpenAIResponses completed: status=#{status} output_items=#{length(output)} " <>
          "types=#{inspect(Enum.map(output, & &1["type"]))} tool_acc_keys=#{inspect(Map.keys(tool_acc))}"
        )

        Logger.info("OpenAIResponses completed response keys: #{inspect(Map.keys(response))}")

        has_function_calls =
          Enum.any?(output, fn item -> item["type"] == "function_call" end)

        stop_reason = if has_function_calls, do: "tool_use", else: "end_turn"
        send(caller, {:llm_stop, stop_reason})

      _ ->
        send(caller, {:llm_stop, "end_turn"})
    end

    tool_acc
  end

  # Response failed
  def dispatch_event(caller, %{event: "response.failed", data: data}, tool_acc) do
    reason =
      case Jason.decode(data) do
        {:ok, %{"response" => %{"error" => error} = resp}} ->
          Logger.error("OpenAIResponses failed: status=#{resp["status"]} error=#{inspect(error)}")
          error
        _ ->
          Logger.error("OpenAIResponses failed: raw=#{String.slice(data, 0..500)}")
          "unknown error"
      end

    send(caller, {:llm_stop, {:error, :response_failed, reason}})
    tool_acc
  end

  # Response incomplete (e.g. max_tokens hit)
  def dispatch_event(caller, %{event: "response.incomplete", data: _data}, tool_acc) do
    send(caller, {:llm_stop, {:error, :incomplete}})
    tool_acc
  end

  # Catch-all: log and ignore other event types (reasoning, audio, MCP, etc.)
  def dispatch_event(_caller, %{event: event_type} = event, tool_acc) do
    Logger.info("OpenAIResponses unhandled event: type=#{event_type} data=#{String.slice(event[:data] || "", 0..1000)}")
    tool_acc
  end

  def dispatch_event(_caller, _event, tool_acc), do: tool_acc
end
