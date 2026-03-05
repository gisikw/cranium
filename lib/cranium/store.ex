defmodule Cranium.Store do
  @moduledoc """
  Persistence stage.

  Central storage service with soft read/write locking during active
  inference. All database access from pipeline stages goes through this
  module — no direct Repo calls.

  ## Locking Model

  Store uses per-conversation soft locks:
  - Reads are always allowed (no lock needed)
  - Writes during active inference for the same conversation queue behind
    the inference (soft lock via GenServer message ordering)
  - Lock scope is per-conversation, never global

  ## Entities

  - **Epochs** — per-conversation state (status, saturation, turn count)
  - **Messages** — conversation history (role, content, token counts)
  - **Handoffs** — conversation handoff documents for epoch continuity
  - **Summaries** — cross-conversation awareness cache

  ## Design Note

  The data model is intentionally minimal in this initial scaffold.
  Schema design needs iteration — see README open questions.
  """

  use GenServer

  require Logger

  defstruct locks: %{}

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Epoch operations

  @spec get_epoch(String.t()) :: {:ok, map()} | :not_found
  def get_epoch(conversation_id) do
    GenServer.call(__MODULE__, {:get_epoch, conversation_id})
  end

  @spec upsert_epoch(String.t(), map()) :: :ok
  def upsert_epoch(conversation_id, attrs) do
    GenServer.call(__MODULE__, {:upsert_epoch, conversation_id, attrs})
  end

  # Message operations

  @spec append_message(String.t(), map()) :: :ok
  def append_message(conversation_id, message) do
    GenServer.call(__MODULE__, {:append_message, conversation_id, message})
  end

  @spec get_messages(String.t(), keyword()) :: {:ok, [map()]}
  def get_messages(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_messages, conversation_id, opts})
  end

  # Handoff operations

  @spec save_handoff(String.t(), String.t()) :: :ok
  def save_handoff(conversation_id, content) do
    GenServer.call(__MODULE__, {:save_handoff, conversation_id, content})
  end

  @spec get_latest_handoff(String.t()) :: {:ok, String.t()} | :not_found
  def get_latest_handoff(conversation_id) do
    GenServer.call(__MODULE__, {:get_latest_handoff, conversation_id})
  end

  # Summary operations

  @spec save_summary(String.t(), String.t()) :: :ok
  def save_summary(conversation_id, content) do
    GenServer.call(__MODULE__, {:save_summary, conversation_id, content})
  end

  @spec get_all_summaries() :: {:ok, [map()]}
  def get_all_summaries do
    GenServer.call(__MODULE__, :get_all_summaries)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_opts) do
    Logger.info("Store started", stage: :store)
    {:ok, %__MODULE__{}}
  end

  # TODO: Implement handlers with Ecto queries once schemas are defined.
  # For now, these are stubs that will be replaced.

  @impl true
  def handle_call({:get_epoch, _conversation_id}, _from, state) do
    {:reply, :not_found, state}
  end

  @impl true
  def handle_call({:upsert_epoch, _conversation_id, _attrs}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:append_message, _conversation_id, _message}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_messages, _conversation_id, _opts}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  @impl true
  def handle_call({:save_handoff, _conversation_id, _content}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_latest_handoff, _conversation_id}, _from, state) do
    {:reply, :not_found, state}
  end

  @impl true
  def handle_call({:save_summary, _conversation_id, _content}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_summaries, _from, state) do
    {:reply, {:ok, []}, state}
  end
end
