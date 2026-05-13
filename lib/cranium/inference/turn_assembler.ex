defmodule Cranium.Inference.TurnAssembler do
  @moduledoc """
  Per-conversation turn assembler.

  Correlates PassHeaders with content (TextInput or TakeComplete), performs
  context assembly (epoch resolution, system prompt, turn injection, history),
  and dispatches assembled turns to the Harness for inference.

  For each pass, Transport emits a PassHeader (routing metadata) and a
  content message (TextInput for text, segment_received for audio).
  TurnAssembler holds both sides keyed by pass_id and fires when the
  pair is complete.

  Media uses take_id; Inference uses pass_id. For audio passes,
  PassHeader carries both and TurnAssembler maintains a take_id → pass_id
  index for correlation. TakeCollector (Media) handles both single-segment
  and multi-segment transcription assembly, emitting take_complete events
  that TurnAssembler correlates with PassHeaders.

  ## Per-Conversation Model

  Each conversation gets its own TurnAssembler, started as part of a
  Conversation supervisor pair (with Harness). Subscribes globally to
  Events and filters by conversation_id — PassHeaders carry conversation_id,
  and TextInput/TakeComplete only match if their pass_id/take_id is already
  indexed from a prior PassHeader for this conversation.

  ## Backpressure

  TurnAssembler won't assemble a new turn until the prior pass completes.
  If a second pair arrives while a pass is in flight, it queues. On
  pass_done from Harness, the queued pair is dispatched.
  """

  use GenServer
  require Logger

  alias Cranium.Messages.{PassHeader, TextInput, TakeComplete}

  @stale_timeout_ms :timer.minutes(20)
  @sweep_interval_ms :timer.minutes(1)
  @registry Cranium.Inference.ConversationRegistry

  @orientation_prompt "This is your private orientation time before the conversation begins. Read your handoff and cross-room context. Reflect on where things stand — what's in progress, what matters, what you want to bring to this session. This is journaling, not performance. The user will not see this output. Think out loud."

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    GenServer.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  defp via(conversation_id) do
    {:via, Registry, {@registry, {conversation_id, :turn_assembler}}}
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Logger.metadata(conversation_id: conversation_id)
    Cranium.Events.subscribe()
    schedule_sweep()

    {:ok,
     %{
       conversation_id: conversation_id,
       pending: %{},
       take_index: %{},
       active_pass: nil,
       queued: nil
     }}
  end

  # --- PassHeader arrives: cache and check for matching content ---
  # Only process headers for our conversation.

  @impl true
  def handle_info(
        {:pass_header, %PassHeader{pass_id: pass_id, conversation_id: cid} = header},
        %{conversation_id: cid} = state
      ) do
    Logger.debug("TurnAssembler: header received pass=#{pass_id}")
    state = put_field(state, pass_id, :header, header)

    # If this pass has an associated take, index it for transcription lookup
    state =
      if header.take_id do
        %{state | take_index: Map.put(state.take_index, header.take_id, pass_id)}
      else
        state
      end

    {:noreply, maybe_dispatch(state, pass_id)}
  end

  # --- TextInput arrives: cache and check for matching header ---

  @impl true
  def handle_info({:text_input, %TextInput{pass_id: pass_id} = input}, state) do
    # Only process if pass_id is in our pending map (indexed from a prior PassHeader)
    if Map.has_key?(state.pending, pass_id) do
      Logger.debug("TurnAssembler: text_input received pass=#{pass_id}")
      state = put_field(state, pass_id, :input, input)
      {:noreply, maybe_dispatch(state, pass_id)}
    else
      {:noreply, state}
    end
  end

  # --- TakeComplete (audio path — both single-segment and chunked) ---

  @impl true
  def handle_info(
        {:take_complete, %TakeComplete{take_id: take_id} = tc},
        state
      )
      when not is_nil(take_id) do
    case Map.get(state.take_index, take_id) do
      nil ->
        # Not our conversation's take — ignore silently
        {:noreply, state}

      pass_id ->
        Logger.debug("TurnAssembler: take_complete received take=#{take_id} pass=#{pass_id}")
        state = put_field(state, pass_id, :input, tc)
        {:noreply, maybe_dispatch(state, pass_id)}
    end
  end

  # --- Backpressure: Harness signals pass completion ---

  @impl true
  def handle_info({:pass_done, _stream_id}, state) do
    state = %{state | active_pass: nil}

    # Dispatch queued pair if any
    case state.queued do
      {header, input} ->
        state = %{state | queued: nil}
        {:noreply, assemble_and_dispatch(state, header, input)}

      nil ->
        {:noreply, state}
    end
  end

  # --- Sweep stale entries ---

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @stale_timeout_ms
    stale = for {id, %{inserted_at: t}} <- state.pending, t < cutoff, do: id

    if stale != [] do
      Logger.warning("TurnAssembler: sweeping #{length(stale)} stale passes")
    end

    # Clean up take_index entries for stale passes
    stale_set = MapSet.new(stale)

    take_index =
      state.take_index
      |> Enum.reject(fn {_take_id, pass_id} -> MapSet.member?(stale_set, pass_id) end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | pending: Map.drop(state.pending, stale), take_index: take_index}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp put_field(state, pass_id, field, value) do
    entry =
      Map.get(state.pending, pass_id, %{
        header: nil,
        input: nil,
        inserted_at: System.monotonic_time(:millisecond)
      })

    entry = Map.put(entry, field, value)
    %{state | pending: Map.put(state.pending, pass_id, entry)}
  end

  defp maybe_dispatch(state, pass_id) do
    case Map.get(state.pending, pass_id) do
      %{header: %PassHeader{} = header, input: input} when not is_nil(input) ->
        # Clean up take_index if this pass had a take
        take_index =
          if header.take_id,
            do: Map.delete(state.take_index, header.take_id),
            else: state.take_index

        state = %{state | pending: Map.delete(state.pending, pass_id), take_index: take_index}

        if state.active_pass do
          # A pass is already in flight — queue this pair
          Logger.info("TurnAssembler: queueing pass=#{pass_id} (active_pass=#{state.active_pass})")
          %{state | queued: {header, input}}
        else
          assemble_and_dispatch(state, header, input)
        end

      _ ->
        state
    end
  end

  # --- Context Assembly ---
  # This was previously Epoch.submit's context pipeline.

  defp assemble_and_dispatch(state, %PassHeader{} = header, input) do
    ephemeral = header.ephemeral == true

    # 1. Resolve epoch from Store (get existing or create fresh)
    {:ok, epoch_ctx} = Cranium.Store.get_or_create_epoch(header.conversation_id)
    is_fresh = epoch_ctx.turn_count == 0

    # Waking room: on fresh epoch, dispatch an orientation pass first and
    # queue the user's pass behind it via existing backpressure.
    if is_fresh and not ephemeral and header.origin != "orientation" do
      dispatch_orientation(state, header, input, epoch_ctx)
    else
      do_assemble_and_dispatch(state, header, input, epoch_ctx)
    end
  end

  defp do_assemble_and_dispatch(state, %PassHeader{} = header, input, epoch_ctx) do
    text =
      case input do
        %TextInput{text: text} -> text
        %TakeComplete{text: text} -> "[Transcribed from audio]\n#{text}"
      end

    ephemeral = header.ephemeral == true
    stream_id = header.stream_id

    Logger.info(
      "TurnAssembler: assembling pass=#{header.pass_id} conversation=#{header.conversation_id}",
      transport: :turn_assembler
    )

    epoch_id = epoch_ctx.epoch_id
    turn_count = epoch_ctx.turn_count
    is_fresh = turn_count == 0

    # 2. Broadcast message_received so firehose clients see inbound messages
    #    Orientation prompts are private — suppress their input from the firehose.
    unless ephemeral or header.origin == "orientation" do
      Cranium.Events.broadcast(header.conversation_id, {:message_received, header.conversation_id, %{
        text: text,
        origin: header.origin,
        stream_id: stream_id
      }})
    end

    # 3. Resolve profile → backend, model, identity
    {backend_module, resolved_model, identity, profile_name, thinking, saturation_config, profile} =
      resolve_profile(header)

    # 4. Resolve routing context
    projects_dir = Application.get_env(:cranium, :projects_dir, "~/Projects")
    working_dir = Cranium.Context.Router.resolve_working_dir(header.conversation_id, projects_dir)

    # 5. System prompt — profile identity, with header.system as direct override
    system_prompt =
      Cranium.Inference.SystemPrompt.contribute(
        header.conversation_id,
        is_fresh: is_fresh,
        identity: identity
      )

    # 5b. Ensure plugins are running (idempotent — no-ops if already started)
    Cranium.Plugin.ConversationSupervisor.start_plugins(
      header.conversation_id,
      %{
        conversation_id: header.conversation_id,
        epoch_id: epoch_id,
        room_name: header.conversation_id,
        profile: profile,
        plugin_config: nil
      }
    )

    # 5c. Dispatch before_context_build hook to plugins
    turn_context = %{
      conversation_id: header.conversation_id,
      epoch_id: epoch_id,
      turn_count: turn_count,
      message_text: text
    }

    plugin_injections =
      Cranium.Plugin.ConversationSupervisor.dispatch_hook(
        header.conversation_id,
        :before_context_build,
        turn_context
      )

    # 6. Turn injections (merged with plugin injections)
    injection_message = %{
      text: text,
      conversation_id: header.conversation_id,
      is_fresh: is_fresh
    }

    injection_ctx = %{
      now: DateTime.utc_now(),
      epoch: %{
        last_invoked_at: epoch_ctx.last_invoked_at,
        saturation: epoch_ctx.saturation,
        last_reminder_bucket: epoch_ctx.last_reminder_bucket,
        last_landscape_at: epoch_ctx.last_landscape_at,
        interrupted_context: epoch_ctx.interrupted_context
      },
      saturation_warn: saturation_config[:saturation_warn],
      saturation_critical: saturation_config[:saturation_critical]
    }

    {:ok, injected} = Cranium.Context.TurnInjector.process(injection_message, injection_ctx, plugin_injections)

    # 7. Write injection flags to Store immediately
    injection_flags = %{
      landscape_injected: injected[:landscape_injected] || false,
      saturation_warned_bucket: injected[:saturation_warned_bucket]
    }

    if injection_flags.landscape_injected do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Cranium.Store.update_epoch(epoch_id, %{last_landscape_at: now})
    end

    if injection_flags.saturation_warned_bucket do
      Cranium.Store.update_epoch(epoch_id, %{
        last_reminder_bucket: injection_flags.saturation_warned_bucket
      })
    end

    # 8. Build history BEFORE persisting current message, so it doesn't
    #    appear twice (once from DB, once from the explicit append).
    enriched_text = injected[:text] || text

    messages =
      Cranium.Inference.History.contribute(
        header.conversation_id,
        epoch_id: epoch_id,
        text: enriched_text,
        attachments: Map.get(header, :attachments, [])
      )

    # 9. Persist enriched user message (after history fetch)
    unless ephemeral do
      Cranium.Store.append_message(header.conversation_id, epoch_id, %{
        role: :user,
        content: enriched_text,
        origin: header.origin
      })
    end

    # 10. Build Dispatch for OutputSegmenter metadata
    harness_type =
      case backend_module do
        Cranium.Backend.LLM.ClaudeCode -> :claude_code
        Cranium.Backend.LLM.Anthropic -> :api
        Cranium.Backend.LLM.Ollama -> :ollama
        _ -> nil
      end

    dispatch =
      Cranium.Dispatch.from_submit(%{
        conversation_id: header.conversation_id,
        harness: harness_type,
        model: resolved_model,
        disposition: header.disposition,
        ephemeral: header.ephemeral
      })

    # 11. Emit turn_ready to Harness
    turn = %{
      system: system_prompt,
      messages: messages,
      mode: :text,
      conversation_id: header.conversation_id,
      stream_id: stream_id,
      disposition: header.disposition || ["text"],
      cc_session_id: unless(ephemeral, do: epoch_ctx.cc_session_id),
      working_dir: working_dir,
      backend: backend_module,
      model: resolved_model,
      profile: profile_name,
      thinking: thinking,
      context_window: saturation_config[:context_window],
      ephemeral: ephemeral,
      dispatch: dispatch,
      epoch_id: epoch_id,
      turn_count: turn_count,
      injection_flags: injection_flags,
      origin: header.origin,
      pass_id: header.pass_id,
      silent: header.origin == "orientation",
      tools_disabled: header.origin == "orientation"
    }

    case Registry.lookup(@registry, {header.conversation_id, :harness}) do
      [{pid, _}] ->
        send(pid, {:turn_ready, turn})

      [] ->
        Logger.error("TurnAssembler: no Harness found for conversation=#{header.conversation_id}")
    end

    %{state | active_pass: stream_id}
  end

  # --- Waking Room ---
  # Dispatches a synthetic orientation pass and queues the user's pass behind it.

  defp dispatch_orientation(state, %PassHeader{} = header, input, epoch_ctx) do
    Logger.info(
      "TurnAssembler: fresh epoch — dispatching orientation before pass=#{header.pass_id}",
      conversation_id: header.conversation_id
    )

    orientation_pass_id = Cranium.Stage.new_stream_id()
    orientation_stream_id = Cranium.Stage.new_stream_id()

    orientation_header = %PassHeader{
      pass_id: orientation_pass_id,
      conversation_id: header.conversation_id,
      stream_id: orientation_stream_id,
      origin: "orientation",
      profile: header.profile,
      disposition: ["text"]
    }

    orientation_input = %TextInput{
      pass_id: orientation_pass_id,
      text: @orientation_prompt
    }

    # Queue the user's original pass — it will dispatch after orientation completes
    state = %{state | queued: {header, input}}

    # Dispatch orientation through the normal assembly pipeline
    do_assemble_and_dispatch(state, orientation_header, orientation_input, epoch_ctx)
  end

  defp resolve_profile(%PassHeader{profile: profile_name, model: model_override, system: system_override}) do
    profile_name = profile_name || Cranium.Config.default_profile_name()

    resolved =
      case Cranium.Config.resolve_profile(profile_name) do
        {:ok, r} ->
          r

        {:error, :not_found} ->
          Logger.warning("TurnAssembler: profile '#{profile_name}' not found, using default")
          {:ok, r} = Cranium.Config.resolve_profile(Cranium.Config.default_profile_name())
          r
      end

    model = model_override || resolved.model

    # header.system (direct string override) wins over profile identity
    identity =
      cond do
        is_binary(system_override) and system_override != "" -> system_override
        is_binary(resolved.identity) -> resolved.identity
        true -> ""
      end

    saturation_config = %{
      context_window: resolved[:context_window],
      saturation_warn: resolved[:saturation_warn],
      saturation_critical: resolved[:saturation_critical]
    }

    # Build a lightweight profile struct for plugin initialization
    profile = %Cranium.Config.Profile{
      name: profile_name,
      backend: resolved.backend,
      model: model,
      plugins: resolved[:plugins] || []
    }

    {resolved.backend_module, model, identity, profile_name, resolved.thinking, saturation_config, profile}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
