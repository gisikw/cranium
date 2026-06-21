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
  def stream_chat(_messages, opts) do
    caller = self()
    pid = spawn_link(fn -> do_stream(caller, opts) end)
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

  defp do_stream(caller, opts) do
    with {:ok, request} <- build_request(opts),
         {:ok, response} <- post_turn(request, opts) do
      apply_normalization_delta(request, response, opts)
      dispatch_response(caller, response)
    else
      {:error, reason} ->
        Logger.error("Tiamat request failed", error: inspect(reason))
        send(caller, {:llm_stop, {:error, reason}})
    end
  end

  defp build_request(opts) do
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
            tools_disabled: Keyword.get(opts, :tools_disabled, false)
          )

        {:ok, request}
    end
  end

  defp post_turn(request, opts) do
    backend_config = Keyword.get(opts, :backend_config, %{}) || %{}
    endpoint = backend_config["endpoint"] || @default_endpoint
    timeout = backend_config["timeout"] || @default_timeout
    url = String.trim_trailing(endpoint, "/") <> "/v1/router/turns"

    Logger.info(
      "Tiamat request: endpoint=#{endpoint} router_profile=#{request["router_profile"]} messages=#{length(request["messages"])} tools=#{length(request["tools"])}"
    )

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
