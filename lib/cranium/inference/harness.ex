defmodule Cranium.Inference.Harness do
  @moduledoc """
  Per-conversation inference executor.

  Receives assembled turns from TurnAssembler, manages the Agent process
  lifecycle, and emits pass_complete/pass_cancelled events.

  ## Cancel

  While blocked in Agent.infer, Harness can't receive messages. Cancel
  goes directly to the Agent process via `cancel/1`, which looks up the
  agent PID in ConversationRegistry. The Agent's receive loop handles
  the cancel cast and returns {:error, :cancelled, partial}.

  ## Temporary Bookkeeping

  Post-inference Store mutations (persist assistant message, compute
  saturation, update cc_session_id, etc.) live here temporarily.
  Phase 4 will extract them to a Persistence/Effects subscriber.
  """

  use GenServer
  require Logger

  @registry Cranium.Inference.ConversationRegistry

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

    Logger.info("Harness: starting inference pass=#{turn[:pass_id]} stream=#{stream_id}")

    # Subscribe OutputSegmenter to the raw stream before inference starts
    :ok = GenServer.call(Cranium.Media.OutputSegmenter, {:subscribe_stream, stream_id})

    # Start Agent
    {:ok, agent_pid} =
      Cranium.Agent.start_link(
        conversation_id: cid,
        epoch_pid: self()
      )

    # Register agent PID so cancel/1 can reach it while we're blocked
    Registry.register(@registry, {cid, :agent}, agent_pid)

    unless ephemeral do
      Cranium.Store.update_epoch(turn.epoch_id, %{status: "inferring"})
    end

    Cranium.Manifest.stamp(stream_id, :inference_start)

    # Build Agent context
    context = %{
      system: turn.system,
      messages: turn.messages,
      mode: turn[:mode] || :text,
      conversation_id: cid,
      stream_id: stream_id,
      disposition: turn[:disposition] || ["text"],
      cc_session_id: turn[:cc_session_id],
      working_dir: turn[:working_dir],
      model: turn[:model],
      ephemeral: ephemeral,
      dispatch: turn[:dispatch]
    }

    result = Cranium.Agent.infer(agent_pid, context)

    # Unregister agent — inference is done
    Registry.unregister(@registry, {cid, :agent})

    # Stop the Agent process (single-use)
    GenServer.stop(agent_pid, :normal, 5_000)

    # --- Temporary bookkeeping (moves to Effects in Phase 4) ---
    handle_inference_result(result, turn, state)

    # Signal backpressure release to TurnAssembler
    signal_pass_done(cid, stream_id)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Post-inference bookkeeping ---

  defp handle_inference_result({:ok, %{output: output, usage: usage} = agent_result}, turn, _state) do
    cid = turn.conversation_id
    epoch_id = turn.epoch_id
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true

    # Persist assistant response
    unless ephemeral do
      if output != "" do
        Cranium.Store.append_message(cid, epoch_id, %{
          role: :assistant,
          content: output
        })
      end
    end

    saturation = compute_saturation(usage)
    new_count = (turn[:turn_count] || 0) + 1
    cc_session_id = agent_result[:cc_session_id] || turn[:cc_session_id]

    unless ephemeral do
      # Generate cross-conversation summary every N turns
      summary_interval = Application.get_env(:cranium, :pipeline)[:summary_interval] || 10

      if summary_interval > 0 and rem(new_count, summary_interval) == 0 do
        Cranium.Effects.generate_summary(cid, cc_session_id)
      end

      Cranium.Store.update_epoch(epoch_id, %{
        status: "active",
        saturation: saturation,
        turn_count: new_count,
        cc_session_id: cc_session_id,
        interrupted_context: nil
      })
    end

    # Push saturation to manifest
    if agent_stream_id = agent_result[:stream_id] do
      Cranium.Manifest.set_metadata(agent_stream_id, %{
        "saturation" => Float.round(saturation, 3),
        "turn_count" => new_count
      })
    end

    # Emit pass_complete for firehose
    unless ephemeral do
      Cranium.Event.broadcast(stream_id, cid,
        {:pass_complete, cid, stream_id, %{
          saturation: saturation,
          turn_count: new_count,
          reason: :complete
        }})
    end

    # TTS cache cleanup
    Cranium.TTS.Cache.schedule_cleanup(stream_id)
  end

  defp handle_inference_result({:error, :cancelled, partial}, turn, _state) do
    cid = turn.conversation_id
    epoch_id = turn.epoch_id
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true
    output = partial[:output] || ""

    # Persist partial assistant response so history isn't gapped
    unless ephemeral do
      if output != "" do
        Cranium.Store.append_message(cid, epoch_id, %{
          role: :assistant,
          content: output
        })
      end
    end

    # Truncate for context injection (matching v1's 2000 char limit)
    interrupted =
      if not ephemeral and output != "" do
        if String.length(output) > 2000,
          do: String.slice(output, 0, 2000) <> "\n\n[...output truncated...]",
          else: output
      end

    cc_session_id = partial[:cc_session_id] || turn[:cc_session_id]

    unless ephemeral do
      Cranium.Store.update_epoch(epoch_id, %{
        status: "active",
        cc_session_id: cc_session_id,
        interrupted_context: interrupted
      })
    end

    unless ephemeral do
      Cranium.Event.broadcast(stream_id, cid,
        {:pass_complete, cid, stream_id, %{reason: :cancelled}})
    end

    # Manifest cancel
    Cranium.Manifest.cancel(stream_id)
  end

  defp handle_inference_result({:error, _reason}, turn, _state) do
    cid = turn.conversation_id
    epoch_id = turn.epoch_id
    stream_id = turn.stream_id
    ephemeral = turn[:ephemeral] == true

    unless ephemeral do
      Cranium.Store.update_epoch(epoch_id, %{status: "active"})
    end

    unless ephemeral do
      Cranium.Event.broadcast(stream_id, cid,
        {:pass_complete, cid, stream_id, %{reason: :error}})
    end

    Cranium.Manifest.complete(stream_id)
  end

  # --- Helpers ---

  defp signal_pass_done(conversation_id, stream_id) do
    case Registry.lookup(@registry, {conversation_id, :turn_assembler}) do
      [{pid, _}] -> send(pid, {:pass_done, stream_id})
      [] -> :ok
    end
  end

  @doc false
  def compute_saturation(usage) do
    max_context_tokens =
      Application.get_env(:cranium, :pipeline)[:max_context_tokens] || 200_000

    total =
      (usage[:input_tokens] || 0) +
        (usage[:output_tokens] || 0) +
        (usage[:cache_creation_input_tokens] || 0) +
        (usage[:cache_read_input_tokens] || 0)

    min(total / max_context_tokens, 1.0)
  end

end
