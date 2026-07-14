defmodule Cranium.Effects.PassReactor do
  @moduledoc """
  Post-inference state mutations subscriber.

  Subscribes to pass_complete events via Cranium.Events and handles
  all Store mutations after inference: persist assistant messages,
  update epoch state (saturation, turn_count, cc_session_id,
  interrupted_context), and trigger periodic summary generation.

  Owns the pass_done backpressure signal to TurnAssembler — the pass
  isn't truly done until state is persisted (next turn needs the
  assistant message in history).
  """

  use GenServer
  require Logger

  alias Cranium.Inference.SuppressedThought

  @registry Cranium.Inference.ConversationRegistry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Cranium.Events.subscribe()
    {:ok, %{}}
  end

  # --- Successful inference ---

  @impl true
  def handle_info(
        {:pass_complete, cid, stream_id, %{reason: :complete} = payload},
        state
      ) do
    output = payload[:output] || ""
    epoch_id = payload[:epoch_id]
    turn_count = payload[:turn_count] || 0
    saturation = payload[:saturation] || 0.0
    cc_session_id = payload[:cc_session_id]

    unless payload[:ephemeral] do
      # Strip suppressed spans before anything is persisted or fanned out.
      # The Agent already strips at stream ingress, so this is normally a
      # no-op — it is the guarantee at the Store boundary. Anything caught
      # here still gets its journal trace.
      {output, output_spans} = SuppressedThought.strip(output)

      {final_message_content, content_spans} =
        case payload[:final_message_content] do
          nil -> {nil, []}
          content -> SuppressedThought.strip_content(content)
        end

      # Persist intermediate messages (assistant + tool_result pairs from tool loop)
      intermediate_spans =
        persist_intermediate_messages(
          cid,
          epoch_id,
          payload[:intermediate_messages] || [],
          payload[:origin]
        )

      # The same span can appear in output, final content blocks, and an
      # intermediate message — journal it once.
      Cranium.Store.SuppressionJournal.append(
        cid,
        epoch_id,
        Enum.uniq(intermediate_spans ++ output_spans ++ content_spans)
      )

      if output != "" or final_message_content not in [nil, []] do
        # Persist final assistant message as content blocks
        {:ok, message} =
          Cranium.Store.append_message(cid, epoch_id, %{
            role: :assistant,
            content: final_message_content || [%{"type" => "text", "text" => output}],
            origin: payload[:origin],
            usage: payload[:usage]
          })

        # Emit room event for assistant message
        Cranium.RoomEvents.message_created(cid, %{
          role: :assistant,
          text: output,
          epoch_id: epoch_id,
          origin: payload[:origin],
          message: message
        })
      else
        if (payload[:intermediate_messages] || []) == [] do
          Logger.warning("Inference completed with empty output",
            conversation_id: cid,
            stage: :effects
          )
        end
      end

      summary_interval = Application.get_env(:cranium, :pipeline)[:summary_interval] || 10

      if summary_interval > 0 and rem(turn_count, summary_interval) == 0 do
        Cranium.Effects.generate_summary(cid, cc_session_id, payload[:profile])
      end

      Cranium.Store.update_epoch(epoch_id, %{
        status: "active",
        saturation: saturation,
        turn_count: turn_count,
        cc_session_id: cc_session_id,
        profile: payload[:profile],
        interrupted_context: nil
      })

      # Emit turn.completed room event
      Cranium.RoomEvents.turn_completed(cid, %{
        stream_id: stream_id,
        epoch_id: epoch_id,
        turn_count: turn_count,
        saturation: saturation
      })

      # Notify plugins of assistant output (e.g., glossary mention tracking)
      if output != "" do
        after_pass_context = %{
          conversation_id: cid,
          epoch_id: epoch_id,
          output: output,
          turn_count: turn_count
        }

        Cranium.Plugin.ConversationSupervisor.dispatch_after_pass_complete(
          cid,
          after_pass_context
        )

        # Dispatch sidecar evaluations for active macros
        Cranium.Macro.Engine.after_pass(after_pass_context)
      end
    end

    signal_pass_done(cid, stream_id)
    {:noreply, state}
  end

  # --- Cancelled inference ---

  @impl true
  def handle_info(
        {:pass_complete, cid, stream_id, %{reason: :cancelled} = payload},
        state
      ) do
    unless payload[:ephemeral] do
      # Same Store-boundary guarantee as the :complete path — strip before
      # persisting, journal anything that slipped through.
      {output, output_spans} = SuppressedThought.strip(payload[:output] || "")

      # Persist intermediate messages (assistant + tool_result pairs from
      # completed tool rounds). Drop any trailing assistant message without
      # a following tool_result — on the CC path, cancel can land between
      # tool_use dispatch and result arrival.
      intermediate_spans =
        persist_intermediate_messages(
          cid,
          payload.epoch_id,
          trim_trailing_assistant(payload[:intermediate_messages] || []),
          payload[:origin]
        )

      {interrupted_source, interrupted_spans} =
        SuppressedThought.strip(payload[:interrupted_context] || output)

      Cranium.Store.SuppressionJournal.append(
        cid,
        payload.epoch_id,
        Enum.uniq(intermediate_spans ++ output_spans ++ interrupted_spans)
      )

      if output != "" do
        Cranium.Store.append_message(cid, payload.epoch_id, %{
          role: :assistant,
          content: [%{"type" => "text", "text" => output}]
        })
      end

      interrupted = truncate_interrupted(interrupted_source)

      Cranium.Store.update_epoch(payload.epoch_id, %{
        status: "active",
        cc_session_id: payload[:cc_session_id],
        interrupted_context: interrupted
      })

      # Emit turn.cancelled room event
      Cranium.RoomEvents.turn_cancelled(cid, %{
        stream_id: stream_id,
        epoch_id: payload.epoch_id
      })
    end

    signal_pass_done(cid, stream_id)
    {:noreply, state}
  end

  # --- Error ---

  @impl true
  def handle_info(
        {:pass_complete, cid, stream_id, %{reason: :error} = payload},
        state
      ) do
    unless payload[:ephemeral] do
      # A failed turn persists exactly like a cancelled one — completed tool
      # rounds and streamed output must survive into the next turn's history.
      {output, output_spans} = SuppressedThought.strip(payload[:output] || "")

      intermediate_spans =
        persist_intermediate_messages(
          cid,
          payload[:epoch_id],
          trim_trailing_assistant(payload[:intermediate_messages] || []),
          payload[:origin]
        )

      {interrupted_source, interrupted_spans} =
        SuppressedThought.strip(payload[:interrupted_context] || output)

      Cranium.Store.SuppressionJournal.append(
        cid,
        payload[:epoch_id],
        Enum.uniq(intermediate_spans ++ output_spans ++ interrupted_spans)
      )

      if output != "" do
        Cranium.Store.append_message(cid, payload[:epoch_id], %{
          role: :assistant,
          content: [%{"type" => "text", "text" => output}]
        })
      end

      # Unlike cancel, an error only overwrites interrupted_context /
      # cc_session_id when the failed turn actually produced them — an
      # early failure (e.g. transport timeout before first token) must not
      # clobber state left by a previous turn.
      epoch_attrs =
        %{status: "active"}
        |> maybe_put(:interrupted_context, truncate_interrupted(interrupted_source))
        |> maybe_put(:cc_session_id, payload[:cc_session_id])

      Cranium.Store.update_epoch(payload[:epoch_id], epoch_attrs)

      # Emit turn.errored room event
      Cranium.RoomEvents.turn_errored(cid, %{
        stream_id: stream_id,
        epoch_id: payload[:epoch_id],
        error: payload[:error]
      })
    end

    signal_pass_done(cid, stream_id)
    {:noreply, state}
  end

  # Ignore all other events (stream chunks, message_received, etc.)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Test support: synchronous flush ensures all prior messages are processed
  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, state}
  end

  # --- Helpers ---

  # Persist intermediate messages (assistant tool_use + tool_result pairs
  # from completed tool rounds), stripping suppressed spans from assistant
  # content at the Store boundary. Returns the stripped spans for journaling.
  defp persist_intermediate_messages(cid, epoch_id, messages, origin) do
    for msg <- messages do
      role = msg[:role] || msg["role"]

      {content, spans} =
        if role in [:assistant, "assistant"] do
          SuppressedThought.strip_content(msg[:content] || msg["content"])
        else
          {msg[:content] || msg["content"], []}
        end

      Cranium.Store.append_message(cid, epoch_id, %{
        role: role,
        content: content,
        origin: origin
      })

      spans
    end
    |> List.flatten()
  end

  defp truncate_interrupted(""), do: nil

  defp truncate_interrupted(source) when is_binary(source) do
    if String.length(source) > 2000,
      do: String.slice(source, 0, 2000) <> "\n\n[...output truncated...]",
      else: source
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Drop a trailing assistant message that has no following tool_result.
  # On the CC path, cancel can land between tool_use dispatch and result
  # arrival, leaving an orphaned assistant turn that would cause the API
  # to reject the next history payload.
  defp trim_trailing_assistant([]), do: []

  defp trim_trailing_assistant(messages) do
    case List.last(messages) do
      %{role: role} when role in [:assistant, "assistant"] ->
        List.delete_at(messages, -1)

      %{"role" => role} when role in ["assistant", :assistant] ->
        List.delete_at(messages, -1)

      _ ->
        messages
    end
  end

  defp signal_pass_done(conversation_id, stream_id) do
    case Registry.lookup(@registry, {conversation_id, :turn_assembler}) do
      [{pid, _}] -> send(pid, {:pass_done, stream_id})
      [] -> :ok
    end
  end
end
