defmodule Cranium.Inference.Harness do
  @moduledoc """
  Per-conversation inference executor.

  Receives assembled turns from TurnAssembler, manages the Agent process
  lifecycle, and emits pass_complete events. Post-inference state
  mutations and backpressure signaling are handled by Persistence.Effects.

  ## Cancel

  While blocked in Agent.infer, Harness can't receive messages. Cancel
  goes directly to the Agent process via `cancel/1`, which looks up the
  agent PID in ConversationRegistry. The Agent's receive loop handles
  the cancel cast and returns {:error, :cancelled, partial}.

  ## Bridge Calls

  TTS.Cache cleanup remains here as a bridge until Media owns TTS lifecycle.
  """

  use GenServer
  require Logger

  @registry Cranium.Inference.ConversationRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    GenServer.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  defp via(conversation_id) do
    {:via, Registry, {@registry, {conversation_id, :harness}}}
  end

  @doc """
  Cancel active inference for a conversation.

  Bypasses the blocked Harness GenServer and sends cancel directly to the
  Agent process via Registry lookup.
  """
  @spec cancel(String.t()) :: :ok | :not_found
  def cancel(conversation_id) do
    case Registry.lookup(@registry, {conversation_id, :agent}) do
      [{_harness_pid, agent_pid}] ->
        Logger.info("Harness.cancel: sending to agent #{inspect(agent_pid)}",
          conversation_id: conversation_id
        )

        GenServer.cast(agent_pid, :cancel)
        :ok

      [] ->
        Logger.warning("Harness.cancel: no agent registered",
          conversation_id: conversation_id
        )

        :not_found
    end
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Logger.metadata(conversation_id: conversation_id)
    {:ok, %{conversation_id: conversation_id}}
  end

  # --- Turn Ready: run inference ---

  @impl true
  def handle_info({:turn_ready, %{conversation_id: cid} = turn}, %{conversation_id: cid} = state) do
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true

    silent = turn[:silent] == true

    Logger.info(
      "Harness: starting inference pass=#{turn[:pass_id]} stream=#{stream_id}#{if silent, do: " (silent)"}"
    )

    # Subscribe OutputSegmenter to the raw stream before inference starts.
    # Silent passes (e.g. orientation) skip this — their output is persisted
    # but not broadcast to clients via manifest or firehose.
    unless silent do
      :ok = GenServer.call(Cranium.Media.OutputSegmenter, {:subscribe_stream, stream_id})
    end

    # Start Agent with profile-resolved backend
    {:ok, agent_pid} =
      Cranium.Inference.Agent.start_link(
        conversation_id: cid,
        epoch_pid: self(),
        llm_backend: turn[:backend]
      )

    # Register agent PID so cancel/1 can reach it while we're blocked
    Registry.register(@registry, {cid, :agent}, agent_pid)

    unless ephemeral do
      Cranium.Store.update_epoch(turn.epoch_id, %{status: "inferring"})
    end

    # Build Agent context
    context = %{
      system: turn.system,
      system_prompt_pre: turn[:system_prompt_pre],
      system_prompt_post: turn[:system_prompt_post],
      messages: turn.messages,
      mode: turn[:mode] || :text,
      conversation_id: cid,
      stream_id: stream_id,
      disposition: turn[:disposition] || ["text"],
      cc_session_id: turn[:cc_session_id],
      working_dir: turn[:working_dir],
      model: turn[:model],
      thinking: turn[:thinking],
      backend_config: turn[:backend_config],
      router_profile: turn[:router_profile],
      ephemeral: ephemeral,
      dispatch: turn[:dispatch],
      tools_disabled: turn[:tools_disabled] == true,
      silent: silent,
      tool_posture: turn[:tool_posture] || :sandbox,
      tool_rw: turn[:tool_rw] || [],
      tool_ro: turn[:tool_ro] || [],
      exec_endpoint: turn[:exec_endpoint],
      epoch_id: turn[:epoch_id]
    }

    result = Cranium.Inference.Agent.infer(agent_pid, context)

    # Unregister agent — inference is done
    Registry.unregister(@registry, {cid, :agent})

    # Stop the Agent process (single-use)
    GenServer.stop(agent_pid, :normal, 5_000)

    # Drain OutputSegmenter before emitting pass_complete. This ensures
    # stream_end has been processed and all segment_ready events have been
    # delivered to the Manifest — otherwise pass_complete can arrive first,
    # causing the manifest to transition to "complete" before final segments
    # are appended. Hearth polls the manifest and exits on "complete", so
    # any segments arriving after that are silently lost (never played).
    unless silent do
      GenServer.call(Cranium.Media.OutputSegmenter, {:drain_stream, stream_id})
    end

    # Emit pass events and handle bridge calls.
    # Store mutations + pass_done are handled by Persistence.Effects.
    handle_inference_result(result, turn, state)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Post-inference: emit events + bridge calls ---

  defp handle_inference_result(
         {:ok, %{output: output, usage: usage} = agent_result},
         turn,
         _state
       ) do
    cid = turn.conversation_id
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true

    saturation = compute_saturation(usage, turn[:context_window], turn, output)
    new_count = (turn[:turn_count] || 0) + 1
    cc_session_id = agent_result[:cc_session_id] || turn[:cc_session_id]

    # Enrich usage with model identifier for transcript export attribution
    usage = if turn[:model], do: Map.put(usage, :model, turn[:model]), else: usage

    # Emit pass_complete — Persistence.Effects handles Store mutations + pass_done
    Cranium.Events.broadcast(
      stream_id,
      cid,
      {:pass_complete, cid, stream_id,
       %{
         reason: :complete,
         epoch_id: turn.epoch_id,
         output: output,
         final_message_content: agent_result[:final_message_content],
         intermediate_messages: agent_result[:intermediate_messages] || [],
         saturation: saturation,
         turn_count: new_count,
         cc_session_id: cc_session_id,
         profile: turn[:profile],
         origin: turn[:origin],
         ephemeral: ephemeral,
         silent: turn[:silent] == true,
         usage: usage
       }}
    )

    # Bridge: TTS cache cleanup
    Cranium.Media.TTS.Cache.schedule_cleanup(stream_id)
  end

  defp handle_inference_result({:error, :cancelled, partial}, turn, _state) do
    cid = turn.conversation_id
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true
    output = partial[:output] || ""
    cc_session_id = partial[:cc_session_id] || turn[:cc_session_id]

    interrupted_context = partial[:interrupted_context] || output

    # Emit pass_complete (cancelled) — Persistence.Effects handles Store mutations + pass_done
    Cranium.Events.broadcast(
      stream_id,
      cid,
      {:pass_complete, cid, stream_id,
       %{
         reason: :cancelled,
         epoch_id: turn.epoch_id,
         output: output,
         intermediate_messages: partial[:intermediate_messages] || [],
         interrupted_context: interrupted_context,
         cc_session_id: cc_session_id,
         profile: turn[:profile],
         ephemeral: ephemeral
       }}
    )
  end

  defp handle_inference_result({:error, reason}, turn, _state) do
    cid = turn.conversation_id
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true

    # Emit pass_complete (error) — Persistence.Effects handles Store mutations + pass_done
    Cranium.Events.broadcast(
      stream_id,
      cid,
      {:pass_complete, cid, stream_id,
       %{
         reason: :error,
         epoch_id: turn.epoch_id,
         error: format_error(reason),
         ephemeral: ephemeral
       }}
    )
  end

  # Room events persist payloads as JSON, so the error must be a bounded string.
  @error_detail_max_length 500

  defp format_error(reason) do
    reason
    |> case do
      text when is_binary(text) -> text
      other -> inspect(other)
    end
    |> String.slice(0, @error_detail_max_length)
  end

  # --- Helpers ---

  @doc false
  @spec compute_saturation(map(), pos_integer() | nil, map() | nil, String.t()) :: float()
  def compute_saturation(usage, context_window \\ nil, turn \\ nil, output \\ "") do
    max_context_tokens =
      context_window || Application.get_env(:cranium, :pipeline)[:max_context_tokens] || 200_000

    total = usage_token_total(usage)
    total = if total > 0, do: total, else: estimate_turn_tokens(turn, output)

    min(total / max_context_tokens, 1.0)
  end

  defp usage_token_total(usage) when is_map(usage) do
    usage_value(usage, :input_tokens) +
      usage_value(usage, :output_tokens) +
      usage_value(usage, :cache_creation_input_tokens) +
      usage_value(usage, :cache_read_input_tokens)
  end

  defp usage_token_total(_), do: 0

  defp usage_value(usage, key) do
    string_key = Atom.to_string(key)
    value = Map.get(usage, key) || Map.get(usage, string_key) || 0

    cond do
      is_integer(value) -> value
      is_float(value) -> trunc(value)
      is_binary(value) -> String.to_integer(value)
      true -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp estimate_turn_tokens(nil, _output), do: 0

  defp estimate_turn_tokens(turn, output) when is_map(turn) do
    chars =
      [
        turn[:system],
        turn[:system_prompt_pre],
        turn[:system_prompt_post],
        turn[:messages],
        output
      ]
      |> Enum.reduce(0, &(&2 + estimated_chars(&1)))

    # Deliberately conservative: four characters per token is a common rough
    # English/code heuristic. The estimate is only used when the backend reports
    # no usage at all, so a useful warning beats silent saturation blindness.
    div(chars + 3, 4)
  end

  defp estimated_chars(nil), do: 0
  defp estimated_chars(text) when is_binary(text), do: String.length(text)

  defp estimated_chars(list) when is_list(list),
    do: Enum.reduce(list, 0, &(&2 + estimated_chars(&1)))

  defp estimated_chars(map) when is_map(map) do
    map
    |> Map.values()
    |> estimated_chars()
  end

  defp estimated_chars(other), do: other |> inspect() |> String.length()
end
