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
    :transport,
    :transport_meta,
    status: :idle,
    stream_id: nil,
    started_at: nil
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t(),
          transport: module() | nil,
          transport_meta: map() | nil,
          status: :idle | :processing | :inferring | :cancelled,
          stream_id: String.t() | nil,
          started_at: DateTime.t() | nil
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
  @spec submit(pid(), map()) :: {:ok, String.t()} | {:error, term()}
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
    Logger.info("Epoch started")

    state = %__MODULE__{
      conversation_id: conversation_id,
      transport: Keyword.get(opts, :transport),
      transport_meta: Keyword.get(opts, :transport_meta, %{}),
      started_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, _message}, _from, %{status: :idle} = state) do
    # Pipeline flow: Ingress → Context → Agent → Egress
    # For now, this is a placeholder that will be fleshed out as stages
    # are implemented. The shape is correct — each stage is called in
    # sequence, with Agent being the streaming/async portion.
    state = %{state | status: :processing, stream_id: Cranium.Stage.new_stream_id()}
    Logger.info("Processing message", stage: :epoch)

    # TODO: Wire pipeline stages
    # 1. Cranium.Ingress.process(message, context)
    # 2. Cranium.Context.process(ingress_result, context)
    # 3. Cranium.Agent.infer(context_result, callback)
    # 4. Cranium.Egress.process(agent_output, context)

    state = %{state | status: :idle, stream_id: nil}
    {:reply, {:ok, state.conversation_id}, state}
  end

  def handle_call({:submit, _message}, _from, state) do
    {:reply, {:error, :already_active}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    Logger.info("Clearing epoch", stage: :epoch)

    # TODO: Trigger handoff generation via Effects
    # Cranium.Effects.generate_handoff(state.conversation_id)

    state = %{state | status: :idle, stream_id: nil}
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: status} = state) when status in [:processing, :inferring] do
    Logger.info("Cancelling inference", stage: :epoch)
    # TODO: Kill the Agent process, capture partial context
    {:noreply, %{state | status: :cancelled}}
  end

  def handle_cast(:cancel, state) do
    {:noreply, state}
  end
end
