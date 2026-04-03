defmodule Cranium.Epoch do
  @moduledoc """
  Per-conversation epoch coordinator.

  An Epoch orchestrates a single span of continuous context within a
  conversation. At most one Epoch exists per conversation at any time,
  enforced by the Registry.

  The Epoch does not hold conversation history in process state — that lives
  in Store. Epoch state tracks the active invocation lifecycle:

  - `:idle` — waiting for input
  - `:processing` — pipeline is running
  - `:inferring` — Agent is streaming from the LLM
  - `:cancelled` — cancel was requested, draining
  """

  use GenServer, restart: :transient

  require Logger

  use TypedStruct

  typedstruct do
    field :conversation_id, String.t()
    field :epoch_id, String.t() | nil
    field :transport, module() | nil
    field :transport_meta, map() | nil
    field :agent_pid, pid() | nil
    field :cc_session_id, String.t() | nil
    field :last_landscape_at, DateTime.t() | nil
    field :interrupted_context, String.t() | nil
    field :dispatch, Cranium.Dispatch.t() | nil
    field :status, :idle | :processing | :inferring | :cancelled, default: :idle
    field :stream_id, String.t() | nil
    field :turn_count, non_neg_integer(), default: 0
    field :saturation, float(), default: 0.0
    field :last_reminder_bucket, non_neg_integer(), default: 0
  end

  # --- Public API ---

  @doc """
  Start a new epoch for a conversation, or return the existing one.
  """
  @spec start_or_get(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_or_get(conversation_id, opts \\ []) do
    case lookup(conversation_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        case DynamicSupervisor.start_child(
               Cranium.Epoch.Supervisor,
               {__MODULE__, Keyword.merge(opts, conversation_id: conversation_id)}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Look up the epoch process for a conversation.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :not_found
  def lookup(conversation_id) do
    case Registry.lookup(Cranium.Epoch.Registry, conversation_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc """
  Submit a message to the epoch's pipeline.
  """
  @spec submit(pid(), map() | String.t()) :: {:ok, map()} | {:error, term()}
  def submit(pid, message) do
    GenServer.call(pid, {:submit, message}, :infinity)
  end

  @doc """
  Clear the epoch — trigger handoff and reset.

  Options:
  - `:source` — origin of the clear (e.g. "matrix", "api")
  """
  @spec clear(pid(), keyword()) :: :ok
  def clear(pid, opts \\ []) do
    GenServer.call(pid, {:clear, opts}, 30_000)
  end

  @doc """
  Cancel active inference.

  Bypasses the Epoch GenServer (which is blocked in handle_call during
  inference) and sends the cancel directly to the Agent process via
  a Registry lookup.
  """
  @spec cancel(String.t()) :: :ok | :not_found
  def cancel(conversation_id) do
    case Registry.lookup(Cranium.Epoch.Registry, {conversation_id, :agent}) do
      [{_epoch_pid, agent_pid}] ->
        Logger.info("Cancel: sending to agent #{inspect(agent_pid)}",
          conversation_id: conversation_id
        )

        GenServer.cast(agent_pid, :cancel)
        :ok

      [] ->
        Logger.warning("Cancel: no agent registered",
          conversation_id: conversation_id
        )

        :not_found
    end
  end

  @doc false
  @spec compute_saturation(map()) :: float()
  def compute_saturation(usage) do
    max_context_tokens =
      Application.get_env(:cranium, :pipeline)[:max_context_tokens] || 200_000

    # Total context = uncached + newly cached + cache hits + output
    total =
      (usage[:input_tokens] || 0) +
        (usage[:output_tokens] || 0) +
        (usage[:cache_creation_input_tokens] || 0) +
        (usage[:cache_read_input_tokens] || 0)

    min(total / max_context_tokens, 1.0)
  end

  # --- GenServer Implementation ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    GenServer.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  defp via(conversation_id) do
    {:via, Registry, {Cranium.Epoch.Registry, conversation_id}}
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Logger.metadata(conversation_id: conversation_id)

    {epoch_id, turn_count, saturation, last_reminder_bucket, cc_session_id} =
      case Cranium.Store.get_epoch(conversation_id) do
        {:ok,
         %{
           id: id,
           status: status,
           turn_count: tc,
           saturation: sat,
           last_reminder_bucket: lrb,
           cc_session_id: ccid
         }}
        when status != "cleared" ->
          Logger.info("Epoch resumed", epoch_id: id, turn_count: tc)
          {id, tc, sat || 0.0, lrb || 0, ccid}

        _ ->
          {:ok, id} = Cranium.Store.create_epoch(conversation_id)
          Logger.info("Epoch started", epoch_id: id)
          {id, 0, 0.0, 0, nil}
      end

    state = %__MODULE__{
      conversation_id: conversation_id,
      epoch_id: epoch_id,
      turn_count: turn_count,
      saturation: saturation,
      last_reminder_bucket: last_reminder_bucket,
      cc_session_id: cc_session_id,
      transport: Keyword.get(opts, :transport),
      transport_meta: Keyword.get(opts, :transport_meta, %{})
    }

    Cranium.Event.broadcast(conversation_id, {:epoch_started, conversation_id, %{epoch_id: epoch_id}})

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, message}, _from, %{status: :idle} = state) do
    state = %{state | status: :processing, stream_id: Cranium.Stage.new_stream_id()}
    Logger.info("Processing message", stage: :epoch)

    msg_map = normalize_message(message)
    text = msg_map[:text] || ""
    ephemeral = msg_map[:ephemeral] == true
    dispatch = msg_map[:dispatch]
    state = %{state | dispatch: dispatch}

    # Broadcast message_received so firehose clients see inbound messages
    unless ephemeral do
      Cranium.Event.broadcast(state.conversation_id, {:message_received, state.conversation_id, %{
        text: text,
        origin: msg_map[:origin],
        stream_id: state.stream_id
      }})
    end

    # Derive last_invoked_at from most recent message timestamp
    last_invoked_at =
      if ephemeral do
        nil
      else
        case Cranium.Store.get_last_message_at(state.epoch_id) do
          {:ok, ts} -> ts
          :not_found -> nil
        end
      end

    # 1. Resolve routing context (was Context.Router)
    projects_dir = Application.get_env(:cranium, :projects_dir, "~/Projects")
    working_dir = Cranium.Context.Router.resolve_project_dir(state.conversation_id, projects_dir)
    is_fresh = state.turn_count == 0

    # 2. System prompt (was Context.PromptBuilder)
    system_prompt =
      Cranium.Inference.SystemPrompt.contribute(
        state.conversation_id,
        is_fresh: is_fresh,
        identity: msg_map[:system]
      )

    # 3. Turn injections (was Context.TurnInjector via Context.process)
    #    Note: persist AFTER injection so History doesn't fetch the current
    #    message (it appends the enriched version with system-reminders).
    injection_message = %{
      text: text,
      conversation_id: state.conversation_id,
      is_fresh: is_fresh
    }

    injection_ctx = %{
      now: DateTime.utc_now(),
      epoch: %{
        last_invoked_at: last_invoked_at,
        saturation: state.saturation * 100,
        last_reminder_bucket: state.last_reminder_bucket,
        last_landscape_at: state.last_landscape_at,
        interrupted_context: state.interrupted_context
      }
    }

    {:ok, injected} = Cranium.Context.TurnInjector.process(injection_message, injection_ctx)

    stream_id = msg_map[:stream_id] || state.stream_id
    Cranium.Manifest.stamp(stream_id, :context_assembled)

    # Track landscape injection for delta filtering on subsequent idle returns
    state =
      if injected[:landscape_injected],
        do: %{state | last_landscape_at: DateTime.utc_now()},
        else: state

    # Only advance reminder bucket when a saturation warning was actually injected
    state =
      if injected[:saturation_warned_bucket],
        do: %{state | last_reminder_bucket: injected[:saturation_warned_bucket]},
        else: state

    # 4. Persist enriched user message (includes system-reminders from TurnInjector)
    enriched_text = injected[:text] || text

    unless ephemeral do
      Cranium.Store.append_message(state.conversation_id, state.epoch_id, %{
        role: :user,
        content: enriched_text,
        origin: msg_map[:origin]
      })
    end

    # 5. History (was Context.HistoryManager)
    messages =
      Cranium.Inference.History.contribute(
        state.conversation_id,
        epoch_id: state.epoch_id,
        window: 50,
        text: enriched_text,
        attachments: Map.get(msg_map, :attachments, [])
      )

    # 6. Build Agent context
    context = %{
      system: system_prompt,
      messages: messages,
      mode: Map.get(msg_map, :mode, :text),
      conversation_id: state.conversation_id,
      stream_id: msg_map[:stream_id] || state.stream_id,
      disposition: Map.get(msg_map, :disposition, ["text"]),
      cc_session_id: if(ephemeral, do: nil, else: state.cc_session_id),
      working_dir: working_dir || Map.get(msg_map, :working_dir),
      model: msg_map[:model],
      ephemeral: ephemeral
    }

    # 4. Run inference
    {:ok, agent_pid} =
      Cranium.Agent.start_link(
        conversation_id: state.conversation_id,
        epoch_pid: self()
      )

    # Register agent_pid so cancel/1 can reach it without going through
    # this blocked handle_call
    Registry.register(Cranium.Epoch.Registry, {state.conversation_id, :agent}, agent_pid)

    # Subscribe OutputSegmenter to the raw stream before inference starts
    :ok = GenServer.call(Cranium.Media.OutputSegmenter, {:subscribe_stream, stream_id})

    state = %{state | status: :inferring, agent_pid: agent_pid}

    unless ephemeral do
      Cranium.Store.update_epoch(state.epoch_id, %{status: "inferring"})
    end

    Cranium.Manifest.stamp(stream_id, :inference_start)
    result = Cranium.Agent.infer(agent_pid, context)

    # Unregister agent — inference is done
    Registry.unregister(Cranium.Epoch.Registry, {state.conversation_id, :agent})

    # Stop the Agent process. It's single-use and would otherwise linger
    # as a zombie GenServer linked to this Epoch until the Epoch dies.
    GenServer.stop(agent_pid, :normal, 5_000)

    # 5. Persist assistant response, track saturation, capture CC session ID
    {reply, state} =
      case result do
        {:ok, %{output: output, usage: usage} = agent_result} ->
          unless ephemeral do
            if output != "" do
              Cranium.Store.append_message(state.conversation_id, state.epoch_id, %{
                role: :assistant,
                content: output
              })
            end
          end

          saturation = compute_saturation(usage)
          new_count = state.turn_count + 1

          cc_session_id = agent_result[:cc_session_id] || state.cc_session_id

          unless ephemeral do
            # Generate cross-conversation summary every N turns
            summary_interval = Application.get_env(:cranium, :pipeline)[:summary_interval] || 10

            if summary_interval > 0 and rem(new_count, summary_interval) == 0 do
              Cranium.Effects.generate_summary(state.conversation_id, state.cc_session_id)
            end

            Cranium.Store.update_epoch(state.epoch_id, %{
              status: "active",
              saturation: saturation,
              turn_count: new_count,
              last_reminder_bucket: state.last_reminder_bucket,
              cc_session_id: cc_session_id
            })
          end

          # Push saturation to the manifest so clients can surface it
          if stream_id = agent_result[:stream_id] do
            Cranium.Manifest.set_metadata(stream_id, %{
              "saturation" => Float.round(saturation, 3),
              "turn_count" => new_count
            })
          end

          # Emit pass_complete so firehose clients get post-inference metadata
          unless ephemeral do
            Cranium.Event.broadcast(stream_id, state.conversation_id,
              {:pass_complete, state.conversation_id, stream_id, %{
                saturation: saturation,
                turn_count: new_count,
                reason: :complete
              }})
          end

          {result,
           %{
             state
             | turn_count: if(ephemeral, do: state.turn_count, else: new_count),
               saturation: if(ephemeral, do: state.saturation, else: saturation),
               cc_session_id: if(ephemeral, do: state.cc_session_id, else: cc_session_id),
               interrupted_context: nil
           }}

        {:error, :cancelled, partial} ->
          output = partial[:output] || ""

          unless ephemeral do
            # Persist partial assistant response so history isn't gapped
            if output != "" do
              Cranium.Store.append_message(state.conversation_id, state.epoch_id, %{
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

          cc_session_id = partial[:cc_session_id] || state.cc_session_id

          unless ephemeral do
            Cranium.Store.update_epoch(state.epoch_id, %{
              status: "active",
              cc_session_id: cc_session_id
            })
          end

          unless ephemeral do
            Cranium.Event.broadcast(stream_id, state.conversation_id,
              {:pass_complete, state.conversation_id, stream_id, %{reason: :cancelled}})
          end

          {{:error, :cancelled},
           %{
             state
             | interrupted_context: interrupted,
               cc_session_id: if(ephemeral, do: state.cc_session_id, else: cc_session_id)
           }}

        {:error, _reason} ->
          unless ephemeral do
            Cranium.Store.update_epoch(state.epoch_id, %{status: "active"})
          end

          unless ephemeral do
            Cranium.Event.broadcast(stream_id, state.conversation_id,
              {:pass_complete, state.conversation_id, stream_id, %{reason: :error}})
          end

          {result, state}
      end

    state = %{state | status: :idle, stream_id: nil, agent_pid: nil, dispatch: nil}
    {:reply, reply, state}
  end

  def handle_call({:submit, _message}, _from, state) do
    {:reply, {:error, :already_active}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, %{status: state.status}, state}
  end

  @impl true
  def handle_call({:clear, opts}, _from, state) do
    Logger.info("Clearing epoch", stage: :epoch)
    source = Keyword.get(opts, :source)

    Cranium.Store.update_epoch(state.epoch_id, %{status: "cleared"})

    Cranium.Event.broadcast(state.conversation_id,
      {:epoch_cleared, state.conversation_id, %{epoch_id: state.epoch_id, source: source}})

    Cranium.Effects.generate_handoff(state.conversation_id, state.epoch_id, state.cc_session_id)

    {:ok, new_epoch_id} = Cranium.Store.create_epoch(state.conversation_id)

    state = %{
      state
      | status: :idle,
        stream_id: nil,
        epoch_id: new_epoch_id,
        turn_count: 0,
        saturation: 0.0,
        last_reminder_bucket: 0,
        cc_session_id: nil,
        last_landscape_at: nil,
        interrupted_context: nil
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: status} = state) when status in [:processing, :inferring] do
    Logger.info("Cancelling inference", stage: :epoch)

    if state.agent_pid do
      GenServer.cast(state.agent_pid, :cancel)
    end

    {:noreply, %{state | status: :cancelled}}
  end

  def handle_cast(:cancel, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp normalize_message(message) when is_binary(message), do: %{text: message}

  defp normalize_message(message) when is_map(message) do
    %{
      text: Map.get(message, :text) || Map.get(message, "text") || "",
      system: Map.get(message, :system) || Map.get(message, "system"),
      stream_id: Map.get(message, :stream_id),
      disposition: Map.get(message, :disposition, ["text"]),
      mode: Map.get(message, :mode, :text),
      attachments: Map.get(message, :attachments, []),
      origin: Map.get(message, :origin),
      model: Map.get(message, :model) || Map.get(message, "model"),
      ephemeral: Map.get(message, :ephemeral, false),
      dispatch: Map.get(message, :dispatch)
    }
  end
end
