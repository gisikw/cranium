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
  - `response.function_call_arguments.done` → finalize tool call (Codex fallback)
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
  # Accepts both "call_id" (standard API) and "id" (Codex endpoint) as identifiers
  def dispatch_event(_caller, %{event: "response.output_item.added", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"output_index" => idx, "item" => %{"type" => "function_call"} = item}} ->
        call_id = item["call_id"] || item["id"] || "unknown_#{idx}"
        name = item["name"]

        if name do
          Map.put(tool_acc, idx, %{call_id: call_id, name: name, arguments: ""})
        else
          Logger.warning("OpenAIResponses output_item.added: function_call missing name, item_keys=#{inspect(Map.keys(item))}")
          tool_acc
        end

      {:ok, decoded} ->
        Logger.info("OpenAIResponses output_item.added: non-function_call item, keys=#{inspect(Map.keys(decoded))}")
        tool_acc

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
            Logger.info("OpenAIResponses args.delta: no accumulator for output_index=#{idx}")
            tool_acc
        end

      _ ->
        tool_acc
    end
  end

  # Function call arguments complete — Codex endpoint sends this with full args
  # in one shot, sometimes without output_item.added/done events.
  # If we have an accumulator entry, update it. If not, store what we can
  # and try to resolve on output_item.done or response.completed.
  def dispatch_event(caller, %{event: "response.function_call_arguments.done", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        idx = decoded["output_index"] || 0
        arguments = decoded["arguments"] || ""
        item_id = decoded["item_id"]
        # Some endpoints include name here
        name = decoded["name"]

        case Map.get(tool_acc, idx) do
          %{} = entry ->
            # Accumulator exists from output_item.added — update with final args
            Map.put(tool_acc, idx, %{entry | arguments: arguments})

          nil ->
            # No accumulator — Codex skipped output_item.added
            # Store what we have; we'll need to resolve the name somehow
            Logger.info(
              "OpenAIResponses args.done: no accumulator for idx=#{idx}, " <>
              "item_id=#{item_id} name=#{inspect(name)} keys=#{inspect(Map.keys(decoded))}"
            )

            call_id = item_id || "unknown_#{idx}"

            if name do
              # We have everything — emit directly
              input = parse_arguments(arguments)
              send(caller, {:llm_tool_use, %{id: call_id, name: name, input: input}})
              tool_acc |> Map.put(idx, :emitted) |> mark_had_tool_calls()
            else
              # Store partial info — need name from output_item.done
              Map.put(tool_acc, idx, %{call_id: call_id, name: nil, arguments: arguments})
            end
        end

      _ ->
        tool_acc
    end
  end

  # Output item complete — emit tool_use for function_call items
  def dispatch_event(caller, %{event: "response.output_item.done", data: data}, tool_acc) do
    case Jason.decode(data) do
      {:ok, %{"output_index" => idx, "item" => %{"type" => "function_call"} = item}} ->
        case Map.pop(tool_acc, idx) do
          {:emitted, new_acc} ->
            # Already emitted in args.done handler
            mark_had_tool_calls(new_acc)

          {%{call_id: call_id, name: acc_name, arguments: args_json}, new_acc} ->
            # Use name from accumulator, fall back to item
            name = acc_name || item["name"]
            call_id = call_id || item["call_id"] || item["id"] || "unknown_#{idx}"
            input = parse_arguments(args_json)
            send(caller, {:llm_tool_use, %{id: call_id, name: name, input: input}})
            mark_had_tool_calls(new_acc)

          {nil, _} ->
            # No accumulator — extract everything from the done item
            name = item["name"]
            call_id = item["call_id"] || item["id"]
            args_json = item["arguments"] || ""
            input = parse_arguments(args_json)

            if name do
              send(caller, {:llm_tool_use, %{id: call_id, name: name, input: input}})
              mark_had_tool_calls(tool_acc)
            else
              Logger.warning("OpenAIResponses output_item.done: no name for function_call idx=#{idx}")
              tool_acc
            end
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

        # Check for un-emitted tool calls still in accumulator
        # (Codex endpoint may skip output_item.done)
        pending_tool_calls =
          tool_acc
          |> Enum.filter(fn
            {_idx, %{name: name, arguments: _}} when is_binary(name) -> true
            _ -> false
          end)

        for {idx, %{call_id: call_id, name: name, arguments: args_json}} <- pending_tool_calls do
          Logger.info("OpenAIResponses completed: emitting pending tool call idx=#{idx} name=#{name}")
          input = parse_arguments(args_json)
          send(caller, {:llm_tool_use, %{id: call_id, name: name, input: input}})
        end

        # Determine stop reason from output items OR pending tool calls
        output = response["output"] || []
        status = response["status"]

        has_function_calls =
          Enum.any?(output, fn item -> item["type"] == "function_call" end) or
          pending_tool_calls != [] or
          Map.get(tool_acc, :_had_tool_calls, false)

        Logger.info(
          "OpenAIResponses completed: status=#{status} output_items=#{length(output)} " <>
          "types=#{inspect(Enum.map(output, & &1["type"]))} tool_acc_keys=#{inspect(Map.keys(tool_acc))} " <>
          "pending_emitted=#{length(pending_tool_calls)}"
        )

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

  # --- Helpers ---

  defp mark_had_tool_calls(tool_acc), do: Map.put(tool_acc, :_had_tool_calls, true)

  defp parse_arguments(args_json) when is_binary(args_json) do
    case Jason.decode(args_json) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_arguments(_), do: %{}
end
