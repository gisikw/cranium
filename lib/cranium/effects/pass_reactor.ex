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
    unless payload[:ephemeral] do
      # Persist intermediate messages (assistant + tool_result pairs from tool loop)
      for msg <- payload[:intermediate_messages] || [] do
        Cranium.Store.append_message(cid, payload.epoch_id, %{
          role: msg[:role] || msg["role"],
          content: msg[:content] || msg["content"],
          origin: payload[:origin]
        })
      end

      final_message_content = payload[:final_message_content]

      if payload.output != "" or final_message_content not in [nil, []] do
        # Persist final assistant message as content blocks
        Cranium.Store.append_message(cid, payload.epoch_id, %{
          role: :assistant,
          content: final_message_content || [%{"type" => "text", "text" => payload.output}],
          origin: payload[:origin],
          usage: payload[:usage]
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

      if summary_interval > 0 and rem(payload.turn_count, summary_interval) == 0 do
        Cranium.Effects.generate_summary(cid, payload.cc_session_id, payload[:profile])
      end

      Cranium.Store.update_epoch(payload.epoch_id, %{
        status: "active",
        saturation: payload.saturation,
        turn_count: payload.turn_count,
        cc_session_id: payload.cc_session_id,
        profile: payload[:profile],
        interrupted_context: nil
      })

      # Notify plugins of assistant output (e.g., glossary mention tracking)
      if payload.output != "" do
        after_pass_context = %{
          conversation_id: cid,
          epoch_id: payload.epoch_id,
          output: payload.output,
          turn_count: payload.turn_count
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
      output = payload[:output] || ""

      if output != "" do
        Cranium.Store.append_message(cid, payload.epoch_id, %{
          role: :assistant,
          content: [%{"type" => "text", "text" => output}]
        })
      end

      interrupted =
        if output != "" do
          if String.length(output) > 2000,
            do: String.slice(output, 0, 2000) <> "\n\n[...output truncated...]",
            else: output
        end

      Cranium.Store.update_epoch(payload.epoch_id, %{
        status: "active",
        cc_session_id: payload[:cc_session_id],
        interrupted_context: interrupted
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
      Cranium.Store.update_epoch(payload[:epoch_id], %{status: "active"})
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

  defp signal_pass_done(conversation_id, stream_id) do
    case Registry.lookup(@registry, {conversation_id, :turn_assembler}) do
      [{pid, _}] -> send(pid, {:pass_done, stream_id})
      [] -> :ok
    end
  end
end
