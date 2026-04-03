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
  - **Handoffs** — stored as a text field on the epoch row
  - **Summaries** — cross-conversation awareness cache
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Cranium.Store.{Repo, Epoch, Message, Summary}

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

  @spec create_epoch(String.t(), map()) :: {:ok, String.t()}
  def create_epoch(conversation_id, attrs \\ %{}) do
    GenServer.call(__MODULE__, {:create_epoch, conversation_id, attrs})
  end

  @spec update_epoch(String.t(), map()) :: :ok
  def update_epoch(epoch_id, attrs) do
    GenServer.call(__MODULE__, {:update_epoch, epoch_id, attrs})
  end

  # Message operations

  @spec append_message(String.t(), String.t(), map()) :: :ok
  def append_message(conversation_id, epoch_id, message) do
    GenServer.call(__MODULE__, {:append_message, conversation_id, epoch_id, message})
  end

  @spec get_messages(String.t(), keyword()) :: {:ok, [map()]}
  def get_messages(conversation_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_messages, conversation_id, opts})
  end

  # Handoff operations

  @spec save_handoff(String.t(), String.t()) :: :ok
  def save_handoff(epoch_id, content) do
    GenServer.call(__MODULE__, {:save_handoff, epoch_id, content})
  end

  @spec get_latest_handoff(String.t()) :: {:ok, String.t()} | :not_found
  def get_latest_handoff(conversation_id) do
    GenServer.call(__MODULE__, {:get_latest_handoff, conversation_id})
  end

  @doc """
  Eagerly persist the CC session ID for a conversation's active epoch.

  Called mid-inference by the Agent so a process restart doesn't lose
  the session ID (which would cause CC to start a fresh session with
  no conversation history).
  """
  @spec update_epoch_session(String.t(), String.t()) :: :ok
  def update_epoch_session(conversation_id, session_id) do
    GenServer.call(__MODULE__, {:update_epoch_session, conversation_id, session_id})
  end

  @doc """
  Clear the active epoch for a conversation directly in the DB.

  Used when no Epoch GenServer is running (e.g., after a service restart).
  Marks the current epoch as cleared and creates a fresh one. Skips handoff
  generation since there's no running session to summarize.

  Returns `{:ok, new_epoch_id}` or `:not_found`.
  """
  @spec clear_epoch(String.t()) :: {:ok, String.t()} | :not_found
  def clear_epoch(conversation_id) do
    GenServer.call(__MODULE__, {:clear_epoch, conversation_id})
  end

  @doc """
  Get the injection context for a conversation's active epoch.

  Returns the fields TurnInjector needs: saturation, last_reminder_bucket,
  last_landscape_at, interrupted_context. Also includes epoch_id, turn_count,
  and cc_session_id for TurnAssembler's broader context assembly needs.

  Returns :not_found if no active epoch exists.
  """
  @spec get_injection_context(String.t()) :: {:ok, map()} | :not_found
  def get_injection_context(conversation_id) do
    GenServer.call(__MODULE__, {:get_injection_context, conversation_id})
  end

  @doc """
  Get or create the active epoch for a conversation, returning injection context.

  Like `get_injection_context/1` but creates a fresh epoch if none exists.
  Used by TurnAssembler for epoch resolution without needing an Epoch GenServer.
  """
  @spec get_or_create_epoch(String.t()) :: {:ok, map()}
  def get_or_create_epoch(conversation_id) do
    GenServer.call(__MODULE__, {:get_or_create_epoch, conversation_id})
  end

  # Message timestamp queries

  @spec get_last_message_at(String.t()) :: {:ok, DateTime.t()} | :not_found
  def get_last_message_at(epoch_id) do
    GenServer.call(__MODULE__, {:get_last_message_at, epoch_id})
  end

  # Summary operations

  @spec save_summary(String.t(), String.t()) :: :ok
  def save_summary(conversation_id, content) do
    GenServer.call(__MODULE__, {:save_summary, conversation_id, content})
  end

  @spec get_all_summaries() :: {:ok, [map()]} | {:error, term()}
  def get_all_summaries do
    GenServer.call(__MODULE__, :get_all_summaries)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_opts) do
    Logger.info("Store started", stage: :store)
    {:ok, %__MODULE__{}}
  end

  # All handle_call clauses route through a rescue wrapper so that
  # transient Repo errors (or Ecto sandbox teardown in tests) never
  # crash this GenServer — which would cascade via rest_for_one and
  # take down Manifest, Egress, and everything downstream.

  @impl true
  def handle_call(request, from, state) do
    try do
      do_handle_call(request, from, state)
    rescue
      e ->
        Logger.error("Store operation failed: #{Exception.message(e)}", stage: :store)
        {:reply, {:error, :db_error}, state}
    catch
      :exit, reason ->
        Logger.error("Store operation exit: #{inspect(reason)}", stage: :store)
        {:reply, {:error, :db_error}, state}
    end
  end

  defp do_handle_call({:get_epoch, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        epoch -> {:ok, epoch_to_map(epoch)}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:create_epoch, conversation_id, attrs}, _from, state) do
    epoch =
      %Epoch{}
      |> Epoch.changeset(Map.put(attrs, :conversation_id, conversation_id))
      |> Repo.insert!()

    {:reply, {:ok, epoch.id}, state}
  end

  defp do_handle_call({:update_epoch, epoch_id, attrs}, _from, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.get!(Epoch, epoch_id)
    |> Epoch.changeset(Map.put(attrs, :updated_at, now))
    |> Repo.update!()

    {:reply, :ok, state}
  end

  defp do_handle_call({:append_message, conversation_id, epoch_id, message}, _from, state) do
    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation_id,
      epoch_id: epoch_id,
      role: to_string(message[:role] || "user"),
      content: message[:content] || "",
      origin: message[:origin]
    })
    |> Repo.insert!()

    {:reply, :ok, state}
  end

  defp do_handle_call({:get_messages, conversation_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit)
    epoch_id = Keyword.get(opts, :epoch_id)

    base = from(m in Message, where: m.conversation_id == ^conversation_id)

    base =
      case epoch_id do
        id when is_binary(id) -> from(m in base, where: m.epoch_id == ^id)
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

  defp do_handle_call({:save_handoff, epoch_id, content}, _from, state) do
    Repo.get!(Epoch, epoch_id)
    |> Epoch.changeset(%{handoff: content})
    |> Repo.update!()

    {:reply, :ok, state}
  end

  defp do_handle_call({:get_latest_handoff, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and not is_nil(e.handoff),
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        epoch -> {:ok, epoch.handoff}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:update_epoch_session, conversation_id, session_id}, _from, state) do
    from(e in Epoch,
      where: e.conversation_id == ^conversation_id and e.status != "cleared",
      order_by: [desc: e.inserted_at],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil ->
        :ok

      epoch ->
        epoch
        |> Epoch.changeset(%{cc_session_id: session_id})
        |> Repo.update!()
    end

    {:reply, :ok, state}
  end

  defp do_handle_call({:get_injection_context, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil ->
          :not_found

        epoch ->
          # Get last_invoked_at from most recent message in this epoch
          last_invoked_at =
            from(m in Message,
              where: m.epoch_id == ^epoch.id,
              select: max(m.inserted_at)
            )
            |> Repo.one()

          {:ok,
           %{
             epoch_id: epoch.id,
             turn_count: epoch.turn_count || 0,
             saturation: (epoch.saturation || 0.0) * 100,
             last_reminder_bucket: epoch.last_reminder_bucket || 0,
             last_landscape_at: epoch.last_landscape_at,
             interrupted_context: epoch.interrupted_context,
             cc_session_id: epoch.cc_session_id,
             last_invoked_at: last_invoked_at
           }}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:get_or_create_epoch, conversation_id}, _from, state) do
    epoch =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()

    epoch =
      case epoch do
        nil ->
          %Epoch{}
          |> Epoch.changeset(%{conversation_id: conversation_id})
          |> Repo.insert!()

        existing ->
          existing
      end

    last_invoked_at =
      from(m in Message,
        where: m.epoch_id == ^epoch.id,
        select: max(m.inserted_at)
      )
      |> Repo.one()

    result =
      {:ok,
       %{
         epoch_id: epoch.id,
         turn_count: epoch.turn_count || 0,
         saturation: (epoch.saturation || 0.0) * 100,
         last_reminder_bucket: epoch.last_reminder_bucket || 0,
         last_landscape_at: epoch.last_landscape_at,
         interrupted_context: epoch.interrupted_context,
         cc_session_id: epoch.cc_session_id,
         last_invoked_at: last_invoked_at
       }}

    {:reply, result, state}
  end

  defp do_handle_call({:get_last_message_at, epoch_id}, _from, state) do
    result =
      from(m in Message,
        where: m.epoch_id == ^epoch_id,
        select: max(m.inserted_at)
      )
      |> Repo.one()
      |> case do
        nil -> :not_found
        ts -> {:ok, ts}
      end

    {:reply, result, state}
  end

  defp do_handle_call({:save_summary, conversation_id, content}, _from, state) do
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

  defp do_handle_call(:get_all_summaries, _from, state) do
    summaries =
      from(s in Summary, order_by: [desc: s.updated_at])
      |> Repo.all()
      |> Enum.map(&summary_to_map/1)

    {:reply, {:ok, summaries}, state}
  end

  defp do_handle_call({:clear_epoch, conversation_id}, _from, state) do
    result =
      from(e in Epoch,
        where: e.conversation_id == ^conversation_id and e.status != "cleared",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
      |> Repo.one()
      |> case do
        nil ->
          :not_found

        epoch ->
          epoch
          |> Epoch.changeset(%{status: "cleared"})
          |> Repo.update!()

          new_epoch =
            %Epoch{}
            |> Epoch.changeset(%{conversation_id: conversation_id})
            |> Repo.insert!()

          {:ok, new_epoch.id}
      end

    {:reply, result, state}
  end

  # --- Private ---

  defp epoch_to_map(%Epoch{} = e) do
    %{
      id: e.id,
      conversation_id: e.conversation_id,
      status: e.status,
      system_prompt: e.system_prompt,
      turn_count: e.turn_count,
      saturation: e.saturation,
      handoff: e.handoff,
      last_reminder_bucket: e.last_reminder_bucket,
      cc_session_id: e.cc_session_id,
      last_landscape_at: e.last_landscape_at,
      interrupted_context: e.interrupted_context,
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
