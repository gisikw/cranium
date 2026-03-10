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
  - **Messages** — conversation history (role, content)
  - **Handoffs** — conversation handoff documents for epoch continuity
  - **Summaries** — cross-conversation awareness cache
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Cranium.Store.{Repo, Epoch, Message, Handoff, Summary}

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

  @impl true
  def handle_call({:get_epoch, conversation_id}, _from, state) do
    result =
      case Repo.get_by(Epoch, conversation_id: conversation_id) do
        nil -> :not_found
        epoch -> {:ok, epoch_to_map(epoch)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:upsert_epoch, conversation_id, attrs}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Epoch, conversation_id: conversation_id) do
      nil ->
        %Epoch{}
        |> Epoch.changeset(Map.put(attrs, :conversation_id, conversation_id))
        |> Repo.insert!()

      existing ->
        existing
        |> Epoch.changeset(Map.put(attrs, :updated_at, now))
        |> Repo.update!()
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:append_message, conversation_id, message}, _from, state) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation_id,
      role: to_string(message[:role] || "user"),
      content: message[:content] || ""
    })
    |> Repo.insert!()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_messages, conversation_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)
    since = Keyword.get(opts, :since)

    base = from(m in Message, where: m.conversation_id == ^conversation_id)

    base =
      case since do
        %DateTime{} = ts -> from(m in base, where: m.inserted_at >= ^ts)
        _ -> base
      end

    messages =
      if limit do
        recent = from(m in base, order_by: [desc: m.inserted_at, desc: m.id], limit: ^limit)
        from(m in subquery(recent), order_by: [asc: m.inserted_at, asc: m.id])
        |> Repo.all()
      else
        from(m in base, order_by: [asc: m.inserted_at, asc: m.id])
        |> Repo.all()
      end

    result = Enum.map(messages, &message_to_map/1)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call({:save_handoff, conversation_id, content}, _from, state) do
    %Handoff{}
    |> Handoff.changeset(%{conversation_id: conversation_id, content: content})
    |> Repo.insert!()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_latest_handoff, conversation_id}, _from, state) do
    result =
      from(h in Handoff,
        where: h.conversation_id == ^conversation_id,
        order_by: [desc: h.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        handoff -> {:ok, handoff.content}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:save_summary, conversation_id, content}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Summary, conversation_id: conversation_id) do
      nil ->
        %Summary{}
        |> Summary.changeset(%{conversation_id: conversation_id, content: content})
        |> Repo.insert!()

      existing ->
        existing
        |> Summary.changeset(%{content: content, updated_at: now})
        |> Repo.update!()
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_summaries, _from, state) do
    summaries =
      from(s in Summary, order_by: [desc: s.updated_at])
      |> Repo.all()
      |> Enum.map(&summary_to_map/1)

    {:reply, {:ok, summaries}, state}
  end

  # --- Private ---

  defp epoch_to_map(%Epoch{} = e) do
    %{
      conversation_id: e.conversation_id,
      status: e.status,
      system_prompt: e.system_prompt,
      turn_count: e.turn_count,
      saturation: e.saturation,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end

  defp message_to_map(%Message{} = m) do
    %{role: String.to_existing_atom(m.role), content: m.content}
  end

  defp message_to_map(%{role: role, content: content}) do
    %{role: String.to_existing_atom(to_string(role)), content: content}
  end

  defp summary_to_map(%Summary{} = s) do
    %{
      conversation_id: s.conversation_id,
      content: s.content,
      updated_at: s.updated_at
    }
  end
end
