defmodule Cranium.Backend.LLM.Tiamat do
  @moduledoc false

  @behaviour Cranium.Backend.LLM

  require Logger

  alias Cranium.Backend.LLM.Tiamat.Events
  alias Cranium.Backend.SSE
  alias Cranium.Inference.TiamatTurnRequest

  @default_endpoint "http://localhost:4002"
  @default_timeout 300_000

  @impl true
  def manages_tool_loop?, do: false

  @impl true
  def stream_chat(messages, opts) do
    caller = self()
    pid = spawn_link(fn -> do_stream(caller, messages, opts) end)
    {:ok, pid}
  end

  def dispatch_response(caller, response, opts \\ [])

  def dispatch_response(caller, %{"status" => "completed"} = response, opts) do
    delta = transcript_delta(response)
    assistant_blocks = assistant_content_blocks(delta)

    unless Keyword.get(opts, :emitted_text, false) do
      delta
      |> text_chunks()
      |> Enum.each(&send(caller, {:llm_text, &1}))
    end

    if not Keyword.get(opts, :emitted_assistant_content, false) and assistant_blocks != [] do
      send(caller, {:llm_assistant_content, assistant_blocks})
    end

    maybe_send_usage(caller, response, opts)
    send(caller, {:llm_stop, "end_turn"})
    :ok
  end

  def dispatch_response(caller, %{"status" => "tool_call"} = response, opts) do
    delta = transcript_delta(response)
    assistant_blocks = assistant_content_blocks(delta)

    unless Keyword.get(opts, :emitted_text, false) do
      delta
      |> text_chunks()
      |> Enum.each(&send(caller, {:llm_text, &1}))
    end

    if not Keyword.get(opts, :emitted_assistant_content, false) and assistant_blocks != [] do
      send(caller, {:llm_assistant_content, assistant_blocks})
    end

    unless Keyword.get(opts, :emitted_tool_calls, false) do
      assistant_blocks
      |> tool_calls()
      |> Enum.each(&send(caller, {:llm_tool_use, &1}))
    end

    maybe_send_usage(caller, response, opts)
    send(caller, {:llm_stop, "tool_use"})
    :ok
  end

  def dispatch_response(caller, %{"status" => "error"} = response, opts) do
    reason = %{
      error_code: response["error_code"],
      errors: response["errors"] || []
    }

    maybe_send_usage(caller, response, opts)
    send(caller, {:llm_stop, {:error, reason}})
    :ok
  end

  def dispatch_response(caller, response, _opts) do
    send(caller, {:llm_stop, {:error, {:unexpected_tiamat_response, response}}})
    :ok
  end

  defp do_stream(caller, messages, opts) do
    with {:ok, request} <- build_request(messages, opts),
         {:ok, result} <- post_turn(caller, request, opts) do
      apply_normalization_delta(request, result.response, opts)

      dispatch_response(caller, result.response,
        emitted_text: result.emitted_text,
        emitted_assistant_content: result.emitted_assistant_content,
        emitted_tool_calls: result.emitted_tool_calls,
        emitted_usage: result.emitted_usage
      )
    else
      {:error, reason} ->
        Logger.error("Tiamat request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  defp build_request(messages, opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    epoch_id = Keyword.get(opts, :epoch_id)
    router_profile = Keyword.get(opts, :router_profile)

    cond do
      not is_binary(conversation_id) ->
        {:error, :missing_conversation_id}

      not is_binary(epoch_id) ->
        {:error, :missing_epoch_id}

      not is_binary(router_profile) or String.trim(router_profile) == "" ->
        {:error, :missing_router_profile}

      true ->
        request =
          TiamatTurnRequest.assemble(
            conversation_id: conversation_id,
            epoch_id: epoch_id,
            router_profile: router_profile,
            system_prompt: Keyword.get(opts, :system),
            system_prompt_pre: Keyword.get(opts, :system_prompt_pre),
            system_prompt_post: Keyword.get(opts, :system_prompt_post),
            tools_disabled: Keyword.get(opts, :tools_disabled, false),
            no_cache: Keyword.get(opts, :no_cache, false)
          )
          |> append_in_memory_messages(messages)

        {:ok, request}
    end
  end

  defp append_in_memory_messages(request, messages) when is_list(messages) do
    existing_messages = request["messages"] || []
    existing_ids = message_ids(existing_messages)
    existing_fingerprints = message_fingerprints(existing_messages)
    stored_count = length(existing_messages)

    in_memory_messages = Enum.map(messages, &stringify_in_memory_message/1)
    candidate_messages = Enum.drop(in_memory_messages, stored_count)

    Logger.warning(
      "Tiamat in-memory append pre-dedupe " <>
        "persisted_count=#{length(existing_messages)} " <>
        "in_memory_count=#{length(in_memory_messages)} " <>
        "dropped_count=#{stored_count} " <>
        "persisted_tail=#{inspect(message_summaries(Enum.take(existing_messages, -6)))} " <>
        "in_memory=#{inspect(message_summaries(in_memory_messages))} " <>
        "candidates_after_drop=#{inspect(message_summaries(candidate_messages))}"
    )

    {additions, _ids, _fingerprints} =
      candidate_messages
      |> Enum.reduce({[], existing_ids, existing_fingerprints}, fn message,
                                                                   {acc, ids, fingerprints} ->
        id = message["id"]
        fingerprint = message_fingerprint(message)

        cond do
          is_binary(id) and MapSet.member?(ids, id) ->
            {acc, ids, fingerprints}

          MapSet.member?(fingerprints, fingerprint) ->
            {acc, ids, fingerprints}

          true ->
            ids = if is_binary(id), do: MapSet.put(ids, id), else: ids
            {[message | acc], ids, MapSet.put(fingerprints, fingerprint)}
        end
      end)

    final_messages = existing_messages ++ Enum.reverse(additions)

    Logger.warning(
      "Tiamat in-memory append final " <>
        "additions_count=#{length(additions)} " <>
        "final_count=#{length(final_messages)} " <>
        "additions=#{inspect(message_summaries(Enum.reverse(additions)))} " <>
        "final_tail=#{inspect(message_summaries(Enum.take(final_messages, -10)))}"
    )

    Map.put(request, "messages", final_messages)
  end

  defp append_in_memory_messages(request, _messages), do: request

  defp message_ids(messages) do
    messages
    |> Enum.map(& &1["id"])
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp message_fingerprints(messages) do
    messages
    |> Enum.map(&message_fingerprint/1)
    |> MapSet.new()
  end

  defp message_summaries(messages) do
    Enum.map(messages, fn message ->
      %{
        id: short_id(message["id"]),
        role: message["role"],
        blocks: content_block_summaries(message["content"] || [])
      }
    end)
  end

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(other), do: other

  defp content_block_summaries(blocks) when is_list(blocks) do
    Enum.map(blocks, fn block ->
      type = block["type"]

      case type do
        "text" ->
          %{type: type, text: String.slice(to_string(block["text"] || ""), 0, 80)}

        "tool_use" ->
          %{
            type: type,
            id: short_id(block["tool_use_id"] || block["id"]),
            name: block["tool_name"] || block["name"]
          }

        "tool_result" ->
          %{
            type: type,
            for: short_id(block["tool_result_for"] || block["tool_use_id"]),
            content: String.slice(inspect(block["tool_output"] || block["content"] || ""), 0, 120)
          }

        _ ->
          %{type: type, keys: Map.keys(block || %{})}
      end
    end)
  end

  defp content_block_summaries(other), do: [%{type: :non_list, value: inspect(other)}]

  defp message_fingerprint(message) do
    {message["role"], canonical_content(message["content"] || [])}
  end

  defp canonical_content(content) do
    content
    |> stringify_value()
    |> prune_empty_metadata()
  end

  defp prune_empty_metadata(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}] end)
    |> Map.new(fn {key, value} -> {key, prune_empty_metadata(value)} end)
  end

  defp prune_empty_metadata(list) when is_list(list), do: Enum.map(list, &prune_empty_metadata/1)
  defp prune_empty_metadata(value), do: value

  defp stringify_in_memory_message(message) when is_map(message) do
    raw_role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content") || []
    role = normalize_tiamat_role(raw_role, content)

    %{
      "id" =>
        Map.get(message, :id) || Map.get(message, "id") || "agent-memory-#{Ecto.UUID.generate()}",
      "parent_id" => Map.get(message, :parent_id) || Map.get(message, "parent_id"),
      "created_at" =>
        Map.get(message, :created_at) || Map.get(message, "created_at") || DateTime.utc_now(),
      "role" => role,
      "content" => stringify_content_blocks(content),
      "provenance" => Map.get(message, :provenance) || Map.get(message, "provenance") || %{}
    }
  end

  defp normalize_tiamat_role(role, content) do
    if to_string(role || "user") == "user" and tool_result_content?(content),
      do: "tool",
      else: to_string(role || "user")
  end

  defp tool_result_content?(content) when is_list(content) do
    Enum.any?(content, fn block -> block_value(block, "type") == "tool_result" end)
  end

  defp tool_result_content?(_), do: false

  defp stringify_content_blocks(content) when is_list(content) do
    Enum.map(content, &stringify_content_block/1)
  end

  defp stringify_content_blocks(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp stringify_content_blocks(content), do: [%{"type" => "text", "text" => inspect(content)}]

  defp stringify_content_block(block) when is_map(block) do
    block
    |> stringify_keys()
    |> normalize_tiamat_content_block()
  end

  defp stringify_content_block(text) when is_binary(text), do: %{"type" => "text", "text" => text}
  defp stringify_content_block(other), do: %{"type" => "text", "text" => inspect(other)}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp normalize_tiamat_content_block(%{"type" => "tool_use"} = block) do
    block
    |> put_alias_if_present("tool_use_id", "id")
    |> put_alias_if_present("tool_name", "name")
    |> put_alias_if_present("tool_input", "input")
    |> Map.drop(["id", "name", "input"])
  end

  defp normalize_tiamat_content_block(%{"type" => "tool_result"} = block) do
    block
    |> put_alias_if_present("tool_result_for", "tool_use_id")
    |> put_alias_if_present("tool_output", "content")
    |> Map.drop(["tool_use_id", "content"])
  end

  defp normalize_tiamat_content_block(block), do: block

  defp put_alias_if_present(block, canonical_key, alias_key) do
    case Map.fetch(block, canonical_key) do
      {:ok, _} ->
        block

      :error ->
        case Map.fetch(block, alias_key) do
          {:ok, value} -> Map.put(block, canonical_key, value)
          :error -> block
        end
    end
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp post_turn(caller, request, opts) do
    backend_config = Keyword.get(opts, :backend_config, %{}) || %{}
    endpoint = backend_config["endpoint"] || @default_endpoint
    timeout = backend_config["timeout"] || @default_timeout
    url = String.trim_trailing(endpoint, "/") <> "/v1/router/turns"

    Logger.info(
      "Tiamat request: endpoint=#{endpoint} router_profile=#{request["router_profile"]} messages=#{length(request["messages"])} tools=#{length(request["tools"])}"
    )

    sse_state = SSE.new()

    Process.put(:tiamat_stream_result, %{
      response: nil,
      emitted_text: false,
      emitted_assistant_content: false,
      emitted_tool_calls: false,
      emitted_usage: false,
      normalization_delta: nil,
      failure_reason: nil,
      text_delta_part_ids: MapSet.new(),
      completed_content_keys: MapSet.new()
    })

    stream_fn = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        {events, new_sse} = SSE.parse(Process.get(:sse_state, sse_state), data)
        Process.put(:sse_state, new_sse)
        handle_events(caller, events)
        {:cont, {req, resp}}
      else
        Process.put(:error_body, [data | Process.get(:error_body, [])])
        {:cont, {req, resp}}
      end
    end

    case Req.post(
           url,
           json: request,
           headers: [{"accept", "text/event-stream"}],
           receive_timeout: timeout,
           into: stream_fn
         ) do
      {:ok, %{status: 200}} ->
        case Process.get(:tiamat_stream_result) do
          %{
            response: %{} = response,
            emitted_text: emitted_text,
            emitted_assistant_content: emitted_assistant_content,
            emitted_tool_calls: emitted_tool_calls,
            emitted_usage: emitted_usage,
            normalization_delta: delta
          } ->
            response =
              if is_map(delta),
                do: Map.put_new(response, "normalization_delta", delta),
                else: response

            {:ok,
             %{
               response: response,
               emitted_text: emitted_text,
               emitted_assistant_content: emitted_assistant_content,
               emitted_tool_calls: emitted_tool_calls,
               emitted_usage: emitted_usage
             }}

          %{
            failure_reason: failure_reason,
            response: nil
          }
          when is_map(failure_reason) ->
            failure_reason = stringify_keys(failure_reason)

            {:ok,
             %{
               response: %{
                 "status" => "error",
                 "error_code" => failure_reason["error_code"],
                 "errors" => failure_reason["errors"] || []
               },
               emitted_text: false,
               emitted_assistant_content: false,
               emitted_tool_calls: false,
               emitted_usage: false
             }}

          _ ->
            {:error, Process.get(:tiamat_decode_error) || :missing_turn_response}
        end

      {:ok, %{status: status}} ->
        error_body =
          Process.get(:error_body, [])
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        {:error, {:http_error, status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_events(caller, events) do
    Enum.each(events, fn event ->
      case Events.decode_sse(event) do
        {:ok, envelope} -> handle_turn_event(caller, envelope)
        {:error, error} -> Process.put(:tiamat_decode_error, error)
        :ignore -> :ok
      end
    end)
  end

  defp handle_turn_event(_caller, %{"type" => "turn_response"} = envelope) do
    case Events.turn_response(envelope) do
      {:ok, response} -> update_stream_result(:response, response)
      :error -> Process.put(:tiamat_decode_error, :invalid_turn_response_event)
    end
  end

  defp handle_turn_event(_caller, %{"type" => "normalization_delta"} = envelope) do
    update_stream_result(:normalization_delta, Events.normalization_delta(envelope))
  end

  defp handle_turn_event(caller, %{"type" => "content_part_delta"} = envelope) do
    case Events.text_delta(envelope) do
      text when is_binary(text) ->
        send(caller, {:llm_text, text})
        remember_text_delta_part(envelope)
        update_stream_result(:emitted_text, true)

      _ ->
        :ok
    end
  end

  defp handle_turn_event(caller, %{"type" => "content_part_completed"} = envelope) do
    maybe_emit_completed_text(caller, envelope)
    blocks = Events.completed_content(envelope)
    emit_completed_content(caller, blocks)
  end

  defp handle_turn_event(caller, %{"type" => "assistant_message_completed"} = envelope) do
    blocks = Events.message_content(envelope)
    emit_completed_content(caller, blocks)
  end

  defp handle_turn_event(caller, %{"type" => "usage_update"} = envelope) do
    case Events.usage(envelope) do
      %{} = usage ->
        send(caller, {:llm_usage, atomize_usage(usage)})
        update_stream_result(:emitted_usage, true)

      _ ->
        :ok
    end
  end

  defp handle_turn_event(_caller, %{"type" => "turn_failed"} = envelope) do
    update_stream_result(:failure_reason, Events.failure_reason(envelope))
  end

  defp handle_turn_event(_caller, %{"type" => "stream_closed"}), do: :ok
  defp handle_turn_event(_caller, _envelope), do: :ok

  defp maybe_emit_completed_text(caller, envelope) do
    part_id = Events.part_id(envelope)

    cond do
      text_delta_streamed?() ->
        :ok

      streamed_text_part?(part_id) ->
        :ok

      true ->
        case Events.completed_text(envelope) do
          text when is_binary(text) ->
            send(caller, {:llm_text, text})
            update_stream_result(:emitted_text, true)

          _ ->
            :ok
        end
    end
  end

  defp text_delta_streamed? do
    Process.get(:tiamat_stream_result, %{})
    |> Map.get(:emitted_text, false)
  end

  defp remember_text_delta_part(envelope) do
    case Events.part_id(envelope) do
      part_id when is_binary(part_id) ->
        update_stream_result(:text_delta_part_ids, MapSet.put(text_delta_part_ids(), part_id))

      _ ->
        :ok
    end
  end

  defp streamed_text_part?(part_id) when is_binary(part_id),
    do: MapSet.member?(text_delta_part_ids(), part_id)

  defp streamed_text_part?(_), do: false

  defp text_delta_part_ids do
    Process.get(:tiamat_stream_result, %{})
    |> Map.get(:text_delta_part_ids, MapSet.new())
  end

  defp completed_content_keys do
    Process.get(:tiamat_stream_result, %{})
    |> Map.get(:completed_content_keys, MapSet.new())
  end

  defp remember_completed_content_keys(keys) when is_list(keys) do
    update_stream_result(
      :completed_content_keys,
      Enum.reduce(keys, completed_content_keys(), &MapSet.put(&2, &1))
    )
  end

  defp completed_content_key(block) when is_map(block) do
    cond do
      is_binary(block_value(block, "tool_use_id") || block_value(block, "id")) ->
        {"tool_use", block_value(block, "tool_use_id") || block_value(block, "id")}

      block_value(block, "type") == "text" and is_binary(block_value(block, "text")) ->
        {"text", block_value(block, "text")}

      true ->
        {:block, :erlang.phash2(block)}
    end
  end

  defp completed_content_key(block), do: {:block, :erlang.phash2(block)}

  defp emit_completed_content(_caller, []), do: :ok

  defp emit_completed_content(caller, blocks) do
    fresh_blocks =
      Enum.reject(blocks, fn block ->
        MapSet.member?(completed_content_keys(), completed_content_key(block))
      end)

    if fresh_blocks != [] do
      remember_completed_content_keys(Enum.map(fresh_blocks, &completed_content_key/1))
      send(caller, {:llm_assistant_content, fresh_blocks})
      update_stream_result(:emitted_assistant_content, true)

      tool_calls = Events.tool_calls(fresh_blocks)
      Enum.each(tool_calls, &send(caller, {:llm_tool_use, &1}))

      if tool_calls != [] do
        update_stream_result(:emitted_tool_calls, true)
      end
    end
  end

  defp update_stream_result(key, value) do
    result =
      Process.get(:tiamat_stream_result, %{
        response: nil,
        emitted_text: false,
        emitted_assistant_content: false,
        emitted_tool_calls: false,
        emitted_usage: false,
        normalization_delta: nil,
        text_delta_part_ids: MapSet.new(),
        completed_content_keys: MapSet.new()
      })

    Process.put(:tiamat_stream_result, Map.put(result, key, value))
  end

  defp transcript_delta(response), do: response["transcript_delta"] || []

  defp assistant_content_blocks(delta) do
    delta
    |> Enum.filter(&(Map.get(&1, "role") == "assistant" or Map.get(&1, :role) == "assistant"))
    |> Enum.flat_map(fn message ->
      Map.get(message, "content") || Map.get(message, :content) || []
    end)
  end

  defp apply_normalization_delta(request, response, opts) do
    delta = response["normalization_delta"]

    if is_map(delta) do
      conversation_id = Keyword.get(opts, :conversation_id)
      epoch_id = Keyword.get(opts, :epoch_id)
      request_messages = request["messages"] || []

      case Cranium.Store.apply_tiamat_normalization_delta(
             conversation_id,
             epoch_id,
             request_messages,
             delta
           ) do
        {:ok, %{applied: applied, skipped: skipped}} ->
          if applied > 0 or skipped > 0 do
            Logger.debug("Applied Tiamat normalization delta",
              applied: applied,
              skipped: skipped,
              conversation_id: conversation_id,
              epoch_id: epoch_id
            )
          end

        {:error, reason} ->
          Logger.warning("Failed to apply Tiamat normalization delta", error: inspect(reason))
      end
    end
  end

  defp text_chunks(delta) do
    delta
    |> assistant_content_blocks()
    |> Enum.filter(&(block_value(&1, "type") == "text" and is_binary(block_value(&1, "text"))))
    |> Enum.map(&block_value(&1, "text"))
    |> Enum.reject(&(&1 == ""))
  end

  defp tool_calls(blocks) do
    blocks
    |> Enum.filter(&(block_value(&1, "type") == "tool_use"))
    |> Enum.map(fn block ->
      %{
        id: block_value(block, "tool_use_id") || block_value(block, "id"),
        name: block_value(block, "tool_name") || block_value(block, "name"),
        input: block_value(block, "tool_input") || block_value(block, "input") || %{}
      }
    end)
  end

  defp block_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp maybe_send_usage(caller, response, opts) do
    usage = response["usage"]

    if is_map(usage) and not Keyword.get(opts, :emitted_usage, false) do
      send(caller, {:llm_usage, atomize_usage(usage)})
    end
  end

  defp atomize_usage(usage) do
    Map.new(usage, fn {key, value} ->
      {String.to_atom(to_string(key)), value}
    end)
  end
end
