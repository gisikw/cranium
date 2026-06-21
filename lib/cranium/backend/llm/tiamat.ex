defmodule Cranium.Backend.LLM.Tiamat do
  @moduledoc """
  Tiamat router backend.

  Satisfies Cranium's existing `Cranium.Backend.LLM` behaviour by POSTing a
  native Cranium transcript request to Tiamat's `/v1/router/turns` SSE endpoint
  and translating the final `turn_response` event into the Agent protocol.

  V0 Tiamat responses are final-response streams rather than true token streams:
  this adapter emits text/tool calls after receiving `turn_response`, then emits
  the appropriate `:llm_stop` reason.
  """

  @behaviour Cranium.Backend.LLM

  require Logger

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

  @doc false
  def dispatch_response(caller, %{"status" => "completed"} = response) do
    delta = transcript_delta(response)
    assistant_blocks = assistant_content_blocks(delta)

    if assistant_blocks != [] do
      send(caller, {:llm_assistant_content, assistant_blocks})
    end

    delta
    |> text_chunks()
    |> Enum.each(&send(caller, {:llm_text, &1}))

    maybe_send_usage(caller, response)
    send(caller, {:llm_stop, "end_turn"})
    :ok
  end

  def dispatch_response(caller, %{"status" => "tool_call"} = response) do
    delta = transcript_delta(response)
    assistant_blocks = assistant_content_blocks(delta)

    if assistant_blocks != [] do
      send(caller, {:llm_assistant_content, assistant_blocks})
    end

    delta
    |> text_chunks()
    |> Enum.each(&send(caller, {:llm_text, &1}))

    assistant_blocks
    |> tool_calls()
    |> Enum.each(&send(caller, {:llm_tool_use, &1}))

    maybe_send_usage(caller, response)
    send(caller, {:llm_stop, "tool_use"})
    :ok
  end

  def dispatch_response(caller, %{"status" => "error"} = response) do
    reason = %{
      error_code: response["error_code"],
      errors: response["errors"] || []
    }

    maybe_send_usage(caller, response)
    send(caller, {:llm_stop, {:error, reason}})
    :ok
  end

  def dispatch_response(caller, response) do
    send(caller, {:llm_stop, {:error, {:unexpected_tiamat_response, response}}})
    :ok
  end

  defp do_stream(caller, messages, opts) do
    with {:ok, request} <- build_request(messages, opts),
         {:ok, response} <- post_turn(request, opts) do
      apply_normalization_delta(request, response, opts)
      dispatch_response(caller, response)
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
            tools_disabled: Keyword.get(opts, :tools_disabled, false)
          )
          |> append_in_memory_messages(messages)

        {:ok, request}
    end
  end

  defp append_in_memory_messages(request, messages) when is_list(messages) do
    stored_count = length(request["messages"] || [])
    additions = messages |> Enum.drop(stored_count) |> Enum.map(&stringify_in_memory_message/1)
    Map.update!(request, "messages", &(&1 ++ additions))
  end

  defp append_in_memory_messages(request, _messages), do: request

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

  defp post_turn(request, opts) do
    backend_config = Keyword.get(opts, :backend_config, %{}) || %{}
    endpoint = backend_config["endpoint"] || @default_endpoint
    timeout = backend_config["timeout"] || @default_timeout
    url = String.trim_trailing(endpoint, "/") <> "/v1/router/turns"

    Logger.info(
      "Tiamat request: endpoint=#{endpoint} router_profile=#{request["router_profile"]} messages=#{length(request["messages"])} tools=#{length(request["tools"])}"
    )

    log_tool_block_diagnostics(request)

    sse_state = SSE.new()

    stream_fn = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        {events, new_sse} = SSE.parse(Process.get(:sse_state, sse_state), data)
        Process.put(:sse_state, new_sse)
        handle_events(events)
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
        case Process.get(:tiamat_response) do
          %{} = response -> {:ok, response}
          nil -> {:error, :missing_turn_response}
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

  defp log_tool_block_diagnostics(request) do
    request
    |> Map.get("messages", [])
    |> Enum.with_index()
    |> Enum.each(fn {message, index} ->
      role = Map.get(message, "role")

      message
      |> Map.get("content", [])
      |> Enum.each(fn
        %{"type" => "tool_use"} = block ->
          Logger.debug("Tiamat request tool block",
            message_index: index,
            role: role,
            block_type: "tool_use",
            tool_use_id: Map.get(block, "tool_use_id"),
            tool_name: Map.get(block, "tool_name")
          )

        %{"type" => "tool_result"} = block ->
          Logger.debug("Tiamat request tool block",
            message_index: index,
            role: role,
            block_type: "tool_result",
            tool_use_id: Map.get(block, "tool_result_for")
          )

        _ ->
          :ok
      end)
    end)
  end

  defp handle_events(events) do
    Enum.each(events, fn
      %{event: "turn_response", data: data} ->
        case Jason.decode(data) do
          {:ok, response} -> Process.put(:tiamat_response, response)
          {:error, error} -> Process.put(:tiamat_decode_error, error)
        end

      _other ->
        :ok
    end)
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

  defp maybe_send_usage(caller, response) do
    usage = response["usage"]

    if is_map(usage) do
      send(caller, {:llm_usage, atomize_usage(usage)})
    end
  end

  defp atomize_usage(usage) do
    Map.new(usage, fn {key, value} ->
      {String.to_atom(key), value}
    end)
  end
end
