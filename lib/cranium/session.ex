defmodule Cranium.Session do
  @moduledoc """
  Per-room session coordinator.

  A Session orchestrates a single invocation through the pipeline for a room.
  At most one Session exists per room at any time, enforced by the Registry.

  The Session does not hold conversation history in process state — that lives
  in Store. Session state tracks the active invocation lifecycle:

  - `:idle` — waiting for input
  - `:processing` — pipeline is running
  - `:inferring` — Agent is streaming from the LLM
  - `:cancelled` — cancel was requested, draining
  """

  use GenServer, restart: :transient

  require Logger

  defstruct [
    :room_id,
    :transport,
    :transport_meta,
    status: :idle,
    stream_id: nil,
    started_at: nil
  ]

  @type t :: %__MODULE__{
          room_id: String.t(),
          transport: module() | nil,
          transport_meta: map() | nil,
          status: :idle | :processing | :inferring | :cancelled,
          stream_id: String.t() | nil,
          started_at: DateTime.t() | nil
        }

  # --- Public API ---

  @doc """
  Start a new session for a room, or return the existing one.
  """
  @spec start_or_get(String.t(), keyword()) :: {:ok, pid()} | {:error, :already_active}
  def start_or_get(room_id, opts \\ []) do
    case lookup(room_id) do
      {:ok, pid} ->
        {:ok, pid}

      :not_found ->
        case DynamicSupervisor.start_child(
               Cranium.Session.Supervisor,
               {__MODULE__, Keyword.merge(opts, room_id: room_id)}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Look up the session process for a room.
  """
  @spec lookup(String.t()) :: {:ok, pid()} | :not_found
  def lookup(room_id) do
    case Registry.lookup(Cranium.Session.Registry, room_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  @doc """
  Submit a message to the session's pipeline.
  """
  @spec submit(pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def submit(pid, message) do
    GenServer.call(pid, {:submit, message}, :infinity)
  end

  @doc """
  Clear the session — trigger handoff and reset.
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
    room_id = Keyword.fetch!(opts, :room_id)
    GenServer.start_link(__MODULE__, opts, name: via(room_id))
  end

  defp via(room_id) do
    {:via, Registry, {Cranium.Session.Registry, room_id}}
  end

  @impl true
  def init(opts) do
    room_id = Keyword.fetch!(opts, :room_id)

    Logger.metadata(room_id: room_id)
    Logger.info("Session started")

    state = %__MODULE__{
      room_id: room_id,
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
    Logger.info("Processing message", stage: :session)

    # TODO: Wire pipeline stages
    # 1. Cranium.Ingress.process(message, context)
    # 2. Cranium.Context.process(ingress_result, context)
    # 3. Cranium.Agent.infer(context_result, callback)
    # 4. Cranium.Egress.process(agent_output, context)

    state = %{state | status: :idle, stream_id: nil}
    {:reply, {:ok, state.room_id}, state}
  end

  def handle_call({:submit, _message}, _from, state) do
    {:reply, {:error, :already_active}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    Logger.info("Clearing session", stage: :session)

    # TODO: Trigger handoff generation via Effects
    # Cranium.Effects.generate_handoff(state.room_id)

    state = %{state | status: :idle, stream_id: nil}
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:cancel, %{status: status} = state) when status in [:processing, :inferring] do
    Logger.info("Cancelling inference", stage: :session)
    # TODO: Kill the Agent process, capture partial context
    {:noreply, %{state | status: :cancelled}}
  end

  def handle_cast(:cancel, state) do
    {:noreply, state}
  end
end
