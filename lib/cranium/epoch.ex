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

  defstruct [
    :conversation_id,
    :epoch_id,
    :transport,
    :transport_meta,
    :agent_pid,
    status: :idle,
    stream_id: nil,
    turn_count: 0
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          epoch_id: String.t() | nil,
          transport: module() | nil,
          transport_meta: map() | nil,
          agent_pid: pid() | nil,
          status: :idle | :processing | :inferring | :cancelled,
          stream_id: String.t() | nil,
          turn_count: non_neg_integer()
        }

  # --- Public API ---

  @doc """
  Start a new epoch for a conversation, or return the existing one.
  """
  @spec start_or_get(String.t(), keyword()) :: {:ok, pid()} | {:error, :already_active}
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
  """
  @spec clear(pid()) :: :ok
  def clear(pid) do
    GenServer.call(pid, :clear, 30_000)
  end

  @doc """
  Cancel active inference.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  @doc false
  @spec compute_saturation(map()) :: float()
  def compute_saturation(usage) do
    max_context_tokens =
      Application.get_env(:cranium, :pipeline)[:max_context_tokens] || 200_000

    min(usage.input_tokens / max_context_tokens, 1.0)
  end

  # --- GenServer Implementation ---

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

    {epoch_id, turn_count} =
      case Cranium.Store.get_epoch(conversation_id) do
        {:ok, %{id: id, status: status, turn_count: tc}} when status != "cleared" ->
          Logger.info("Epoch resumed", epoch_id: id, turn_count: tc)
          {id, tc}

        _ ->
          {:ok, id} = Cranium.Store.create_epoch(conversation_id)
          Logger.info("Epoch started", epoch_id: id)
          {id, 0}
      end

    state = %__MODULE__{
      conversation_id: conversation_id,
      epoch_id: epoch_id,
      turn_count: turn_count,
      transport: Keyword.get(opts, :transport),
      transport_meta: Keyword.get(opts, :transport_meta, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, message}, _from, %{status: :idle} = state) do
    state = %{state | status: :processing, stream_id: Cranium.Stage.new_stream_id()}
    Logger.info("Processing message", stage: :epoch)

    msg_map = normalize_message(message)
    text = msg_map[:text] || ""

    # 1. Assemble context via full pipeline (Router → PromptBuilder → TurnInjector → HistoryManager)
    #    Note: persist AFTER assembly so HistoryManager doesn't fetch the current
    #    message from history (it appends the enriched version with system-reminders).
    normalized = %{
      conversation_id: state.conversation_id,
      text: text,
      attachments: Map.get(msg_map, :attachments, [])
    }

    pipeline_ctx = %{
      identity: msg_map[:system],
      projects_dir: "~/Projects",
      mode: Map.get(msg_map, :mode, :text),
      history_window: 50,
      now: DateTime.utc_now(),
      epoch_id: state.epoch_id
    }

    {:ok, enriched} = Cranium.Context.process(normalized, pipeline_ctx)

    # 2. Persist raw user message (after context assembly, before inference)
    Cranium.Store.append_message(state.conversation_id, state.epoch_id, %{role: :user, content: text})

    # 3. Map pipeline output to Agent context
    context = %{
      system: enriched[:system_prompt],
      messages: enriched[:messages],
      mode: Map.get(msg_map, :mode, :text),
      conversation_id: state.conversation_id,
      stream_id: msg_map[:stream_id] || state.stream_id,
      disposition: Map.get(msg_map, :disposition, ["text"])
    }

    # 4. Run inference
    {:ok, agent_pid} = Cranium.Agent.start_link(
      conversation_id: state.conversation_id,
      epoch_pid: self()
    )

    egress_pid = Process.whereis(Cranium.Egress)
    state = %{state | status: :inferring, agent_pid: agent_pid}

    Cranium.Store.update_epoch(state.epoch_id, %{status: "inferring"})
    result = Cranium.Agent.infer(agent_pid, context, egress_pid)

    # 5. Persist assistant response and track saturation
    state =
      case result do
        {:ok, %{output: output, usage: usage}} ->
          if output != "" do
            Cranium.Store.append_message(state.conversation_id, state.epoch_id, %{
              role: :assistant,
              content: output
            })
          end

          saturation = compute_saturation(usage)
          new_count = state.turn_count + 1

          Cranium.Store.update_epoch(state.epoch_id, %{
            status: "active",
            saturation: saturation,
            turn_count: new_count
          })

          %{state | turn_count: new_count}

        _ ->
          Cranium.Store.update_epoch(state.epoch_id, %{status: "active"})
          state
      end

    state = %{state | status: :idle, stream_id: nil, agent_pid: nil}
    {:reply, result, state}
  end

  def handle_call({:submit, _message}, _from, state) do
    {:reply, {:error, :already_active}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    Logger.info("Clearing epoch", stage: :epoch)

    Cranium.Store.update_epoch(state.epoch_id, %{status: "cleared"})
    Cranium.Effects.generate_handoff(state.conversation_id, state.epoch_id)

    {:ok, new_epoch_id} = Cranium.Store.create_epoch(state.conversation_id)
    state = %{state | status: :idle, stream_id: nil, epoch_id: new_epoch_id, turn_count: 0}
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
      attachments: Map.get(message, :attachments, [])
    }
  end
end
